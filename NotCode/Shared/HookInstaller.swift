import Foundation

/// Installs / removes NotCode hooks in Claude Code and Codex config files.
/// Both operations must preserve everything else the user has configured.
enum HookInstaller {
    static let helperMarker = "notcode-hook"

    /// The command Claude Code runs. Claude executes hooks through a shell,
    /// so $HOME expands and the quoted path survives the space in
    /// "Application Support".
    static func claudeCommand(subcommand: String) -> String {
        "\"$HOME/Library/Application Support/NotCode/notcode-hook\" \(subcommand)"
    }

    static let claudeEvents: [(event: String, subcommand: String)] = [
        ("Notification", "claude-notification"),
        ("Stop", "claude-stop"),
    ]

    enum Status: Equatable {
        case installed
        case notInstalled
        case conflict(existing: String)   // Codex: someone else's notify command
    }

    // MARK: - Claude Code (~/.claude/settings.json)

    static func claudeStatus() -> Status {
        guard let object = readClaudeSettings() else { return .notInstalled }
        let hooks = object["hooks"] as? [String: Any] ?? [:]
        let installed = claudeEvents.allSatisfy { event, _ in
            containsOurHook(hooks[event] as? [[String: Any]] ?? [])
        }
        return installed ? .installed : .notInstalled
    }

    /// Returns the settings JSON as it would look after installation, without
    /// writing anything — used by the UI to show the exact change up front.
    static func claudePreview() throws -> String {
        let merged = try mergedClaudeSettings()
        return prettyJSON(merged)
    }

    static func installClaude() throws {
        let merged = try mergedClaudeSettings()
        try backup(Paths.claudeSettings)
        try writeJSON(merged, to: Paths.claudeSettings)
    }

    static func uninstallClaude() throws {
        guard var object = readClaudeSettings(),
              var hooks = object["hooks"] as? [String: Any] else { return }
        for (event, _) in claudeEvents {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries = entries.compactMap { entry in
                var entry = entry
                var inner = entry["hooks"] as? [[String: Any]] ?? []
                inner.removeAll { ($0["command"] as? String)?.contains(helperMarker) == true }
                if inner.isEmpty { return nil }
                entry["hooks"] = inner
                return entry
            }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        object["hooks"] = hooks
        try backup(Paths.claudeSettings)
        try writeJSON(object, to: Paths.claudeSettings)
    }

    private static func mergedClaudeSettings() throws -> [String: Any] {
        merged(into: readClaudeSettings() ?? [:])
    }

    /// Pure merge: adds our hook entries to a settings object, preserving
    /// everything already there. Idempotent.
    static func merged(into object: [String: Any]) -> [String: Any] {
        var object = object
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        for (event, subcommand) in claudeEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            if !containsOurHook(entries) {
                entries.append([
                    "hooks": [["type": "command", "command": claudeCommand(subcommand: subcommand)]]
                ])
            }
            hooks[event] = entries
        }
        object["hooks"] = hooks
        return object
    }

    private static func readClaudeSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: Paths.claudeSettings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func containsOurHook(_ entries: [[String: Any]]) -> Bool {
        entries.contains { entry in
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            return inner.contains { ($0["command"] as? String)?.contains(helperMarker) == true }
        }
    }

    // MARK: - Codex (~/.codex/config.toml)

    static func codexNotifyLine() -> String {
        "notify = [\"\(Paths.installedHelper.path)\", \"codex\"]"
    }

    static func codexStatus() -> Status {
        guard let text = try? String(contentsOf: Paths.codexConfig, encoding: .utf8),
              let existing = rootNotifyLine(in: text)
        else { return .notInstalled }
        return existing.contains(helperMarker) ? .installed : .conflict(existing: existing)
    }

    static func installCodex() throws {
        let existing = (try? String(contentsOf: Paths.codexConfig, encoding: .utf8)) ?? ""
        if let line = rootNotifyLine(in: existing) {
            guard line.contains(helperMarker) else {
                throw NSError(domain: "NotCode", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "~/.codex/config.toml already has a notify command: \(line)"
                ])
            }
            return
        }
        try FileManager.default.createDirectory(
            at: Paths.codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backup(Paths.codexConfig)
        // Root-level TOML keys must appear before any [table] section.
        let updated = codexNotifyLine() + "\n" + existing
        try updated.write(to: Paths.codexConfig, atomically: true, encoding: .utf8)
    }

    static func uninstallCodex() throws {
        guard let text = try? String(contentsOf: Paths.codexConfig, encoding: .utf8) else { return }
        let kept = text.components(separatedBy: "\n").filter { line in
            !(isNotifyAssignment(line) && line.contains(helperMarker))
        }
        try backup(Paths.codexConfig)
        try kept.joined(separator: "\n")
            .write(to: Paths.codexConfig, atomically: true, encoding: .utf8)
    }

    /// Finds a `notify =` assignment at the TOML root (before any [section]).
    static func rootNotifyLine(in text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }
            if isNotifyAssignment(trimmed) { return trimmed }
        }
        return nil
    }

    private static func isNotifyAssignment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("notify") else { return false }
        return trimmed.dropFirst("notify".count)
            .trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    // MARK: - Common

    private static func backup(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let backupURL = url.appendingPathExtension("notcode-backup")
        if fm.fileExists(atPath: backupURL.path) { try fm.removeItem(at: backupURL) }
        try fm.copyItem(at: url, to: backupURL)
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(prettyJSON(object).utf8).write(to: url, options: .atomic)
    }

    private static func prettyJSON(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        // JSONSerialization escapes slashes; undo for readable commands.
        return String(data: data, encoding: .utf8)!
            .replacingOccurrences(of: "\\/", with: "/")
    }
}
