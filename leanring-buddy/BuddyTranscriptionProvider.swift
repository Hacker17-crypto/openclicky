//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case assemblyAI = "assemblyai"
        case openAI = "openai"
        case appleSpeech = "apple"
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        // The engine picked in OpenClicky's chooser wins over Info.plist.
        if let userSelectedEngineRawValue = UserDefaults.standard.string(forKey: "selectedTranscriptionEngine"),
           let userSelectedEngine = TranscriptionEngine(rawValue: userSelectedEngineRawValue),
           let userSelectedProvider = makeProvider(for: userSelectedEngine) {
            return userSelectedProvider
        }

        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
        let openAIProvider = OpenAIAudioTranscriptionProvider()

        if preferredProvider == .appleSpeech {
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .assemblyAI {
            if assemblyAIProvider.isConfigured {
                return assemblyAIProvider
            }

            print("⚠️ Transcription: AssemblyAI preferred but not configured, falling back")

            if openAIProvider.isConfigured {
                print("⚠️ Transcription: using OpenAI as fallback")
                return openAIProvider
            }

            print("⚠️ Transcription: using Apple Speech as fallback")
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .openAI {
            if openAIProvider.isConfigured {
                return openAIProvider
            }

            print("⚠️ Transcription: OpenAI preferred but not configured, falling back")

            if assemblyAIProvider.isConfigured {
                print("⚠️ Transcription: using AssemblyAI as fallback")
                return assemblyAIProvider
            }

            print("⚠️ Transcription: using Apple Speech as fallback")
            return AppleSpeechTranscriptionProvider()
        }

        if assemblyAIProvider.isConfigured {
            return assemblyAIProvider
        }

        if openAIProvider.isConfigured {
            return openAIProvider
        }

        return AppleSpeechTranscriptionProvider()
    }

    /// The provider for a user-selected engine, or nil if that engine isn't usable on this Mac
    /// (falls back to the Info.plist logic, which ends at Apple Speech).
    private static func makeProvider(for engine: TranscriptionEngine) -> (any BuddyTranscriptionProvider)? {
        switch engine {
        case .appleSpeech:
            return AppleSpeechTranscriptionProvider()
        case .appleSpeechAnalyzer:
            if #available(macOS 26.0, *) {
                return AppleSpeechAnalyzerTranscriptionProvider()
            }
            print("⚠️ Transcription: SpeechAnalyzer needs macOS 26, falling back")
            return nil
        case .whisperCpp:
            #if canImport(whisper)
            // whisper.cpp bundled as a library: no command-line tool needed.
            let bundledWhisperProvider = WhisperBundledTranscriptionProvider()
            if bundledWhisperProvider.isConfigured { return bundledWhisperProvider }
            #endif
            let whisperProvider = WhisperCppTranscriptionProvider()
            if whisperProvider.isConfigured { return whisperProvider }
            print("⚠️ Transcription: \(whisperProvider.unavailableExplanation ?? "Whisper not ready"), falling back")
            return nil
        case .assemblyAI:
            let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
            return assemblyAIProvider.isConfigured ? assemblyAIProvider : nil
        case .openAI:
            let openAIProvider = OpenAIAudioTranscriptionProvider()
            return openAIProvider.isConfigured ? openAIProvider : nil
        }
    }
}
