import Foundation
import SwiftUI
import AppKit

enum UpdateCheckStatus: Equatable {
    case idle
    case checking
    case upToDate(Date)
    case available(UpdateChecker.ReleaseInfo)
    case failed(String)
}

final class AppState: ObservableObject {
    @Published var config: NotCodeConfig {
        didSet {
            try? ConfigStore.save(config)
            Task { @MainActor in self.replyPoller.reconfigure(self.config) }
        }
    }
    @Published var mcpPool: MCPPool {
        didSet {
            guard !suppressPoolSave else { return }
            try? MCPPoolStore.save(mcpPool)
        }
    }
    private var suppressPoolSave = false

    let replyPoller = ReplyPoller()
    @Published var hookStatuses: [String: HookInstaller.Status] = [:]
    /// Agent name → whether its CLI was found on the login-shell PATH.
    /// nil (missing key) while the async probe is still running.
    @Published var cliInstalled: [String: Bool] = [:]
    /// Agent name → when the hook helper last received an event from it.
    @Published var lastEventByAgent: [String: Date] = [:]
    @Published var lastNotification: String?
    @Published var lastDeliveryProblem: String?
    @Published var messageCount: Int = 0
    @Published var testResult: String?

    // Updates
    @Published var availableUpdate: String?   // e.g. "v1.4.1"
    @Published var availableRelease: UpdateChecker.ReleaseInfo?
    @Published var updateStatus: UpdateCheckStatus = .idle
    @Published var updating = false

    // Sleep
    /// Whether macOS sleep is switched off system-wide (`pmset disablesleep`).
    @Published var sleepDisabled = false
    @Published var sleepError: String?

    // MCP Hub
    @Published var mcpScanning = false
    @Published var mcpScanReport: MCPScanReport?
    @Published var mcpSyncReport: MCPSyncReport?
    @Published var mcpStatusMessage: String?

    // Efficiency: throttle slow subprocess probes so opening the menu bar is instant.
    private var lastCLIProbeAt: Date?
    private var lastSleepProbeAt: Date?
    private let cliProbeTTL: TimeInterval = 300
    private let sleepProbeTTL: TimeInterval = 15

    private var updateTimer: Timer?
    private var profilePromptTimer: Timer?
    /// Projects already prompted during this app session so we never nag twice.
    private var promptedProjectsThisSession: Set<String> = []

    init() {
        config = ConfigStore.load()
        mcpPool = MCPPoolStore.load()
        refresh(forceProbes: true)
        Task { @MainActor in self.replyPoller.reconfigure(self.config) }
        checkForUpdates()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
        // Lightweight file-existence check for unbound project profile prompts.
        profilePromptTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.checkPendingProfilePrompt()
        }
        // First-time non-destructive auto-discovery of existing MCPs & auth.
        if mcpPool.lastScanDate == nil {
            scanMCPs()
        }
    }

    // MARK: - Updates

    func checkForUpdates(userInitiated: Bool = false) {
        if userInitiated {
            updateStatus = .checking
        }
        Task {
            let result = await UpdateChecker.checkForUpdateInfo()
            await MainActor.run {
                switch result {
                case .success(let release):
                    if let release {
                        self.availableRelease = release
                        self.availableUpdate = release.version
                        self.updateStatus = .available(release)
                    } else {
                        self.availableRelease = nil
                        self.availableUpdate = nil
                        self.updateStatus = .upToDate(Date())
                    }
                case .failure(let error):
                    if userInitiated {
                        self.updateStatus = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    func performUpdate() {
        guard UpdateChecker.canSelfUpdate else {
            NSWorkspace.shared.open(availableRelease?.htmlURL ?? UpdateChecker.releasesPage)
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

    // MARK: - Refresh (fast path + throttled subprocesses)

    func refresh(forceProbes: Bool = false) {
        // Pick up external edits (helper, MCP gateway, another instance) instead
        // of clobbering them with our stale in-memory copy on the next save.
        let onDisk = ConfigStore.load()
        if onDisk != config { config = onDisk }

        let poolOnDisk = MCPPoolStore.load()
        if poolOnDisk != mcpPool {
            suppressPoolSave = true
            mcpPool = poolOnDisk
            suppressPoolSave = false
        }

        hookStatuses = Dictionary(uniqueKeysWithValues:
            AgentRegistry.all.map { ($0.name, $0.hookStatus()) })
        let state = StateStore.load()
        lastNotification = state.lastNotification
        lastDeliveryProblem = state.lastDeliveryProblem
        messageCount = StateStore.currentMonthMessageCount()
        lastEventByAgent = state.lastEventByAgent

        let now = Date()
        if forceProbes || lastCLIProbeAt == nil || now.timeIntervalSince(lastCLIProbeAt!) > cliProbeTTL {
            lastCLIProbeAt = now
            refreshCLIDetection()
        }
        if forceProbes || lastSleepProbeAt == nil || now.timeIntervalSince(lastSleepProbeAt!) > sleepProbeTTL {
            lastSleepProbeAt = now
            refreshSleepSetting()
        }
    }

    /// Re-reads the sleep switch, which a terminal (`pmset`) can flip at any time.
    private func refreshSleepSetting() {
        Task.detached { [weak self] in
            let disabled = SleepSetting.current()
            await MainActor.run { self?.sleepDisabled = disabled }
        }
    }

    /// Flips system sleep. macOS asks for an administrator password; cancelling
    /// that prompt leaves everything as it was.
    func toggleSleep() {
        do {
            try SleepSetting.set(disabled: !sleepDisabled)
            sleepError = nil
        } catch SleepSetting.ChangeError.cancelled {
            sleepError = nil
        } catch {
            Log.append("sleep toggle failed: \(error)")
            sleepError = "Could not change sleep: \(error.localizedDescription)"
        }
        lastSleepProbeAt = Date()
        refreshSleepSetting()
    }

    /// Probes each agent's CLI on the login-shell PATH. Each probe spawns a
    /// shell (slow), so it runs off the main thread and is cached for 5 minutes.
    private func refreshCLIDetection() {
        let modules = AgentRegistry.all
        Task.detached { [weak self] in
            let installed = Dictionary(uniqueKeysWithValues:
                modules.map { ($0.name, $0.isInstalledOnMachine) })
            await MainActor.run { self?.cliInstalled = installed }
        }
    }

    // MARK: - MCP Hub Operations

    func scanMCPs() {
        guard !mcpScanning else { return }
        mcpScanning = true
        mcpStatusMessage = "Scanning installed AI apps…"
        var workingPool = mcpPool
        Task.detached { [weak self] in
            let report = MCPScanner.scanAll(into: &workingPool)
            await MainActor.run {
                guard let self else { return }
                self.mcpPool = workingPool
                self.mcpScanReport = report
                self.mcpScanning = false
                let variantsNote = report.authVariantsCreated > 0
                    ? " · \(report.authVariantsCreated) auth variant profile\(report.authVariantsCreated == 1 ? "" : "s") created"
                    : ""
                self.mcpStatusMessage = "Found \(report.totalInPool) MCPs (\(report.newlyAdded) new)\(variantsNote)"
            }
        }
    }

    func syncMCPs(profile: MCPProfile? = nil) {
        let currentPool = mcpPool
        let target = profile ?? currentPool.activeProfile
        mcpStatusMessage = "Syncing \(target.name)…"
        Task.detached { [weak self] in
            let report = MCPSyncer.sync(pool: currentPool, profile: target)
            await MainActor.run {
                guard let self else { return }
                self.mcpSyncReport = report
                self.mcpPool.lastSyncDate = report.syncedAt
                if report.failedResults.isEmpty {
                    self.mcpStatusMessage = "Synced '\(report.profileName)' to \(report.succeededCount) app\(report.succeededCount == 1 ? "" : "s") ✓"
                } else {
                    let failedNames = report.failedResults.map(\.app.shortName).joined(separator: ", ")
                    self.mcpStatusMessage = "Synced \(report.succeededCount)/\(report.results.count) (failed: \(failedNames))"
                }
            }
        }
    }

    func switchProfile(_ profileID: UUID, syncImmediately: Bool = true) {
        guard let target = mcpPool.profile(byID: profileID) else { return }
        mcpPool.activeProfileID = target.id
        if syncImmediately {
            syncMCPs(profile: target)
        }
    }

    func bindProject(_ path: String, to profileID: UUID, activateAndSync: Bool = true) {
        mcpPool.bindProject(path, to: profileID)
        if activateAndSync {
            switchProfile(profileID, syncImmediately: true)
        }
    }

    func checkPendingProfilePrompt() {
        guard mcpPool.askProfileForNewProjects,
              let pending = PendingProfilePromptStore.consume()
        else { return }
        let normalized = URL(fileURLWithPath: pending.projectPath).standardizedFileURL.path
        guard mcpPool.binding(forProjectPath: normalized) == nil,
              !promptedProjectsThisSession.contains(normalized)
        else { return }
        promptedProjectsThisSession.insert(normalized)
        Task { @MainActor in
            ProfilePromptController.shared.show(for: pending, state: self)
        }
    }

    // MARK: - Notifications & Hooks

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
                    self.testResult = "Sound ✓, WhatsApp failed: \(error)"
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
