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

    /// The SSID we last applied settings for, so we don't re-apply (and re-prompt
    /// for admin) on every poll tick.
    private var lastAppliedSSID: String??  = .none
    private var applyGeneration = 0

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

        // Initial evaluation.
        handleSSID(monitor.currentSSID())
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
        let match = profile(forSSID: ssid)
        let iface = monitor.interfaceName
        lastAppliedSSID = .some(ssid)

        applyGeneration += 1
        let generation = applyGeneration

        let netLabel = ssid ?? "no Wi-Fi"
        statusLine = "Applying \(match?.summary ?? "Off") for \(netLabel)…"

        let proxy = self.proxy
        Task.detached(priority: .userInitiated) {
            do {
                try proxy.apply(profile: match, interface: iface)
                await MainActor.run {
                    guard generation == self.applyGeneration else { return }
                    if let match {
                        self.statusLine = "\(netLabel): \(match.summary)"
                    } else {
                        self.statusLine = "\(netLabel): proxy off"
                    }
                    self.lastError = nil
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
