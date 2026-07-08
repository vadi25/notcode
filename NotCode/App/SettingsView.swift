import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            WhatsAppSettings()
                .tabItem { Label("WhatsApp", systemImage: "message") }
            SoundsSettings()
                .tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
            BehaviorSettings()
                .tabItem { Label("Behavior", systemImage: "gearshape") }
            AgentsSettings()
                .tabItem { Label("Agents", systemImage: "terminal") }
            BetaSettings()
                .tabItem { Label("Beta", systemImage: "testtube.2") }
        }
        .frame(width: 480, height: 460)
        .onAppear {
            state.refresh()
            // Menu bar apps have no dock presence; without this the settings
            // window can open behind other apps.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - WhatsApp

struct WhatsAppSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var sendResult: String?

    var body: some View {
        Form {
            Toggle("Send WhatsApp notifications", isOn: $state.config.whatsAppEnabled)

            Section("Kapso credentials") {
                SecureField("API key", text: $state.config.kapsoAPIKey)
                TextField("WhatsApp phone number ID", text: $state.config.phoneNumberID)
                TextField("Your phone number (e.g. 34600111222)", text: $state.config.recipientPhone)
                Text("Get these at [kapso.com](https://kapso.com): connect a WhatsApp number, then copy the API key from Project Settings → API Keys and the phone number ID from the number's page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Send test message") { sendTest() }
                    .disabled(!state.config.hasKapsoCredentials)
                if let sendResult {
                    Text(sendResult).font(.caption)
                }
                Text("WhatsApp delivers messages for 24h after your last message to the bot. If sends start failing, just text your Kapso number again (any message works) — the window reopens instantly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func sendTest() {
        sendResult = "Sending…"
        let config = state.config
        Task.detached {
            let client = KapsoClient(apiKey: config.kapsoAPIKey,
                                     phoneNumberID: config.phoneNumberID)
            let result = client.sendText(
                "NotCode is connected — you're all set 🎉",
                to: config.recipientPhone)
            await MainActor.run {
                switch result {
                case .success: sendResult = "Delivered ✓ — check your WhatsApp"
                case .failure(let error): sendResult = "Failed: \(error.userHint)"
                }
            }
        }
    }
}

// MARK: - Sounds

struct SoundsSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            SoundPickerRow(title: "Needs your attention",
                           choice: $state.config.soundAttention,
                           volume: state.config.volume)
            SoundPickerRow(title: "Task finished",
                           choice: $state.config.soundDone,
                           volume: state.config.volume)

            Section {
                Slider(value: $state.config.volume, in: 0...1) {
                    Text("Volume")
                }
            }

            Section("Per-agent sounds") {
                Text("Give an agent its own voice — anything left on \"Default\" uses the sounds above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(AgentRegistry.all, id: \.name) { agent in
                    if agent.emitsAttention {
                        OverrideSoundPickerRow(
                            title: "\(agent.name) — needs attention",
                            choice: overrideBinding(agent.name, .attention),
                            fallback: state.config.soundAttention,
                            volume: state.config.volume)
                    }
                    OverrideSoundPickerRow(
                        title: "\(agent.name) — task finished",
                        choice: overrideBinding(agent.name, .done),
                        fallback: state.config.soundDone,
                        volume: state.config.volume)
                }
            }
        }
        .formStyle(.grouped)
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
        HStack {
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
        Section(title) {
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
            HStack {
                Button("Choose file…") { chooseFile() }
                Button("Preview") {
                    SoundPlayer.play(choice, volume: volume)
                }
                .disabled(choice.kind == .none)
            }
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
        Form {
            Section("Notify me when") {
                Toggle("An agent needs my attention", isOn: $state.config.notifyAttention)
                Toggle("A task finishes", isOn: $state.config.notifyDone)
            }

            Section("Agents") {
                ForEach(AgentRegistry.all, id: \.name) { agent in
                    Toggle(agent.name, isOn: Binding(
                        get: { state.config.isEnabled(agent.name) },
                        set: { state.config.setEnabled(agent.name, $0) }))
                }
            }

            Section("Quiet while you work") {
                Toggle("Skip notifications while I'm actively in a terminal or IDE",
                       isOn: $state.config.suppressWhileWatching)
                Text("When you're typing in Terminal, iTerm, VS Code, etc., you can see the agent finish — so NotCode stays silent. Step away or switch apps and notifications resume. Cursor agent runs always notify: their panel can be hidden while you code, so you might miss the finish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("WhatsApp economy") {
                Toggle("Only send WhatsApp when I'm away from the Mac",
                       isOn: $state.config.awayOnlyWhatsApp)
                if state.config.awayOnlyWhatsApp {
                    Stepper(value: $state.config.awayThresholdMinutes, in: 1...60, step: 1) {
                        Text("Away threshold: \(Int(state.config.awayThresholdMinutes)) min")
                    }
                    Text("Sounds always play locally; WhatsApp messages are only sent when you haven't touched the keyboard or mouse for this long.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Launch NotCode at login", isOn: $launchAtLogin)
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
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Beta features

/// Home for experimental features. Each one gets its own section with a BETA
/// badge, an honest description, and any sub-options — add new betas here and
/// remove them when they graduate to a normal tab.
struct BetaSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                Label {
                    Text("These features work, but they're new and their edges may be rough. They're off by default, safe to toggle anytime, and feedback is very welcome — [open an issue](https://github.com/vadi25/notcode/issues) if something feels wrong.")
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }

            Section {
                Toggle(isOn: $state.config.replyLoopEnabled) {
                    betaTitle("Reply from your phone")
                }
                if state.config.replyLoopEnabled {
                    Toggle("Include a short excerpt of the agent's answer",
                           isOn: $state.config.replyExcerptEnabled)
                }
                Text("Reply to any WhatsApp notification to keep prompting that session, or use \"project-name: your message\" to target a specific one — text \"help\" to your Kapso number for a cheat sheet. Only messages from your own number are accepted, and remote runs never skip permission prompts. Needs WhatsApp configured and the NotCode app running; Claude Code sessions continue headlessly, so a terminal still open on that session won't show the remote turns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.config.replyLoopEnabled && !state.config.whatsAppEnabled {
                    Label("WhatsApp notifications are off — turn them on in the WhatsApp tab for replies to work.",
                          systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Text("That's all for now — new experiments will land here first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func betaTitle(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("BETA")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.orange.opacity(0.2)))
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Agents (hook install)

struct AgentsSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var message: String?
    @State private var showClaudePreview = false
    @State private var claudePreview = ""

    var body: some View {
        Form {
            ForEach(AgentRegistry.all, id: \.name) { agent in
                Section(agent.name) {
                    statusRow(state.hookStatuses[agent.name] ?? .notInstalled,
                              detail: agent.installDetail)
                    HStack {
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

            Section {
                Button("Uninstall all NotCode hooks", role: .destructive) {
                    message = state.uninstallHooks() ?? "Hooks removed. Backups kept as *.notcode-backup."
                }
                if let message {
                    Text(message).font(.caption)
                }
                Text("A backup of each file is written next to it (*.notcode-backup) before any change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showClaudePreview) {
            VStack(alignment: .leading, spacing: 12) {
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
