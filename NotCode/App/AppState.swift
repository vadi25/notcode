import Foundation
import SwiftUI

final class AppState: ObservableObject {
    @Published var config: NotCodeConfig {
        didSet {
            try? ConfigStore.save(config)
            Task { @MainActor in self.replyPoller.reconfigure(self.config) }
        }
    }
    let replyPoller = ReplyPoller()
    @Published var hookStatuses: [String: HookInstaller.Status] = [:]
    @Published var lastNotification: String?
    @Published var lastDeliveryProblem: String?
    @Published var messageCount: Int = 0
    @Published var testResult: String?
    @Published var availableUpdate: String?   // e.g. "v1.0.1"
    @Published var updating = false

    private var updateTimer: Timer?

    init() {
        config = ConfigStore.load()
        refresh()
        Task { @MainActor in self.replyPoller.reconfigure(self.config) }
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

        hookStatuses = Dictionary(uniqueKeysWithValues:
            AgentRegistry.all.map { ($0.name, $0.hookStatus()) })
        let state = StateStore.load()
        lastNotification = state.lastNotification
        lastDeliveryProblem = state.lastDeliveryProblem
        messageCount = StateStore.currentMonthMessageCount()
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

    /// Installs hooks for the named agents; pass AgentRegistry names.
    func installHooks(agents: [String]) -> String? {
        var errors: [String] = []
        for module in AgentRegistry.all where agents.contains(module.name) {
            do { try module.installHooks() }
            catch { errors.append("\(module.name): \(error.localizedDescription)") }
        }
        refresh()
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func installAllHooks() -> String? {
        installHooks(agents: AgentRegistry.all.map(\.name))
    }

    func uninstallHooks() -> String? {
        var errors: [String] = []
        for module in AgentRegistry.all {
            do { try module.uninstallHooks() }
            catch { errors.append("\(module.name): \(error.localizedDescription)") }
        }
        refresh()
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    var allHooksInstalled: Bool {
        AgentRegistry.all.allSatisfy { hookStatuses[$0.name] == .installed }
    }
}
