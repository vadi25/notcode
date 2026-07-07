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
            if !config.isEnabled(event.agent) {
                outcome.skippedReason = "agent disabled"
                return outcome
            }
            // Some agents (Cursor) are exempt from the watching filter: their
            // agent panel can be hidden while you code in the same window, so
            // being in the app does not mean you saw the run finish.
            if config.suppressWhileWatching,
               AgentRegistry.byName(event.agent)?.bypassesWatchingFilter != true,
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

        let sound = config.sound(for: event.agent, kind: event.kind)
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
        var text = event.whatsAppText
        if config.replyLoopEnabled {
            text += "\n↩️ Reply to continue · \"help\" for options"
        }
        switch client.sendText(text, to: config.recipientPhone) {
        case .success:
            outcome.whatsAppSent = true
            StateStore.recordDeliveryProblem(nil)
            StateStore.recordWhatsAppSent()
            Log.append("whatsapp sent: \(event.whatsAppText)")
        case .failure(let error):
            outcome.whatsAppError = error.userHint
            StateStore.recordDeliveryProblem(error.userHint)
            Log.append("whatsapp failed: \(error)")
        }
        return outcome
    }
}
