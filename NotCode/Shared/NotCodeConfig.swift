import Foundation

/// Which sound to play for an event.
struct SoundChoice: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case bundled   // shipped with NotCode, value = file name (e.g. "alarm.wav")
        case system    // /System/Library/Sounds, value = name without extension (e.g. "Sosumi")
        case file      // arbitrary local file, value = absolute path
        case none
    }

    var kind: Kind
    var value: String

    static let defaultAttention = SoundChoice(kind: .bundled, value: "claude-needs-you.aiff")
    static let defaultDone = SoundChoice(kind: .bundled, value: "tada.wav")
    static let silent = SoundChoice(kind: .none, value: "")
}

struct NotCodeConfig: Codable, Equatable {
    // Kapso / WhatsApp
    var whatsAppEnabled: Bool = false
    var kapsoAPIKey: String = ""
    var phoneNumberID: String = ""
    var recipientPhone: String = ""

    // Behavior
    var paused: Bool = false
    var notifyAttention: Bool = true
    var notifyDone: Bool = true
    /// Agents the user muted, by AgentRegistry name. A set (rather than one
    /// bool per agent) so new agent modules need no config change.
    var disabledAgents: Set<String> = []
    /// Only send WhatsApp when no keyboard/mouse input for this long. 0 = always send.
    var awayOnlyWhatsApp: Bool = true
    var awayThresholdMinutes: Double = 2
    /// Skip all notifications while the user is actively in a terminal/IDE —
    /// they're watching the agent, so every turn-end ding is noise.
    var suppressWhileWatching: Bool = true

    // Reply loop (beta): drive sessions by replying on WhatsApp.
    var replyLoopEnabled: Bool = false
    /// Include a short excerpt of the agent's answer in the completion
    /// message. Off by default: the privacy stance is status-only.
    var replyExcerptEnabled: Bool = false
    /// How often (seconds) the reply poller checks for inbound messages in the
    /// idle (non-active) state. Active windows always clamp to ≤ 15 s.
    var pollIntervalSeconds: Int = 15
    /// When false the ▶️ / ✅ progress confirmations are suppressed to save
    /// messages. ⚠️ error alerts always send regardless.
    var replyConfirmationsEnabled: Bool = true
    /// Kapso plan limit shown in the UI so the user can track usage.
    var monthlyMessageBudget: Int = 2000

    // Sounds
    var soundAttention: SoundChoice = .defaultAttention
    var soundDone: SoundChoice = .defaultDone
    /// Optional per-agent overrides keyed "<agent name>|<kind rawValue>";
    /// a missing key falls back to the global choice above.
    var soundOverrides: [String: SoundChoice] = [:]
    var volume: Double = 1.0

    // App state
    var onboardingCompleted: Bool = false

    var hasKapsoCredentials: Bool {
        !kapsoAPIKey.isEmpty && !phoneNumberID.isEmpty && !recipientPhone.isEmpty
    }

    func isEnabled(_ agent: String) -> Bool {
        !disabledAgents.contains(agent)
    }

    static func soundOverrideKey(_ agent: String, _ kind: AgentEvent.Kind) -> String {
        "\(agent)|\(kind.rawValue)"
    }

    func sound(for agent: String, kind: AgentEvent.Kind) -> SoundChoice {
        soundOverrides[Self.soundOverrideKey(agent, kind)]
            ?? (kind == .attention ? soundAttention : soundDone)
    }

    mutating func setEnabled(_ agent: String, _ enabled: Bool) {
        if enabled { disabledAgents.remove(agent) } else { disabledAgents.insert(agent) }
    }

    init() {}

    /// Tolerant decoding: any key missing from an older config.json keeps its
    /// default instead of failing the whole file (which would silently reset
    /// the user's credentials whenever we add a setting).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotCodeConfig()
        whatsAppEnabled = try c.decodeIfPresent(Bool.self, forKey: .whatsAppEnabled) ?? d.whatsAppEnabled
        kapsoAPIKey = try c.decodeIfPresent(String.self, forKey: .kapsoAPIKey) ?? d.kapsoAPIKey
        phoneNumberID = try c.decodeIfPresent(String.self, forKey: .phoneNumberID) ?? d.phoneNumberID
        recipientPhone = try c.decodeIfPresent(String.self, forKey: .recipientPhone) ?? d.recipientPhone
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? d.paused
        notifyAttention = try c.decodeIfPresent(Bool.self, forKey: .notifyAttention) ?? d.notifyAttention
        notifyDone = try c.decodeIfPresent(Bool.self, forKey: .notifyDone) ?? d.notifyDone
        disabledAgents = try c.decodeIfPresent(Set<String>.self, forKey: .disabledAgents) ?? d.disabledAgents
        // Migrate the pre-1.2 per-agent booleans into disabledAgents.
        let legacy = try decoder.container(keyedBy: LegacyAgentKeys.self)
        for (key, agent) in LegacyAgentKeys.agentNames
        where (try? legacy.decodeIfPresent(Bool.self, forKey: key)) == false {
            disabledAgents.insert(agent)
        }
        awayOnlyWhatsApp = try c.decodeIfPresent(Bool.self, forKey: .awayOnlyWhatsApp) ?? d.awayOnlyWhatsApp
        awayThresholdMinutes = try c.decodeIfPresent(Double.self, forKey: .awayThresholdMinutes) ?? d.awayThresholdMinutes
        suppressWhileWatching = try c.decodeIfPresent(Bool.self, forKey: .suppressWhileWatching) ?? d.suppressWhileWatching
        replyLoopEnabled = try c.decodeIfPresent(Bool.self, forKey: .replyLoopEnabled) ?? d.replyLoopEnabled
        replyExcerptEnabled = try c.decodeIfPresent(Bool.self, forKey: .replyExcerptEnabled) ?? d.replyExcerptEnabled
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? d.pollIntervalSeconds
        replyConfirmationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .replyConfirmationsEnabled) ?? d.replyConfirmationsEnabled
        monthlyMessageBudget = try c.decodeIfPresent(Int.self, forKey: .monthlyMessageBudget) ?? d.monthlyMessageBudget
        soundAttention = try c.decodeIfPresent(SoundChoice.self, forKey: .soundAttention) ?? d.soundAttention
        soundDone = try c.decodeIfPresent(SoundChoice.self, forKey: .soundDone) ?? d.soundDone
        soundOverrides = try c.decodeIfPresent([String: SoundChoice].self, forKey: .soundOverrides) ?? d.soundOverrides
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? d.onboardingCompleted
    }

    private enum LegacyAgentKeys: String, CodingKey {
        case claudeEnabled, codexEnabled, cursorEnabled

        static let agentNames: [(LegacyAgentKeys, String)] = [
            (.claudeEnabled, "Claude Code"),
            (.codexEnabled, "Codex"),
            (.cursorEnabled, "Cursor"),
        ]
    }
}

enum ConfigStore {
    static func load() -> NotCodeConfig {
        guard let data = try? Data(contentsOf: Paths.config),
              let config = try? JSONDecoder().decode(NotCodeConfig.self, from: data)
        else { return NotCodeConfig() }
        return config
    }

    static func save(_ config: NotCodeConfig) throws {
        Paths.ensureAppSupportExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: Paths.config, options: .atomic)
        // The file holds the Kapso API key; keep it owner-readable only.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Paths.config.path)
    }
}
