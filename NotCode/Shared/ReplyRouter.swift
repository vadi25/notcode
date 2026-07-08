import Foundation

/// Decides where an inbound WhatsApp message should go. Pure functions so the
/// whole routing table is unit-testable.
///
/// Syntax (also shown by the "help" reply):
///   help                → usage + active session list
///   <message>           → most recently notified session
///   <project>: <message> → the session whose project folder matches <project>
enum ReplyRouter {
    enum Route: Equatable {
        case help
        case session(id: String, prompt: String)
        case notFound(prefix: String)
        case noSessions
    }

    static func route(text: String, sessions: [String: SessionInfo]) -> Route {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["help", "?"].contains(trimmed.lowercased()) { return .help }

        let ordered = byRecency(sessions)
        guard let mostRecent = ordered.first else { return .noSessions }

        // "<project>: message": only a single-token prefix counts as routing,
        // so a sentence like "fix this: the button" stays a bare message.
        if let colon = trimmed.firstIndex(of: ":") {
            let prefix = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty, !rest.isEmpty, !prefix.contains(" ") {
                if let match = ordered.first(where: {
                    $0.value.projectName?.lowercased() == prefix.lowercased()
                }) {
                    return .session(id: match.key, prompt: rest)
                }
                return .notFound(prefix: prefix)
            }
        }
        guard !trimmed.isEmpty else { return .noSessions }
        return .session(id: mostRecent.key, prompt: trimmed)
    }

    static func byRecency(_ sessions: [String: SessionInfo]) -> [(key: String, value: SessionInfo)] {
        sessions.sorted { $0.value.lastNotified > $1.value.lastNotified }
    }

    static func sessionList(_ sessions: [String: SessionInfo]) -> String {
        let lines = byRecency(sessions).prefix(5).map { _, info in
            "• *\(info.projectName ?? "unknown")* (\(info.agent))"
        }
        return lines.isEmpty ? "No active sessions right now." : lines.joined(separator: "\n")
    }

    static func helpText(sessions: [String: SessionInfo]) -> String {
        """
        🤖 NotCode. Reply to drive your agents:
        • Any message goes to the most recent session
        • "<project>: <message>" targets that project
        • "help" shows this again

        Active sessions:
        \(sessionList(sessions))
        """
    }

    static func notFoundText(prefix: String, sessions: [String: SessionInfo]) -> String {
        """
        ⚠️ No session matches *\(prefix)*.
        \(sessionList(sessions))
        """
    }
}
