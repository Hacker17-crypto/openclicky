//
//  AppleSpeechAnalyzerTranscriptionProvider.swift
//  leanring-buddy
//
//  Streaming on-device transcription with Apple's SpeechAnalyzer +
//  SpeechTranscriber (macOS 26+), the newer model that replaces
//  SFSpeechRecognizer for long-form and fast speech. The language model is
//  downloaded once through AssetInventory the first time it's used.
//
//  Flow: mic buffers → converted to the analyzer's preferred format →
//  AsyncStream<AnalyzerInput> → SpeechAnalyzer. Results stream back as
//  volatile (in-progress) and final segments; on key-up we finalize through
//  the end of input and deliver the accumulated final text.
//

import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class AppleSpeechAnalyzerTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Apple SpeechAnalyzer"
    let requiresSpeechRecognitionPermission = false
    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let transcriptionSession = AppleSpeechAnalyzerTranscriptionSession(
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
        try await transcriptionSession.start()
        return transcriptionSession
    }
}

@available(macOS 26.0, *)
nonisolated private final class AppleSpeechAnalyzerTranscriptionSession: BuddyStreamingTranscriptionSession, @unchecked Sendable {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 4.0

    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateLock = NSLock()
    private var finalizedTranscriptText = ""
    private var volatileTranscriptText = ""
    private var hasDeliveredFinalTranscript = false

    private var speechAnalyzer: SpeechAnalyzer?
    private var speechTranscriber: SpeechTranscriber?
    private var analyzerAudioFormat: AVAudioFormat?
    private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private let audioConversionQueue = DispatchQueue(label: "com.openclicky.speechanalyzer.conversion")
    private var audioConverter: AVAudioConverter?
    private var audioConverterInputFormat: AVAudioFormat?

    init(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func start() async throws {
        let transcriptionLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-US")

        let newSpeechTranscriber = SpeechTranscriber(
            locale: transcriptionLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        // Downloads the on-device language model the first time (no-op afterwards).
        if let assetInstallationRequest = try await AssetInventory.assetInstallationRequest(supporting: [newSpeechTranscriber]) {
            print("🎙️ SpeechAnalyzer: downloading the \(transcriptionLocale.identifier) speech model...")
            try await assetInstallationRequest.downloadAndInstall()
        }

        let newSpeechAnalyzer = SpeechAnalyzer(modules: [newSpeechTranscriber])
        let preferredAudioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [newSpeechTranscriber])

        let (analyzerInputStream, analyzerInputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        stateLock.withLock {
            speechTranscriber = newSpeechTranscriber
            speechAnalyzer = newSpeechAnalyzer
            analyzerAudioFormat = preferredAudioFormat
            self.analyzerInputContinuation = analyzerInputContinuation
        }

        resultsTask = Task { [weak self] in
            do {
                for try await transcriptionResult in newSpeechTranscriber.results {
                    guard let self else { return }
                    let segmentText = String(transcriptionResult.text.characters)
                    let combinedText: String = self.stateLock.withLock {
                        if transcriptionResult.isFinal {
                            self.finalizedTranscriptText = Self.joinTranscriptSegments(self.finalizedTranscriptText, segmentText)
                            self.volatileTranscriptText = ""
                        } else {
                            self.volatileTranscriptText = segmentText
                        }
                        return Self.joinTranscriptSegments(self.finalizedTranscriptText, self.volatileTranscriptText)
                    }
                    self.onTranscriptUpdate(combinedText)
                }
            } catch {
                guard let self else { return }
                if !(error is CancellationError) {
                    self.onError(error)
                }
            }
        }

        try await newSpeechAnalyzer.start(inputSequence: analyzerInputStream)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        let (targetAudioFormat, analyzerInputContinuation) = stateLock.withLock {
            (analyzerAudioFormat, self.analyzerInputContinuation)
        }
        guard let targetAudioFormat, let analyzerInputContinuation else { return }

        let convertedAudioBuffer = audioConversionQueue.sync {
            convertAudioBuffer(audioBuffer, to: targetAudioFormat)
        }
        if let convertedAudioBuffer {
            analyzerInputContinuation.yield(AnalyzerInput(buffer: convertedAudioBuffer))
        }
    }

    func requestFinalTranscript() {
        let (activeSpeechAnalyzer, analyzerInputContinuation) = stateLock.withLock {
            (speechAnalyzer, self.analyzerInputContinuation)
        }
        analyzerInputContinuation?.finish()

        Task { [weak self] in
            do {
                try await activeSpeechAnalyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                print("🎙️ SpeechAnalyzer finalize error: \(error)")
            }
            await self?.resultsTask?.value
            guard let self else { return }
            let finalText = self.stateLock.withLock {
                Self.joinTranscriptSegments(self.finalizedTranscriptText, self.volatileTranscriptText)
            }
            self.deliverFinalTranscript(finalText)
        }
    }

    func cancel() {
        let (activeSpeechAnalyzer, analyzerInputContinuation) = stateLock.withLock {
            (speechAnalyzer, self.analyzerInputContinuation)
        }
        analyzerInputContinuation?.finish()
        resultsTask?.cancel()
        Task {
            await activeSpeechAnalyzer?.cancelAndFinishNow()
        }
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        let shouldDeliver: Bool = stateLock.withLock {
            guard !hasDeliveredFinalTranscript else { return false }
            hasDeliveredFinalTranscript = true
            return true
        }
        if shouldDeliver {
            onFinalTranscriptReady(transcriptText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func joinTranscriptSegments(_ firstSegment: String, _ secondSegment: String) -> String {
        let trimmedFirstSegment = firstSegment.trimmingCharacters(in: .whitespaces)
        let trimmedSecondSegment = secondSegment.trimmingCharacters(in: .whitespaces)
        if trimmedFirstSegment.isEmpty { return trimmedSecondSegment }
        if trimmedSecondSegment.isEmpty { return trimmedFirstSegment }
        return trimmedFirstSegment + " " + trimmedSecondSegment
    }

    /// Converts mic audio into the format SpeechAnalyzer asked for.
    private func convertAudioBuffer(_ audioBuffer: AVAudioPCMBuffer, to targetAudioFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if audioBuffer.format == targetAudioFormat {
            return audioBuffer
        }

        if audioConverterInputFormat != audioBuffer.format {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: targetAudioFormat)
            audioConverterInputFormat = audioBuffer.format
        }
        guard let audioConverter else { return nil }

        let sampleRateRatio = targetAudioFormat.sampleRate / audioBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount((Double(audioBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetAudioFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }

        var hasProvidedInput = false
        var conversionError: NSError?
        audioConverter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if hasProvidedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            inputStatus.pointee = .haveData
            return audioBuffer
        }
        return conversionError == nil ? outputBuffer : nil
    }
}
