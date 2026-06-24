import Foundation

/// Appends timestamped activity to a log file.
///
/// When the proxy fails to revert it strands connectivity, which also takes
/// down anything that depends on the network (including the `claude` CLI), so
/// the failure can't be debugged live. This log lets us reconstruct what the
/// app saw and did *after the fact* — once a working network is back, read the
/// file to see exactly why a transition did (or didn't) happen.
///
/// Thread-safe: callable from any thread/actor.
final class ActivityLog {
    static let shared = ActivityLog()

    private let url: URL
    private let queue = DispatchQueue(label: "proxyswitcher.activitylog")
    private let stamp: DateFormatter

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProxySwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("activity.log")

        stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
    }

    var path: String { url.path }

    func log(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        queue.async {
            // Keep the file from growing without bound.
            if let attr = try? FileManager.default.attributesOfItem(atPath: self.url.path),
               let size = attr[.size] as? Int, size > 512_000 {
                try? FileManager.default.removeItem(at: self.url)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: self.url)
            }
        }
    }
}
