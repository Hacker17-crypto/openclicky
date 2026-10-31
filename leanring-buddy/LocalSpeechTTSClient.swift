//
//  LocalSpeechTTSClient.swift
//  leanring-buddy
//
//  Text-to-speech backends. OpenClicky speaks with macOS's built-in voices
//  by default (fully on-device, no account needed). If the user adds their
//  own ElevenLabs key, ElevenLabsTTSClient is used instead, with the local
//  voice as an automatic fallback.
//

import AVFoundation
import Foundation

/// Shared surface for anything that can speak Claude's response aloud.
@MainActor
protocol CompanionTextToSpeechClient: AnyObject {
    /// Starts speaking `text`. Returns once playback has begun.
    func speakText(_ text: String) async throws
    /// Whether audio is currently playing back.
    var isPlaying: Bool { get }
    /// Stops any in-progress playback immediately.
    func stopPlayback()
    /// True when `enqueueText` can add sentences without interrupting the current one,
    /// which lets OpenClicky start talking while Claude is still writing.
    var supportsQueuedSpeech: Bool { get }
    /// Speaks `text` after whatever is already queued.
    func enqueueText(_ text: String)
}

extension CompanionTextToSpeechClient {
    var supportsQueuedSpeech: Bool { false }
    func enqueueText(_ text: String) {}
}

@MainActor
enum CompanionTextToSpeechClientFactory {
    static func makeDefaultClient() -> any CompanionTextToSpeechClient {
        let localSpeechClient = LocalSpeechTTSClient()

        if let elevenLabsAPIKey = AppBundleConfiguration.stringValue(forKey: "ElevenLabsAPIKey") {
            let elevenLabsVoiceID = AppBundleConfiguration.stringValue(forKey: "ElevenLabsVoiceID")
                ?? ElevenLabsTTSClient.defaultVoiceID
            print("🔊 TTS: using ElevenLabs (your own key) with macOS voice fallback")
            return FallbackTextToSpeechClient(
                primaryClient: ElevenLabsTTSClient(apiKey: elevenLabsAPIKey, voiceID: elevenLabsVoiceID),
                fallbackClient: localSpeechClient
            )
        }

        print("🔊 TTS: using macOS on-device voice (\(localSpeechClient.voiceDisplayName))")
        return localSpeechClient
    }
}

/// Speaks with AVSpeechSynthesizer. Picks the highest-quality installed English
/// voice (Premium > Enhanced > default). Users can download nicer voices in
/// System Settings > Accessibility > Spoken Content > System Voice > Manage Voices,
/// or force a specific one with:
/// `defaults write com.openclicky.app LocalSpeechVoiceIdentifier com.apple.voice.premium.en-US.Zoe`
@MainActor
final class LocalSpeechTTSClient: NSObject, CompanionTextToSpeechClient {
    static let voiceIdentifierOverrideDefaultsKey = "LocalSpeechVoiceIdentifier"

    private let speechSynthesizer = AVSpeechSynthesizer()

    /// Re-resolved on every utterance so voice changes in Settings apply immediately.
    private var selectedVoice: AVSpeechSynthesisVoice? {
        Self.pickBestAvailableVoice()
    }

    var voiceDisplayName: String {
        selectedVoice?.name ?? "system default"
    }

    /// Normal rate scaled by the user's 0.5x–1.5x speed setting.
    private static var userAdjustedSpeechRate: Float {
        let speechRateMultiplier = Float(OpenClickySettings.shared.speechRateMultiplier)
        let adjustedSpeechRate = AVSpeechUtteranceDefaultSpeechRate * speechRateMultiplier
        return min(max(adjustedSpeechRate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    /// English voices installed on this Mac, best quality first, for the Settings picker.
    static func installedEnglishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { firstVoice, secondVoice in
                if firstVoice.quality.rawValue != secondVoice.quality.rawValue {
                    return firstVoice.quality.rawValue > secondVoice.quality.rawValue
                }
                return firstVoice.name < secondVoice.name
            }
    }

    /// Speaks a short sample with a specific voice so the user can compare voices in Settings.
    func previewVoice(identifier voiceIdentifier: String) {
        stopPlayback()
        let previewUtterance = AVSpeechUtterance(string: "hey, i'm openclicky. this is how i sound.")
        previewUtterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? selectedVoice
        previewUtterance.rate = Self.userAdjustedSpeechRate
        speechSynthesizer.speak(previewUtterance)
    }

    func speakText(_ text: String) async throws {
        try Task.checkCancellation()

        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = selectedVoice
        utterance.rate = Self.userAdjustedSpeechRate
        speechSynthesizer.speak(utterance)

        // speak() is asynchronous. Wait briefly until audio is actually playing so
        // callers that poll `isPlaying` right after this returns see the true state.
        let waitDeadline = Date().addingTimeInterval(1.0)
        while !speechSynthesizer.isSpeaking && Date() < waitDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        print("🔊 macOS TTS: speaking \(text.count) characters with \(voiceDisplayName)")
    }

    var isPlaying: Bool {
        speechSynthesizer.isSpeaking
    }

    func stopPlayback() {
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    var supportsQueuedSpeech: Bool { true }

    /// AVSpeechSynthesizer queues utterances, so sentences play back to back with natural pauses.
    func enqueueText(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.voice = selectedVoice
        utterance.rate = Self.userAdjustedSpeechRate
        speechSynthesizer.speak(utterance)
    }

    private static func pickBestAvailableVoice() -> AVSpeechSynthesisVoice? {
        if let overrideVoiceIdentifier = UserDefaults.standard.string(forKey: voiceIdentifierOverrideDefaultsKey),
           !overrideVoiceIdentifier.isEmpty,
           let overrideVoice = AVSpeechSynthesisVoice(identifier: overrideVoiceIdentifier) {
            return overrideVoice
        }

        let preferredLanguageCode = Locale.preferredLanguages.first ?? "en-US"
        let allInstalledVoices = AVSpeechSynthesisVoice.speechVoices()

        // Novelty voices (Bells, Bubbles, Zarvox...) technically qualify but sound silly.
        let usableEnglishVoices = allInstalledVoices.filter { voice in
            voice.language.hasPrefix("en") && !voice.voiceTraits.contains(.isNoveltyVoice)
        }

        func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
            switch voice.quality {
            case .premium: return 3
            case .enhanced: return 2
            default: return 1
            }
        }

        let bestVoice = usableEnglishVoices.max { firstVoice, secondVoice in
            let firstVoiceMatchesLocale = firstVoice.language == preferredLanguageCode ? 1 : 0
            let secondVoiceMatchesLocale = secondVoice.language == preferredLanguageCode ? 1 : 0
            if qualityRank(firstVoice) != qualityRank(secondVoice) {
                return qualityRank(firstVoice) < qualityRank(secondVoice)
            }
            return firstVoiceMatchesLocale < secondVoiceMatchesLocale
        }

        return bestVoice ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

/// Tries the primary voice (ElevenLabs) and falls back to the local voice if it fails,
/// so a bad key or an outage never leaves OpenClicky mute.
@MainActor
final class FallbackTextToSpeechClient: CompanionTextToSpeechClient {
    private let primaryClient: any CompanionTextToSpeechClient
    private let fallbackClient: any CompanionTextToSpeechClient

    init(primaryClient: any CompanionTextToSpeechClient, fallbackClient: any CompanionTextToSpeechClient) {
        self.primaryClient = primaryClient
        self.fallbackClient = fallbackClient
    }

    func speakText(_ text: String) async throws {
        do {
            try await primaryClient.speakText(text)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("⚠️ Primary TTS failed (\(error.localizedDescription)), using macOS voice")
            try await fallbackClient.speakText(text)
        }
    }

    var isPlaying: Bool {
        primaryClient.isPlaying || fallbackClient.isPlaying
    }

    func stopPlayback() {
        primaryClient.stopPlayback()
        fallbackClient.stopPlayback()
    }
}

// MARK: - Streaming Speech

/// Splits a reply that's still streaming into complete sentences that can be spoken
/// right away. Only the speakable part is considered: everything before the first
/// tag ("[POINT:...", "[CIRCLE:...") or "<visual" block, since tags come at the end.
struct StreamingSpeechSegmenter {
    /// How many characters of the speakable text have already been handed to TTS.
    private(set) var consumedCharacterCount = 0
    private(set) var spokenTextSoFar = ""

    var hasSpokenAnything: Bool { consumedCharacterCount > 0 }

    /// Text before the first tag or visual block.
    static func speakablePrefix(of responseText: String) -> String {
        var cutIndex = responseText.endIndex
        if let tagStart = responseText.firstIndex(of: "[") {
            cutIndex = min(cutIndex, tagStart)
        }
        if let visualStart = responseText.range(of: "<visual", options: .caseInsensitive)?.lowerBound {
            cutIndex = min(cutIndex, visualStart)
        }
        if let boardStart = responseText.range(of: "<board", options: .caseInsensitive)?.lowerBound {
            cutIndex = min(cutIndex, boardStart)
        }
        return String(responseText[..<cutIndex])
    }

    /// Returns any newly completed sentences (nil if none yet).
    mutating func takeCompletedSentences(from accumulatedResponseText: String) -> String? {
        let speakableText = Self.speakablePrefix(of: accumulatedResponseText)
        let speakableCharacters = Array(speakableText)
        guard speakableCharacters.count > consumedCharacterCount else { return nil }

        // The last sentence end: . ! ? followed by whitespace, or a line break.
        var lastSentenceEndOffset: Int?
        var characterOffset = speakableCharacters.count - 1
        while characterOffset >= consumedCharacterCount {
            let character = speakableCharacters[characterOffset]
            if character.isNewline {
                lastSentenceEndOffset = characterOffset + 1
                break
            }
            if (character == "." || character == "!" || character == "?"),
               characterOffset + 1 < speakableCharacters.count,
               speakableCharacters[characterOffset + 1].isWhitespace {
                lastSentenceEndOffset = characterOffset + 1
                break
            }
            characterOffset -= 1
        }

        guard let lastSentenceEndOffset, lastSentenceEndOffset > consumedCharacterCount else { return nil }
        let newSentencesText = String(speakableCharacters[consumedCharacterCount..<lastSentenceEndOffset])
        // Wait for a bit more if all we have is a tiny fragment like "ok."
        guard newSentencesText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 || consumedCharacterCount > 0 else {
            return nil
        }
        consumedCharacterCount = lastSentenceEndOffset
        spokenTextSoFar += newSentencesText
        return newSentencesText
    }

    /// Once the full reply has arrived: whatever part of the final spoken text (board and tags
    /// already removed) hasn't been handed to TTS yet. Catches the last partial sentence and
    /// any words Claude wrote after the board.
    mutating func takeRemainder(afterSpeaking fullSpokenText: String) -> String? {
        func collapsedWhitespace(_ text: String) -> String {
            text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let collapsedFullText = collapsedWhitespace(fullSpokenText)
        let collapsedAlreadySpoken = collapsedWhitespace(spokenTextSoFar)

        let remainderText: String
        if collapsedAlreadySpoken.isEmpty {
            remainderText = collapsedFullText
        } else if collapsedFullText.hasPrefix(collapsedAlreadySpoken) {
            remainderText = String(collapsedFullText.dropFirst(collapsedAlreadySpoken.count))
        } else {
            // Text didn't line up (rare); don't risk repeating what was already said.
            return nil
        }

        let trimmedRemainderText = remainderText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRemainderText.isEmpty else { return nil }
        spokenTextSoFar += " " + trimmedRemainderText
        consumedCharacterCount = Int.max / 2
        return trimmedRemainderText
    }

    /// Whatever speakable text is left once the full reply has arrived.
    mutating func takeRemainder(from fullResponseText: String) -> String? {
        let speakableCharacters = Array(Self.speakablePrefix(of: fullResponseText))
        guard speakableCharacters.count > consumedCharacterCount else { return nil }
        let remainderText = String(speakableCharacters[consumedCharacterCount...])
        consumedCharacterCount = speakableCharacters.count
        spokenTextSoFar += remainderText
        let trimmedRemainderText = remainderText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedRemainderText.isEmpty ? nil : trimmedRemainderText
    }
}
