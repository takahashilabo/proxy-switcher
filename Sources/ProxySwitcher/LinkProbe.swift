import Foundation
import Darwin

/// Decides whether a proxy host is on the machine's *physically connected* link.
///
/// We must NOT use a TCP-connect probe for this: once our own TUN tunnel is up,
/// it completes TCP handshakes locally, so a connect to the proxy always
/// "succeeds" even after we've left the tethering network — which permanently
/// locks the tunnel on and kills connectivity.
///
/// Instead we inspect the Wi-Fi interface's own IPv4 address/netmask (a local
/// property the tunnel cannot fake) and check whether the proxy host falls in
/// that directly-connected subnet. On NetShare the Wi-Fi gets 192.168.49.x, so
/// 192.168.49.1 is on-link; on any other network it isn't.
enum LinkProbe {
    /// True if `host` is in the directly-connected IPv4 subnet of interface
    /// `ifname` (e.g. "en0"). If `ifname` is nil, scans physical interfaces
    /// (skipping loopback and tun/utun).
    static func hostOnLocalSubnet(_ host: String, interface ifname: String?) -> Bool {
        guard let target = ipv4ToHostOrder(host) else { return false }

        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }

        var ptr = list
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let nm = ifa.ifa_netmask else { continue }

            let name = String(cString: ifa.ifa_name)
            if let ifname {
                if name != ifname { continue }
            } else if name == "lo0" || name.hasPrefix("utun") || name.hasPrefix("tun") {
                continue
            }

            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            if mask != 0 && (addr & mask) == (target & mask) { return true }
        }
        return false
    }

    /// Parse "a.b.c.d" into a host-order UInt32 (a is most-significant).
    private static func ipv4ToHostOrder(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}
