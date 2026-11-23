import XCTest

final class HookPayloadTests: XCTestCase {
    private let claude = ClaudeAgent()
    private let codex = CodexAgent()
    private let cursor = CursorAgent()

    func testClaudeNotificationParsing() {
        let json = """
        {"session_id":"abc123","cwd":"/Users/me/projects/my-app",
         "hook_event_name":"Notification",
         "message":"Claude needs your permission to use Bash"}
        """
        let event = claude.parse(subcommand: "claude-notification", payload: Data(json.utf8))
        XCTAssertEqual(event?.agent, "Claude Code")
        XCTAssertEqual(event?.kind, .attention)
        XCTAssertEqual(event?.detail, "Claude needs your permission to use Bash")
        XCTAssertEqual(event?.sessionID, "abc123")
        XCTAssertEqual(event?.projectName, "my-app")
    }

    func testClaudeStopParsing() {
        let json = #"{"session_id":"abc","cwd":"/tmp/demo","hook_event_name":"Stop"}"#
        let event = claude.parse(subcommand: "claude-stop", payload: Data(json.utf8))
        XCTAssertEqual(event?.kind, .done)
        XCTAssertNil(event?.detail)
    }

    func testStopHookActiveIsSkipped() {
        let json = #"{"session_id":"abc","cwd":"/tmp","stop_hook_active":true}"#
        XCTAssertNil(claude.parse(subcommand: "claude-stop", payload: Data(json.utf8)),
                     "hook-forced continuations must not notify twice")
        XCTAssertNotNil(claude.parse(subcommand: "claude-notification", payload: Data(json.utf8)))
    }

    func testClaudeGarbageInputStillProducesEvent() {
        let event = claude.parse(subcommand: "claude-notification", payload: Data("not json".utf8))
        XCTAssertEqual(event?.agent, "Claude Code")
        XCTAssertNil(event?.cwd)
    }

    func testCodexTurnCompleteParsing() {
        let json = """
        {"type":"agent-turn-complete","turn-id":"t1",
         "input-messages":["Fix the login bug in auth.ts please"],
         "last-assistant-message":"Done, the bug was..."}
        """
        let event = codex.parse(subcommand: "codex", payload: Data(json.utf8))
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.agent, "Codex")
        XCTAssertEqual(event?.kind, .done)
        XCTAssertEqual(event?.detail, "Fix the login bug in auth.ts please")
        // Never leak the result into the message, only the task.
        XCTAssertFalse(event!.whatsAppText.contains("the bug was"))
    }

    func testCodexUnknownEventIsIgnored() {
        let json = #"{"type":"something-else"}"#
        XCTAssertNil(codex.parse(subcommand: "codex", payload: Data(json.utf8)))
    }

    func testCursorStopParsing() {
        let json = """
        {"hook_event_name":"stop","status":"completed","conversation_id":"conv-1",
         "workspace_roots":["/Users/me/projects/my-app"],"loop_count":0}
        """
        let event = cursor.parse(subcommand: "cursor", payload: Data(json.utf8))
        XCTAssertEqual(event?.agent, "Cursor")
        XCTAssertEqual(event?.kind, .done)
        XCTAssertNil(event?.detail)
        XCTAssertEqual(event?.sessionID, "conv-1")
        XCTAssertEqual(event?.projectName, "my-app")
    }

    func testCursorAbortedIsSkipped() {
        let json = #"{"hook_event_name":"stop","status":"aborted","conversation_id":"c"}"#
        XCTAssertNil(cursor.parse(subcommand: "cursor", payload: Data(json.utf8)),
                     "an aborted turn means the user is at the machine")
        let errored = #"{"hook_event_name":"stop","status":"error","conversation_id":"c"}"#
        XCTAssertNotNil(cursor.parse(subcommand: "cursor", payload: Data(errored.utf8)))
    }

    func testWhatsAppTextFormats() {
        let attention = AgentEvent(agent: "Claude Code", kind: .attention,
                                   detail: "waiting for permission",
                                   cwd: "/x/my-app", sessionID: "s")
        XCTAssertEqual(attention.whatsAppText,
                       "🔔 Claude Code needs you in *my-app*: waiting for permission")

        let done = AgentEvent(agent: "Codex", kind: .done, detail: nil,
                              cwd: nil, sessionID: nil)
        XCTAssertEqual(done.whatsAppText, "✅ Codex finished")
    }
}

final class HookInstallerMergeTests: XCTestCase {
    private let claude = ClaudeAgent()
    private let codex = CodexAgent()
    private let cursor = CursorAgent()

    func testRegistryInvariants() {
        let names = AgentRegistry.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "agent names must be unique")
        let subcommands = AgentRegistry.all.flatMap(\.hookSubcommands)
        XCTAssertEqual(Set(subcommands).count, subcommands.count,
                       "hook subcommands must be unique across modules")
        // Installed hooks in the wild use these exact strings; never change them.
        XCTAssertEqual(Set(subcommands),
                       ["claude-notification", "claude-stop", "codex", "cursor"])
        XCTAssertNil(AgentRegistry.bySubcommand("test"),
                     "the built-in test subcommand must not be shadowed")
    }

    func testMergeIntoEmptySettings() {
        let merged = claude.merged(into: [:])
        let hooks = merged["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks?["Notification"])
        XCTAssertNotNil(hooks?["Stop"])
    }

    func testMergePreservesExistingSettingsAndHooks() {
        let existing: [String: Any] = [
            "model": "opus",
            "permissions": ["allow": ["Bash(npm:*)"]],
            "hooks": [
                "Notification": [
                    ["matcher": "", "hooks": [["type": "command", "command": "my-other-tool"]]]
                ],
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "audit.sh"]]]
                ],
            ],
        ]
        let merged = claude.merged(into: existing)

        XCTAssertEqual(merged["model"] as? String, "opus")
        XCTAssertNotNil(merged["permissions"])
        let hooks = merged["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["PreToolUse"], "unrelated hook events must survive")

        let notification = hooks["Notification"] as! [[String: Any]]
        XCTAssertEqual(notification.count, 2, "existing entry kept, ours appended")
        let commands = notification.flatMap { entry in
            (entry["hooks"] as! [[String: Any]]).compactMap { $0["command"] as? String }
        }
        XCTAssertTrue(commands.contains("my-other-tool"))
        XCTAssertTrue(commands.contains { $0.contains("notcode-hook") })
    }

    func testMergeIsIdempotent() {
        let once = claude.merged(into: [:])
        let twice = claude.merged(into: once)
        let onceJSON = try! JSONSerialization.data(withJSONObject: once, options: .sortedKeys)
        let twiceJSON = try! JSONSerialization.data(withJSONObject: twice, options: .sortedKeys)
        XCTAssertEqual(onceJSON, twiceJSON)
    }

    func testParseNotifyArray() throws {
        let line = #"notify = ["/Users/x/Sky Client.app/Contents/MacOS/SkyClient", "turn-ended"]"#
        let tokens = try codex.parseNotifyArray(line)
        XCTAssertEqual(tokens, ["/Users/x/Sky Client.app/Contents/MacOS/SkyClient", "turn-ended"])
        XCTAssertThrowsError(try codex.parseNotifyArray("notify = not-an-array"))
    }

    func testReplaceRootNotifyOnlyTouchesRootLine() {
        let toml = """
        model = "gpt-5"
        notify = ["old"]
        [profiles.x]
        notify = ["inner-stays"]
        """
        let updated = codex.replaceRootNotify(in: toml, with: "notify = [\"new\"]")
        XCTAssertTrue(updated.contains("notify = [\"new\"]"))
        XCTAssertTrue(updated.contains("notify = [\"inner-stays\"]"))
        XCTAssertFalse(updated.contains("notify = [\"old\"]"))
        XCTAssertTrue(updated.contains("model = \"gpt-5\""))
    }

    func testHelperOnlyChainWhenDownstreamOfCodexApp() {
        let script = codex.chainScriptContent(existingCommand: [])
        XCTAssertTrue(script.contains("notcode-hook' codex \"$@\""))
        XCTAssertFalse(script.contains("SkyClient"))

        let rewritten = #"notify = ["/x/SkyComputerUseClient", "turn-ended", "--previous-notify", "[\"/y/NotCode/codex-notify-chain.sh\"]"]"#
        XCTAssertTrue(codex.chainIsDownstream(notifyLine: rewritten))
        XCTAssertTrue(codex.isOurNotify(rewritten), "downstream chain still counts as installed")
        XCTAssertFalse(codex.chainIsDownstream(
            notifyLine: #"notify = ["/y/NotCode/codex-notify-chain.sh"]"#))
    }

    func testChainScriptForwardsToBothHandlers() {
        let script = codex.chainScriptContent(
            existingCommand: ["/Users/x/Sky Client.app/MacOS/SkyClient", "turn-ended"])
        XCTAssertTrue(script.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(script.contains("'/Users/x/Sky Client.app/MacOS/SkyClient' 'turn-ended' \"$@\""))
        XCTAssertTrue(script.contains("notcode-hook' codex \"$@\""))
    }

    func testCursorMergeIntoEmptyHooks() {
        let merged = cursor.merged(into: [:])
        XCTAssertEqual(merged["version"] as? Int, 1)
        let hooks = merged["hooks"] as? [String: Any]
        let stop = hooks?["stop"] as? [[String: Any]]
        XCTAssertEqual(stop?.count, 1)
        XCTAssertTrue(stop?.first?["command"] as? String != nil
                      && (stop!.first!["command"] as! String).contains("notcode-hook"))
    }

    func testCursorMergePreservesExistingHooks() {
        let existing: [String: Any] = [
            "version": 1,
            "hooks": [
                "stop": [["command": "./scripts/my-hook.sh"]],
                "beforeShellExecution": [["command": "./scripts/audit.sh"]],
            ],
        ]
        let merged = cursor.merged(into: existing)
        let hooks = merged["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["beforeShellExecution"], "unrelated hook events must survive")
        let stop = hooks["stop"] as! [[String: Any]]
        let commands = stop.compactMap { $0["command"] as? String }
        XCTAssertEqual(stop.count, 2, "existing entry kept, ours appended")
        XCTAssertTrue(commands.contains("./scripts/my-hook.sh"))
        XCTAssertTrue(commands.contains { $0.contains("notcode-hook") })
    }

    func testCursorMergeIsIdempotent() {
        let once = cursor.merged(into: [:])
        let twice = cursor.merged(into: once)
        let onceJSON = try! JSONSerialization.data(withJSONObject: once, options: .sortedKeys)
        let twiceJSON = try! JSONSerialization.data(withJSONObject: twice, options: .sortedKeys)
        XCTAssertEqual(onceJSON, twiceJSON)
    }

    func testCursorWrapperExecsHelper() {
        let script = cursor.wrapperContent()
        XCTAssertTrue(script.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(script.contains("notcode-hook' cursor"))
    }

    func testCodexRootNotifyDetection() {
        XCTAssertNil(codex.rootNotifyLine(in: ""))
        XCTAssertNil(codex.rootNotifyLine(in: "model = \"gpt-5\"\n[tui]\nnotifications = true"))
        XCTAssertNil(codex.rootNotifyLine(in: "[profiles.x]\nnotify = [\"foo\"]"),
                     "notify inside a table is not a root notify")
        XCTAssertEqual(
            codex.rootNotifyLine(in: "model = \"gpt-5\"\nnotify = [\"foo\"]\n[tui]"),
            "notify = [\"foo\"]")
        XCTAssertNotNil(codex.rootNotifyLine(in: "notify=[\"x\"]"))
    }
}

final class VersionCompareTests: XCTestCase {
    func testIsNewer() {
        XCTAssertTrue(VersionCompare.isNewer("v1.0.1", than: "1.0.0"))
        XCTAssertTrue(VersionCompare.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertTrue(VersionCompare.isNewer("2.0", than: "1.9.9"))
        XCTAssertFalse(VersionCompare.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(VersionCompare.isNewer("v0.9", than: "1.0.0"))
        XCTAssertFalse(VersionCompare.isNewer("1.0.0", than: "1.0.1"))
    }
}

final class ReplyRouterTests: XCTestCase {
    private func sessions(_ entries: [(id: String, cwd: String?, agent: String, age: TimeInterval)])
        -> [String: SessionInfo] {
        Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, SessionInfo(cwd: $0.cwd, agent: $0.agent,
                                lastNotified: Date().addingTimeInterval(-$0.age)))
        })
    }

    func testBareReplyGoesToMostRecentSession() {
        let s = sessions([("old", "/x/api-server", "Codex", 600),
                          ("new", "/x/my-app", "Claude Code", 10)])
        XCTAssertEqual(ReplyRouter.route(text: "keep going", sessions: s),
                       .session(id: "new", prompt: "keep going"))
    }

    func testPrefixRoutesToMatchingProjectCaseInsensitively() {
        let s = sessions([("a", "/x/api-server", "Codex", 600),
                          ("b", "/x/my-app", "Claude Code", 10)])
        XCTAssertEqual(ReplyRouter.route(text: "API-Server: run the tests", sessions: s),
                       .session(id: "a", prompt: "run the tests"))
    }

    func testUnknownSingleTokenPrefixIsNotFound() {
        let s = sessions([("a", "/x/my-app", "Claude Code", 10)])
        XCTAssertEqual(ReplyRouter.route(text: "my-ap: do x", sessions: s),
                       .notFound(prefix: "my-ap"))
    }

    func testColonInsideSentenceIsNotRouting() {
        let s = sessions([("a", "/x/my-app", "Claude Code", 10)])
        XCTAssertEqual(ReplyRouter.route(text: "fix this: the button is broken", sessions: s),
                       .session(id: "a", prompt: "fix this: the button is broken"),
                       "a multi-word prefix is part of the message, not routing")
    }

    func testHelpAndNoSessions() {
        XCTAssertEqual(ReplyRouter.route(text: " HELP ", sessions: [:]), .help)
        XCTAssertEqual(ReplyRouter.route(text: "?", sessions: [:]), .help)
        XCTAssertEqual(ReplyRouter.route(text: "hello", sessions: [:]), .noSessions)
        let s = sessions([("a", "/x/my-app", "Claude Code", 10)])
        XCTAssertTrue(ReplyRouter.helpText(sessions: s).contains("*my-app*"))
    }
}

final class CodexResumeTests: XCTestCase {
    func testSessionIDFromRolloutFilename() {
        XCTAssertEqual(
            CodexAgent.sessionID(
                fromRolloutFilename: "rollout-2026-07-07T12-52-52-019f3d48-3e18-7741-b6ad-1268e62b321e.jsonl"),
            "019f3d48-3e18-7741-b6ad-1268e62b321e")
        XCTAssertNil(CodexAgent.sessionID(fromRolloutFilename: "rollout-notauuid.jsonl"))
        XCTAssertNil(CodexAgent.sessionID(fromRolloutFilename: "whatever.txt"))
    }

    func testResolveSessionIDByTurnIDContent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-resolve-test-\(UUID().uuidString)/2026/07/07")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionUUID = "019f3d48-3e18-7741-b6ad-1268e62b321e"
        let turnID = "019f3d48-3ea5-77d2-ad0a-c01ef6cb0772"
        let rollout = dir.appendingPathComponent("rollout-2026-07-07T12-52-52-\(sessionUUID).jsonl")
        try #"{"type":"turn","payload":{"id":"\#(turnID)"}}"#
            .write(to: rollout, atomically: true, encoding: .utf8)

        let root = dir.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        XCTAssertEqual(CodexAgent.resolveSessionID(containing: turnID, sessionsDir: root),
                       sessionUUID, "turn-id resolves via rollout content")
        XCTAssertEqual(CodexAgent.resolveSessionID(containing: sessionUUID, sessionsDir: root),
                       sessionUUID, "a real session id resolves via the filename")
        XCTAssertNil(CodexAgent.resolveSessionID(containing: "not-there", sessionsDir: root))
    }
}

final class KapsoParsingTests: XCTestCase {
    func testParseInboundMessages() {
        let json = """
        {"data":[
          {"id":"wamid.2","from":"34600111222","timestamp":"1700000060",
           "type":"text","text":{"body":"second"}},
          {"id":"wamid.1","from":"34600111222","timestamp":"1700000000",
           "type":"text","text":{"body":"first"}},
          {"id":"wamid.3","from":"34600111222","timestamp":"1700000090","type":"image"}
        ]}
        """
        let messages = KapsoClient.parseInboundMessages(Data(json.utf8))
        XCTAssertEqual(messages.map(\.text), ["first", "second"],
                       "sorted oldest-first; non-text messages skipped")
        XCTAssertEqual(messages.first?.timestamp, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testPhoneMatchingIgnoresFormatting() {
        XCTAssertTrue(KapsoClient.phoneMatches("+34 600-111-222", "34600111222"))
        XCTAssertFalse(KapsoClient.phoneMatches("34600111223", "34600111222"))
        XCTAssertFalse(KapsoClient.phoneMatches("", ""), "empty never matches")
    }
}

final class HardeningTests: XCTestCase {
    func testKapsoEndpointNeverCrashesOnBadPhoneNumberID() {
        XCTAssertNil(KapsoClient(apiKey: "k", phoneNumberID: "").endpoint)
        XCTAssertNil(KapsoClient(apiKey: "k", phoneNumberID: "  \n ").endpoint)

        let spaced = KapsoClient(apiKey: "k", phoneNumberID: "123 456").endpoint
        XCTAssertEqual(spaced?.absoluteString,
                       "https://api.kapso.ai/meta/whatsapp/v24.0/123%20456/messages")

        let normal = KapsoClient(apiKey: "k", phoneNumberID: "123456789").endpoint
        XCTAssertEqual(normal?.absoluteString,
                       "https://api.kapso.ai/meta/whatsapp/v24.0/123456789/messages")
    }

    func testLogSanitizationStripsControlCharacters() {
        XCTAssertEqual(Log.sanitized("plain message 🎉"), "plain message 🎉")
        XCTAssertEqual(Log.sanitized("forged\nnew line"), "forged new line",
                       "newlines must not create fake log entries")
        XCTAssertEqual(Log.sanitized("evil\u{1B}[2Jclear"), "evil [2Jclear",
                       "ANSI escapes must be neutralized")
        XCTAssertEqual(Log.sanitized("tab\tbell\u{07}"), "tab bell ")
    }
}

final class ConfigTests: XCTestCase {
    func testConfigRoundTrip() throws {
        var config = NotCodeConfig()
        config.kapsoAPIKey = "key"
        config.recipientPhone = "34600111222"
        config.soundAttention = SoundChoice(kind: .file, value: "/tmp/quack.wav")
        config.awayThresholdMinutes = 7

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(NotCodeConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testDecodingOldConfigWithMissingKeysKeepsCredentials() throws {
        // A config written before suppressWhileWatching existed.
        let old = """
        {"kapsoAPIKey":"secret","phoneNumberID":"123","recipientPhone":"34600111222",
         "whatsAppEnabled":true,"notifyAttention":false}
        """
        let decoded = try JSONDecoder().decode(NotCodeConfig.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.kapsoAPIKey, "secret")
        XCTAssertEqual(decoded.recipientPhone, "34600111222")
        XCTAssertFalse(decoded.notifyAttention)
        XCTAssertTrue(decoded.suppressWhileWatching, "new fields fall back to defaults")
    }

    func testLegacyAgentBooleansMigrateToDisabledAgents() throws {
        let old = #"{"claudeEnabled":false,"codexEnabled":true,"cursorEnabled":false}"#
        let decoded = try JSONDecoder().decode(NotCodeConfig.self, from: Data(old.utf8))
        XCTAssertFalse(decoded.isEnabled("Claude Code"))
        XCTAssertTrue(decoded.isEnabled("Codex"))
        XCTAssertFalse(decoded.isEnabled("Cursor"))

        // Round-trips through the new representation.
        let data = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(NotCodeConfig.self, from: data)
        XCTAssertEqual(again.disabledAgents, ["Claude Code", "Cursor"])
    }

    func testPerAgentSoundOverridesFallBackToGlobals() throws {
        var config = NotCodeConfig()
        config.soundDone = SoundChoice(kind: .system, value: "Glass")
        XCTAssertEqual(config.sound(for: "Cursor", kind: .done).value, "Glass")

        let quack = SoundChoice(kind: .file, value: "/tmp/quack.wav")
        config.soundOverrides[NotCodeConfig.soundOverrideKey("Cursor", .done)] = quack
        XCTAssertEqual(config.sound(for: "Cursor", kind: .done), quack)
        XCTAssertEqual(config.sound(for: "Codex", kind: .done).value, "Glass",
                       "an override for one agent must not leak to others")
        XCTAssertEqual(config.sound(for: "Cursor", kind: .attention), .defaultAttention,
                       "kinds resolve independently")

        // Overrides survive the config round trip.
        let decoded = try JSONDecoder().decode(
            NotCodeConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.sound(for: "Cursor", kind: .done), quack)
    }

    func testHasKapsoCredentials() {
        var config = NotCodeConfig()
        XCTAssertFalse(config.hasKapsoCredentials)
        config.kapsoAPIKey = "k"
        config.phoneNumberID = "p"
        config.recipientPhone = "r"
        XCTAssertTrue(config.hasKapsoCredentials)
    }
}

final class SleepSettingTests: XCTestCase {
    func testDisabledWhenPmsetReportsOne() {
        let output = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         sleep                1 (sleep prevented by caffeinate)
        """
        XCTAssertTrue(SleepSetting.isDisabled(pmsetOutput: output))
    }

    func testEnabledWhenPmsetReportsZero() {
        XCTAssertFalse(SleepSetting.isDisabled(pmsetOutput: " SleepDisabled\t\t0\n sleep 1"))
    }

    func testEnabledWhenTheSwitchWasNeverSet() {
        let output = "Currently in use:\n sleep                1\n displaysleep         10"
        XCTAssertFalse(SleepSetting.isDisabled(pmsetOutput: output),
                       "no SleepDisabled line means the switch was never touched")
    }
}

// MARK: - MCP Hub, Auth Extraction, Profiles & Gateway Tests

final class MCPHubTests: XCTestCase {
    func testCodexTOMLParseAndPreserveNonMCPSections() {
        let toml = """
        model = "gpt-5"
        notify = ["/usr/local/bin/notcode-hook", "codex"]

        [tui]
        notifications = true

        [mcp_servers.firecrawl]
        url = "https://mcp.firecrawl.dev/mcp"
        bearer_token_env_var = "FIRECRAWL_API_KEY"

        [mcp_servers.aws-mcp]
        command = "uvx"
        args = ["mcp-proxy-for-aws@latest", "https://aws-mcp.us-east-1.api.aws/mcp"]

        [mcp_servers.aws-mcp.env]
        AWS_PROFILE = "work-admin"
        """

        let parsed = MCPClientConfigIO.parseCodexTOML(toml, source: "Codex")
        XCTAssertEqual(parsed.count, 2)

        let aws = parsed.first { $0.name == "aws-mcp" }
        XCTAssertEqual(aws?.transport, .stdio)
        XCTAssertEqual(aws?.command, "uvx")
        XCTAssertEqual(aws?.args.count, 2)
        XCTAssertEqual(aws?.env["AWS_PROFILE"], "work-admin")

        let firecrawl = parsed.first { $0.name == "firecrawl" }
        XCTAssertEqual(firecrawl?.transport, .http)
        XCTAssertEqual(firecrawl?.bearerTokenEnvVar, "FIRECRAWL_API_KEY")
        XCTAssertTrue(firecrawl?.hasExtractedAuth == true)

        // Writing back must preserve `model`, `notify`, and `[tui]`.
        let updated = MCPClientConfigIO.replaceCodexMCPServers(in: toml, with: [firecrawl!])
        XCTAssertTrue(updated.contains("model = \"gpt-5\""))
        XCTAssertTrue(updated.contains("notify = [\"/usr/local/bin/notcode-hook\", \"codex\"]"))
        XCTAssertTrue(updated.contains("[tui]"))
        XCTAssertTrue(updated.contains("[mcp_servers.firecrawl]"))
        XCTAssertFalse(updated.contains("[mcp_servers.aws-mcp]"))
    }

    func testScanExtractsAuthAndCreatesProfileVariantOnConflict() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notcode-mcp-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let claudeFile = tmp.appendingPathComponent("claude.json")
        let cursorFile = tmp.appendingPathComponent("cursor.json")

        let claudeJSON = """
        {
          "mcpServers": {
            "linear": {
              "type": "http",
              "url": "https://mcp.linear.app/mcp",
              "headers": { "Authorization": "Bearer personal-token-1234" }
            }
          }
        }
        """
        let cursorJSON = """
        {
          "mcpServers": {
            "linear": {
              "type": "http",
              "url": "https://mcp.linear.app/mcp",
              "headers": { "Authorization": "Bearer work-token-9999" }
            },
            "aws-mcp": {
              "command": "uvx",
              "args": ["mcp-proxy-for-aws"]
            }
          }
        }
        """
        try claudeJSON.write(to: claudeFile, atomically: true, encoding: .utf8)
        try cursorJSON.write(to: cursorFile, atomically: true, encoding: .utf8)

        var pool = MCPPool()
        let report = MCPScanner.scanAll(
            into: &pool,
            apps: [.claudeCode, .cursor],
            urlOverrides: [.claudeCode: claudeFile, .cursor: cursorFile])

        XCTAssertEqual(report.totalInPool, 2)
        XCTAssertEqual(report.authVariantsCreated, 1, "conflicting auth must become a profile override")

        let linear = pool.servers.first { $0.name == "linear" }
        XCTAssertEqual(linear?.headers["Authorization"], "Bearer personal-token-1234")
        XCTAssertEqual(Set(linear?.sources ?? []), ["Claude Code", "Cursor"])

        let variantProfile = pool.profiles.first { $0.name == "Cursor Account" }
        XCTAssertNotNil(variantProfile)
        let resolvedVariant = pool.resolvedServers(for: variantProfile)
        XCTAssertEqual(resolvedVariant.first?.headers["Authorization"], "Bearer work-token-9999")
    }

    func testProjectBindingAndLongestPrefixResolution() {
        var pool = MCPPool()
        let personal = pool.profile(named: "Personal")!
        let work = pool.profile(named: "Work")!

        pool.bindProject("/Users/me/code", to: personal.id)
        pool.bindProject("/Users/me/code/work-app", to: work.id)

        let (p1, bound1) = pool.effectiveProfile(forProjectPath: "/Users/me/code/work-app/web")
        XCTAssertTrue(bound1)
        XCTAssertEqual(p1.id, work.id, "more specific project path must win")

        let (p2, bound2) = pool.effectiveProfile(forProjectPath: "/Users/me/code/side-project")
        XCTAssertTrue(bound2)
        XCTAssertEqual(p2.id, personal.id)

        let (p3, bound3) = pool.effectiveProfile(forProjectPath: "/tmp/random")
        XCTAssertFalse(bound3)
        XCTAssertEqual(p3.id, pool.activeProfileID)
    }

    func testSyncDirectAndGatewayModes() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notcode-mcp-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cursorFile = tmp.appendingPathComponent("cursor.json")
        try #"{"unrelatedKey": true, "mcpServers": {}}"#.write(to: cursorFile, atomically: true, encoding: .utf8)

        var pool = MCPPool()
        pool.enabledSyncApps = [.cursor]
        pool.servers = [
            MCPServerEntry(name: "github", transport: .http, url: "https://mcp.github.com",
                           headers: ["Authorization": "Bearer default-pat"], sources: ["Manual"])
        ]
        let work = pool.profile(named: "Work")!
        pool.setServer("github", enabled: true, in: work.id)
        if let idx = pool.profiles.firstIndex(where: { $0.id == work.id }) {
            pool.profiles[idx].overrides["github"] = MCPCredentialOverride(
                headers: ["Authorization": "Bearer work-pat"])
        }

        // Direct sync with Work profile should write work-pat and preserve unrelatedKey.
        let updatedWork = pool.profile(named: "Work")!
        pool.syncMode = .direct
        let directReport = MCPSyncer.sync(pool: pool, profile: updatedWork, urlOverrides: [.cursor: cursorFile])
        XCTAssertEqual(directReport.succeededCount, 1)

        let raw = try Data(contentsOf: cursorFile)
        let parsed = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        XCTAssertEqual(parsed["unrelatedKey"] as? Bool, true)
        let mcpServers = parsed["mcpServers"] as! [String: Any]
        let gh = mcpServers["github"] as! [String: Any]
        let headers = gh["headers"] as! [String: String]
        XCTAssertEqual(headers["Authorization"], "Bearer work-pat")

        // Gateway sync should write a single `notcode-hub` entry.
        pool.syncMode = .gateway
        let gwReport = MCPSyncer.sync(pool: pool, profile: work, urlOverrides: [.cursor: cursorFile])
        XCTAssertEqual(gwReport.succeededCount, 1)
        let gwParsed = try JSONSerialization.jsonObject(with: Data(contentsOf: cursorFile)) as! [String: Any]
        let gwServers = gwParsed["mcpServers"] as! [String: Any]
        XCTAssertEqual(Array(gwServers.keys), ["notcode-hub"])
    }

    func testMCPGatewayProtocolInitializeAndProfileSelection() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notcode-mcp-gw-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var pool = MCPPool()
        pool.enabledSyncApps = [] // keep test isolated from host filesystem
        pool.askProfileForNewProjects = true // off by default; this test covers the ask path
        try MCPPoolStore.save(pool, to: tmp)

        // 1. initialize
        let initReq = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let initResp = MCPGateway.handleMessage(Data(initReq.utf8), defaultProjectPath: "/tmp/new-proj", poolURL: tmp)
        XCTAssertEqual(initResp?["id"] as? Int, 1)
        let initResult = initResp?["result"] as? [String: Any]
        XCTAssertEqual(initResult?["protocolVersion"] as? String, MCPGateway.protocolVersion)

        // 2. tools/list
        let listReq = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let listResp = MCPGateway.handleMessage(Data(listReq.utf8), defaultProjectPath: "/tmp/new-proj", poolURL: tmp)
        let tools = (listResp?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let toolNames = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(toolNames.contains("notcode_get_profile"))
        XCTAssertTrue(toolNames.contains("notcode_set_profile"))

        // 3. notcode_get_profile on unbound project prompts agent to ask user
        let getReq = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"notcode_get_profile","arguments":{}}}"#
        let getResp = MCPGateway.handleMessage(Data(getReq.utf8), defaultProjectPath: "/tmp/new-proj", poolURL: tmp)
        let content = ((getResp?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(content.contains("NOT bound"))

        // 4. notcode_set_profile binds project to Work
        let setReq = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"notcode_set_profile","arguments":{"profile":"Work","rememberForProject":true,"syncApps":false}}}"#
        _ = MCPGateway.handleMessage(Data(setReq.utf8), defaultProjectPath: "/tmp/new-proj", poolURL: tmp)

        let reloaded = MCPPoolStore.load(from: tmp)
        let (effective, isBound) = reloaded.effectiveProfile(forProjectPath: "/tmp/new-proj")
        XCTAssertTrue(isBound)
        XCTAssertEqual(effective.name, "Work")
    }

    // MARK: Sync safety

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notcode-mcp-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func posixMode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) ?? -1
    }

    func testSyncKeepsUnmanagedServersExtraKeysAndWritesOwnerOnlyBackups() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cursorFile = tmp.appendingPathComponent("mcp.json")
        let original = #"{"mcpServers": {"hand-added": {"command": "my-tool"}, "github": {"url": "https://old.example", "disabled": true}}}"#
        try original.write(to: cursorFile, atomically: true, encoding: .utf8)

        var pool = MCPPool()
        pool.enabledSyncApps = [.cursor]
        pool.servers = [
            MCPServerEntry(name: "github", transport: .http, url: "https://new.example",
                           headers: ["Authorization": "Bearer fake-test-value"], sources: ["Manual"])
        ]
        let report = MCPSyncer.sync(pool: pool, urlOverrides: [.cursor: cursorFile])
        XCTAssertEqual(report.succeededCount, 1)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: cursorFile)) as! [String: Any]
        let servers = parsed["mcpServers"] as! [String: Any]
        XCTAssertNotNil(servers["hand-added"], "a server the pool does not know must survive a sync")
        let gh = servers["github"] as! [String: Any]
        XCTAssertEqual(gh["url"] as? String, "https://new.example")
        XCTAssertEqual(gh["disabled"] as? Bool, true, "unmodeled per-server keys must survive")
        XCTAssertEqual(posixMode(cursorFile), 0o600)

        let backups = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
            .filter { $0.hasPrefix("mcp.json.notcode-mcp-backup-") }
        XCTAssertEqual(backups.count, 1)
        let backupURL = tmp.appendingPathComponent(backups[0])
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), original)
        XCTAssertEqual(posixMode(backupURL), 0o600)

        // A second sync with nothing to change writes no file and no backup.
        _ = MCPSyncer.sync(pool: pool, urlOverrides: [.cursor: cursorFile])
        let after = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
            .filter { $0.hasPrefix("mcp.json.notcode-mcp-backup-") }
        XCTAssertEqual(after.count, 1)
    }

    func testSyncRefusesToOverwriteUnparseableConfig() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let vscodeFile = tmp.appendingPathComponent("mcp.json")
        let jsonc = "{\n  // my servers\n  \"servers\": {},\n}\n"
        try jsonc.write(to: vscodeFile, atomically: true, encoding: .utf8)

        var pool = MCPPool()
        pool.enabledSyncApps = [.vscode]
        pool.servers = [MCPServerEntry(name: "x", transport: .stdio, command: "x", sources: ["Manual"])]
        let report = MCPSyncer.sync(pool: pool, urlOverrides: [.vscode: vscodeFile])
        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertEqual(try String(contentsOf: vscodeFile, encoding: .utf8), jsonc)
    }

    func testCodexSyncKeepsUnmanagedAndUnchangedBlocks() {
        let toml = """
        model = "gpt-5"

        [mcp_servers.mine]
        command = "my-tool"

        [mcp_servers.linear]
        url = "https://mcp.linear.app/mcp"
        startup_timeout_sec = 30
        """
        let linear = MCPClientConfigIO.parseCodexTOML(toml, source: "Codex").first { $0.name == "linear" }!
        let out = MCPClientConfigIO.replaceCodexMCPServers(
            in: toml, with: [linear], managedNames: ["linear"])
        XCTAssertTrue(out.contains("[mcp_servers.mine]"), "unmanaged block must be kept")
        XCTAssertTrue(out.contains("startup_timeout_sec = 30"), "unchanged block must be kept verbatim")
    }

    func testEndpointPreviewRedactsSecretArgs() {
        let entry = MCPServerEntry(
            name: "remote", transport: .stdio, command: "npx",
            args: ["-y", "mcp-remote", "https://x.example/mcp?api_key=fake", "--header",
                   "Authorization: Bearer fake-value", "--api-key", "fake-value-2", "--token=fake-3"],
            sources: ["Manual"])
        let preview = entry.endpointPreview
        XCTAssertFalse(preview.contains("fake"), preview)
        XCTAssertTrue(preview.contains("mcp-remote"))
    }
}
