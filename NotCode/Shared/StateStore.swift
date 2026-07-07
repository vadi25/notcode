import Foundation

/// Small shared state file: rate-limit timestamps, last notification (shown in
/// the menu bar), and session → cwd mapping kept for v2 reply routing.
struct NotCodeState: Codable {
    var recentEvents: [String: Date] = [:]        // dedupeKey → last fired
    var lastNotification: String?
    var lastNotificationDate: Date?
    var sessions: [String: String] = [:]          // session_id → cwd (v2)
}

enum StateStore {
    static let rateLimitWindow: TimeInterval = 30

    static func load() -> NotCodeState {
        guard let data = try? Data(contentsOf: Paths.state),
              let state = try? JSONDecoder().decode(NotCodeState.self, from: data)
        else { return NotCodeState() }
        return state
    }

    static func save(_ state: NotCodeState) {
        Paths.ensureAppSupportExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(state) {
            try? data.write(to: Paths.state, options: .atomic)
        }
    }

    /// Returns false when an identical event fired within the rate-limit
    /// window; otherwise records the event and returns true.
    static func shouldFire(_ event: AgentEvent, now: Date = Date()) -> Bool {
        var state = load()
        if let last = state.recentEvents[event.dedupeKey],
           now.timeIntervalSince(last) < rateLimitWindow {
            return false
        }
        state.recentEvents = state.recentEvents.filter {
            now.timeIntervalSince($0.value) < 3600
        }
        state.recentEvents[event.dedupeKey] = now
        state.lastNotification = event.whatsAppText
        state.lastNotificationDate = now
        if let session = event.sessionID, let cwd = event.cwd {
            state.sessions[session] = cwd
        }
        save(state)
        return true
    }
}
