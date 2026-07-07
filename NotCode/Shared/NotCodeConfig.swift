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
    var claudeEnabled: Bool = true
    var codexEnabled: Bool = true
    /// Only send WhatsApp when no keyboard/mouse input for this long. 0 = always send.
    var awayOnlyWhatsApp: Bool = true
    var awayThresholdMinutes: Double = 2

    // Sounds
    var soundAttention: SoundChoice = .defaultAttention
    var soundDone: SoundChoice = .defaultDone
    var volume: Double = 1.0

    // App state
    var onboardingCompleted: Bool = false

    var hasKapsoCredentials: Bool {
        !kapsoAPIKey.isEmpty && !phoneNumberID.isEmpty && !recipientPhone.isEmpty
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
