import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            Text(state.config.paused ? "NotCode — Paused" : "NotCode — Active")
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

            Button("Quit NotCode") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .onAppear { state.refresh() }
    }
}
