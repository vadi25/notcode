import Foundation

/// Tiny append-only logger. The hook helper must never crash or block the
/// agent, so everything here is best-effort.
enum Log {
    private static let maxSize = 1_000_000

    static func append(_ message: String) {
        let fm = FileManager.default
        // Owner-only: log lines can embed notification content.
        try? fm.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])

        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(sanitized(message))\n"

        if let size = (try? fm.attributesOfItem(atPath: Paths.logFile.path)[.size]) as? Int,
           size > maxSize {
            try? fm.removeItem(at: Paths.logFile)
        }

        if let handle = try? FileHandle(forWritingTo: Paths.logFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: Paths.logFile)
            try? fm.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: Paths.logFile.path)
        }
    }

    /// Messages can embed agent-controlled text (e.g. Claude's notification
    /// message). Strip control characters so crafted input can't forge log
    /// lines or emit terminal escape sequences when the log is cat'ed.
    static func sanitized(_ message: String) -> String {
        String(message.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
        })
    }
}
