import Foundation
import CoreWLAN

/// Watches for Wi-Fi SSID changes.
///
/// Uses CoreWLAN's event monitor for instant notification, plus a slow timer
/// as a safety net (events can be missed when waking from sleep, etc.).
final class WiFiMonitor: NSObject, CWEventDelegate {
    private let client = CWWiFiClient.shared()
    private var timer: Timer?

    /// Called whenever the SSID may have changed. Always dispatched on main.
    var onChange: ((String?) -> Void)?

    /// The interface name backing Wi-Fi, e.g. "en0".
    var interfaceName: String? { client.interface()?.interfaceName }

    /// The currently associated SSID, or nil if not on Wi-Fi (or no location permission).
    func currentSSID() -> String? {
        let ssid = client.interface()?.ssid()
        if let ssid, !ssid.isEmpty { return ssid }
        return nil
    }

    func start() {
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
        try? client.startMonitoringEvent(with: .linkDidChange)

        // Safety-net poll every 8 seconds.
        let t = Timer(timeInterval: 8.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fire()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    private func fire() {
        let ssid = currentSSID()
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(ssid)
        }
    }

    // MARK: CWEventDelegate

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        fire()
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        fire()
    }
}
