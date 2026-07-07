import AppKit

/// Detects "the user is sitting right there watching the agent work" — the
/// case where any notification is just noise. Frontmost terminal/IDE plus
/// recent keyboard/mouse input means they'll see the turn end themselves.
enum FocusDetector {
    /// Substrings matched against the frontmost app's bundle id and name.
    static let terminalApps = [
        "terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "hyper",
        "tabby", "wezterm", "vscode", "cursor", "windsurf", "zed", "codex",
        "claude", "jetbrains", "intellij", "xcode",
    ]

    static func userIsWatchingTerminal(awayThresholdSeconds: TimeInterval) -> Bool {
        guard IdleTime.secondsSinceLastInput() < awayThresholdSeconds else { return false }
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let id = front.bundleIdentifier?.lowercased() ?? ""
        let name = front.localizedName?.lowercased() ?? ""
        return terminalApps.contains { id.contains($0) || name.contains($0) }
    }
}
