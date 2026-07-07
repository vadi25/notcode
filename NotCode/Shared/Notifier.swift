import Foundation

/// The full notification pipeline: toggles → rate limit → sound → WhatsApp.
/// Used by the hook helper and by the app's "send test notification" button.
enum Notifier {
    struct Outcome {
        var soundPlayed = false
        var whatsAppSent = false
        var whatsAppError: String?
        var skippedReason: String?
    }

    @discardableResult
    static func fire(_ event: AgentEvent, config: NotCodeConfig = ConfigStore.load(),
                     blockingSound: Bool = false, bypassFilters: Bool = false) -> Outcome {
        var outcome = Outcome()

        if !bypassFilters {
            if config.paused {
                outcome.skippedReason = "paused"
                return outcome
            }
            switch event.kind {
            case .attention where !config.notifyAttention,
                 .done where !config.notifyDone:
                outcome.skippedReason = "event type disabled"
                return outcome
            default: break
            }
            if (event.agent == "Claude Code" && !config.claudeEnabled)
                || (event.agent == "Codex" && !config.codexEnabled) {
                outcome.skippedReason = "agent disabled"
                return outcome
            }
            if !StateStore.shouldFire(event) {
                outcome.skippedReason = "rate limited"
                return outcome
            }
        }

        let sound = event.kind == .attention ? config.soundAttention : config.soundDone
        outcome.soundPlayed = SoundPlayer.play(sound, volume: config.volume,
                                               blocking: blockingSound)

        guard config.whatsAppEnabled, config.hasKapsoCredentials else { return outcome }

        if !bypassFilters && config.awayOnlyWhatsApp {
            let idleMinutes = IdleTime.secondsSinceLastInput() / 60
            if idleMinutes < config.awayThresholdMinutes {
                Log.append("whatsapp skipped: user active (idle \(Int(idleMinutes * 60))s)")
                return outcome
            }
        }

        let client = KapsoClient(apiKey: config.kapsoAPIKey,
                                 phoneNumberID: config.phoneNumberID)
        switch client.sendText(event.whatsAppText, to: config.recipientPhone,
                               templateName: config.templateName,
                               templateLanguage: config.templateLanguage) {
        case .success:
            outcome.whatsAppSent = true
            Log.append("whatsapp sent: \(event.whatsAppText)")
        case .failure(let error):
            outcome.whatsAppError = String(describing: error)
            Log.append("whatsapp failed: \(error)")
        }
        return outcome
    }
}
