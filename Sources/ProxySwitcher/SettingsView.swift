import SwiftUI

/// The window for adding / editing / removing SSID → proxy rules.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection: ProxyProfile.ID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.profiles) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.ssid.isEmpty ? "(new rule)" : p.ssid)
                            .font(.headline)
                            .foregroundStyle(p.enabled ? .primary : .secondary)
                        Text(p.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(p.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { remove(id: p.id) }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { model.profiles[$0].id }
                    ids.forEach { remove(id: $0) }
                }
                .onMove { from, to in
                    model.profiles.move(fromOffsets: from, toOffset: to)
                    model.saveProfiles()
                }
            }
            .onDeleteCommand(perform: removeSelected)
            .frame(minWidth: 220)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(action: { addProfile() }) { Image(systemName: "plus") }
                    Button(action: removeSelected) { Image(systemName: "minus") }
                        .disabled(selection == nil)
                    Spacer()
                }
                .padding(8)
                .buttonStyle(.borderless)
            }
        } detail: {
            if let id = selection,
               let index = model.profiles.firstIndex(where: { $0.id == id }) {
                ProfileEditor(profile: $model.profiles[index], onChange: model.saveProfiles)
                    .id(id)
            } else {
                ContentUnavailableView("Select or add a rule",
                                       systemImage: "wifi",
                                       description: Text("Each rule maps a Wi-Fi network name to a proxy setting."))
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle("Proxy Switcher")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if let ssid = model.currentSSID {
                    Button("Use current: \(ssid)") { addProfile(ssid: ssid) }
                }
            }
        }
    }

    private func addProfile(ssid: String = "") {
        var p = ProxyProfile()
        p.ssid = ssid
        model.profiles.append(p)
        selection = p.id
        model.saveProfiles()
    }

    private func removeSelected() {
        guard let id = selection else { return }
        remove(id: id)
    }

    private func remove(id: ProxyProfile.ID) {
        model.profiles.removeAll { $0.id == id }
        if selection == id { selection = nil }
        model.saveProfiles()
    }
}

/// The right-hand editor for a single rule.
private struct ProfileEditor: View {
    @Binding var profile: ProxyProfile
    var onChange: () -> Void

    var body: some View {
        Form {
            Section("Network") {
                TextField("Wi-Fi name (SSID)", text: $profile.ssid)
                Toggle("Rule enabled", isOn: $profile.enabled)
            }

            Section("Proxy") {
                Picker("Type", selection: $profile.type) {
                    ForEach(ProxyType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }

                if profile.type.needsHostPort {
                    TextField("Host", text: $profile.host)
                    TextField("Port", value: $profile.port, format: .number.grouping(.never))
                    TextField("Username (optional)", text: $profile.username)
                    SecureField("Password (optional)", text: $profile.password)
                }

                if profile.type.needsPAC {
                    TextField("PAC URL (http://…/proxy.pac)", text: $profile.pacURL)
                }

                if profile.type == .off {
                    Text("Proxy will be turned off on this network.")
                        .foregroundStyle(.secondary)
                }
            }

            if profile.type == .socks || profile.type == .http || profile.type == .https {
                Section("Full tunnel (advanced)") {
                    Toggle("Route ALL apps through proxy (TUN tunnel)", isOn: $profile.useTunnel)
                    Text("Forces every app — even ones that ignore the system proxy, like LINE — through the proxy using sing-box. Requires a one-time install: `sudo ./install_tunnel_helper.sh`. Needs admin to set up the virtual network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: profile) { _, _ in onChange() }
    }
}
