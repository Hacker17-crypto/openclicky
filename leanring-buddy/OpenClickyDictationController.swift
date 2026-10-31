//
//  OpenClickyDictationController.swift
//  leanring-buddy
//
//  System-wide dictation: hold Fn + Control, speak, release, and the text
//  is typed into whatever app has focus. Double-tap Fn + Control for
//  hands-free mode (keeps listening until the next press).
//
//  Extras:
//  - "Polish with Claude" (Settings) cleans up punctuation, filler words
//    and self-corrections with Claude Haiku before inserting.
//  - Screen-aware drafting: start with "draft ..." (e.g. "draft a reply
//    saying I'll be there at five") and OpenClicky looks at the screen and
//    writes the message for you, then inserts it.
//
//  Speech recognition reuses the same BuddyDictationManager as talk mode,
//  so only one of talk/dictation can run at a time.
//

import AppKit
import Foundation

@MainActor
final class OpenClickyDictationController {
    private let buddyDictationManager: BuddyDictationManager
    /// Lets CompanionManager show the spinner while Claude polishes or drafts.
    private let setProcessingIndicatorVisible: (Bool) -> Void

    private var isDictationSessionActive = false
    private var isHandsFreeModeActive = false
    private var currentPressStartedAt = Date.distantPast
    private var lastQuickTapReleasedAt: Date?
    private var pendingStartTask: Task<Void, Never>?

    /// Presses shorter than this are taps (part of a double-tap), not dictation.
    private let quickTapMaximumDurationSeconds: TimeInterval = 0.3
    /// Two taps within this window turn on hands-free mode.
    private let doubleTapWindowSeconds: TimeInterval = 0.6

    private let polishingClaudeClient = ClaudeCodeCLIClient(model: "haiku")
    private let draftingClaudeClient = ClaudeCodeCLIClient(model: "sonnet")

    init(buddyDictationManager: BuddyDictationManager, setProcessingIndicatorVisible: @escaping (Bool) -> Void) {
        self.buddyDictationManager = buddyDictationManager
        self.setProcessingIndicatorVisible = setProcessingIndicatorVisible
    }

    var isBusy: Bool { isDictationSessionActive }

    // MARK: - Shortcut Handling

    func handleDictationShortcutTransition(_ shortcutTransition: BuddyPushToTalkShortcut.ShortcutTransition) {
        guard OpenClickySettings.shared.isDictationEnabled else { return }

        switch shortcutTransition {
        case .pressed:
            // In hands-free mode, the next press ends the dictation.
            if isHandsFreeModeActive {
                isHandsFreeModeActive = false
                isDictationSessionActive = false
                buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
                return
            }

            // Talk mode (or a finalizing dictation) is using the microphone.
            guard !buddyDictationManager.isDictationInProgress else { return }

            currentPressStartedAt = Date()
            isDictationSessionActive = true

            pendingStartTask?.cancel()
            pendingStartTask = Task { [weak self] in
                guard let self else { return }
                await self.buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.handleFinalTranscript(finalTranscript)
                    }
                )
            }

        case .released:
            guard isDictationSessionActive, !isHandsFreeModeActive else { return }

            let pressDurationSeconds = Date().timeIntervalSince(currentPressStartedAt)
            let isQuickTap = pressDurationSeconds < quickTapMaximumDurationSeconds

            if isQuickTap,
               let lastQuickTapReleasedAt,
               Date().timeIntervalSince(lastQuickTapReleasedAt) < doubleTapWindowSeconds {
                // Second tap of a double-tap: keep the microphone open until the next press.
                self.lastQuickTapReleasedAt = nil
                isHandsFreeModeActive = true
                print("🎙️ Dictation: hands-free mode on")
                return
            }

            isDictationSessionActive = false
            pendingStartTask?.cancel()
            pendingStartTask = nil

            if isQuickTap {
                // Too short to contain speech; discard immediately so a second tap can start fresh.
                lastQuickTapReleasedAt = Date()
                buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
            } else {
                lastQuickTapReleasedAt = nil
                buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            }

        case .none:
            break
        }
    }

    // MARK: - Transcript → Text

    private func handleFinalTranscript(_ finalTranscript: String) {
        let trimmedTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }
        print("🎙️ Dictation transcript: \(trimmedTranscript)")

        if let draftingInstruction = Self.draftingInstruction(from: trimmedTranscript) {
            draftTextFromScreen(instruction: draftingInstruction)
            return
        }

        if OpenClickySettings.shared.polishesDictationWithClaude {
            polishAndInsert(rawTranscript: trimmedTranscript)
        } else {
            FocusedAppTextInserter.insertText(Self.lightlyCleanedTranscript(trimmedTranscript))
        }
    }

    /// "draft a reply saying..." / "draft an email to..." → the instruction; otherwise nil.
    static func draftingInstruction(from transcript: String) -> String? {
        let lowercasedTranscript = transcript.lowercased()
        let draftingPrefixes = ["draft a ", "draft an ", "draft me ", "draft the ", "draft my ", "write a reply", "write a response", "reply saying"]
        guard draftingPrefixes.contains(where: { lowercasedTranscript.hasPrefix($0) }) else { return nil }
        return transcript
    }

    /// Without Claude: just make sure the text starts with a capital letter.
    private static func lightlyCleanedTranscript(_ transcript: String) -> String {
        guard let firstCharacter = transcript.first else { return transcript }
        return firstCharacter.uppercased() + transcript.dropFirst()
    }

    private static let polishingSystemPrompt = """
    you clean up dictated text before it's typed into an app. fix punctuation, capitalization and obvious speech-recognition mistakes, remove filler words (um, uh, like, you know), and apply spoken self-corrections ("at five, no, six" becomes "at six"). keep the speaker's wording, tone and language otherwise. never add content, never answer questions in the text, never use em dashes. output only the cleaned text, nothing else.
    """

    private func polishAndInsert(rawTranscript: String) {
        setProcessingIndicatorVisible(true)
        Task {
            defer { setProcessingIndicatorVisible(false) }
            do {
                let (polishedText, _) = try await polishingClaudeClient.analyzeImage(
                    images: [],
                    systemPrompt: Self.polishingSystemPrompt,
                    userPrompt: rawTranscript
                )
                let trimmedPolishedText = polishedText.trimmingCharacters(in: .whitespacesAndNewlines)
                FocusedAppTextInserter.insertText(trimmedPolishedText.isEmpty ? rawTranscript : trimmedPolishedText)
            } catch {
                print("⚠️ Dictation polish failed, inserting raw text: \(error)")
                FocusedAppTextInserter.insertText(Self.lightlyCleanedTranscript(rawTranscript))
            }
        }
    }

    private static let draftingSystemPrompt = """
    you write text for the user to send or type, based on what they asked for and what's on their screen (for example the email, chat or document they're replying to). write it in the user's own voice: natural, concise, matching the tone of the conversation on screen. never use em dashes. output only the text to insert, with no preamble, no quotes and no explanation.
    """

    private func draftTextFromScreen(instruction: String) {
        setProcessingIndicatorVisible(true)
        Task {
            defer { setProcessingIndicatorVisible(false) }
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                let cursorScreenImages = screenCaptures
                    .filter { $0.isCursorScreen }
                    .map { (data: $0.imageData, label: $0.label) }

                var userPrompt = instruction
                let profileText = OpenClickySettings.shared.isMemoryEnabled ? OpenClickyMemoryStore.readProfileText() : ""
                if !profileText.isEmpty {
                    userPrompt += "\n\n(about me, for context:\n\(profileText))"
                }

                let (draftedText, _) = try await draftingClaudeClient.analyzeImage(
                    images: cursorScreenImages,
                    systemPrompt: Self.draftingSystemPrompt,
                    userPrompt: userPrompt
                )
                let trimmedDraftedText = draftedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedDraftedText.isEmpty {
                    FocusedAppTextInserter.insertText(trimmedDraftedText)
                }
            } catch {
                print("⚠️ Screen-aware drafting failed: \(error)")
                NSSound.beep()
            }
        }
    }
}

// MARK: - Text Insertion

/// Types text into the focused app by putting it on the pasteboard and sending
/// Cmd+V, then restoring whatever the user had copied. Works in virtually every
/// app (uses the Accessibility permission OpenClicky already has).
@MainActor
enum FocusedAppTextInserter {
    static func insertText(_ text: String) {
        guard !text.isEmpty else { return }

        let generalPasteboard = NSPasteboard.general
        let previousPasteboardItems = snapshotPasteboardItems(generalPasteboard)

        generalPasteboard.clearContents()
        generalPasteboard.setString(text, forType: .string)
        let changeCountAfterOurWrite = generalPasteboard.changeCount

        // Small delay so the user's fingers are off the modifier keys before we press Cmd+V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            postCommandV()

            // Restore the user's clipboard once the paste has been handled,
            // unless something else has written to it in the meantime.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard generalPasteboard.changeCount == changeCountAfterOurWrite else { return }
                generalPasteboard.clearContents()
                if !previousPasteboardItems.isEmpty {
                    generalPasteboard.writeObjects(previousPasteboardItems)
                }
            }
        }
        print("⌨️ Inserted \(text.count) characters into the focused app")
    }

    private static func postCommandV() {
        let keyboardEventSource = CGEventSource(stateID: .combinedSessionState)
        let virtualKeyCodeForV: CGKeyCode = 9

        let commandVKeyDown = CGEvent(keyboardEventSource: keyboardEventSource, virtualKey: virtualKeyCodeForV, keyDown: true)
        commandVKeyDown?.flags = .maskCommand
        commandVKeyDown?.post(tap: .cghidEventTap)

        let commandVKeyUp = CGEvent(keyboardEventSource: keyboardEventSource, virtualKey: virtualKeyCodeForV, keyDown: false)
        commandVKeyUp?.flags = .maskCommand
        commandVKeyUp?.post(tap: .cghidEventTap)
    }

    /// Deep-copies the current pasteboard items so they survive clearContents().
    private static func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { originalItem in
            let copiedItem = NSPasteboardItem()
            for pasteboardType in originalItem.types {
                if let itemData = originalItem.data(forType: pasteboardType) {
                    copiedItem.setData(itemData, forType: pasteboardType)
                }
            }
            return copiedItem
        }
    }
}
