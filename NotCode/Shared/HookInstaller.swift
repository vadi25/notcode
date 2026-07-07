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

    static let chainScriptName = "codex-notify-chain.sh"
    static var chainScript: URL { Paths.appSupport.appendingPathComponent(chainScriptName) }
    /// Original notify line saved before chaining, restored on uninstall.
    static var codexOriginalNotify: URL {
        Paths.appSupport.appendingPathComponent("codex-notify-original.txt")
    }

    static func codexNotifyLine() -> String {
        "notify = [\"\(Paths.installedHelper.path)\", \"codex\"]"
    }

    static func isOurNotify(_ line: String) -> Bool {
        line.contains(helperMarker) || line.contains(chainScriptName)
    }

    static func codexStatus() -> Status {
        guard let text = try? String(contentsOf: Paths.codexConfig, encoding: .utf8),
              let existing = rootNotifyLine(in: text)
        else { return .notInstalled }
        return isOurNotify(existing) ? .installed : .conflict(existing: existing)
    }

    /// Installs the Codex notify hook. Codex supports only ONE notify command,
    /// so when a foreign one exists we generate a chain script that forwards
    /// the event to both the existing handler and notcode-hook.
    static func installCodex() throws {
        let existing = (try? String(contentsOf: Paths.codexConfig, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(
            at: Paths.codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let line = rootNotifyLine(in: existing) else {
            try backup(Paths.codexConfig)
            // Root-level TOML keys must appear before any [table] section.
            let updated = codexNotifyLine() + "\n" + existing
            try updated.write(to: Paths.codexConfig, atomically: true, encoding: .utf8)
            return
        }
        if isOurNotify(line) { return }

        let tokens = try parseNotifyArray(line)
        Paths.ensureAppSupportExists()
        try chainScriptContent(existingCommand: tokens)
            .write(to: chainScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: chainScript.path)
        try Data(line.utf8).write(to: codexOriginalNotify)

        try backup(Paths.codexConfig)
        let newLine = "notify = [\"\(chainScript.path)\"]"
        let updated = replaceRootNotify(in: existing, with: newLine)
        try updated.write(to: Paths.codexConfig, atomically: true, encoding: .utf8)
    }

    static func uninstallCodex() throws {
        guard let text = try? String(contentsOf: Paths.codexConfig, encoding: .utf8),
              let line = rootNotifyLine(in: text), isOurNotify(line) else { return }
        try backup(Paths.codexConfig)

        let updated: String
        if let original = try? String(contentsOf: codexOriginalNotify, encoding: .utf8),
           !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated = replaceRootNotify(
                in: text, with: original.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            updated = text.components(separatedBy: "\n")
                .filter { !(isNotifyAssignment($0) && isOurNotify($0)) }
                .joined(separator: "\n")
        }
        try updated.write(to: Paths.codexConfig, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: chainScript)
        try? FileManager.default.removeItem(at: codexOriginalNotify)
    }

    /// Parses the string array out of a `notify = ["...", "..."]` line.
    /// TOML basic strings in an array are close enough to JSON to reuse it.
    static func parseNotifyArray(_ line: String) throws -> [String] {
        guard let eq = line.firstIndex(of: "="),
              let tokens = try? JSONSerialization.jsonObject(
                  with: Data(line[line.index(after: eq)...]
                      .trimmingCharacters(in: .whitespaces).utf8)) as? [String],
              !tokens.isEmpty
        else {
            throw NSError(domain: "NotCode", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Couldn't parse the existing notify command in ~/.codex/config.toml: \(line)"
            ])
        }
        return tokens
    }

    /// Replaces the root-level notify assignment, leaving everything else as is.
    static func replaceRootNotify(in text: String, with newLine: String) -> String {
        var replaced = false
        var inRoot = true
        return text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inRoot = false }
            if inRoot && !replaced && isNotifyAssignment(trimmed) {
                replaced = true
                return newLine
            }
            return line
        }.joined(separator: "\n")
    }

    static func chainScriptContent(existingCommand: [String]) -> String {
        var lines = [
            "#!/bin/bash",
            "# Generated by NotCode. Codex supports a single notify command, so this",
            "# script forwards each event to every handler. \"$@\" carries the JSON payload.",
        ]
        if !existingCommand.isEmpty {
            lines.append(existingCommand.map(shellEscape).joined(separator: " ") + " \"$@\" &")
        }
        lines.append(shellEscape(Paths.installedHelper.path) + " codex \"$@\" &")
        lines.append("wait")
        return lines.joined(separator: "\n")
    }

    /// The Codex desktop app manages the notify slot itself: on launch it
    /// rewrites notify to its own handler and passes the previous command via
    /// --previous-notify, which it invokes after handling the event. When our
    /// chain ends up downstream like that, it must stop re-invoking the
    /// (now upstream) original handler or that handler runs twice per event.
    static func codexChainIsDownstream(notifyLine: String) -> Bool {
        notifyLine.contains("--previous-notify") && isOurNotify(notifyLine)
    }

    /// Called on every app launch. Keeps the chain script consistent with
    /// however Codex last rewrote the notify line.
    static func repairCodexChain() {
        guard let text = try? String(contentsOf: Paths.codexConfig, encoding: .utf8),
              let line = rootNotifyLine(in: text),
              codexChainIsDownstream(notifyLine: line),
              FileManager.default.fileExists(atPath: chainScript.path)
        else { return }
        let helperOnly = chainScriptContent(existingCommand: [])
        if (try? String(contentsOf: chainScript, encoding: .utf8)) != helperOnly {
            try? helperOnly.write(to: chainScript, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: chainScript.path)
            Log.append("codex: chain is downstream of the Codex app handler; slimmed to helper-only")
        }
    }

    static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
