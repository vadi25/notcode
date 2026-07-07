import XCTest

final class HookPayloadTests: XCTestCase {
    func testClaudeNotificationParsing() {
        let json = """
        {"session_id":"abc123","cwd":"/Users/me/projects/my-app",
         "hook_event_name":"Notification",
         "message":"Claude needs your permission to use Bash"}
        """
        let event = HookPayload.parseClaude(kind: .attention, json: Data(json.utf8))
        XCTAssertEqual(event.agent, "Claude Code")
        XCTAssertEqual(event.kind, .attention)
        XCTAssertEqual(event.detail, "Claude needs your permission to use Bash")
        XCTAssertEqual(event.sessionID, "abc123")
        XCTAssertEqual(event.projectName, "my-app")
    }

    func testClaudeStopParsing() {
        let json = #"{"session_id":"abc","cwd":"/tmp/demo","hook_event_name":"Stop"}"#
        let event = HookPayload.parseClaude(kind: .done, json: Data(json.utf8))
        XCTAssertEqual(event.kind, .done)
        XCTAssertNil(event.detail)
    }

    func testClaudeGarbageInputStillProducesEvent() {
        let event = HookPayload.parseClaude(kind: .attention, json: Data("not json".utf8))
        XCTAssertEqual(event.agent, "Claude Code")
        XCTAssertNil(event.cwd)
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

    func testChainScriptForwardsToBothHandlers() {
        let script = HookInstaller.chainScriptContent(
            existingCommand: ["/Users/x/Sky Client.app/MacOS/SkyClient", "turn-ended"])
        XCTAssertTrue(script.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(script.contains("'/Users/x/Sky Client.app/MacOS/SkyClient' 'turn-ended' \"$@\""))
        XCTAssertTrue(script.contains("notcode-hook' codex \"$@\""))
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

    func testHasKapsoCredentials() {
        var config = NotCodeConfig()
        XCTAssertFalse(config.hasKapsoCredentials)
        config.kapsoAPIKey = "k"
        config.phoneNumberID = "p"
        config.recipientPhone = "r"
        XCTAssertTrue(config.hasKapsoCredentials)
    }
}
