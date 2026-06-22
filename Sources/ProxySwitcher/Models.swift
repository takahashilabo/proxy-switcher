import Foundation

/// The kind of proxy to apply for a given Wi-Fi network.
enum ProxyType: String, Codable, CaseIterable, Identifiable {
    case off
    case http
    case https
    case socks
    case pac

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:   return "Off"
        case .http:  return "HTTP (Web)"
        case .https: return "HTTPS (Secure Web)"
        case .socks: return "SOCKS"
        case .pac:   return "Auto (PAC URL)"
        }
    }

    /// Whether this type needs a host + port.
    var needsHostPort: Bool {
        self == .http || self == .https || self == .socks
    }

    /// Whether this type needs a PAC URL.
    var needsPAC: Bool { self == .pac }
}

/// One rule: "when connected to <ssid>, apply <proxy>".
struct ProxyProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var ssid: String = ""
    var type: ProxyType = .socks
    var host: String = ""
    var port: Int = 8080
    var pacURL: String = ""
    var username: String = ""
    var password: String = ""
    /// If false the rule is ignored (network falls back to "Off").
    var enabled: Bool = true
    /// Route *all* traffic through the proxy via a TUN tunnel (sing-box), so
    /// even apps that ignore the system proxy (e.g. LINE) work. SOCKS/HTTP only.
    var useTunnel: Bool = false

    init() {}

    /// Tolerant decoding so older profiles.json files (missing newer fields)
    /// still load, falling back to sensible defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decodeIfPresent(UUID.self,      forKey: .id)        ?? UUID()
        ssid      = try c.decodeIfPresent(String.self,    forKey: .ssid)      ?? ""
        type      = try c.decodeIfPresent(ProxyType.self, forKey: .type)      ?? .socks
        host      = try c.decodeIfPresent(String.self,    forKey: .host)      ?? ""
        port      = try c.decodeIfPresent(Int.self,       forKey: .port)      ?? 8080
        pacURL    = try c.decodeIfPresent(String.self,    forKey: .pacURL)    ?? ""
        username  = try c.decodeIfPresent(String.self,    forKey: .username)  ?? ""
        password  = try c.decodeIfPresent(String.self,    forKey: .password)  ?? ""
        enabled   = try c.decodeIfPresent(Bool.self,      forKey: .enabled)   ?? true
        useTunnel = try c.decodeIfPresent(Bool.self,      forKey: .useTunnel) ?? false
    }

    /// A short human-readable summary of what this profile does.
    var summary: String {
        switch type {
        case .off:
            return "Off"
        case .pac:
            return pacURL.isEmpty ? "PAC (no URL)" : "PAC \(pacURL)"
        case .http, .https, .socks:
            let label = type == .socks ? "SOCKS" : (type == .http ? "HTTP" : "HTTPS")
            return "\(label) \(host):\(port)"
        }
    }
}
