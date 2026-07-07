import Foundation

/// Tiny append-only logger. The hook helper must never crash or block the
/// agent, so everything here is best-effort.
enum Log {
    private static let maxSize = 1_000_000

    static func append(_ message: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"

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
        }
    }
}
