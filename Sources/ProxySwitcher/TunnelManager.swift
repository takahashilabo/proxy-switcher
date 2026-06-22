import Foundation

/// Starts/stops the sing-box TUN tunnel via a root helper script that the user
/// has whitelisted in sudoers (so no password is needed at runtime).
///
/// Install once with `sudo ./install_tunnel_helper.sh`.
struct TunnelManager {
    static let helperPath = "/usr/local/bin/proxy-tunnel"

    enum TunnelError: Error, CustomStringConvertible {
        case notInstalled
        case failed(String)
        var description: String {
            switch self {
            case .notInstalled:
                return "Tunnel helper not installed. Run: sudo ./install_tunnel_helper.sh"
            case .failed(let s):
                return "Tunnel error: \(s)"
            }
        }
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.helperPath)
    }

    func start() throws { try run("start") }
    func stop()  throws { try run("stop") }

    private func run(_ action: String) throws {
        guard isInstalled else { throw TunnelError.notInstalled }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -n: never prompt; relies on the NOPASSWD sudoers rule.
        proc.arguments = ["-n", Self.helperPath, action]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let out = String(data: data, encoding: .utf8) ?? ""
                throw TunnelError.failed(out.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch let e as TunnelError {
            throw e
        } catch {
            throw TunnelError.failed("\(error)")
        }
    }
}
