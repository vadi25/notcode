# NotCode 🔔

Never babysit your terminal again. NotCode is a native macOS menu bar app that plays a sound on your Mac and sends you a WhatsApp message when **Claude Code** or **Codex** needs your attention — or finishes a task.

- 🔊 Local sounds: bundled funny/loud alerts, any macOS system sound, or your own audio file
- 📱 WhatsApp notifications via [Kapso](https://kapso.com) — status updates only, never task output
- 🧠 Smart economy: WhatsApp only sends when you've actually been away from the keyboard
- ⚙️ One-click hook install for `~/.claude/settings.json` and `~/.codex/config.toml` (with backups)
- 🪶 Tiny native Swift app; notifications work even when the app isn't running

## How it works

```
Claude Code / Codex ──hook──▶ notcode-hook (helper CLI) ──▶ 🔊 sound
                                                        └─▶ 📱 Kapso WhatsApp API
NotCode.app (menu bar) ──▶ settings, onboarding, hook install, pause
```

The app installs a tiny helper at `~/Library/Application Support/NotCode/notcode-hook`. Claude Code's `Notification` and `Stop` hooks and Codex's `notify` config call it directly, so alerts fire even if the menu bar app is closed.

## Build

```bash
brew install xcodegen
xcodegen
xcodebuild -project NotCode.xcodeproj -scheme NotCode -configuration Debug build
open build/Build/Products/Debug/NotCode.app   # with -derivedDataPath build
```

Run tests: `xcodebuild -project NotCode.xcodeproj -scheme NotCode test`

## Setup

First launch opens the onboarding guide:

1. **Create a Kapso account** at [kapso.com](https://kapso.com), connect a WhatsApp number, copy the **API key** (Project Settings → API Keys) and the **phone number ID**
2. **Send "hi"** to your Kapso WhatsApp number from your phone (WhatsApp's 24h window)
3. **Install hooks** — one click for Claude Code + Codex
4. **Test** 🎉

NotCode sends plain individual messages only. WhatsApp delivers them for 24h after your last message to the bot; every message you send resets the clock. If the window closes, NotCode shows a warning in the menu bar — text your number again and alerts resume.

## Roadmap (v2)

- Reply from WhatsApp to keep prompting a session while away (polls Kapso's messages API — no webhook/tunnel needed)
- Full guided onboarding with screenshots
- Notarized DMG, Homebrew cask, Sparkle auto-updates

## Logs & files

| Path | Purpose |
|---|---|
| `~/Library/Application Support/NotCode/config.json` | settings (0600) |
| `~/Library/Application Support/NotCode/notcode-hook` | hook helper |
| `~/Library/Logs/NotCode/notcode.log` | activity log |
| `~/.claude/settings.json.notcode-backup` | backup before hook install |
