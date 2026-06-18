import Foundation

/// Applies proxy settings to the Wi-Fi network service via `networksetup`.
///
/// Changing proxy state requires admin rights, so the batch of commands is run
/// through a single `do shell script ... with administrator privileges` call —
/// the user is asked for their password at most once per change.
struct ProxyManager {

    enum ApplyError: Error, CustomStringConvertible {
        case noService
        case command(String)
        var description: String {
            switch self {
            case .noService: return "Could not find the Wi-Fi network service."
            case .command(let s): return s
            }
        }
    }

    private let networksetup = "/usr/sbin/networksetup"

    /// Resolve the network *service* name (e.g. "Wi-Fi") for a given BSD
    /// interface (e.g. "en0"). networksetup operates on service names.
    func wifiServiceName(for interface: String?) -> String? {
        let out = runCapture(networksetup, ["-listallhardwareports"]) ?? ""
        // Blocks look like:
        //   Hardware Port: Wi-Fi
        //   Device: en0
        //   Ethernet Address: ...
        var currentPort: String?
        for rawLine in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                currentPort = line.replacingOccurrences(of: "Hardware Port:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:") {
                let dev = line.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let iface = interface, dev == iface { return currentPort }
            }
        }
        // Fallbacks.
        let services = runCapture(networksetup, ["-listallnetworkservices"]) ?? ""
        if services.contains("Wi-Fi") { return "Wi-Fi" }
        return currentPort
    }

    /// Build the list of `networksetup` argument arrays for a profile.
    /// Passing `nil` means "turn everything off".
    private func commands(for profile: ProxyProfile?, service: String) -> [[String]] {
        // Always start from a clean slate: disable every proxy kind.
        var cmds: [[String]] = [
            ["-setwebproxystate", service, "off"],
            ["-setsecurewebproxystate", service, "off"],
            ["-setsocksfirewallproxystate", service, "off"],
            ["-setautoproxystate", service, "off"],
        ]

        guard let p = profile, p.enabled, p.type != .off else { return cmds }

        let auth = !p.username.isEmpty
        let port = String(p.port)

        switch p.type {
        case .http:
            var set = ["-setwebproxy", service, p.host, port]
            if auth { set += ["on", p.username, p.password] }
            cmds.append(set)
            cmds.append(["-setwebproxystate", service, "on"])
        case .https:
            var set = ["-setsecurewebproxy", service, p.host, port]
            if auth { set += ["on", p.username, p.password] }
            cmds.append(set)
            cmds.append(["-setsecurewebproxystate", service, "on"])
        case .socks:
            var set = ["-setsocksfirewallproxy", service, p.host, port]
            if auth { set += ["on", p.username, p.password] }
            cmds.append(set)
            cmds.append(["-setsocksfirewallproxystate", service, "on"])
        case .pac:
            cmds.append(["-setautoproxyurl", service, p.pacURL])
            cmds.append(["-setautoproxystate", service, "on"])
        case .off:
            break
        }
        return cmds
    }

    /// Apply the given profile (or turn proxies off if nil) to the Wi-Fi service.
    ///
    /// On macOS, `networksetup` proxy changes do **not** require root for an
    /// admin user, so the commands are run directly — no password prompt.
    func apply(profile: ProxyProfile?, interface: String?) throws {
        guard let service = wifiServiceName(for: interface) else {
            throw ApplyError.noService
        }
        for args in commands(for: profile, service: service) {
            let result = run(networksetup, args)
            if result.status != 0 {
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ApplyError.command("networksetup \(args.first ?? "") failed: \(detail)")
            }
        }
    }

    // MARK: - Shell helpers

    @discardableResult
    private func runCapture(_ launchPath: String, _ args: [String]) -> String? {
        let r = run(launchPath, args)
        return r.status == 0 ? r.output : nil
    }

    /// Run a command, returning its exit status and combined stdout+stderr.
    private func run(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            return (proc.terminationStatus, out)
        } catch {
            return (-1, "\(error)")
        }
    }
}
