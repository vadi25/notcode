import Foundation

/// Codex: a single root-level `notify = [...]` command in ~/.codex/config.toml,
/// JSON as the last CLI argument. Codex allows only one notify handler, so
/// installs chain with any existing one via a generated forwarding script.
struct CodexAgent: AgentModule {
    let name = "Codex"
    let hookSubcommands = ["codex"]
    let payloadSource = PayloadSource.argument
    let installDetail = "Adds notify = [\"…/notcode-hook\", \"codex\"] to ~/.codex/config.toml"

    static let chainScriptName = "codex-notify-chain.sh"
    var chainScript: URL { Paths.appSupport.appendingPathComponent(Self.chainScriptName) }
    /// Original notify line saved before chaining, restored on uninstall.
    var originalNotify: URL {
        Paths.appSupport.appendingPathComponent("codex-notify-original.txt")
    }

    func notifyLine() -> String {
        "notify = [\"\(Paths.installedHelper.path)\", \"codex\"]"
    }

    func isOurNotify(_ line: String) -> Bool {
        line.contains(HookInstaller.helperMarker) || line.contains(Self.chainScriptName)
    }

    // MARK: - Hooks (~/.codex/config.toml)

    func hookStatus() -> HookInstaller.Status {
        guard let text = try? String(contentsOf: Paths.codexConfig, encoding: .utf8),
              let existing = rootNotifyLine(in: text)
        else { return .notInstalled }
        return isOurNotify(existing) ? .installed : .conflict(existing: existing)
    }

    /// Installs the Codex notify hook. Codex supports only ONE notify command,
    /// so when a foreign one exists we generate a chain script that forwards
    /// the event to both the existing handler and notcode-hook.
    func installHooks() throws {
        let existing = (try? String(contentsOf: Paths.codexConfig, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(
            at: Paths.codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let line = rootNotifyLine(in: existing) else {
            try HookInstaller.backup(Paths.codexConfig)
            // Root-level TOML keys must appear before any [table] section.
            let updated = notifyLine() + "\n" + existing
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
        try Data(line.utf8).write(to: originalNotify)

        try HookInstaller.backup(Paths.codexConfig)
        let newLine = "notify = [\"\(chainScript.path)\"]"
        let updated = replaceRootNotify(in: existing, with: newLine)
        try updated.write(to: Paths.codexConfig, atomically: true, encoding: .utf8)
    }

    func uninstallHooks() throws {
        guard let text = try? String(contentsOf: Paths.codexConfig, encoding: .utf8),
              let line = rootNotifyLine(in: text), isOurNotify(line) else { return }
        try HookInstaller.backup(Paths.codexConfig)

        let updated: String
        if let original = try? String(contentsOf: originalNotify, encoding: .utf8),
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
        try? FileManager.default.removeItem(at: originalNotify)
    }

    /// Parses the string array out of a `notify = ["...", "..."]` line.
    /// TOML basic strings in an array are close enough to JSON to reuse it.
    func parseNotifyArray(_ line: String) throws -> [String] {
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
    func replaceRootNotify(in text: String, with newLine: String) -> String {
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

    func chainScriptContent(existingCommand: [String]) -> String {
        var lines = [
            "#!/bin/bash",
            "# Generated by NotCode. Codex supports a single notify command, so this",
            "# script forwards each event to every handler. \"$@\" carries the JSON payload.",
        ]
        if !existingCommand.isEmpty {
            lines.append(existingCommand.map(HookInstaller.shellEscape).joined(separator: " ") + " \"$@\" &")
        }
        lines.append(HookInstaller.shellEscape(Paths.installedHelper.path) + " codex \"$@\" &")
        lines.append("wait")
        return lines.joined(separator: "\n")
    }

    /// The Codex desktop app manages the notify slot itself: on launch it
    /// rewrites notify to its own handler and passes the previous command via
    /// --previous-notify, which it invokes after handling the event. When our
    /// chain ends up downstream like that, it must stop re-invoking the
    /// (now upstream) original handler or that handler runs twice per event.
    func chainIsDownstream(notifyLine: String) -> Bool {
        notifyLine.contains("--previous-notify") && isOurNotify(notifyLine)
    }

    /// Called on every app launch. Keeps the chain script consistent with
    /// however Codex last rewrote the notify line.
    func repairAfterLaunch() {
        guard let text = try? String(contentsOf: Paths.codexConfig, encoding: .utf8),
              let line = rootNotifyLine(in: text),
              chainIsDownstream(notifyLine: line),
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

    /// Finds a `notify =` assignment at the TOML root (before any [section]).
    func rootNotifyLine(in text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }
            if isNotifyAssignment(trimmed) { return trimmed }
        }
        return nil
    }

    private func isNotifyAssignment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("notify") else { return false }
        return trimmed.dropFirst("notify".count)
            .trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    // MARK: - Events

    /// Codex passes JSON as the last CLI argument, e.g.
    /// {"type":"agent-turn-complete","turn-id":"...","input-messages":["..."],
    ///  "last-assistant-message":"..."}
    func parse(subcommand: String, payload: Data) -> AgentEvent? {
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        let type = object["type"] as? String ?? "agent-turn-complete"
        guard type == "agent-turn-complete" else { return nil }

        var summary: String?
        if let inputs = object["input-messages"] as? [String], let first = inputs.first {
            summary = String(first.prefix(60))
        }
        return AgentEvent(
            agent: name,
            kind: .done,
            detail: summary,
            cwd: object["cwd"] as? String,
            sessionID: object["turn-id"] as? String)
    }

    // MARK: - Remote resume
    // `codex exec resume <session-id>` exists, but the notify payload carries
    // a turn-id whose relationship to the session id is unverified. Until the
    // investigation lands, the default unavailable implementation applies.
}
