//
//  WhisperBundledTranscriptionProvider.swift
//  leanring-buddy
//
//  Whisper transcription running inside OpenClicky through the whisper.cpp
//  library (no Homebrew, no command-line tool). Loads any ggml Whisper
//  model found on disk, including ones downloaded by Superwhisper,
//  MacWhisper or VoiceInk, and runs it on the GPU via Metal.
//
//  Only compiled when the `whisper` module is available, i.e. when the
//  WhisperFramework Swift package (official whisper.cpp XCFramework) is
//  added to the project. Without it, OpenClicky falls back to `whisper-cli`
//  (WhisperCppTranscriptionProvider).
//

#if canImport(whisper)
import AVFoundation
import Foundation
import whisper

/// Keeps one model loaded between presses; loading a large model takes a second or two.
/// whisper_full isn't thread-safe for a single context, so all inference runs on one queue.
nonisolated final class WhisperBundledModelCache: @unchecked Sendable {
    static let shared = WhisperBundledModelCache()

    let inferenceQueue = DispatchQueue(label: "com.openclicky.whisper.inference", qos: .userInitiated)

    private var loadedModelPath: String?
    private var loadedContext: OpaquePointer?

    private init() {
        // whisper.cpp logs every layer it loads; keep the console readable.
        whisper_log_set({ _, _, _ in }, nil)
    }

    /// Must be called on `inferenceQueue`.
    func context(forModelAt modelURL: URL) -> OpaquePointer? {
        if loadedModelPath == modelURL.path, let loadedContext {
            return loadedContext
        }
        if let loadedContext {
            whisper_free(loadedContext)
            self.loadedContext = nil
            loadedModelPath = nil
        }

        var contextParameters = whisper_context_default_params()
        contextParameters.use_gpu = true
        contextParameters.flash_attn = true

        let loadStartTime = Date()
        guard let newContext = whisper_init_from_file_with_params(modelURL.path, contextParameters) else {
            print("🎙️ whisper.cpp couldn't load \(modelURL.lastPathComponent)")
            return nil
        }
        print("🎙️ whisper.cpp loaded \(modelURL.lastPathComponent) in \(String(format: "%.1f", Date().timeIntervalSince(loadStartTime)))s")
        loadedContext = newContext
        loadedModelPath = modelURL.path
        return newContext
    }

    /// Loads the model in the background so the first press is fast.
    func preloadModel(at modelURL: URL) {
        inferenceQueue.async {
            _ = self.context(forModelAt: modelURL)
        }
    }
}

final class WhisperBundledTranscriptionProvider: BuddyTranscriptionProvider {
    private let selectedModel: WhisperInstalledModel?

    init() {
        if let selectedModelURL = WhisperCppInstallation.selectedModelURL() {
            selectedModel = WhisperModelFileInspector.inspectModel(at: selectedModelURL, sourceName: "")
        } else {
            selectedModel = nil
        }
        if let selectedModel {
            WhisperBundledModelCache.shared.preloadModel(at: selectedModel.fileURL)
        }
    }

    var displayName: String {
        selectedModel.map { "Whisper \($0.displayName)" } ?? "Whisper (local)"
    }

    let requiresSpeechRecognitionPermission = false
    var isConfigured: Bool { selectedModel != nil }
    var unavailableExplanation: String? {
        isConfigured ? nil : "No Whisper model selected. Pick or download one in OpenClicky Settings → Transcription."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let selectedModel else {
            throw WhisperCppTranscriptionProviderError(message: unavailableExplanation ?? "Whisper isn't set up.")
        }
        return WhisperBundledTranscriptionSession(
            model: selectedModel,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

nonisolated private final class WhisperBundledTranscriptionSession: BuddyStreamingTranscriptionSession, @unchecked Sendable {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 15.0

    private let model: WhisperInstalledModel
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateLock = NSLock()
    private var bufferedSamples: [Float] = []
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false

    private let audioConversionQueue = DispatchQueue(label: "com.openclicky.whisper.bundled.conversion")
    private var audioConverter: AVAudioConverter?
    private var audioConverterInputFormat: AVAudioFormat?
    private let whisperAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    init(
        model: WhisperInstalledModel,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.model = model
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let convertedSamples = audioConversionQueue.sync(execute: { convertToWhisperSamples(audioBuffer) }),
              !convertedSamples.isEmpty else { return }
        stateLock.withLock {
            guard !hasRequestedFinalTranscript, !isCancelled else { return }
            bufferedSamples.append(contentsOf: convertedSamples)
        }
    }

    func requestFinalTranscript() {
        let samplesToTranscribe: [Float]? = stateLock.withLock {
            guard !hasRequestedFinalTranscript, !isCancelled else { return nil }
            hasRequestedFinalTranscript = true
            return bufferedSamples
        }
        guard let samplesToTranscribe else { return }

        WhisperBundledModelCache.shared.inferenceQueue.async {
            self.transcribe(samplesToTranscribe)
        }
    }

    func cancel() {
        stateLock.withLock {
            isCancelled = true
            bufferedSamples.removeAll(keepingCapacity: false)
        }
    }

    /// Runs on the model cache's inference queue.
    private func transcribe(_ samples: [Float]) {
        // Under ~0.3 s there's no speech worth decoding (and Whisper tends to hallucinate on silence).
        guard samples.count >= 4_800, !stateLock.withLock({ isCancelled }) else {
            deliverFinalTranscript("")
            return
        }

        guard let whisperContext = WhisperBundledModelCache.shared.context(forModelAt: model.fileURL) else {
            onError(WhisperCppTranscriptionProviderError(message: "Couldn't load the Whisper model at \(model.fileURL.path)."))
            return
        }

        var fullParameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        fullParameters.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        fullParameters.print_progress = false
        fullParameters.print_realtime = false
        fullParameters.print_timestamps = false
        fullParameters.print_special = false
        fullParameters.no_timestamps = true
        fullParameters.translate = false
        fullParameters.no_context = true
        fullParameters.suppress_blank = true

        let languageCode = model.isEnglishOnly ? "en" : "auto"
        let vocabularyPrompt = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(40)
            .joined(separator: ", ")

        let inferenceStartTime = Date()
        let whisperResultCode: Int32 = languageCode.withCString { languagePointer in
            vocabularyPrompt.withCString { vocabularyPromptPointer in
                fullParameters.language = languagePointer
                fullParameters.initial_prompt = vocabularyPrompt.isEmpty ? nil : vocabularyPromptPointer
                return samples.withUnsafeBufferPointer { sampleBuffer in
                    whisper_full(whisperContext, fullParameters, sampleBuffer.baseAddress, Int32(sampleBuffer.count))
                }
            }
        }

        guard !stateLock.withLock({ isCancelled }) else { return }
        guard whisperResultCode == 0 else {
            onError(WhisperCppTranscriptionProviderError(message: "whisper.cpp failed (code \(whisperResultCode))."))
            return
        }

        var transcriptText = ""
        let segmentCount = whisper_full_n_segments(whisperContext)
        for segmentIndex in 0..<segmentCount {
            if let segmentTextPointer = whisper_full_get_segment_text(whisperContext, segmentIndex) {
                transcriptText += String(cString: segmentTextPointer)
            }
        }

        let cleanedTranscriptText = transcriptText
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\((?:music|applause|laughter|silence|noise|inaudible)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("🎙️ whisper.cpp (\(model.displayName)) transcribed \(String(format: "%.1f", Double(samples.count) / 16_000))s of audio in \(String(format: "%.2f", Date().timeIntervalSince(inferenceStartTime)))s")

        if !cleanedTranscriptText.isEmpty {
            onTranscriptUpdate(cleanedTranscriptText)
        }
        deliverFinalTranscript(cleanedTranscriptText)
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        let shouldDeliver: Bool = stateLock.withLock {
            guard !hasDeliveredFinalTranscript else { return false }
            hasDeliveredFinalTranscript = true
            return true
        }
        if shouldDeliver {
            onFinalTranscriptReady(transcriptText)
        }
    }

    /// Microphone buffer (any format) → 16 kHz mono Float32 samples, which whisper.cpp expects.
    private func convertToWhisperSamples(_ audioBuffer: AVAudioPCMBuffer) -> [Float]? {
        if audioConverterInputFormat != audioBuffer.format {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: whisperAudioFormat)
            audioConverterInputFormat = audioBuffer.format
        }
        guard let audioConverter else { return nil }

        let sampleRateRatio = whisperAudioFormat.sampleRate / audioBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount((Double(audioBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: whisperAudioFormat, frameCapacity: outputFrameCapacity) else {
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
        guard conversionError == nil, let floatChannelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: floatChannelData[0], count: Int(outputBuffer.frameLength)))
    }
}
#endif
