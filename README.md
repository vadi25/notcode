<div align="center">

# 🔔 NotCode

**Your AI agents work. You live your life. NotCode taps you on the shoulder when it matters.**

A native macOS menu bar app that plays a sound on your Mac and sends you a **WhatsApp** when
[Claude Code](https://claude.com/claude-code), [Codex](https://developers.openai.com/codex) or [Cursor](https://cursor.com) finishes a task or needs your attention.

[![Latest release](https://img.shields.io/github/v/release/vadi25/notcode)](https://github.com/vadi25/notcode/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-native-F05138?logo=swift&logoColor=white)

**[⬇️ Download](https://notcode.rairai.xyz)** · [Latest DMG](https://github.com/vadi25/notcode/releases/latest/download/NotCode.dmg) · [Setup](#setup) · [How it works](#how-it-works)

</div>

---

You kick off a long agent run and walk away. Twenty minutes later it has been sitting there waiting for a permission click, and you're in the kitchen. NotCode fixes that loop:

- 📱 **WhatsApp on your phone**: "✅ Claude Code finished in *my-app*", wherever you are
- 🔊 **A sound on your Mac**: from a gentle ping to a full siren, any system sound, or your own audio file — with optional per-agent sounds so you know who finished without looking
- 💬 **Reply to keep it moving (beta)**: answer the WhatsApp message and NotCode feeds it back into the session — prompt your agents from the couch, the street, anywhere
- 🤫 **Silent while you're watching**: typing in your terminal or IDE? NotCode knows you can see the agent and stays quiet. One notification per conversation, never spam
- 💸 **Message-frugal**: WhatsApp only sends when you've actually been away from the keyboard, and it carries status updates only, never your code or task output
- 🪶 **Native Swift, ~5 MB**: no Electron, no background CPU, works even when the app isn't running
- 🔌 **One-click hook install**: safely merges into `~/.claude/settings.json`, `~/.codex/config.toml` and `~/.cursor/hooks.json` with backups, and plays nice with existing hooks (it chains, never overwrites)

Works with **Claude Code** (CLI + desktop app), **Codex** (CLI + desktop app) and **Cursor** (via its [hooks](https://cursor.com/docs/hooks); Cursor reports task completion only, since it has no attention/permission hook).

## Install

**Terminal (recommended, no Gatekeeper prompt):**

```bash
curl -fsSL https://notcode.rairai.xyz/install.sh | bash
```

**Or the classic way:** download the DMG from [notcode.rairai.xyz](https://notcode.rairai.xyz) (or the [latest release](https://github.com/vadi25/notcode/releases/latest/download/NotCode.dmg)), drag **NotCode** to Applications, and open it. Since this build isn't notarized yet, macOS will ask you to allow it once: **System Settings → Privacy & Security → "Open Anyway"**.

## Setup

NotCode's onboarding walks you through this, but here's the gist:

1. **Get a WhatsApp API number**, free at [kapso.com](https://kapso.com): sign up, connect a WhatsApp number, then copy your **API key** (Project Settings → API Keys) and the **phone number ID**
2. **Paste both + your phone number** into NotCode
3. **Text "hi" to your new number** from your phone. WhatsApp delivers bot messages for 24h after your last message to it, and every text you send resets the clock. If alerts ever pause, text it again; NotCode shows a menu bar warning when that happens
4. **Click "Install hooks"** and you're done. Run any agent task and go make coffee ☕

## How it works

```
Claude Code ─ Notification/Stop hooks ─┐
Codex ──────── notify config ──────────┼─▶ notcode-hook ──▶ 🔊 local sound
Cursor ─────── stop hook ──────────────┘   (helper CLI)└──▶ 📱 Kapso WhatsApp API
                                               ▲
NotCode.app (menu bar) ── settings · onboarding · pause · hook installer
```

The app installs a tiny helper at `~/Library/Application Support/NotCode/` and points the agents' own hook mechanisms at it. That means **notifications fire even if the menu bar app is closed**; the app is just the control panel.

Before notifying, the helper checks, in order: paused? → event type enabled? → are you actively in a terminal/IDE (then you're watching, stay silent)? → did this session already notify in the last 60s? → sound. WhatsApp additionally requires you to have been away from the keyboard (2 min by default, configurable).

## Reply from WhatsApp (beta)

Turn it on in **Settings → WhatsApp → Reply from your phone**. While the menu bar app is running, NotCode polls your Kapso inbox after each notification (no webhook or tunnel needed) and routes replies back into your sessions:

| You send | What happens |
|---|---|
| `and add tests for it` | goes to the most recent session that notified you |
| `my-app: fix the login bug` | goes to the session running in the `my-app` folder |
| `help` | cheat sheet + list of active sessions |

Under the hood it resumes the session headlessly (`claude -p --resume`, `codex exec resume`, or `cursor-agent` when installed) in the session's own directory. Some ground rules:

- Only messages from **your configured number** are accepted
- Remote runs **never skip permission prompts** — if the agent needs one, your phone gets the notification and the loop continues
- Completion messages are **status-only** by default; an optional toggle includes a short excerpt of the agent's answer
- Claude Code replies continue the conversation headlessly, so a terminal still sitting open on that session won't display the remote turns

## Can't see the bell?

macOS hides the leftmost menu bar icons when the bar runs out of space (very common around the notch). NotCode keeps working either way — hooks and notifications don't depend on the icon. To bring it back, quit a menu bar app you don't use; and opening NotCode again (Spotlight or Applications) always opens its Settings window, so the app is never unreachable.

## Build from source

```bash
brew install xcodegen
git clone https://github.com/vadi25/notcode.git && cd notcode
xcodegen
xcodebuild -project NotCode.xcodeproj -scheme NotCode -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/NotCode.app
```

Tests: `xcodebuild -project NotCode.xcodeproj -scheme NotCode -derivedDataPath build test`

Release DMG: `./scripts/release.sh`

## Where things live

| Path | What |
|---|---|
| `~/Library/Application Support/NotCode/config.json` | your settings (0600; the API key never leaves your Mac except to call Kapso) |
| `~/Library/Application Support/NotCode/notcode-hook` | the helper the agents invoke |
| `~/Library/Logs/NotCode/notcode.log` | activity log, check here first when debugging |
| `~/.claude/settings.json.notcode-backup` | automatic backup made before hook install |

## Roadmap

- ~~Answer from WhatsApp~~ — shipped in 1.2 (see [Reply from WhatsApp](#reply-from-whatsapp-beta))
- Notarized builds + Homebrew cask (`brew install --cask notcode`)
- Approve/deny permission prompts straight from a WhatsApp reply
- Guided onboarding with screenshots

## Contributing

Issues and PRs welcome. The codebase is small and boring on purpose: `NotCode/Shared/` is the engine (config, Kapso client, sounds, hook installer, fully unit-tested), `NotCode/Hook/` is the 50-line helper entry point, `NotCode/App/` is the SwiftUI menu bar app.

## License

[MIT](LICENSE): do whatever you want, just keep the notice. 🔔
