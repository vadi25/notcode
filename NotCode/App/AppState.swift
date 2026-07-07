import Foundation
import SwiftUI

final class AppState: ObservableObject {
    @Published var config: NotCodeConfig {
        didSet { try? ConfigStore.save(config) }
    }
    @Published var claudeHooks: HookInstaller.Status = .notInstalled
    @Published var codexHooks: HookInstaller.Status = .notInstalled
    @Published var cursorHooks: HookInstaller.Status = .notInstalled
    @Published var lastNotification: String?
    @Published var lastDeliveryProblem: String?
    @Published var testResult: String?
    @Published var availableUpdate: String?   // e.g. "v1.0.1"
    @Published var updating = false

    private var updateTimer: Timer?

    init() {
        config = ConfigStore.load()
        refresh()
        checkForUpdates()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
    }

    func checkForUpdates() {
        Task {
            let newer = await UpdateChecker.checkForUpdate()
            await MainActor.run { self.availableUpdate = newer }
        }
    }

    func performUpdate() {
        guard UpdateChecker.canSelfUpdate else {
            NSWorkspace.shared.open(UpdateChecker.releasesPage)
            return
        }
        updating = true
        Task {
            do {
                try await UpdateChecker.downloadAndInstall()
            } catch {
                Log.append("update failed: \(error)")
                await MainActor.run {
                    self.updating = false
                    self.testResult = "Update failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func refresh() {
        // Pick up external edits (helper, another instance) instead of
        // clobbering them with our stale in-memory copy on the next save.
        let onDisk = ConfigStore.load()
        if onDisk != config { config = onDisk }

        claudeHooks = HookInstaller.claudeStatus()
        codexHooks = HookInstaller.codexStatus()
        cursorHooks = HookInstaller.cursorStatus()
        let state = StateStore.load()
        lastNotification = state.lastNotification
        lastDeliveryProblem = state.lastDeliveryProblem
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

    func installHooks(claude: Bool, codex: Bool, cursor: Bool) -> String? {
        var errors: [String] = []
        if claude {
            do { try HookInstaller.installClaude() }
            catch { errors.append("Claude Code: \(error.localizedDescription)") }
        }
        if codex {
            do { try HookInstaller.installCodex() }
            catch { errors.append("Codex: \(error.localizedDescription)") }
        }
        if cursor {
            do { try HookInstaller.installCursor() }
            catch { errors.append("Cursor: \(error.localizedDescription)") }
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
        do { try HookInstaller.uninstallCursor() }
        catch { errors.append("Cursor: \(error.localizedDescription)") }
        refresh()
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}
