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
        // Installed hooks in the wild use these exact strings — never change them.
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
