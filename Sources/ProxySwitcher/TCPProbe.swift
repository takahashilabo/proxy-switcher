import Foundation
import Darwin

/// A tiny dependency-free TCP reachability probe.
///
/// Used as a robust fallback for matching a rule when macOS won't hand us the
/// Wi-Fi name (CoreWLAN returns nil without Location permission, and tethering
/// SSIDs vary). A tethering rule's proxy lives at a fixed LAN address
/// (e.g. NetShare at 192.168.49.1:8282), so "can I open a TCP socket to it?"
/// reliably answers "am I on that network?" — independent of the SSID.
///
/// Note: a raw BSD socket connect ignores the macOS system proxy and goes
/// straight out the interface, and the gateway address is directly connected,
/// so this stays true while the proxy/tunnel is active (no flapping).
enum TCPProbe {
    /// True if a TCP connection to host:port completes within `timeout` seconds.
    static func canConnect(host: String, port: Int, timeout: TimeInterval = 1.0) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else {
            return false
        }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd < 0 { return false }
        defer { close(fd) }

        // Non-blocking connect so we can bound the wait with poll().
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if rc == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(max(0, timeout * 1000))
        guard poll(&pfd, nfds_t(1), ms) > 0 else { return false }

        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0 else { return false }
        return soErr == 0
    }
}
