# OpenClicky

An AI buddy that lives next to your cursor on macOS. It can see your screen, talk to you, and fly over to point at things, like having a teacher sitting next to you.

OpenClicky is a fork of [Clicky](https://github.com/farzaa/clicky) by Farza (MIT licensed) with one big difference: **it runs on the Claude Code already installed on your Mac.** No Cloudflare Worker, no API keys, no accounts, no analytics. Your screenshots go from your Mac to Claude through your own Claude Code login, and nowhere else.

![OpenClicky demo](clicky-demo.gif)

## How it works

1. Hold **Control + Option** and talk.
2. Your voice is transcribed **on-device** by Apple Speech.
3. OpenClicky screenshots your display(s) and runs `claude -p` locally with the screenshot + what you said.
4. Claude's reply streams back, is spoken aloud with a macOS voice, and if Claude says `[POINT:x,y:label]` the blue cursor flies to that spot.

| | Upstream Clicky | OpenClicky |
|---|---|---|
| Claude | Anthropic API via a Cloudflare Worker you deploy | Your local `claude` CLI (your Claude Code subscription/login) |
| Speech-to-text | AssemblyAI via the Worker | Apple Speech, on-device (AssemblyAI/OpenAI optional with your own key) |
| Text-to-speech | ElevenLabs via the Worker | macOS voices, on-device (ElevenLabs optional with your own key) |
| Analytics | PostHog (sends transcripts) | None |
| Email signup | FormSpark | None |
| Onboarding intro | Video streamed from upstream's host + bundled game music | Goes straight to the pointing demo; no music bundled |

## Requirements

- macOS 14.2+
- Xcode 26+ (the project uses Swift's default-MainActor isolation)
- [Claude Code](https://claude.com/claude-code), installed and logged in. Run `claude` once in Terminal and finish login.

## Setup

```bash
git clone <your-openclicky-repo-url>
cd openclicky
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme. Yes, the typo is inherited from upstream and the folder names stay as they are.
2. Under **Signing & Capabilities**, pick your own team.
3. **Cmd + R**.

OpenClicky appears in the menu bar, not the Dock. Click the triangle, grant the four permissions (Microphone, Accessibility, Screen Recording, Screen Content), hit **Start**, then hold Control + Option and talk.

### If OpenClicky can't find Claude Code

Apps launched from Finder don't get your shell's `PATH`. OpenClicky looks in `~/.claude/local`, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.bun/bin`, `~/.volta/bin` and `~/.nvm/versions/node/*/bin`, and also asks your login shell. If yours is somewhere else:

```bash
defaults write com.openclicky.app ClaudeCodeCLIPath "$(which claude)"
```

Then click **Re-check** in the panel.

## Options

**Model.** Pick Sonnet or Opus in the panel. These are Claude Code aliases, so you always get the latest one your plan includes.

**Voice.** OpenClicky uses the best English macOS voice you have installed. For a much nicer one, download a *Premium* or *Enhanced* voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices. To force a specific voice:

```bash
defaults write com.openclicky.app LocalSpeechVoiceIdentifier com.apple.voice.premium.en-US.Zoe
```

**Cloud speech (optional).** To use upstream's ElevenLabs voice or AssemblyAI transcription, put **your own** keys in `leanring-buddy/Info.plist`: `ElevenLabsAPIKey` (+ `ElevenLabsVoiceID`), `AssemblyAIAPIKey`, or `OpenAIAPIKey`, and set `VoiceTranscriptionProvider` to `assemblyai`/`openai`. Keys there are compiled into your build, so don't distribute a build that contains them. If ElevenLabs fails, OpenClicky falls back to the macOS voice.

## Privacy

- A screenshot is only taken when you hold the hotkey.
- Screenshots and transcripts go to Claude through your local Claude Code, under your Claude account's terms. Nothing else is sent anywhere.
- Claude Code runs with **all tools disabled** (`--tools ""`), no MCP servers and no session persistence, from its own scratch folder (`~/Library/Application Support/OpenClicky/claude-workspace`). In talk mode it can only look and talk; it can't run commands or edit files.

## What's not here

heyclicky.com is the closed-source successor to Clicky, made by Farza's company. Its newer features (Windows, "agent" mode, drawing on screen, accounts/plans) are not open source, so they aren't part of this fork. OpenClicky is the open-source Clicky codebase rewired to local Claude Code. It isn't affiliated with or endorsed by HeyClicky / Humansongs, Inc.

## Architecture

See [`AGENTS.md`](AGENTS.md) (also `CLAUDE.md`) for the full breakdown. The short version:

- `CompanionManager.swift` — the state machine: hotkey → dictation → screenshot → Claude → speech → pointing.
- `ClaudeCodeCLIClient.swift` — spawns `claude -p --input-format stream-json --output-format stream-json --include-partial-messages`, sends the screenshot(s) and transcript as one message, and streams text deltas back.
- `LocalSpeechTTSClient.swift` — macOS voice TTS, plus the optional ElevenLabs fallback chain.
- `OverlayWindow.swift` — the blue cursor buddy and its pointing animation.

## License

MIT. See [LICENSE](LICENSE). Original work © 2026 Farza.
