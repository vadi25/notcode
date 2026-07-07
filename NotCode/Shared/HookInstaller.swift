import Foundation

/// Shared plumbing for the agent modules' hook installers. Per-agent install
/// logic lives in NotCode/Shared/Agents/; everything here is agent-agnostic.
/// All config edits must preserve everything else the user has configured.
enum HookInstaller {
    static let helperMarker = "notcode-hook"

    enum Status: Equatable {
        case installed
        case notInstalled
        case conflict(existing: String)   // e.g. Codex: someone else's notify command
    }

    static func backup(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let backupURL = url.appendingPathExtension("notcode-backup")
        if fm.fileExists(atPath: backupURL.path) { try fm.removeItem(at: backupURL) }
        try fm.copyItem(at: url, to: backupURL)
    }

    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(prettyJSON(object).utf8).write(to: url, options: .atomic)
    }

    static func prettyJSON(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        // JSONSerialization escapes slashes; undo for readable commands.
        return String(data: data, encoding: .utf8)!
            .replacingOccurrences(of: "\\/", with: "/")
    }

    static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
