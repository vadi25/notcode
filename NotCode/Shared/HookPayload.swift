import Foundation

/// A normalized notification event coming from any supported agent.
/// Parsing of each agent's raw payload lives in its AgentModule
/// (NotCode/Shared/Agents/).
struct AgentEvent {
    enum Kind: String {
        case attention  // agent is waiting for the user (permission, question, idle)
        case done       // agent finished a task/turn
    }

    var agent: String       // an AgentRegistry module name, e.g. "Claude Code"
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
