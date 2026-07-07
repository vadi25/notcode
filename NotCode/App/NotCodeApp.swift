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

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        HelperDeployer.deploy()
        if !ConfigStore.load().onboardingCompleted {
            showOnboarding()
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
