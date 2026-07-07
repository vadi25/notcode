import SwiftUI
import AppKit

@main
struct NotCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(state)
        } label: {
            Image(systemName: state.config.paused ? "bell.slash" : "bell.badge")
        }

        Settings {
            SettingsView().environmentObject(state)
        }
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
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SettingsOpener.open()
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
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
