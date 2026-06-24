import Foundation
import SwiftUI
import CoreLocation
import ServiceManagement

/// Central state: holds profiles, watches Wi-Fi, applies proxy on change.
@MainActor
final class AppModel: NSObject, ObservableObject {
    @Published var profiles: [ProxyProfile] = []
    @Published var currentSSID: String?
    @Published var statusLine: String = "Starting…"
    @Published var lastError: String?
    @Published var launchAtLogin: Bool = false
    @Published var locationAuthorized: Bool = false

    private let store = ProfileStore()
    private let monitor = WiFiMonitor()
    private let proxy = ProxyManager()
    private let location = CLLocationManager()
    private let singbox = SingBoxConfigWriter()
    private let tunnel = TunnelManager()

    /// The match we last applied, keyed by profile id (.some(nil) = "proxy off"),
    /// so we only re-apply (and re-touch the tunnel) when the effective rule
    /// actually changes — not on every poll tick.
    private var lastAppliedKey: UUID?? = .none
    private var applyGeneration = 0

    /// The profile whose proxy endpoint is currently TCP-reachable on the LAN.
    /// This is the robust matching signal for tethering rules (e.g. NetShare),
    /// independent of whether macOS lets us read the Wi-Fi name. Updated by the
    /// async reachability probe.
    private var reachableProfileID: UUID?
    /// True once the reachability probe has completed since the last network
    /// change, so we never flip the proxy "off" before we've actually probed.
    private var probedSinceChange = false
    /// Set by the emergency "Turn Proxy Off Now" override. While set, auto-apply
    /// is suppressed so the proxy stays off — until the network actually changes
    /// (or the user picks "Apply Now").
    private var suppressed = false

    // MARK: Tunnel state
    /// Whether we currently have the TUN tunnel running.
    private var tunnelStarted = false

    var profilesPath: String { store.path }

    override init() {
        super.init()
        profiles = store.load()
        refreshLoginItemState()

        location.delegate = self
        locationAuthorized = (location.authorizationStatus == .authorizedAlways
                              || location.authorizationStatus == .authorized)

        monitor.onChange = { [weak self] ssid in
            self?.handleSSID(ssid)
        }
        monitor.start()

        // Reading the SSID requires Location permission on modern macOS.
        location.requestWhenInUseAuthorization()

        // Tear down the tunnel on quit so connectivity isn't stranded.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [tunnel] _ in
            try? tunnel.stop()
        }

        ActivityLog.shared.log("=== launched; \(profiles.count) rule(s); location=\(locationAuthorized) ===")

        // Initial evaluation. The WiFiMonitor's safety-net poll (every 8s) keeps
        // re-driving this, which also re-runs the reachability probe — that's our
        // ongoing safety net: if we leave a tethering network the probe goes
        // unreachable and the tunnel/proxy is torn down. It never reacts to mere
        // packet loss, only to the proxy endpoint becoming unreachable.
        handleSSID(monitor.currentSSID())
    }

    // MARK: - Profiles

    func saveProfiles() {
        store.save(profiles)
        // Re-evaluate in case the rule for the current network changed.
        forceReapply()
    }

    /// The rule that applies right now. A rule matches when its SSID equals the
    /// current Wi-Fi name, OR — more robustly — when its proxy endpoint is
    /// directly reachable on the LAN. The reachability fallback lets a tethering
    /// rule (e.g. NetShare at 192.168.49.1:8282) engage even when macOS won't
    /// surrender the Wi-Fi name, which is the usual reason auto-switching
    /// silently did nothing.
    func currentMatch() -> ProxyProfile? {
        if let ssid = currentSSID,
           let m = profiles.first(where: { $0.enabled && $0.ssid == ssid }) {
            return m
        }
        if let rid = reachableProfileID,
           let m = profiles.first(where: { $0.id == rid && $0.enabled }) {
            return m
        }
        return nil
    }

    var activeProfile: ProxyProfile? { currentMatch() }

    // MARK: - SSID handling

    private func handleSSID(_ ssid: String?) {
        let changed = (currentSSID != ssid)
        if changed {
            ActivityLog.shared.log("wifi name: \(currentSSID ?? "nil") → \(ssid ?? "nil")")
            suppressed = false
        }
        currentSSID = ssid
        locationAuthorized = (location.authorizationStatus == .authorizedAlways
                              || location.authorizationStatus == .authorized)
        // A genuine network change: re-probe before we'd consider turning off.
        if changed { probedSinceChange = false }
        refreshReachability()
    }

    /// Re-check which rule's proxy is on the physically-connected link, then
    /// re-evaluate. This inspects the Wi-Fi interface's own address (a fast,
    /// local syscall that the TUN tunnel cannot fake), so it's synchronous and
    /// race-free — and, crucially, never fooled by our own tunnel into thinking
    /// a left-behind network is still reachable.
    private func refreshReachability() {
        let iface = monitor.interfaceName
        let prev = reachableProfileID
        reachableProfileID = profiles.first {
            $0.enabled && $0.type.needsHostPort && Self.isIPv4($0.host)
                && LinkProbe.hostOnLocalSubnet($0.host, interface: iface)
        }?.id
        probedSinceChange = true

        if reachableProfileID != prev {
            let name = reachableProfileID
                .flatMap { id in profiles.first { $0.id == id }?.ssid } ?? "none"
            ActivityLog.shared.log("on-link proxy → \(name)")
            suppressed = false
        }
        evaluate()
    }

    /// Apply the current match if it differs from what's already applied.
    private func evaluate() {
        // Emergency override active: stay off until the network changes.
        if suppressed { return }
        let match = currentMatch()
        // Don't flip the proxy off until we've actually probed reachability.
        if match == nil && !probedSinceChange { return }
        let key: UUID? = match?.id
        if case .some(let last) = lastAppliedKey, last == key { return }
        apply(match)
    }

    /// Re-apply unconditionally (used after editing rules or "Apply Now").
    func forceReapply() {
        suppressed = false
        lastAppliedKey = .none
        probedSinceChange = false
        refreshReachability()
    }

    /// Emergency override: immediately clear the proxy and stop the tunnel,
    /// restoring the direct route. Works with no network (menu bar only), so it
    /// rescues a stranded machine if a network change was ever missed. Stays off
    /// until the network changes or the user picks "Apply Now".
    func disableNow() {
        ActivityLog.shared.log("MANUAL disable requested")
        suppressed = true
        lastAppliedKey = .some(nil)
        applyGeneration += 1
        statusLine = "Disabling…"
        let proxy = self.proxy
        let tunnel = self.tunnel
        let iface = monitor.interfaceName
        Task.detached(priority: .userInitiated) {
            try? proxy.apply(profile: nil, interface: iface)
            try? tunnel.stop()
            ActivityLog.shared.log("MANUAL disable done (proxy off, tunnel stopped)")
            await MainActor.run {
                self.tunnelStarted = false
                self.statusLine = "Proxy off (manual override)"
                self.lastError = nil
            }
        }
    }

    private func apply(_ match: ProxyProfile?) {
        let iface = monitor.interfaceName
        lastAppliedKey = .some(match?.id)

        applyGeneration += 1
        let generation = applyGeneration

        let netLabel = currentSSID ?? match?.ssid ?? "no Wi-Fi"
        statusLine = "Applying \(match?.summary ?? "Off") for \(netLabel)…"

        let proxy = self.proxy
        let singbox = self.singbox
        let tunnel = self.tunnel
        let wantTunnel = (match.map { $0.useTunnel && SingBoxConfigWriter.supportsTunnel($0) }) ?? false
        ActivityLog.shared.log("APPLY \(match?.summary ?? "OFF")\(wantTunnel ? " +tunnel" : "") for \(netLabel)")
        Task.detached(priority: .userInitiated) {
            do {
                try proxy.apply(profile: match, interface: iface)

                // Full-tunnel mode for apps that ignore the system proxy.
                var tunnelNote = ""
                var started = false
                if wantTunnel, let m = match {
                    singbox.write(profile: m)
                    do { try tunnel.start(); started = true; ActivityLog.shared.log("tunnel started") }
                    catch { tunnelNote = " (tunnel: \(error))"; ActivityLog.shared.log("tunnel start FAILED: \(error)") }
                } else {
                    try? tunnel.stop()
                    ActivityLog.shared.log("tunnel stopped")
                }

                let note = tunnelNote
                let didStart = started
                await MainActor.run {
                    guard generation == self.applyGeneration else { return }
                    self.tunnelStarted = didStart
                    if let match {
                        self.statusLine = "\(netLabel): \(match.summary)\(wantTunnel ? " +tunnel" : "")\(note)"
                    } else {
                        self.statusLine = "\(netLabel): proxy off"
                    }
                    self.lastError = note.isEmpty ? nil : String(note.dropFirst())
                }
            } catch {
                ActivityLog.shared.log("APPLY ERROR: \(error)")
                await MainActor.run {
                    guard generation == self.applyGeneration else { return }
                    self.lastError = "\(error)"
                    self.statusLine = "\(netLabel): error"
                    // Allow another attempt next time.
                    self.lastAppliedKey = .none
                }
            }
        }
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "Login item: \(error.localizedDescription)"
        }
        refreshLoginItemState()
    }

    private func refreshLoginItemState() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    /// True if the string is a literal IPv4 address (so it's probe-able and safe
    /// to treat as a fixed LAN endpoint).
    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }
    }
}

// MARK: - CLLocationManagerDelegate

extension AppModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.locationAuthorized = (manager.authorizationStatus == .authorizedAlways
                                       || manager.authorizationStatus == .authorized)
            // Once granted, the SSID becomes readable — re-evaluate.
            if self.locationAuthorized {
                self.forceReapply()
            }
        }
    }
}
