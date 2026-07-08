import Foundation

// notcode-hook, invoked by the agents' own hook mechanisms; each subcommand
// belongs to one AgentModule in the registry. Must always exit 0 quickly, and
// never write JSON to stdout: Cursor would interpret a followup_message as an
// instruction to keep the agent going.

/// Env markers each agent CLI exports to the processes it spawns. Because
/// environment variables flow parent -> child only, a hook whose environment
/// carries a marker for an agent *other than the one firing* must be running
/// nested inside that other agent, e.g. a `codex` launched mid-task by a
/// Claude Code session inherits CLAUDECODE. The outermost agent already reports
/// for the whole turn, so these nested sub-invocations stay quiet.
private let agentAncestorMarkers: [(agent: String, keys: [String])] = [
    ("Claude Code", ["CLAUDECODE", "CLAUDE_CODE_SESSION_ID"]),
    ("Codex", ["CODEX_THREAD_ID", "CODEX_SANDBOX"]),
    ("Cursor", ["CURSOR_AGENT_ID", "CURSOR_TRACE_ID"]),   // best-effort
]

private func nestedUnderOtherAgent(_ agent: String, env: [String: String]) -> Bool {
    for marker in agentAncestorMarkers where marker.agent != agent {
        if marker.keys.contains(where: { env[$0] != nil }) { return true }
    }
    return false
}

func run() {
    // Runs launched by the reply loop set this; their outcome is reported by
    // the poller itself, so the agent's own hooks must stay quiet or every
    // remote reply would double-notify.
    if ProcessInfo.processInfo.environment["NOTCODE_REMOTE_RUN"] == "1" {
        Log.append("hook: remote-run session, staying quiet")
        return
    }
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        Log.append("hook: missing subcommand")
        return
    }
    let subcommand = arguments[1]

    let event: AgentEvent?
    if let module = AgentRegistry.bySubcommand(subcommand) {
        let payload: Data
        switch module.payloadSource {
        case .stdin:
            payload = FileHandle.standardInput.readDataToEndOfFile()
        case .argument:
            payload = arguments.count >= 3 ? Data(arguments[2].utf8) : Data()
        }
        event = module.parse(subcommand: subcommand, payload: payload)
    } else if subcommand == "test" {
        event = AgentEvent(agent: "Claude Code", kind: .attention,
                           detail: "test notification from notcode-hook",
                           cwd: FileManager.default.currentDirectoryPath,
                           sessionID: "test")
    } else {
        Log.append("hook: unknown subcommand \(subcommand)")
        return
    }

    guard let event else { return }

    // Only the top-level agent/conversation should alert; a sub-agent or nested
    // CLI (a codex spawned inside a Claude turn, etc.) inherits the parent
    // agent's env markers and must stay quiet.
    if nestedUnderOtherAgent(event.agent, env: ProcessInfo.processInfo.environment) {
        Log.append("hook: \(event.dedupeKey) suppressed (nested under another agent)")
        return
    }

    let outcome = Notifier.fire(event, blockingSound: true)
    if let reason = outcome.skippedReason {
        Log.append("hook: \(event.dedupeKey) skipped (\(reason))")
    } else {
        Log.append("hook: \(event.dedupeKey) sound=\(outcome.soundPlayed) whatsapp=\(outcome.whatsAppSent)")
    }
}

run()
exit(0)
