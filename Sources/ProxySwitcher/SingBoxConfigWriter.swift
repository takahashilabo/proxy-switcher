import Foundation

/// Generates a sing-box config that builds a TUN tunnel forwarding *all* system
/// traffic to the rule's proxy. Used for apps that ignore the system proxy.
///
/// The helper script (`/usr/local/bin/proxy-tunnel`) runs sing-box as root with
/// the file this writer produces.
struct SingBoxConfigWriter {
    private let fileURL: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/sing-box", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Must match CONF in install_tunnel_helper.sh.
        self.fileURL = dir.appendingPathComponent("proxy-switcher.json")
    }

    var path: String { fileURL.path }

    /// True if this profile can be tunneled (SOCKS or HTTP upstream).
    static func supportsTunnel(_ p: ProxyProfile) -> Bool {
        p.enabled && (p.type == .socks || p.type == .http || p.type == .https)
    }

    /// Write the config for the given profile. Returns false if not tunnelable.
    @discardableResult
    func write(profile: ProxyProfile) -> Bool {
        guard Self.supportsTunnel(profile) else { return false }

        var outbound: [String: Any] = [
            "type": profile.type == .socks ? "socks" : "http",
            "tag": "proxy",
            "server": profile.host,
            "server_port": profile.port,
        ]
        if profile.type == .socks { outbound["version"] = "5" }
        if !profile.username.isEmpty {
            outbound["username"] = profile.username
            outbound["password"] = profile.password
        }

        var routeRules: [[String: Any]] = [
            ["action": "sniff"],
            // Capture DNS and resolve it through the proxy over TCP. Many
            // tethering SOCKS proxies don't pass UDP, so plain UDP/53 fails —
            // hijacking sends lookups to sing-box's DNS (TCP via the proxy).
            ["protocol": "dns", "action": "hijack-dns"],
            // Reject QUIC (UDP/443). The SOCKS proxy can't relay UDP, so QUIC
            // would silently hang; rejecting it makes apps (Apple Music, LINE,
            // browsers) fall back to TCP/HTTPS, which does work through SOCKS.
            ["network": "udp", "port": 443, "action": "reject"],
        ]
        // Reach the proxy server itself directly (avoid a routing loop). Only
        // valid as a CIDR when the host is a literal IPv4 address.
        if isIPv4(profile.host) {
            routeRules.append(["ip_cidr": ["\(profile.host)/32"], "outbound": "direct"])
        }

        let config: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "dns": [
                "servers": [
                    ["tag": "remote", "type": "tcp", "server": "1.1.1.1", "detour": "proxy"]
                ],
                "final": "remote",
                "strategy": "ipv4_only",
            ],
            "inbounds": [[
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.18.0.1/30"],
                "auto_route": true,
                "strict_route": true,
                // Small MTU avoids PMTU blackholes over a tethered proxy link,
                // which otherwise stall large/streaming transfers (Apple Music,
                // Claude streaming, LINE media) while small requests still work.
                "mtu": 1280,
                "stack": "gvisor",
            ]],
            "outbounds": [
                outbound,
                ["type": "direct", "tag": "direct"],
            ],
            "route": [
                "rules": routeRules,
                "final": "proxy",
                "auto_detect_interface": true,
            ],
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        try? data.write(to: fileURL, options: .atomic)
        return true
    }

    private func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }
    }
}
