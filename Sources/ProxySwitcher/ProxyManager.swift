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
    func apply(profile: ProxyProfile?, interface: String?) throws {
        guard let service = wifiServiceName(for: interface) else {
            throw ApplyError.noService
        }
        let cmds = commands(for: profile, service: service)
        let script = cmds.map { args in
            ([networksetup] + args).map(Self.shellQuote).joined(separator: " ")
        }.joined(separator: " && ")

        try runAdmin(shellScript: script)
    }

    // MARK: - Shell helpers

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run a shell command and capture stdout (no privilege escalation).
    private func runCapture(_ launchPath: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Run a shell script with administrator privileges via AppleScript.
    /// Throws if the user cancels the auth prompt or a command fails.
    private func runAdmin(shellScript: String) throws {
        // Escape for embedding inside an AppleScript string literal.
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let apple = "do shell script \"\(escaped)\" with administrator privileges"

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: apple) else {
            throw ApplyError.command("Could not build AppleScript.")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            throw ApplyError.command(msg)
        }
    }
}
