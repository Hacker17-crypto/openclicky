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
