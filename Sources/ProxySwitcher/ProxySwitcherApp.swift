import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only agent: no Dock icon, no main window on launch.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct ProxySwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Proxy Switcher", systemImage: menuIcon) {
            MenuView(model: model)
        }

        Window("Proxy Switcher Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }

    /// Globe with a slash when proxy is off / no rule; solid globe when active.
    private var menuIcon: String {
        model.activeProfile != nil ? "globe.badge.chevron.backward" : "globe"
    }
}
