import Foundation

// notcode-hook — invoked by Claude Code hooks (JSON on stdin), Codex's
// notify config (JSON as the last argument), and Cursor's stop hook (JSON on
// stdin, via the ~/.cursor/notcode-hook.sh wrapper). Must always exit 0
// quickly, and never write JSON to stdout — Cursor would interpret a
// followup_message as an instruction to keep the agent going.

func run() {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        Log.append("hook: missing subcommand")
        return
    }

    let event: AgentEvent?
    switch arguments[1] {
    case "claude-notification":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        event = HookPayload.parseClaude(kind: .attention, json: input)
    case "claude-stop":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        event = HookPayload.parseClaude(kind: .done, json: input)
    case "codex":
        let payload = arguments.count >= 3 ? Data(arguments[2].utf8) : Data()
        event = HookPayload.parseCodex(json: payload)
    case "cursor":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        event = HookPayload.parseCursor(json: input)
    case "test":
        event = AgentEvent(agent: "Claude Code", kind: .attention,
                           detail: "test notification from notcode-hook",
                           cwd: FileManager.default.currentDirectoryPath,
                           sessionID: "test")
    default:
        Log.append("hook: unknown subcommand \(arguments[1])")
        return
    }

    guard let event else { return }
    let outcome = Notifier.fire(event, blockingSound: true)
    if let reason = outcome.skippedReason {
        Log.append("hook: \(event.dedupeKey) skipped (\(reason))")
    } else {
        Log.append("hook: \(event.dedupeKey) sound=\(outcome.soundPlayed) whatsapp=\(outcome.whatsAppSent)")
    }
}

run()
exit(0)
