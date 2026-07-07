import Foundation

/// A normalized notification event coming from any supported agent.
struct AgentEvent {
    enum Kind: String {
        case attention  // agent is waiting for the user (permission, question, idle)
        case done       // agent finished a task/turn
    }

    var agent: String       // "Claude Code" | "Codex"
    var kind: Kind
    var detail: String?     // e.g. Claude's notification message or task summary
    var cwd: String?
    var sessionID: String?

    var projectName: String? {
        cwd.map { ($0 as NSString).lastPathComponent }
    }

    /// Short WhatsApp text — status updates only, never task results, so a
    /// notification stays a single cheap message.
    var whatsAppText: String {
        let location = projectName.map { " in *\($0)*" } ?? ""
        switch kind {
        case .attention:
            let reason = detail.map { ": \($0)" } ?? ""
            return "🔔 \(agent) needs you\(location)\(reason)"
        case .done:
            let task = detail.map { ": \($0)" } ?? ""
            return "✅ \(agent) finished\(location)\(task)"
        }
    }

    /// Key used for rate limiting — same event type from the same session.
    var dedupeKey: String {
        "\(agent)|\(kind.rawValue)|\(sessionID ?? cwd ?? "global")"
    }
}

enum HookPayload {
    /// Claude Code hooks pass JSON on stdin, e.g.
    /// {"session_id":"...","cwd":"...","hook_event_name":"Notification","message":"..."}
    static func parseClaude(kind: AgentEvent.Kind, json data: Data) -> AgentEvent {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return AgentEvent(
            agent: "Claude Code",
            kind: kind,
            detail: kind == .attention ? object["message"] as? String : nil,
            cwd: object["cwd"] as? String,
            sessionID: object["session_id"] as? String)
    }

    /// Codex passes JSON as the last CLI argument, e.g.
    /// {"type":"agent-turn-complete","turn-id":"...","input-messages":["..."],
    ///  "last-assistant-message":"..."}
    static func parseCodex(json data: Data) -> AgentEvent? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let type = object["type"] as? String ?? "agent-turn-complete"
        guard type == "agent-turn-complete" else { return nil }

        var summary: String?
        if let inputs = object["input-messages"] as? [String], let first = inputs.first {
            summary = String(first.prefix(60))
        }
        return AgentEvent(
            agent: "Codex",
            kind: .done,
            detail: summary,
            cwd: object["cwd"] as? String,
            sessionID: object["turn-id"] as? String)
    }
}
