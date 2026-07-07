import Foundation

/// Claude Code: Notification + Stop hooks in ~/.claude/settings.json, JSON on
/// stdin. The only agent (so far) with a reliable headless resume path, via
/// `claude -p --resume <session_id>`.
struct ClaudeAgent: AgentModule {
    let name = "Claude Code"
    let hookSubcommands = ["claude-notification", "claude-stop"]
    let payloadSource = PayloadSource.stdin
    let installDetail = "Adds Notification + Stop hooks to ~/.claude/settings.json"
    let emitsAttention = true

    static let events: [(event: String, subcommand: String)] = [
        ("Notification", "claude-notification"),
        ("Stop", "claude-stop"),
    ]

    /// The command Claude Code runs. Claude executes hooks through a shell,
    /// so $HOME expands and the quoted path survives the space in
    /// "Application Support".
    func command(subcommand: String) -> String {
        "\"$HOME/Library/Application Support/NotCode/notcode-hook\" \(subcommand)"
    }

    // MARK: - Hooks (~/.claude/settings.json)

    func hookStatus() -> HookInstaller.Status {
        guard let object = readSettings() else { return .notInstalled }
        let hooks = object["hooks"] as? [String: Any] ?? [:]
        let installed = Self.events.allSatisfy { event, _ in
            containsOurHook(hooks[event] as? [[String: Any]] ?? [])
        }
        return installed ? .installed : .notInstalled
    }

    func installPreview() throws -> String? {
        HookInstaller.prettyJSON(merged(into: readSettings() ?? [:]))
    }

    func installHooks() throws {
        let merged = merged(into: readSettings() ?? [:])
        try HookInstaller.backup(Paths.claudeSettings)
        try HookInstaller.writeJSON(merged, to: Paths.claudeSettings)
    }

    func uninstallHooks() throws {
        guard var object = readSettings(),
              var hooks = object["hooks"] as? [String: Any] else { return }
        for (event, _) in Self.events {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries = entries.compactMap { entry in
                var entry = entry
                var inner = entry["hooks"] as? [[String: Any]] ?? []
                inner.removeAll {
                    ($0["command"] as? String)?.contains(HookInstaller.helperMarker) == true
                }
                if inner.isEmpty { return nil }
                entry["hooks"] = inner
                return entry
            }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        object["hooks"] = hooks
        try HookInstaller.backup(Paths.claudeSettings)
        try HookInstaller.writeJSON(object, to: Paths.claudeSettings)
    }

    /// Pure merge: adds our hook entries to a settings object, preserving
    /// everything already there. Idempotent.
    func merged(into object: [String: Any]) -> [String: Any] {
        var object = object
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        for (event, subcommand) in Self.events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            if !containsOurHook(entries) {
                entries.append([
                    "hooks": [["type": "command", "command": command(subcommand: subcommand)]]
                ])
            }
            hooks[event] = entries
        }
        object["hooks"] = hooks
        return object
    }

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: Paths.claudeSettings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func containsOurHook(_ entries: [[String: Any]]) -> Bool {
        entries.contains { entry in
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            return inner.contains {
                ($0["command"] as? String)?.contains(HookInstaller.helperMarker) == true
            }
        }
    }

    // MARK: - Events

    /// Claude Code hooks pass JSON on stdin, e.g.
    /// {"session_id":"...","cwd":"...","hook_event_name":"Notification","message":"..."}
    /// Returns nil for Stop events re-fired by hook-forced continuations
    /// (stop_hook_active) — notifying those would duplicate the real stop.
    func parse(subcommand: String, payload: Data) -> AgentEvent? {
        let kind: AgentEvent.Kind = subcommand == "claude-notification" ? .attention : .done
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        if kind == .done, object["stop_hook_active"] as? Bool == true {
            return nil
        }
        return AgentEvent(
            agent: name,
            kind: kind,
            detail: kind == .attention ? object["message"] as? String : nil,
            cwd: object["cwd"] as? String,
            sessionID: object["session_id"] as? String)
    }

    // MARK: - Remote resume

    func resumeAvailability() -> ResumeAvailability {
        loginShellWhich("claude")
            ? .available
            : .unavailable(reason: "the claude CLI isn't on this Mac's PATH")
    }

    func resumeCommand(sessionID: String, prompt: String) -> String? {
        "claude -p --resume \(HookInstaller.shellEscape(sessionID)) "
            + "--output-format json \(HookInstaller.shellEscape(prompt))"
    }

    /// `claude -p --output-format json` emits one object with `result` (the
    /// final answer) and `session_id` (the forked branch to resume next time).
    func parseResumeOutput(stdout: Data) -> ResumeResult {
        let object = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any] ?? [:]
        return ResumeResult(
            excerpt: object["result"] as? String,
            newSessionID: object["session_id"] as? String)
    }
}
