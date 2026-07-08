import SwiftUI

/// First-run setup as a stepped wizard: welcome, hook the agents on this Mac,
/// optional phone alerts, done. Steps live behind an internal index with
/// animated push transitions; the fastest path to value is step 2, where
/// detection, hook install, and a test sound all happen without any account.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState

    @State private var step = 0
    @State private var movingForward = true
    /// Error text from the last hook install attempt, if any.
    @State private var installError: String?
    @State private var whatsAppSendResult: String?

    private static let stepCount = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                stepContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)

            Divider()
            footer
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.vertical, DS.Spacing.l)
        }
        .frame(width: 560, height: 640)
        .onAppear { state.refresh() }
    }

    // MARK: Step routing

    @ViewBuilder private var stepContent: some View {
        Group {
            switch step {
            case 0: welcomeStep
            case 1: agentsStep
            case 2: phoneStep
            default: doneStep
            }
        }
        .transition(stepTransition)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: movingForward ? .trailing : .leading)
                .combined(with: .opacity),
            removal: .move(edge: movingForward ? .leading : .trailing)
                .combined(with: .opacity))
    }

    private func go(to newStep: Int) {
        movingForward = newStep > step
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            step = newStep
        }
    }

    // MARK: Footer (Back, dots, Next)

    private var footer: some View {
        ZStack {
            StepDots(count: Self.stepCount, current: step)
            HStack(spacing: DS.Spacing.m) {
                if step > 0 {
                    Button("Back") { go(to: step - 1) }
                }
                Spacer()
                switch step {
                case 0:
                    Button("Get started") { go(to: 1) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case 1:
                    Button("Next") { go(to: 2) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case 2:
                    Button("Skip for now") { go(to: 3) }
                    Button("Continue") {
                        state.config.whatsAppEnabled = state.config.hasKapsoCredentials
                        go(to: 3)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                default:
                    Button("Finish") { finish() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Same completion mechanics as before: persist the flag (didSet saves the
    /// config) and close the onboarding window.
    private func finish() {
        state.config.onboardingCompleted = true
        NSApp.keyWindow?.close()
    }

    // MARK: Step 1, Welcome

    private var welcomeStep: some View {
        VStack(spacing: DS.Spacing.l) {
            Spacer()
            TintedIcon(systemImage: "bell.badge.fill", tint: .blue, size: 76)
            Text("Welcome to NotCode")
                .font(.largeTitle.bold())
            Text("A sound on your Mac, and, if you want, a WhatsApp on your phone, the moment Claude Code, Codex, or Cursor needs you or finishes a task.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Two minutes of setup. No account needed for desktop alerts.")
                .dsCaption()
            Spacer()
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Step 2, Connect your agents

    /// True while the off-main CLI probe is still running for any agent.
    private var probing: Bool {
        AgentRegistry.all.contains { state.cliInstalled[$0.name] == nil }
    }

    private var detectedAgents: [AgentModule] {
        AgentRegistry.all.filter { state.cliInstalled[$0.name] == true }
    }

    private var allDetectedHooked: Bool {
        detectedAgents.allSatisfy { state.hookStatuses[$0.name] == .installed }
    }

    private var testSoundWorked: Bool {
        state.testResult?.contains("Sound ✓") == true
    }

    private var agentsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                stepHeader("Connect your agents",
                           subtitle: "No accounts, no third party. Hook the agents on this Mac and desktop alerts just work.",
                           systemImage: "terminal.fill",
                           tint: .indigo)

                SettingsCard {
                    if probing {
                        HStack(spacing: DS.Spacing.s) {
                            ProgressView().controlSize(.small)
                            Text("Looking for agents on this Mac")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(AgentRegistry.all, id: \.name) { agent in
                            agentRow(agent)
                            if agent.name != AgentRegistry.all.last?.name {
                                Divider()
                            }
                        }
                        if detectedAgents.isEmpty {
                            Divider()
                            Text("None of the supported agents were found on this Mac. You can still finish setup and install hooks later from Settings, Agents.")
                                .dsCaption()
                        } else if !allDetectedHooked {
                            Divider()
                            HStack(spacing: DS.Spacing.m) {
                                Button("Install hooks") { installDetectedHooks() }
                                    .buttonStyle(.borderedProminent)
                                Text("Sets up \(detectedAgents.map(\.name).joined(separator: ", ")) in one click.")
                                    .dsCaption()
                            }
                        }
                    }
                    if let installError {
                        Text(installError).font(.caption).foregroundStyle(.red)
                    }
                }

                SettingsCard("Hear it work", systemImage: "speaker.wave.2.fill") {
                    Text("This plays your attention sound right now. If you hear it, this step alone means NotCode works.")
                        .dsCaption()
                    HStack(spacing: DS.Spacing.m) {
                        Button("Send test notification") { state.sendTestNotification() }
                            .buttonStyle(.borderedProminent)
                        if let result = state.testResult {
                            Text(result)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if testSoundWorked {
                        Label("You are set. Desktop alerts are on.",
                              systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(DS.Spacing.xl)
        }
    }

    @ViewBuilder private func agentRow(_ agent: AgentModule) -> some View {
        let detected = state.cliInstalled[agent.name]
        let hooked = state.hookStatuses[agent.name] == .installed
        HStack(spacing: DS.Spacing.m) {
            TintedIcon(systemImage: "terminal.fill",
                       tint: detected == true ? .indigo : .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.subheadline.weight(.semibold))
                switch detected {
                case .some(true):
                    Label("Installed on this Mac", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .some(false):
                    Text("Not found on this Mac")
                        .dsCaption()
                case .none:
                    Text("Checking")
                        .dsCaption()
                }
            }
            Spacer(minLength: DS.Spacing.m)
            if detected == true {
                if hooked {
                    Label("Hook active", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else {
                    Button("Install") {
                        installError = state.installHooks(agents: [agent.name])
                    }
                    .controlSize(.small)
                }
            }
        }
        .opacity(detected == false ? 0.5 : 1)
    }

    private func installDetectedHooks() {
        installError = state.installHooks(agents: detectedAgents.map(\.name))
    }

    // MARK: Step 3, Optional phone alerts

    private var phoneStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                stepHeader("Phone alerts",
                           subtitle: "Get a WhatsApp when you step away from the Mac. Skip this now and set it up later in Settings, WhatsApp.",
                           systemImage: "message.fill",
                           tint: .green,
                           optional: true)

                SettingsCard("Kapso credentials", systemImage: "key.fill") {
                    Text("Kapso gives you a WhatsApp API number in minutes: sign up at [kapso.com](https://kapso.com), connect a WhatsApp number (Kapso walks you through Meta's flow), then copy the API key from Project Settings → API Keys and the phone number ID from the number's page.")
                        .dsCaption()
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
                    SettingsRow("Your phone number",
                                subtitle: "International format without the +") {
                        TextField("e.g. 34600111222", text: $state.config.recipientPhone)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: DS.Size.fieldWidth)
                    }
                }

                SettingsCard("Activate the conversation", systemImage: "clock.arrow.circlepath") {
                    Text("From your phone, send any message (a simple \"hi\" works) to your new Kapso WhatsApp number. WhatsApp delivers the bot's messages for 24h after your last message to it, and every reply from you resets the clock. If alerts ever stop arriving, just text the number again and they resume instantly. NotCode shows this in the menu bar when it happens.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                SettingsCard("Connection test", systemImage: "paperplane.fill") {
                    VerifyConnectionRow()
                    Divider()
                    HStack(spacing: DS.Spacing.m) {
                        Button("Send test message") { sendWhatsAppTest() }
                            .disabled(!state.config.hasKapsoCredentials)
                        if let whatsAppSendResult {
                            Text(whatsAppSendResult)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("The test message needs your phone number above; \"Verify connection\" works with just the credentials.")
                        .dsCaption()
                }
            }
            .padding(DS.Spacing.xl)
        }
    }

    private func sendWhatsAppTest() {
        whatsAppSendResult = "Sending…"
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
                case .success: whatsAppSendResult = "Delivered ✓, check your WhatsApp"
                case .failure(let error): whatsAppSendResult = "Failed: \(error.userHint)"
                }
            }
        }
    }

    // MARK: Step 4, Done

    private var doneStep: some View {
        VStack(spacing: DS.Spacing.l) {
            Spacer()
            TintedIcon(systemImage: "checkmark.seal.fill", tint: .green, size: 76)
            Text("You're all set")
                .font(.largeTitle.bold())

            SettingsCard {
                recapRow(hooksRecap)
                Divider()
                recapRow(whatsAppRecap)
            }
            .frame(maxWidth: 420)

            Text("Reopen this guide anytime from the menu bar icon → Setup Guide.")
                .dsCaption()
            Spacer()
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hooksRecap: (icon: String, tint: Color, text: String) {
        let hooked = AgentRegistry.all
            .filter { state.hookStatuses[$0.name] == .installed }
            .map(\.name)
        if hooked.isEmpty {
            return ("exclamationmark.circle.fill", .orange,
                    "No hooks installed yet. Settings, Agents has you covered.")
        }
        return ("checkmark.circle.fill", .green,
                "Desktop alerts are on for \(hooked.joined(separator: ", ")).")
    }

    private var whatsAppRecap: (icon: String, tint: Color, text: String) {
        state.config.hasKapsoCredentials
            ? ("checkmark.circle.fill", .green,
               "Phone alerts are configured. Keep the 24h window open by texting your Kapso number now and then.")
            : ("circle.dashed", .secondary,
               "Phone alerts skipped. Add them anytime in Settings, WhatsApp.")
    }

    private func recapRow(_ item: (icon: String, tint: Color, text: String)) -> some View {
        Label {
            Text(item.text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: item.icon)
                .foregroundStyle(item.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Shared pieces

    private func stepHeader(_ title: String, subtitle: String,
                            systemImage: String, tint: Color,
                            optional: Bool = false) -> some View {
        HStack(spacing: DS.Spacing.m) {
            TintedIcon(systemImage: systemImage, tint: tint, size: DS.Size.paneIcon)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Spacing.s) {
                    Text(title).font(.title2.weight(.semibold))
                    if optional { OptionalBadge() }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, DS.Spacing.xs)
    }
}

/// Small blue capsule marking a step you can skip entirely.
private struct OptionalBadge: View {
    var body: some View {
        Text("OPTIONAL")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.blue.opacity(0.18)))
            .foregroundStyle(.blue)
    }
}
