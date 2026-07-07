import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @State private var installMessage: String?
    @State private var testMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to NotCode 👋").font(.largeTitle.bold())
                    Text("Get a sound on your Mac and a WhatsApp on your phone whenever Claude Code or Codex needs you — or finishes a task.")
                        .foregroundStyle(.secondary)
                }

                step(1, "Create your Kapso account") {
                    Text("""
                    Kapso gives you a WhatsApp API number in minutes:

                    1. Sign up at [kapso.com](https://kapso.com)
                    2. Connect a WhatsApp phone number (Kapso walks you through Meta's flow)
                    3. Copy the **API key** from *Project Settings → API Keys*
                    4. Copy the **phone number ID** from your connected number's page
                    """)
                    SecureField("Kapso API key", text: $state.config.kapsoAPIKey)
                    TextField("WhatsApp phone number ID", text: $state.config.phoneNumberID)
                    TextField("Your phone number, international format without + (e.g. 34600111222)",
                              text: $state.config.recipientPhone)
                }

                step(2, "Activate the conversation") {
                    Text("""
                    From your phone, send **any message** (a simple "hi" works) to your new Kapso WhatsApp number. WhatsApp only lets the bot message you freely for 24h after your last message to it.

                    For alerts that keep working after that window: create a template in the Kapso dashboard named **notcode_alert** with body `{{1}}` — NotCode falls back to it automatically.
                    """)
                }

                step(3, "Connect your agents") {
                    HStack {
                        Button("Install Claude Code + Codex hooks") {
                            state.config.whatsAppEnabled = state.config.hasKapsoCredentials
                            installMessage = state.installHooks(claude: true, codex: true)
                                ?? "Hooks installed ✓"
                        }
                        if state.claudeHooks == .installed && state.codexHooks == .installed {
                            Label("Done", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    if let installMessage {
                        Text(installMessage).font(.caption)
                    }
                }

                step(4, "Try it") {
                    Button("Send test notification") {
                        state.sendTestNotification()
                        testMessage = nil
                    }
                    if let result = state.testResult {
                        Text(result).font(.caption)
                    }
                }

                Divider()

                HStack {
                    Spacer()
                    Button("Finish") {
                        state.config.onboardingCompleted = true
                        NSApp.keyWindow?.close()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("You can reopen this guide anytime from the menu bar icon → Setup Guide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 600)
    }

    @ViewBuilder
    private func step(_ number: Int, _ title: String,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.headline)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.accentColor.opacity(0.2)))
                Text(title).font(.headline)
            }
            content()
                .padding(.leading, 32)
        }
    }
}
