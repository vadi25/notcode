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
                || (event.agent == "Codex" && !config.codexEnabled)
                || (event.agent == "Cursor" && !config.cursorEnabled) {
                outcome.skippedReason = "agent disabled"
                return outcome
            }
            // Cursor is exempt from the watching filter: its agent panel can be
            // hidden while you code in the same window, so being in Cursor does
            // not mean you saw the run finish (unlike a CLI in a terminal).
            if config.suppressWhileWatching, event.agent != "Cursor",
               FocusDetector.userIsWatchingTerminal(
                   awayThresholdSeconds: config.awayThresholdMinutes * 60) {
                outcome.skippedReason = "user is watching the terminal"
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
        switch client.sendText(event.whatsAppText, to: config.recipientPhone) {
        case .success:
            outcome.whatsAppSent = true
            StateStore.recordDeliveryProblem(nil)
            Log.append("whatsapp sent: \(event.whatsAppText)")
        case .failure(let error):
            outcome.whatsAppError = error.userHint
            StateStore.recordDeliveryProblem(error.userHint)
            Log.append("whatsapp failed: \(error)")
        }
        return outcome
    }
}
