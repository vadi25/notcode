import Foundation
import SwiftUI

final class AppState: ObservableObject {
    @Published var config: NotCodeConfig {
        didSet { try? ConfigStore.save(config) }
    }
    @Published var claudeHooks: HookInstaller.Status = .notInstalled
    @Published var codexHooks: HookInstaller.Status = .notInstalled
    @Published var lastNotification: String?
    @Published var testResult: String?

    init() {
        config = ConfigStore.load()
        refresh()
    }

    func refresh() {
        claudeHooks = HookInstaller.claudeStatus()
        codexHooks = HookInstaller.codexStatus()
        let state = StateStore.load()
        lastNotification = state.lastNotification
    }

    func sendTestNotification() {
        testResult = "Sending…"
        let config = self.config
        Task.detached {
            let event = AgentEvent(
                agent: "Claude Code", kind: .attention,
                detail: "test notification 🎉", cwd: nil, sessionID: "app-test")
            let outcome = Notifier.fire(event, config: config, bypassFilters: true)
            await MainActor.run {
                if let error = outcome.whatsAppError {
                    self.testResult = "Sound ✓ — WhatsApp failed: \(error)"
                } else if outcome.whatsAppSent {
                    self.testResult = "Sound ✓ WhatsApp ✓"
                } else if outcome.soundPlayed {
                    self.testResult = config.whatsAppEnabled
                        ? "Sound ✓ (WhatsApp not configured)" : "Sound ✓"
                } else {
                    self.testResult = "Could not play the selected sound"
                }
                self.refresh()
            }
        }
    }

    func installHooks(claude: Bool, codex: Bool) -> String? {
        var errors: [String] = []
        if claude {
            do { try HookInstaller.installClaude() }
            catch { errors.append("Claude Code: \(error.localizedDescription)") }
        }
        if codex {
            do { try HookInstaller.installCodex() }
            catch { errors.append("Codex: \(error.localizedDescription)") }
        }
        refresh()
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func uninstallHooks() -> String? {
        var errors: [String] = []
        do { try HookInstaller.uninstallClaude() }
        catch { errors.append("Claude Code: \(error.localizedDescription)") }
        do { try HookInstaller.uninstallCodex() }
        catch { errors.append("Codex: \(error.localizedDescription)") }
        refresh()
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}
