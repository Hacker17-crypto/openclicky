# OpenClicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app (fork of farzaa/clicky). Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it on-device with Apple Speech, and sends the transcript + a screenshot of the user's screen to Claude **through the user's locally installed Claude Code CLI**. Claude's text streams back and is spoken with a macOS on-device voice. A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

There is no server, no proxy, no API key and no telemetry. Claude access, auth and billing all come from the user's own `claude` login.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude via the local Claude Code CLI (`claude -p`, stream-json in/out, partial messages). Model aliases `sonnet` (default) / `opus`
- **Speech-to-Text**: Apple Speech on-device (default). AssemblyAI / OpenAI are optional with the user's own key in Info.plist
- **Text-to-Speech**: macOS `AVSpeechSynthesizer` (best installed English voice). ElevenLabs optional with the user's own key, falling back to the macOS voice
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: None. `ClickyAnalytics.swift` is a local no-op kept so call sites match upstream

### Claude Code CLI Bridge

`ClaudeCodeCLIClient` spawns one `claude` process per request:

```
claude --print --input-format stream-json --output-format stream-json --verbose \
  --include-partial-messages --model <sonnet|opus> --system-prompt <persona> \
  --tools "" --strict-mcp-config --setting-sources user \
  --disable-slash-commands --no-session-persistence
```

- One stream-json `user` message goes to stdin: prior exchanges as a text block, then each screenshot (base64 image block + label), then the transcript. Then stdin is closed.
- stdout `stream_event` → `content_block_delta` → `text_delta` events are accumulated. `result` with `is_error` becomes a `ClaudeCodeCLIError`.
- All tools are disabled; talk mode is vision + conversation only.
- The process runs in `~/Library/Application Support/OpenClicky/claude-workspace` so no project CLAUDE.md/settings are picked up.
- The binary is found via the `ClaudeCodeCLIPath` UserDefaults override, well-known install dirs, nvm dirs, and the login shell's PATH. The login-shell PATH is passed to the child so npm installs can find `node`.
- Task cancellation (user speaks again) terminates the child process.

Optional Info.plist keys (blank by default): `AssemblyAIAPIKey`, `OpenAIAPIKey`, `ElevenLabsAPIKey`, `ElevenLabsVoiceID`, `VoiceTranscriptionProvider` (`apple`|`assemblyai`|`openai`).

### OpenClicky Features (beyond upstream Clicky)

Talk replies can carry extra tags, parsed in this order: `<visual>` blocks (VisualExplainerParser, first because they contain brackets) → `[AGENT:]`, `[REMEMBER:]`, `[CIRCLE:]`, `[HIGHLIGHT:]`, `[UNDERLINE:]`, `[ARROW:]`, `[LABEL:]`, `[NOTE:]` (ScreenAnnotationTagParser) → `[POINT:]` (CompanionManager.parsePointingCoordinates). The prompt describing them is `companionCapabilitiesSystemPromptExtension` in CompanionManager. It was verified against Claude Code, so change the tag formats and the parsers together.

- **Agents**: `[AGENT:task]` or a transcript starting with "agent, ..." launches a long-lived `claude` process (`--permission-prompt-tool stdio`, stream-json in/out, stdin kept open for follow-ups) in `~/OpenClicky/<date> <name>/`. `can_use_tool` control requests become approval cards unless the mode is Always approve or the tool is always-allowed. The process exits when the card is dismissed.
- **Drawing**: annotations are stored in global AppKit coordinates in `CompanionManager.activeScreenAnnotations` and rendered per screen by `ScreenAnnotationLayerView` inside BlueCursorView. They clear 5 seconds after TTS ends or on the next press.
- **Visual cards**: one WKWebView NSPanel at a time. Diagrams are SVG with a stroke-draw animation; 3D is a three.js r160 script (CDN importmap) run via `new Function` with helpers (material, addPart, addLabel, addArrow). TTS starts as soon as `<visual` appears in the stream (`speakEarlyIfVisualHasStarted`).
- **Dictation**: Fn+Control (without Option) is detected in GlobalPushToTalkShortcutMonitor, handled by OpenClickyDictationController (hold, double-tap hands-free, Claude polish, "draft ..." screen-aware writing), and inserted with pasteboard + Cmd+V (FocusedAppTextInserter), restoring the clipboard afterwards.
- **Memory/settings**: OpenClickySettings (UserDefaults), OpenClickyMemoryStore (`PROFILE.md` + `conversation.json` in Application Support, 20 exchanges), Settings window from the panel footer.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Onboarding**: Upstream streamed a hosted intro video and played bundled game music. OpenClicky has neither: after the welcome text it runs the pointing demo (~2s) and then the "press control + option" prompt (~12s). An optional `onboarding.mp3` in the bundle is played if present.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show OpenClicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1026 | Central state machine. Owns dictation, shortcut monitoring, screen capture, the Claude Code client, TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, Claude Code missing notice, credits link, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Optional (needs `AssemblyAIAPIKey`). Fetches temp tokens directly from AssemblyAI, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Default transcription provider backed by Apple's Speech framework (on-device recognition when supported). |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeCodeCLIClient.swift` | ~520 | Claude via the local Claude Code CLI. Locates `claude` + PATH, builds the stream-json message (history, screenshots, transcript), streams text deltas, maps CLI errors (not installed / not logged in / failed), terminates on cancellation. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `OpenClickyAgents.swift` | ~560 | Agent process (stdio permission protocol), OpenClickyAgent state machine (countdown → working → needs approval → finished/failed), OpenClickyAgentManager. |
| `AgentCardsPanel.swift` | ~330 | Top-right floating NSPanel with an agent card per agent (approve/stop/retry/reply/open folder). |
| `ScreenAnnotations.swift` | ~560 | Tag parser for drawing/agent/memory tags, screenshot→screen coordinate conversion, hand-drawn circle/arrow/highlight/underline, callout labels, sticky notes. |
| `VisualExplainerCards.swift` | ~470 | `<visual>` parser + WKWebView card panels: SVG whiteboard diagrams and three.js 3D models. |
| `OpenClickyDictationController.swift` | ~270 | Fn+Control dictation, hands-free double-tap, Claude polish, screen-aware drafting, FocusedAppTextInserter. |
| `OpenClickySettings.swift` | ~210 | User preferences + OpenClickyMemoryStore (PROFILE.md, persisted conversation). |
| `OpenClickySettingsWindow.swift` | ~260 | Settings window (voice, dictation, agents, memory, shortcuts). |
| `ElevenLabsTTSClient.swift` | ~87 | Optional ElevenLabs TTS client using the user's own key directly. Plays audio via `AVAudioPlayer`. |
| `LocalSpeechTTSClient.swift` | ~165 | `CompanionTextToSpeechClient` protocol, default macOS `AVSpeechSynthesizer` client, ElevenLabs→macOS fallback wrapper, and factory. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~130 | Analytics event surface. All events are local no-ops (no telemetry). |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Claude Code

The user must have Claude Code installed and logged in (`claude` once in Terminal). To debug the exact call the app makes, run the command from "Claude Code CLI Bridge" in Terminal and pipe a stream-json user message into it.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
