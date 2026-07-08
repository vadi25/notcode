import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Sections

private enum SettingsSection: String, CaseIterable, Identifiable {
    case status = "Status"
    case whatsApp = "WhatsApp"
    case sounds = "Sounds"
    case behavior = "Behavior"
    case agents = "Agents"
    case beta = "Beta"

    var id: Self { self }

    var icon: String {
        switch self {
        case .status: return "waveform.path.ecg"
        case .whatsApp: return "message.fill"
        case .sounds: return "speaker.wave.2.fill"
        case .behavior: return "gearshape.fill"
        case .agents: return "terminal.fill"
        case .beta: return "testtube.2"
        }
    }

    var tint: Color {
        switch self {
        case .status: return .teal
        case .whatsApp: return .green
        case .sounds: return .pink
        case .behavior: return .blue
        case .agents: return .indigo
        case .beta: return .orange
        }
    }

    var subtitle: String {
        switch self {
        case .status: return "Is everything working? Check here"
        case .whatsApp: return "Phone notifications and the reply loop"
        case .sounds: return "Alert sounds, volume, and per-agent voices"
        case .behavior: return "When and how NotCode notifies you"
        case .agents: return "Hook installs for each coding agent"
        case .beta: return "Experimental features, off by default"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: SettingsSection? = .status

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsSection.allCases) { section in
                    HStack(spacing: DS.Spacing.s + 2) {
                        TintedIcon(systemImage: section.icon, tint: section.tint)
                        Text(section.rawValue)
                    }
                    .padding(.vertical, 2)
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
        } detail: {
            ZStack {
                detail.transition(.opacity)
            }
            .animation(.easeOut(duration: 0.18), value: selection)
        }
        .frame(width: 760, height: 560)
        .onAppear {
            state.refresh()
            // Menu bar apps have no dock presence; without this the settings
            // window can open behind other apps.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var detail: some View {
        let section = selection ?? .status
        return SettingsPane(title: section.rawValue,
                            subtitle: section.subtitle,
                            systemImage: section.icon,
                            tint: section.tint) {
            switch section {
            case .status: StatusSettings()
            case .whatsApp: WhatsAppSettings()
            case .sounds: SoundsSettings()
            case .behavior: BehaviorSettings()
            case .agents: AgentsSettings()
            case .beta: BetaSettings()
            }
        }
        .id(section)
    }
}

// MARK: - Status

/// The "is this actually working?" panel: per-agent CLI detection, hook state,
/// when we last heard from each agent, and a one-click test notification.
struct StatusSettings: View {
    @EnvironmentObject private var state: AppState
    /// Agent name → error from an inline hook install, if any.
    @State private var installErrors: [String: String] = [:]

    var body: some View {
        SettingsCard {
            SettingsRow("Hear it for yourself",
                        subtitle: "Plays your attention sound and, if WhatsApp is set up, pings your phone.") {
                Button("Send test notification") { state.sendTestNotification() }
            }
            if let result = state.testResult {
                Text(result)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        ForEach(AgentRegistry.all, id: \.name) { agent in
            agentCard(agent)
        }

        Text("\"Last alert\" updates whenever a hooked agent needs you or finishes a task, even if the notification itself was muted or rate limited.")
            .dsCaption()
    }

    private func agentCard(_ agent: AgentModule) -> some View {
        SettingsCard {
            HStack(spacing: DS.Spacing.s + 2) {
                TintedIcon(systemImage: "terminal.fill", tint: .indigo)
                Text(agent.name).font(.headline)
                Spacer(minLength: DS.Spacing.m)
                lastAlertLabel(agent)
            }
            Divider()
            cliRow(agent)
            hookRow(agent)
            if let error = installErrors[agent.name] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func cliRow(_ agent: AgentModule) -> some View {
        HStack(spacing: DS.Spacing.s) {
            switch state.cliInstalled[agent.name] {
            case .some(true):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Installed on this Mac")
            case .some(false):
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                Text("CLI not found on this Mac")
                    .foregroundStyle(.secondary)
            case .none:
                ProgressView()
                    .controlSize(.small)
                Text("Looking for the CLI")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func hookRow(_ agent: AgentModule) -> some View {
        let status = state.hookStatuses[agent.name] ?? .notInstalled
        HStack(spacing: DS.Spacing.s) {
            if status == .installed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Hook active")
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Hook not installed")
                    .foregroundStyle(.secondary)
                Spacer(minLength: DS.Spacing.m)
                Button("Install") { install(agent.name) }
                    .controlSize(.small)
            }
        }
        .font(.subheadline)
    }

    /// "Last alert: 2 min. ago" or "Last alert: none yet", kept fresh while
    /// the window stays open.
    private func lastAlertLabel(_ agent: AgentModule) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Group {
                if let date = state.lastEventByAgent[agent.name] {
                    Text("Last alert: \(Self.relative.localizedString(for: date, relativeTo: context.date))")
                } else {
                    Text("Last alert: none yet")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func install(_ agent: String) {
        installErrors[agent] = state.installHooks(agents: [agent])
    }
}

// MARK: - WhatsApp

struct WhatsAppSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var sendResult: String?

    var body: some View {
        SettingsCard {
            SettingsRow("Send WhatsApp notifications",
                        subtitle: "Get pinged on your phone when an agent needs you or finishes.") {
                Toggle("Send WhatsApp notifications", isOn: $state.config.whatsAppEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }

        SettingsCard("Kapso credentials", systemImage: "key.fill") {
            SettingsRow("API key") {
                SecureField("Paste your API key", text: $state.config.kapsoAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: DS.Size.fieldWidth)
            }
            SettingsRow("WhatsApp phone number ID") {
                TextField("From the number's page", text: $state.config.phoneNumberID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: DS.Size.fieldWidth)
            }
            SettingsRow("Your phone number") {
                TextField("e.g. 34600111222", text: $state.config.recipientPhone)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: DS.Size.fieldWidth)
            }
            Text("Get these at [kapso.com](https://kapso.com): connect a WhatsApp number, then copy the API key from Project Settings → API Keys and the phone number ID from the number's page.")
                .dsCaption()
        }

        SettingsCard("Connection test", systemImage: "paperplane.fill") {
            VerifyConnectionRow()
            Divider()
            HStack(spacing: DS.Spacing.m) {
                Button("Send test message") { sendTest() }
                    .disabled(!state.config.hasKapsoCredentials)
                if let sendResult {
                    Text(sendResult)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("WhatsApp delivers messages for 24h after your last message to the bot. If sends start failing, just text your Kapso number again (any message works) and the window reopens instantly.")
                .dsCaption()
        }

        SettingsCard("Reply loop", systemImage: "arrow.uturn.left.circle.fill") {
            SettingsRow("Reply speed",
                        subtitle: "How often NotCode checks for your replies while running. Polling is free on Kapso; this only affects battery.") {
                Picker("Reply speed", selection: $state.config.pollIntervalSeconds) {
                    Text("Instant (5 s)").tag(5)
                    Text("Fast (15 s)").tag(15)
                    Text("Relaxed (1 min)").tag(60)
                    Text("Battery saver (5 min)").tag(300)
                }
                .labelsHidden()
                .frame(width: DS.Size.controlWidth)
            }
            Divider()
            SettingsRow("Send progress confirmations",
                        subtitle: "Off saves messages. You still get error alerts, just not the ▶️/✅ updates.") {
                Toggle("Send progress confirmations", isOn: $state.config.replyConfirmationsEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Divider()
            let count = state.messageCount
            let budget = state.config.monthlyMessageBudget
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack {
                    Text("Monthly usage")
                    Spacer()
                    Text("\(count) / \(budget) messages this month")
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(min(count, budget)), total: Double(max(budget, 1)))
                Text("Kapso Free ≈ 2,000 msgs/mo. Polling is free; only messages sent or received count.")
                    .dsCaption()
            }
        }
    }

    private func sendTest() {
        sendResult = "Sending…"
        let config = state.config
        Task.detached {
            let client = KapsoClient(apiKey: config.kapsoAPIKey,
                                     phoneNumberID: config.phoneNumberID)
            let result = client.sendText(
                "NotCode is connected, you're all set 🎉",
                to: config.recipientPhone)
            if case .success = result { StateStore.recordWhatsAppSent() }
            await MainActor.run {
                switch result {
                case .success: sendResult = "Delivered ✓, check your WhatsApp"
                case .failure(let error): sendResult = "Failed: \(error.userHint)"
                }
            }
        }
    }
}

/// "Verify connection" button plus inline status: spinner while checking,
/// green "Connected" on success, a specific red hint on failure. Checks the
/// Kapso credentials only; it sends nothing to the phone. Shared by the
/// WhatsApp settings pane and onboarding step 3.
struct VerifyConnectionRow: View {
    @EnvironmentObject private var state: AppState
    @State private var checking = false
    @State private var result: Result<Void, KapsoClient.SendError>?

    private var hasCredentials: Bool {
        !state.config.kapsoAPIKey.isEmpty && !state.config.phoneNumberID.isEmpty
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
            Button("Verify connection") { verify() }
                .disabled(checking || !hasCredentials)
            if checking {
                ProgressView()
                    .controlSize(.small)
            } else {
                switch result {
                case .success:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failure(let error):
                    Label(error.userHint, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                case .none:
                    Text("Checks your API key and phone number ID without sending anything.")
                        .dsCaption()
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: checking)
    }

    private func verify() {
        checking = true
        result = nil
        let config = state.config
        Task.detached {
            let client = KapsoClient(apiKey: config.kapsoAPIKey,
                                     phoneNumberID: config.phoneNumberID)
            let outcome = client.verifyConnection()
            await MainActor.run {
                checking = false
                result = outcome
            }
        }
    }
}

// MARK: - Sounds

struct SoundsSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        SettingsCard("Alert sounds", systemImage: "bell.badge.fill") {
            SoundPickerRow(title: "Needs your attention",
                           choice: $state.config.soundAttention,
                           volume: state.config.volume)
            Divider()
            SoundPickerRow(title: "Task finished",
                           choice: $state.config.soundDone,
                           volume: state.config.volume)
        }

        SettingsCard("Volume", systemImage: "speaker.wave.2.fill") {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(value: $state.config.volume, in: 0...1) {
                    Text("Volume")
                }
                .labelsHidden()
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
        }

        SettingsCard("Per-agent sounds", systemImage: "person.2.wave.2.fill") {
            Text("Give an agent its own voice. Anything left on \"Default\" uses the sounds above.")
                .dsCaption()
            ForEach(AgentRegistry.all, id: \.name) { agent in
                Divider()
                Text(agent.name)
                    .font(.subheadline.weight(.semibold))
                if agent.emitsAttention {
                    OverrideSoundPickerRow(
                        title: "Needs attention",
                        choice: overrideBinding(agent.name, .attention),
                        fallback: state.config.soundAttention,
                        volume: state.config.volume)
                }
                OverrideSoundPickerRow(
                    title: "Task finished",
                    choice: overrideBinding(agent.name, .done),
                    fallback: state.config.soundDone,
                    volume: state.config.volume)
            }
        }
    }

    private func overrideBinding(_ agent: String, _ kind: AgentEvent.Kind) -> Binding<SoundChoice?> {
        let key = NotCodeConfig.soundOverrideKey(agent, kind)
        return Binding(
            get: { state.config.soundOverrides[key] },
            set: { state.config.soundOverrides[key] = $0 })
    }
}

/// A sound picker whose nil state means "use the global default".
struct OverrideSoundPickerRow: View {
    let title: String
    @Binding var choice: SoundChoice?
    let fallback: SoundChoice
    let volume: Double

    private var bundled: [String] { HelperDeployer.bundledSoundNames() }
    private var system: [String] { SoundPlayer.systemSoundNames() }

    var body: some View {
        SettingsRow(title) {
            Picker(title, selection: $choice) {
                Text("Default").tag(SoundChoice?.none)
                Divider()
                Text("None").tag(SoundChoice?.some(.silent))
                if !bundled.isEmpty {
                    Divider()
                    ForEach(bundled, id: \.self) { name in
                        Text("NotCode: \((name as NSString).deletingPathExtension)")
                            .tag(SoundChoice?.some(SoundChoice(kind: .bundled, value: name)))
                    }
                }
                Divider()
                ForEach(system, id: \.self) { name in
                    Text(name).tag(SoundChoice?.some(SoundChoice(kind: .system, value: name)))
                }
                if choice?.kind == .file, let choice {
                    Divider()
                    Text("Custom: \((choice.value as NSString).lastPathComponent)")
                        .tag(SoundChoice?.some(choice))
                }
            }
            .labelsHidden()
            .frame(width: DS.Size.controlWidth)
            Button("Preview") {
                SoundPlayer.play(choice ?? fallback, volume: volume)
            }
        }
    }
}

struct SoundPickerRow: View {
    let title: String
    @Binding var choice: SoundChoice
    let volume: Double

    private var bundled: [String] { HelperDeployer.bundledSoundNames() }
    private var system: [String] { SoundPlayer.systemSoundNames() }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            SettingsRow(title) {
                Picker("Sound", selection: $choice) {
                    Text("None").tag(SoundChoice.silent)
                    if !bundled.isEmpty {
                        Divider()
                        ForEach(bundled, id: \.self) { name in
                            Text("NotCode: \((name as NSString).deletingPathExtension)")
                                .tag(SoundChoice(kind: .bundled, value: name))
                        }
                    }
                    Divider()
                    ForEach(system, id: \.self) { name in
                        Text(name).tag(SoundChoice(kind: .system, value: name))
                    }
                    if choice.kind == .file {
                        Divider()
                        Text("Custom: \((choice.value as NSString).lastPathComponent)")
                            .tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: DS.Size.controlWidth)
            }
            HStack(spacing: DS.Spacing.s) {
                Button("Choose file…") { chooseFile() }
                Button("Preview") {
                    SoundPlayer.play(choice, volume: volume)
                }
                .disabled(choice.kind == .none)
            }
            .controlSize(.small)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            choice = SoundChoice(kind: .file, value: url.path)
        }
    }
}

// MARK: - Behavior

struct BehaviorSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        SettingsCard("Notify me when", systemImage: "bell.fill") {
            SettingsRow("An agent needs my attention") {
                Toggle("An agent needs my attention", isOn: $state.config.notifyAttention)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Divider()
            SettingsRow("A task finishes") {
                Toggle("A task finishes", isOn: $state.config.notifyDone)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }

        SettingsCard("Agents", systemImage: "terminal.fill") {
            Text("Turn an agent off to mute all its notifications.")
                .dsCaption()
            ForEach(AgentRegistry.all, id: \.name) { agent in
                Divider()
                SettingsRow(agent.name) {
                    Toggle(agent.name, isOn: Binding(
                        get: { state.config.isEnabled(agent.name) },
                        set: { state.config.setEnabled(agent.name, $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }

        SettingsCard("Quiet while you work", systemImage: "moon.fill") {
            SettingsRow("Skip notifications while I'm actively in a terminal or IDE",
                        subtitle: "When you're typing in Terminal, iTerm, VS Code, etc., you can see the agent finish, so NotCode stays silent. Step away or switch apps and notifications resume. Cursor agent runs always notify: their panel can be hidden while you code, so you might miss the finish.") {
                Toggle("Skip notifications while I'm actively in a terminal or IDE",
                       isOn: $state.config.suppressWhileWatching)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }

        SettingsCard("WhatsApp economy", systemImage: "battery.75") {
            SettingsRow("Only send WhatsApp when I'm away from the Mac") {
                Toggle("Only send WhatsApp when I'm away from the Mac",
                       isOn: $state.config.awayOnlyWhatsApp)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if state.config.awayOnlyWhatsApp {
                Divider()
                SettingsRow("Away threshold: \(Int(state.config.awayThresholdMinutes)) min",
                            subtitle: "Sounds always play locally; WhatsApp messages are only sent when you haven't touched the keyboard or mouse for this long.") {
                    Stepper(value: $state.config.awayThresholdMinutes, in: 1...60, step: 1) {
                        Text("Away threshold: \(Int(state.config.awayThresholdMinutes)) min")
                    }
                    .labelsHidden()
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.config.awayOnlyWhatsApp)

        SettingsCard("Startup", systemImage: "power") {
            SettingsRow("Launch NotCode at login") {
                Toggle("Launch NotCode at login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            loginItemError = nil
                        } catch {
                            loginItemError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Beta features

/// Home for experimental features. Each one gets its own card with a BETA
/// badge, an honest description, and any sub-options. Add new betas here and
/// remove them when they graduate to a normal section.
struct BetaSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        SettingsCard {
            Label {
                Text("These features work, but they're new and their edges may be rough. They're off by default, safe to toggle anytime, and feedback is very welcome: [open an issue](https://github.com/vadi25/notcode/issues) if something feels wrong.")
                    .font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
        }

        SettingsCard {
            HStack(spacing: DS.Spacing.m) {
                HStack(spacing: 6) {
                    Text("Reply from your phone")
                    BetaBadge()
                }
                Spacer(minLength: DS.Spacing.m)
                Toggle("Reply from your phone", isOn: $state.config.replyLoopEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if state.config.replyLoopEnabled {
                Divider()
                SettingsRow("Include a short excerpt of the agent's answer") {
                    Toggle("Include a short excerpt of the agent's answer",
                           isOn: $state.config.replyExcerptEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            Text("Reply to any WhatsApp notification to keep prompting that session, or use \"project-name: your message\" to target a specific one. Text \"help\" to your Kapso number for a cheat sheet. Only messages from your own number are accepted, and remote runs never skip permission prompts. Needs WhatsApp configured and the NotCode app running; Claude Code sessions continue headlessly, so a terminal still open on that session won't show the remote turns.")
                .dsCaption()
            if state.config.replyLoopEnabled && !state.config.whatsAppEnabled {
                Label("WhatsApp notifications are off. Turn them on in the WhatsApp section for replies to work.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.config.replyLoopEnabled)

        Text("That's all for now. New experiments will land here first.")
            .dsCaption()
    }
}

// MARK: - Agents (hook install)

struct AgentsSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var message: String?
    @State private var showClaudePreview = false
    @State private var claudePreview = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            ForEach(AgentRegistry.all, id: \.name) { agent in
                SettingsCard(agent.name, systemImage: "terminal.fill") {
                    statusRow(state.hookStatuses[agent.name] ?? .notInstalled,
                              detail: agent.installDetail)
                    HStack(spacing: DS.Spacing.s) {
                        Button("Install hooks") { install(agent.name) }
                            .disabled(state.hookStatuses[agent.name] == .installed)
                        if (try? agent.installPreview()) != nil {
                            Button("Preview change") {
                                claudePreview = (try? agent.installPreview() ?? nil) ?? "(unavailable)"
                                showClaudePreview = true
                            }
                        }
                    }
                }
            }

            SettingsCard {
                Button("Uninstall all NotCode hooks", role: .destructive) {
                    message = state.uninstallHooks() ?? "Hooks removed. Backups kept as *.notcode-backup."
                }
                if let message {
                    Text(message).font(.caption)
                }
                Text("A backup of each file is written next to it (*.notcode-backup) before any change.")
                    .dsCaption()
            }
        }
        .sheet(isPresented: $showClaudePreview) {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                Text("~/.claude/settings.json after install:").font(.headline)
                ScrollView {
                    Text(claudePreview)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Close") { showClaudePreview = false }
            }
            .padding()
            .frame(width: 480, height: 360)
        }
    }

    private func install(_ agent: String) {
        message = state.installHooks(agents: [agent]) ?? "Installed ✓"
    }

    @ViewBuilder
    private func statusRow(_ status: HookInstaller.Status, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch status {
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notInstalled:
                Label("Not installed", systemImage: "circle")
                    .foregroundStyle(.secondary)
            case .conflict(let existing):
                Label("Existing notify command found", systemImage: "info.circle")
                    .foregroundStyle(.orange)
                Text(existing).font(.system(.caption, design: .monospaced))
                Text("Codex allows only one notify command. Install will chain them: your existing handler keeps working and NotCode gets notified too.")
                    .font(.caption)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
