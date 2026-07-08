import SwiftUI
import AppKit

@main
struct NotCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
                .background { settingsBridge }
        } label: {
            Image(systemName: state.config.paused ? "bell.slash" : "bell.badge")
                .background { settingsBridge }
        }

        Settings {
            SettingsView().environmentObject(state)
        }
    }

    /// Captures SwiftUI's openSettings action (macOS 14+) so the AppKit code
    /// paths can open Settings; harmless no-op view on macOS 13.
    @ViewBuilder private var settingsBridge: some View {
        if #available(macOS 14.0, *) { SettingsActionBridge() }
    }
}

extension AppState {
    static let shared = AppState()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var instance: AppDelegate?
    private var onboardingWindow: NSWindow?
    private var warnedHiddenIcon = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        HelperDeployer.deploy()
        if !ConfigStore.load().onboardingCompleted {
            showOnboarding()
        }
        // Give the status item time to land in the bar before checking.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.warnIfMenuBarIconHidden()
        }
    }

    /// The app is menu-bar-only; if the icon can't be seen (macOS hides the
    /// leftmost items when the bar is full, common around the notch), opening
    /// the app again must still lead somewhere.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        // AppKit calls delegate methods on the main thread; assumeIsolated
        // bridges that guarantee to the MainActor-isolated openers.
        MainActor.assumeIsolated {
            if ConfigStore.load().onboardingCompleted {
                SettingsOpener.open()
            } else {
                showOnboarding()
            }
        }
        return false
    }

    /// Best-effort detection of "the bell exists but macOS isn't drawing it"
    /// (menu bar full). One gentle heads-up per launch, nothing recurring.
    @MainActor private func warnIfMenuBarIconHidden() {
        guard !warnedHiddenIcon,
              !AppState.shared.config.menuBarHintDismissed,
              let statusWindow = NSApp.windows.first(
                  where: { $0.className.contains("StatusBarWindow") }),
              !statusWindow.occlusionState.contains(.visible)
        else { return }
        warnedHiddenIcon = true
        Log.append("menu bar icon appears hidden (bar full?); showing hint")

        let alert = NSAlert()
        alert.messageText = "NotCode is running, but its bell may be hidden"
        alert.informativeText = """
        Your menu bar looks full, and macOS hides the leftmost icons when \
        space runs out (especially around the notch). NotCode keeps working \
        either way — notifications don't need the icon.

        To see the bell, quit a menu bar app you don't use. And you can open \
        NotCode again anytime (Spotlight or Applications) to get this window \
        back.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Don't show again")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            SettingsOpener.open()
        case .alertThirdButtonReturn:
            AppState.shared.config.menuBarHintDismissed = true   // persists via didSet
        default:
            break
        }
    }

    @MainActor func showOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(
            rootView: OnboardingView().environmentObject(AppState.shared))
        let window = NSWindow(contentViewController: controller)
        window.title = "Welcome to NotCode"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 560, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum SettingsOpener {
    @MainActor static func open() {
        // A menu-bar-only (LSUIElement) app has no responder chain for the old
        // NSApp.sendAction(showSettingsWindow:) route, so on macOS 14+ it silently
        // no-ops. Prefer SwiftUI's openSettings action, captured from a view into
        // SettingsLauncher; fall back to sendAction on macOS 13. Deferred one
        // run-loop hop so it also works right after an NSAlert modal closes.
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            if let opener = SettingsLauncher.shared.opener {
                opener()
            } else if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }
}

/// Stores SwiftUI's openSettings action so AppKit paths (reopen handler, the
/// "menu bar full" alert) can open the Settings scene on modern macOS.
@MainActor
final class SettingsLauncher {
    static let shared = SettingsLauncher()
    var opener: (() -> Void)?
}

/// Zero-size view that captures the environment's openSettings action into
/// SettingsLauncher. Hosted in the menu bar label and menu content so it is
/// registered at launch (label) and whenever the menu opens (content).
@available(macOS 14.0, *)
private struct SettingsActionBridge: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { SettingsLauncher.shared.opener = { openSettings() } }
    }
}
