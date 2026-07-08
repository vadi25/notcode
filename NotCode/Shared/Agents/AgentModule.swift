import Foundation

/// Whether an agent's sessions can be continued remotely (WhatsApp replies).
enum ResumeAvailability {
    case available
    case unavailable(reason: String)
}

/// Result of a completed remote resume run.
struct ResumeResult {
    /// Short excerpt of the agent's answer, when the CLI provides one.
    var excerpt: String?
    /// Resuming often forks the conversation under a new id; store it so the
    /// next reply continues the same branch.
    var newSessionID: String?
}

/// How the hook helper receives an agent's event payload.
enum PayloadSource {
    case stdin      // JSON piped on stdin (Claude Code, Cursor)
    case argument   // JSON as the last CLI argument (Codex)
}

/// Everything NotCode needs to know about one supported agent. Adding an
/// agent means writing one conforming type and appending it to
/// `AgentRegistry.all`; settings toggles, hook install UI, per-agent sounds,
/// and the WhatsApp reply loop all iterate the registry.
protocol AgentModule {
    /// Display name; must match the `AgentEvent.agent` values this module emits.
    var name: String { get }
    /// Subcommands of notcode-hook this module handles. These are baked into
    /// users' installed hook configs; never change existing strings.
    var hookSubcommands: [String] { get }
    var payloadSource: PayloadSource { get }
    /// Caption shown in the Agents settings section.
    var installDetail: String { get }
    /// Whether this agent ever emits `.attention` events (drives which sound
    /// pickers make sense to show).
    var emitsAttention: Bool { get }
    /// Whether events skip the "quiet while you're watching a terminal/IDE"
    /// filter (Cursor: its agent panel can be hidden while you code).
    var bypassesWatchingFilter: Bool { get }
    /// The agent's CLI binary as found on PATH (e.g. "claude"). Drives
    /// `isInstalledOnMachine` and should match what resume probing uses.
    var cliBinaryName: String { get }
    /// Whether the agent's CLI is present on this Mac. The default probes the
    /// login-shell PATH (spawns a shell), so prefer calling it off the main
    /// thread.
    var isInstalledOnMachine: Bool { get }

    func hookStatus() -> HookInstaller.Status
    func installHooks() throws
    func uninstallHooks() throws
    /// Config file contents as they'd look after install, for a preview UI.
    /// nil when a preview isn't meaningful for this agent.
    func installPreview() throws -> String?
    /// Called on every app launch for config self-healing (e.g. the Codex
    /// desktop app rewriting the notify slot).
    func repairAfterLaunch()

    func parse(subcommand: String, payload: Data) -> AgentEvent?

    // Remote reply (WhatsApp) capability.
    func resumeAvailability() -> ResumeAvailability
    /// Shell command (run via `/bin/bash -lc` in the session's cwd) that sends
    /// `prompt` to the session. nil when resume is unavailable.
    func resumeCommand(sessionID: String, prompt: String) -> String?
    func parseResumeOutput(stdout: Data) -> ResumeResult
}

extension AgentModule {
    var emitsAttention: Bool { false }
    var bypassesWatchingFilter: Bool { false }
    var isInstalledOnMachine: Bool { loginShellWhich(cliBinaryName) }
    func installPreview() throws -> String? { nil }
    func repairAfterLaunch() {}
    func resumeAvailability() -> ResumeAvailability {
        .unavailable(reason: "\(name) sessions can't be continued remotely yet")
    }
    func resumeCommand(sessionID: String, prompt: String) -> String? { nil }
    func parseResumeOutput(stdout: Data) -> ResumeResult { ResumeResult() }

    /// Finds an executable in the user's login-shell PATH. Modules use this to
    /// probe for their CLI (the app, launched from Finder, has a minimal PATH).
    func loginShellWhich(_ binary: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", "command -v \(HookInstaller.shellEscape(binary))"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

enum AgentRegistry {
    /// The one list to extend when adding a new agent.
    static let all: [AgentModule] = [ClaudeAgent(), CodexAgent(), CursorAgent()]

    static func byName(_ name: String) -> AgentModule? {
        all.first { $0.name == name }
    }

    static func bySubcommand(_ subcommand: String) -> AgentModule? {
        all.first { $0.hookSubcommands.contains(subcommand) }
    }
}
