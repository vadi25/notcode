import Foundation

/// What we remember about a session that notified the user: enough to route
/// a WhatsApp reply back into it.
struct SessionInfo: Codable, Equatable {
    var cwd: String?
    var agent: String
    var lastNotified: Date

    var projectName: String? {
        cwd.map { ($0 as NSString).lastPathComponent }
    }
}

/// Small shared state file: rate-limit timestamps, last notification (shown in
/// the menu bar), and session bookkeeping for WhatsApp reply routing.
struct NotCodeState: Codable {
    var recentEvents: [String: Date] = [:]        // dedupeKey → last fired
    var lastNotification: String?
    var lastNotificationDate: Date?
    var lastDeliveryProblem: String?              // surfaced in the menu bar
    var sessions: [String: SessionInfo] = [:]     // session_id → routing info
    var processedMessageIDs: [String] = []        // WhatsApp ids already handled
    var lastOutboundWhatsApp: Date?               // drives reply-poll cadence
    /// Calendar month the message counter belongs to, e.g. "2026-07".
    var messageMonth: String = ""
    /// Running count of inbound + outbound WhatsApp messages this month.
    var messageCount: Int = 0
    /// Agent name → when we last received any hook event from it. Written by
    /// the hook helper, read by the app's Status panel.
    var lastEventByAgent: [String: Date] = [:]

    init() {}

    /// Tolerant decoding: new keys missing from older state.json fall back to
    /// their defaults so the rest of the state (sessions, processed IDs, etc.)
    /// is preserved rather than wiped whenever a field is added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recentEvents = try c.decodeIfPresent([String: Date].self, forKey: .recentEvents) ?? [:]
        lastNotification = try c.decodeIfPresent(String.self, forKey: .lastNotification)
        lastNotificationDate = try c.decodeIfPresent(Date.self, forKey: .lastNotificationDate)
        lastDeliveryProblem = try c.decodeIfPresent(String.self, forKey: .lastDeliveryProblem)
        sessions = try c.decodeIfPresent([String: SessionInfo].self, forKey: .sessions) ?? [:]
        processedMessageIDs = try c.decodeIfPresent([String].self, forKey: .processedMessageIDs) ?? []
        lastOutboundWhatsApp = try c.decodeIfPresent(Date.self, forKey: .lastOutboundWhatsApp)
        messageMonth = try c.decodeIfPresent(String.self, forKey: .messageMonth) ?? ""
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        lastEventByAgent = try c.decodeIfPresent([String: Date].self, forKey: .lastEventByAgent) ?? [:]
    }
}

enum StateStore {
    static let rateLimitWindow: TimeInterval = 60
    /// Sessions stop being reply targets after this long without notifying.
    static let sessionRetention: TimeInterval = 12 * 3600
    static let maxProcessedIDs = 200

    static func load() -> NotCodeState {
        guard let data = try? Data(contentsOf: Paths.state),
              let state = try? JSONDecoder().decode(NotCodeState.self, from: data)
        // A pre-1.2 state.json (sessions was [String: String]) fails to decode;
        // starting fresh only resets rate limits and routing, never settings.
        else { return NotCodeState() }
        return state
    }

    static func save(_ state: NotCodeState) {
        Paths.ensureAppSupportExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(state) {
            try? data.write(to: Paths.state, options: .atomic)
            // Holds the last notification text and session → project paths;
            // keep it owner-readable like config.json.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: Paths.state.path)
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
        if let session = event.sessionID {
            state.sessions[session] = SessionInfo(
                cwd: event.cwd, agent: event.agent, lastNotified: now)
            state.sessions = state.sessions.filter {
                now.timeIntervalSince($0.value.lastNotified) < sessionRetention
            }
        }
        save(state)
        return true
    }

    /// Remembers that an agent produced a hook event, whatever became of the
    /// notification. Feeds the Status panel's "Last alert" line.
    static func recordAgentEvent(_ agent: String, now: Date = Date()) {
        var state = load()
        state.lastEventByAgent[agent] = now
        save(state)
    }

    /// When we last received any hook event from the named agent.
    static func lastEvent(for agent: String) -> Date? {
        load().lastEventByAgent[agent]
    }

    static func recordDeliveryProblem(_ problem: String?) {
        var state = load()
        state.lastDeliveryProblem = problem
        save(state)
    }

    /// Returns a "YYYY-MM" string for the given date using the current locale calendar.
    private static func calendarMonth(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    /// Rolls the monthly counter over if the month changed, then increments it.
    private static func bumpCount(in state: inout NotCodeState, now: Date) {
        let month = calendarMonth(now)
        if state.messageMonth != month {
            state.messageMonth = month
            state.messageCount = 0
        }
        state.messageCount += 1
    }

    static func recordWhatsAppSent(now: Date = Date()) {
        var state = load()
        state.lastOutboundWhatsApp = now
        bumpCount(in: &state, now: now)
        save(state)
    }

    /// Records one inbound message against the monthly budget.
    static func recordInboundMessage(now: Date = Date()) {
        var state = load()
        bumpCount(in: &state, now: now)
        save(state)
    }

    /// Returns the message count for the current calendar month (0 if the
    /// stored month has already rolled over).
    static func currentMonthMessageCount(now: Date = Date()) -> Int {
        let state = load()
        return state.messageMonth == calendarMonth(now) ? state.messageCount : 0
    }

    /// Remembers a handled inbound WhatsApp message id (bounded).
    static func markProcessed(_ messageID: String) {
        var state = load()
        state.processedMessageIDs.append(messageID)
        if state.processedMessageIDs.count > maxProcessedIDs {
            state.processedMessageIDs.removeFirst(
                state.processedMessageIDs.count - maxProcessedIDs)
        }
        save(state)
    }

    /// A reply resumed the session under a fresh id: carry the routing info
    /// over so the next reply continues the same branch.
    static func rebindSession(from oldID: String, to newID: String, now: Date = Date()) {
        guard oldID != newID else { return }
        var state = load()
        guard var info = state.sessions[oldID] else { return }
        info.lastNotified = now
        state.sessions[newID] = info
        state.sessions.removeValue(forKey: oldID)
        save(state)
    }
}
