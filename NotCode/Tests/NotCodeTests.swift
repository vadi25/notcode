import XCTest

final class HookPayloadTests: XCTestCase {
    func testClaudeNotificationParsing() {
        let json = """
        {"session_id":"abc123","cwd":"/Users/me/projects/my-app",
         "hook_event_name":"Notification",
         "message":"Claude needs your permission to use Bash"}
        """
        let event = HookPayload.parseClaude(kind: .attention, json: Data(json.utf8))
        XCTAssertEqual(event?.agent, "Claude Code")
        XCTAssertEqual(event?.kind, .attention)
        XCTAssertEqual(event?.detail, "Claude needs your permission to use Bash")
        XCTAssertEqual(event?.sessionID, "abc123")
        XCTAssertEqual(event?.projectName, "my-app")
    }

    func testClaudeStopParsing() {
        let json = #"{"session_id":"abc","cwd":"/tmp/demo","hook_event_name":"Stop"}"#
        let event = HookPayload.parseClaude(kind: .done, json: Data(json.utf8))
        XCTAssertEqual(event?.kind, .done)
        XCTAssertNil(event?.detail)
    }

    func testStopHookActiveIsSkipped() {
        let json = #"{"session_id":"abc","cwd":"/tmp","stop_hook_active":true}"#
        XCTAssertNil(HookPayload.parseClaude(kind: .done, json: Data(json.utf8)),
                     "hook-forced continuations must not notify twice")
        XCTAssertNotNil(HookPayload.parseClaude(kind: .attention, json: Data(json.utf8)))
    }

    func testClaudeGarbageInputStillProducesEvent() {
        let event = HookPayload.parseClaude(kind: .attention, json: Data("not json".utf8))
        XCTAssertEqual(event?.agent, "Claude Code")
        XCTAssertNil(event?.cwd)
    }

    func testCodexTurnCompleteParsing() {
        let json = """
        {"type":"agent-turn-complete","turn-id":"t1",
         "input-messages":["Fix the login bug in auth.ts please"],
         "last-assistant-message":"Done, the bug was..."}
        """
        let event = HookPayload.parseCodex(json: Data(json.utf8))
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.agent, "Codex")
        XCTAssertEqual(event?.kind, .done)
        XCTAssertEqual(event?.detail, "Fix the login bug in auth.ts please")
        // Never leak the result into the message, only the task.
        XCTAssertFalse(event!.whatsAppText.contains("the bug was"))
    }

    func testCodexUnknownEventIsIgnored() {
        let json = #"{"type":"something-else"}"#
        XCTAssertNil(HookPayload.parseCodex(json: Data(json.utf8)))
    }

    func testCursorStopParsing() {
        let json = """
        {"hook_event_name":"stop","status":"completed","conversation_id":"conv-1",
         "workspace_roots":["/Users/me/projects/my-app"],"loop_count":0}
        """
        let event = HookPayload.parseCursor(json: Data(json.utf8))
        XCTAssertEqual(event?.agent, "Cursor")
        XCTAssertEqual(event?.kind, .done)
        XCTAssertNil(event?.detail)
        XCTAssertEqual(event?.sessionID, "conv-1")
        XCTAssertEqual(event?.projectName, "my-app")
    }

    func testCursorAbortedIsSkipped() {
        let json = #"{"hook_event_name":"stop","status":"aborted","conversation_id":"c"}"#
        XCTAssertNil(HookPayload.parseCursor(json: Data(json.utf8)),
                     "an aborted turn means the user is at the machine")
        let errored = #"{"hook_event_name":"stop","status":"error","conversation_id":"c"}"#
        XCTAssertNotNil(HookPayload.parseCursor(json: Data(errored.utf8)))
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
    func testMergeIntoEmptySettings() {
        let merged = HookInstaller.merged(into: [:])
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
        let merged = HookInstaller.merged(into: existing)

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
        let once = HookInstaller.merged(into: [:])
        let twice = HookInstaller.merged(into: once)
        let onceJSON = try! JSONSerialization.data(withJSONObject: once, options: .sortedKeys)
        let twiceJSON = try! JSONSerialization.data(withJSONObject: twice, options: .sortedKeys)
        XCTAssertEqual(onceJSON, twiceJSON)
    }

    func testParseNotifyArray() throws {
        let line = #"notify = ["/Users/x/Sky Client.app/Contents/MacOS/SkyClient", "turn-ended"]"#
        let tokens = try HookInstaller.parseNotifyArray(line)
        XCTAssertEqual(tokens, ["/Users/x/Sky Client.app/Contents/MacOS/SkyClient", "turn-ended"])
        XCTAssertThrowsError(try HookInstaller.parseNotifyArray("notify = not-an-array"))
    }

    func testReplaceRootNotifyOnlyTouchesRootLine() {
        let toml = """
        model = "gpt-5"
        notify = ["old"]
        [profiles.x]
        notify = ["inner-stays"]
        """
        let updated = HookInstaller.replaceRootNotify(in: toml, with: "notify = [\"new\"]")
        XCTAssertTrue(updated.contains("notify = [\"new\"]"))
        XCTAssertTrue(updated.contains("notify = [\"inner-stays\"]"))
        XCTAssertFalse(updated.contains("notify = [\"old\"]"))
        XCTAssertTrue(updated.contains("model = \"gpt-5\""))
    }

    func testHelperOnlyChainWhenDownstreamOfCodexApp() {
        let script = HookInstaller.chainScriptContent(existingCommand: [])
        XCTAssertTrue(script.contains("notcode-hook' codex \"$@\""))
        XCTAssertFalse(script.contains("SkyClient"))

        let rewritten = #"notify = ["/x/SkyComputerUseClient", "turn-ended", "--previous-notify", "[\"/y/NotCode/codex-notify-chain.sh\"]"]"#
        XCTAssertTrue(HookInstaller.codexChainIsDownstream(notifyLine: rewritten))
        XCTAssertTrue(HookInstaller.isOurNotify(rewritten), "downstream chain still counts as installed")
        XCTAssertFalse(HookInstaller.codexChainIsDownstream(
            notifyLine: #"notify = ["/y/NotCode/codex-notify-chain.sh"]"#))
    }

    func testChainScriptForwardsToBothHandlers() {
        let script = HookInstaller.chainScriptContent(
            existingCommand: ["/Users/x/Sky Client.app/MacOS/SkyClient", "turn-ended"])
        XCTAssertTrue(script.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(script.contains("'/Users/x/Sky Client.app/MacOS/SkyClient' 'turn-ended' \"$@\""))
        XCTAssertTrue(script.contains("notcode-hook' codex \"$@\""))
    }

    func testCursorMergeIntoEmptyHooks() {
        let merged = HookInstaller.mergedCursorHooks(into: [:])
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
        let merged = HookInstaller.mergedCursorHooks(into: existing)
        let hooks = merged["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["beforeShellExecution"], "unrelated hook events must survive")
        let stop = hooks["stop"] as! [[String: Any]]
        let commands = stop.compactMap { $0["command"] as? String }
        XCTAssertEqual(stop.count, 2, "existing entry kept, ours appended")
        XCTAssertTrue(commands.contains("./scripts/my-hook.sh"))
        XCTAssertTrue(commands.contains { $0.contains("notcode-hook") })
    }

    func testCursorMergeIsIdempotent() {
        let once = HookInstaller.mergedCursorHooks(into: [:])
        let twice = HookInstaller.mergedCursorHooks(into: once)
        let onceJSON = try! JSONSerialization.data(withJSONObject: once, options: .sortedKeys)
        let twiceJSON = try! JSONSerialization.data(withJSONObject: twice, options: .sortedKeys)
        XCTAssertEqual(onceJSON, twiceJSON)
    }

    func testCursorWrapperExecsHelper() {
        let script = HookInstaller.cursorWrapperContent()
        XCTAssertTrue(script.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(script.contains("notcode-hook' cursor"))
    }

    func testCodexRootNotifyDetection() {
        XCTAssertNil(HookInstaller.rootNotifyLine(in: ""))
        XCTAssertNil(HookInstaller.rootNotifyLine(in: "model = \"gpt-5\"\n[tui]\nnotifications = true"))
        XCTAssertNil(HookInstaller.rootNotifyLine(in: "[profiles.x]\nnotify = [\"foo\"]"),
                     "notify inside a table is not a root notify")
        XCTAssertEqual(
            HookInstaller.rootNotifyLine(in: "model = \"gpt-5\"\nnotify = [\"foo\"]\n[tui]"),
            "notify = [\"foo\"]")
        XCTAssertNotNil(HookInstaller.rootNotifyLine(in: "notify=[\"x\"]"))
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

    func testHasKapsoCredentials() {
        var config = NotCodeConfig()
        XCTAssertFalse(config.hasKapsoCredentials)
        config.kapsoAPIKey = "k"
        config.phoneNumberID = "p"
        config.recipientPhone = "r"
        XCTAssertTrue(config.hasKapsoCredentials)
    }
}
