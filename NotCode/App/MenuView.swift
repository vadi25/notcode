import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            Text(state.config.paused ? "NotCode — Paused" : "NotCode — Active")
            if let project = state.replyPoller.activeRun {
                Text("▶️ Remote reply running in \(project)")
            }
            if let last = state.lastNotification {
                Text("Last: \(last)")
            }
            if let problem = state.lastDeliveryProblem {
                Text("⚠️ \(problem)")
            }

            Divider()

            Button(state.config.paused ? "Resume Notifications" : "Pause Notifications") {
                state.config.paused.toggle()
            }

            Button("Test: Sound + WhatsApp to Me") {
                state.sendTestNotification()
            }
            if let result = state.testResult {
                Text(result)
            }

            if let update = state.availableUpdate {
                Divider()
                if UpdateChecker.canSelfUpdate {
                    Button(state.updating ? "Updating…" : "⬆️ Update to \(update)") {
                        state.performUpdate()
                    }
                    .disabled(state.updating)
                } else {
                    Button("⬇️ Download \(update)…") { state.performUpdate() }
                    Text("Auto-update is off for this build — opens the download page")
                }
            }

            Divider()

            if #available(macOS 14.0, *) {
                SettingsLink { Text("Settings…") }
                    .keyboardShortcut(",")
            } else {
                Button("Settings…") { SettingsOpener.open() }
                    .keyboardShortcut(",")
            }
            Button("Setup Guide…") { AppDelegate.instance?.showOnboarding() }

            Divider()

            Text("Version \(UpdateChecker.currentVersion)")

            Button("Quit NotCode") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .onAppear { state.refresh() }
    }
}
