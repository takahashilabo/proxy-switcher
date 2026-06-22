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

    /// The SSID we last applied settings for, so we don't re-apply (and re-prompt
    /// for admin) on every poll tick.
    private var lastAppliedSSID: String??  = .none
    private var applyGeneration = 0

    // MARK: Tunnel watchdog state
    /// Whether we currently have the TUN tunnel running.
    private var tunnelStarted = false
    /// Consecutive failed connectivity probes while the tunnel is up.
    private var probeFailures = 0
    /// Set when the watchdog has emergency-stopped the tunnel because the network
    /// went away. Prevents restarting it until real connectivity returns.
    private var backedOff = false
    private var watchdog: Timer?

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

        // Initial evaluation.
        handleSSID(monitor.currentSSID())

        // Safety watchdog: if the tunnel is up but the internet is gone (e.g. we
        // left the tethering network without the SSID change being detected),
        // stop the tunnel so the machine isn't stranded with no connectivity.
        let w = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
        RunLoop.main.add(w, forMode: .common)
        watchdog = w
    }

    // MARK: - Tunnel watchdog

    private func watchdogTick() {
        // While backed off, keep probing; once the internet is back, re-evaluate.
        if backedOff {
            Task.detached {
                let ok = await Self.probeInternet()
                await MainActor.run {
                    guard self.backedOff, ok else { return }
                    self.backedOff = false
                    self.probeFailures = 0
                    self.forceReapply()
                }
            }
            return
        }

        guard tunnelStarted else { probeFailures = 0; return }
        Task.detached {
            let ok = await Self.probeInternet()
            await MainActor.run {
                guard self.tunnelStarted, !self.backedOff else { return }
                if ok {
                    self.probeFailures = 0
                } else {
                    self.probeFailures += 1
                    if self.probeFailures >= 2 { self.emergencyStopTunnel() }
                }
            }
        }
    }

    /// Stop the tunnel and clear the system proxy to restore direct connectivity.
    private func emergencyStopTunnel() {
        probeFailures = 0
        tunnelStarted = false
        backedOff = true
        lastError = "接続が失われたためトンネルを自動停止しました"
        statusLine = "tunnel auto-stopped (no connectivity)"
        // Don't let normal apply re-engage until the network actually changes.
        lastAppliedSSID = .some(currentSSID)
        let tunnel = self.tunnel
        let proxy = self.proxy
        let iface = monitor.interfaceName
        Task.detached {
            try? tunnel.stop()
            try? proxy.apply(profile: nil, interface: iface)
        }
    }

    /// Quick reachability check (~4s). Returns true if the internet is reachable
    /// over whatever the current routing is.
    nonisolated private static func probeInternet() async -> Bool {
        var req = URLRequest(url: URL(string: "http://captive.apple.com/hotspot-detect.html")!)
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Profiles

    func saveProfiles() {
        store.save(profiles)
        // Re-evaluate in case the rule for the current network changed.
        forceReapply()
    }

    func profile(forSSID ssid: String?) -> ProxyProfile? {
        guard let ssid else { return nil }
        return profiles.first { $0.enabled && $0.ssid == ssid }
    }

    var activeProfile: ProxyProfile? { profile(forSSID: currentSSID) }

    // MARK: - SSID handling

    private func handleSSID(_ ssid: String?) {
        currentSSID = ssid
        locationAuthorized = (location.authorizationStatus == .authorizedAlways
                              || location.authorizationStatus == .authorized)

        // Only act when the SSID actually changed.
        if case .some(let last) = lastAppliedSSID, last == ssid { return }
        apply(forSSID: ssid)
    }

    /// Re-apply regardless of whether the SSID changed (used after editing rules
    /// or when the user picks "Apply now").
    func forceReapply() {
        lastAppliedSSID = .none
        apply(forSSID: currentSSID)
    }

    private func apply(forSSID ssid: String?) {
        // A real (re)apply means the situation changed — clear any back-off.
        backedOff = false
        probeFailures = 0

        let match = profile(forSSID: ssid)
        let iface = monitor.interfaceName
        lastAppliedSSID = .some(ssid)

        applyGeneration += 1
        let generation = applyGeneration

        let netLabel = ssid ?? "no Wi-Fi"
        statusLine = "Applying \(match?.summary ?? "Off") for \(netLabel)…"

        let proxy = self.proxy
        let singbox = self.singbox
        let tunnel = self.tunnel
        let wantTunnel = (match.map { $0.useTunnel && SingBoxConfigWriter.supportsTunnel($0) }) ?? false
        Task.detached(priority: .userInitiated) {
            do {
                try proxy.apply(profile: match, interface: iface)

                // Full-tunnel mode for apps that ignore the system proxy.
                var tunnelNote = ""
                var started = false
                if wantTunnel, let m = match {
                    singbox.write(profile: m)
                    do { try tunnel.start(); started = true }
                    catch { tunnelNote = " (tunnel: \(error))" }
                } else {
                    try? tunnel.stop()
                }

                let note = tunnelNote
                let didStart = started
                await MainActor.run {
                    guard generation == self.applyGeneration else { return }
                    self.tunnelStarted = didStart
                    self.probeFailures = 0
                    if let match {
                        self.statusLine = "\(netLabel): \(match.summary)\(wantTunnel ? " +tunnel" : "")\(note)"
                    } else {
                        self.statusLine = "\(netLabel): proxy off"
                    }
                    self.lastError = note.isEmpty ? nil : String(note.dropFirst())
                }
            } catch {
                await MainActor.run {
                    guard generation == self.applyGeneration else { return }
                    self.lastError = "\(error)"
                    self.statusLine = "\(netLabel): error"
                    // Allow another attempt next time.
                    self.lastAppliedSSID = .none
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
