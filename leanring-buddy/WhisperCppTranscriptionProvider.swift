//
//  WhisperCppTranscriptionProvider.swift
//  leanring-buddy
//
//  Local Whisper transcription through whisper.cpp's `whisper-cli`
//  (brew install whisper-cpp). Push-to-talk audio is buffered as 16 kHz
//  mono PCM; on release it's written to a temporary WAV and transcribed
//  on-device with the selected ggml model. Nothing leaves the Mac.
//
//  Invocation (whisper.cpp CLI flags):
//    whisper-cli -m <model> -f <audio.wav> -l <en|auto> -t <threads>
//                -nt -np -otxt -of <output base> [--prompt <vocabulary>]
//  The transcript is read from <output base>.txt, falling back to stdout.
//

import AVFoundation
import Foundation

struct WhisperCppTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class WhisperCppTranscriptionProvider: BuddyTranscriptionProvider {
    private let executablePath = WhisperCppInstallation.findExecutablePath()
    private let modelURL = WhisperCppInstallation.selectedModelURL()

    var displayName: String {
        guard let modelURL else { return "Whisper (local)" }
        let modelName = modelURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
        return "Whisper \(modelName)"
    }

    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        executablePath != nil && modelURL != nil
    }

    var unavailableExplanation: String? {
        if executablePath == nil { return "whisper.cpp isn't installed. Run: brew install whisper-cpp" }
        if modelURL == nil { return "No Whisper model found. Download one in OpenClicky Settings → Transcription." }
        return nil
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let executablePath, let modelURL else {
            throw WhisperCppTranscriptionProviderError(message: unavailableExplanation ?? "Whisper isn't set up.")
        }

        return WhisperCppTranscriptionSession(
            executablePath: executablePath,
            modelURL: modelURL,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

/// nonisolated: audio arrives on the audio engine's thread and whisper-cli runs on a
/// background queue. All mutable state is guarded by `stateQueue`.
nonisolated private final class WhisperCppTranscriptionSession: BuddyStreamingTranscriptionSession, @unchecked Sendable {
    /// Local inference on a short clip is usually well under this.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 15.0

    private static let targetSampleRate = 16_000

    private let executablePath: String
    private let modelURL: URL
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.openclicky.whisper.transcription")
    private let audioConversionQueue = DispatchQueue(label: "com.openclicky.whisper.conversion")
    private var audioConverter: AVAudioConverter?
    private var audioConverterInputFormat: AVAudioFormat?
    private let targetAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(targetSampleRate),
        channels: 1,
        interleaved: true
    )!

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var runningWhisperProcess: Process?

    init(
        executablePath: String,
        modelURL: URL,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.executablePath = executablePath
        self.modelURL = modelURL
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioConversionQueue.sync(execute: { convertToPCM16MonoData(audioBuffer) }),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true
            let bufferedPCM16AudioData = self.bufferedPCM16AudioData

            // whisper-cli is a blocking process; run it off the state queue.
            DispatchQueue.global(qos: .userInitiated).async {
                self.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
            if let runningWhisperProcess = self.runningWhisperProcess, runningWhisperProcess.isRunning {
                runningWhisperProcess.terminate()
            }
        }
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) {
        // Under ~0.3s of audio there's nothing worth transcribing.
        let minimumAudioByteCount = Self.targetSampleRate * 2 * 3 / 10
        guard bufferedPCM16AudioData.count >= minimumAudioByteCount,
              !stateQueue.sync(execute: { isCancelled }) else {
            deliverFinalTranscript("")
            return
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-whisper-\(UUID().uuidString)", isDirectory: true)
        let wavFileURL = temporaryDirectory.appendingPathComponent("voice-input.wav")
        let outputBaseURL = temporaryDirectory.appendingPathComponent("transcript")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let wavAudioData = Self.makeWAVData(fromPCM16MonoAudio: bufferedPCM16AudioData, sampleRate: Self.targetSampleRate)
            try wavAudioData.write(to: wavFileURL)

            let transcriptText = try runWhisper(wavFileURL: wavFileURL, outputBaseURL: outputBaseURL)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }
            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("🎙️ whisper.cpp failed: \(error.localizedDescription)")
            onError(error)
        }
    }

    private func runWhisper(wavFileURL: URL, outputBaseURL: URL) throws -> String {
        let modelFileName = modelURL.deletingPathExtension().lastPathComponent
        let isEnglishOnlyModel = modelFileName.hasSuffix(".en") || modelFileName.contains(".en-")
        let threadCount = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))

        var whisperArguments = [
            "-m", modelURL.path,
            "-f", wavFileURL.path,
            "-l", isEnglishOnlyModel ? "en" : "auto",
            "-t", String(threadCount),
            "-nt",
            "-np",
            "-otxt",
            "-of", outputBaseURL.path
        ]

        // An initial prompt biases Whisper toward the user's vocabulary.
        let vocabularyKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(40)
        if !vocabularyKeyterms.isEmpty {
            whisperArguments += ["--prompt", vocabularyKeyterms.joined(separator: ", ") + "."]
        }

        let whisperProcess = Process()
        whisperProcess.executableURL = URL(fileURLWithPath: executablePath)
        whisperProcess.arguments = whisperArguments
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        whisperProcess.standardOutput = standardOutputPipe
        whisperProcess.standardError = standardErrorPipe

        stateQueue.sync { runningWhisperProcess = whisperProcess }
        defer { stateQueue.sync { runningWhisperProcess = nil } }

        let startTime = Date()
        try whisperProcess.run()

        // Drain both pipes so whisper-cli never blocks on a full buffer.
        let standardErrorReadHandle = standardErrorPipe.fileHandleForReading
        let standardErrorDataBox = WhisperDataBox()
        let standardErrorDrainGroup = DispatchGroup()
        standardErrorDrainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            standardErrorDataBox.data = standardErrorReadHandle.readDataToEndOfFile()
            standardErrorDrainGroup.leave()
        }
        let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        whisperProcess.waitUntilExit()
        standardErrorDrainGroup.wait()
        let standardErrorData = standardErrorDataBox.data

        guard whisperProcess.terminationStatus == 0 else {
            let errorText = String(data: standardErrorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw WhisperCppTranscriptionProviderError(
                message: "whisper-cli exited with status \(whisperProcess.terminationStatus). \(String(errorText.suffix(300)))"
            )
        }

        let transcriptFileURL = outputBaseURL.appendingPathExtension("txt")
        let rawTranscriptText = (try? String(contentsOf: transcriptFileURL, encoding: .utf8))
            ?? String(data: standardOutputData, encoding: .utf8)
            ?? ""

        let cleanedTranscriptText = Self.cleanWhisperOutput(rawTranscriptText)
        print("🎙️ whisper.cpp (\(modelFileName)) transcribed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
        return cleanedTranscriptText
    }

    /// Joins lines and drops Whisper's non-speech markers like [BLANK_AUDIO] or (music).
    private static func cleanWhisperOutput(_ rawTranscriptText: String) -> String {
        let joinedText = rawTranscriptText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let withoutMarkers = joinedText
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\((?:music|applause|laughter|silence|noise|inaudible)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return withoutMarkers.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Audio Helpers

    /// Converts a microphone buffer (any format) to 16 kHz mono Int16 PCM bytes.
    private func convertToPCM16MonoData(_ audioBuffer: AVAudioPCMBuffer) -> Data? {
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
        guard conversionError == nil, let int16ChannelData = outputBuffer.int16ChannelData else { return nil }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: int16ChannelData[0], count: byteCount)
    }

    /// Wraps raw 16-bit mono PCM in a standard 44-byte WAV header.
    private static func makeWAVData(fromPCM16MonoAudio pcmAudioData: Data, sampleRate: Int) -> Data {
        func littleEndianBytes<Value: FixedWidthInteger>(_ value: Value) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        let bitsPerSample: UInt16 = 16
        let channelCount: UInt16 = 1
        let byteRate = UInt32(sampleRate) * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)

        var wavData = Data()
        wavData.append(contentsOf: Array("RIFF".utf8))
        wavData.append(littleEndianBytes(UInt32(36 + pcmAudioData.count)))
        wavData.append(contentsOf: Array("WAVE".utf8))
        wavData.append(contentsOf: Array("fmt ".utf8))
        wavData.append(littleEndianBytes(UInt32(16)))
        wavData.append(littleEndianBytes(UInt16(1)))
        wavData.append(littleEndianBytes(channelCount))
        wavData.append(littleEndianBytes(UInt32(sampleRate)))
        wavData.append(littleEndianBytes(byteRate))
        wavData.append(littleEndianBytes(blockAlign))
        wavData.append(littleEndianBytes(bitsPerSample))
        wavData.append(contentsOf: Array("data".utf8))
        wavData.append(littleEndianBytes(UInt32(pcmAudioData.count)))
        wavData.append(pcmAudioData)
        return wavData
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        let shouldDeliver: Bool = stateQueue.sync {
            guard !hasDeliveredFinalTranscript else { return false }
            hasDeliveredFinalTranscript = true
            return true
        }
        if shouldDeliver {
            onFinalTranscriptReady(transcriptText)
        }
    }
}

/// Lets the stderr drain closure hand its data back without capturing a mutable local.
nonisolated private final class WhisperDataBox: @unchecked Sendable {
    var data = Data()
}
