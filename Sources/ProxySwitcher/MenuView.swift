import SwiftUI

/// The content shown when clicking the menu bar icon.
struct MenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Current state.
        Text(model.statusLine)

        if let ssid = model.currentSSID {
            Text("Wi-Fi: \(ssid)")
        } else if let m = model.activeProfile {
            // SSID unreadable, but we matched a rule by reaching its proxy.
            Text("Wi-Fi: (name unavailable) — matched \(m.ssid) by reachability")
        } else if !model.locationAuthorized {
            Text("⚠︎ Location permission needed to read Wi-Fi name")
        } else {
            Text("Wi-Fi: not connected")
        }

        if let err = model.lastError {
            Text("Error: \(err)")
        }

        Divider()

        // List of rules, with a checkmark on the one matching the current SSID.
        if model.profiles.isEmpty {
            Text("No rules yet — open Settings to add one")
        } else {
            ForEach(model.profiles) { p in
                let active = (p.id == model.activeProfile?.id)
                Text("\(active ? "✓ " : "   ")\(p.ssid) → \(p.summary)\(p.enabled ? "" : " (disabled)")")
            }
        }

        Divider()

        Button("Apply Now") { model.forceReapply() }
            .keyboardShortcut("r")

        Button("Turn Proxy Off Now (emergency)") { model.disableNow() }
            .keyboardShortcut("d")

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")

        Toggle("Launch at Login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Divider()

        Button("Quit Proxy Switcher") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
