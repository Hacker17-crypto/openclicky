//
//  TranscriptionEngineCatalog.swift
//  leanring-buddy
//
//  Which speech-to-text engines this Mac can use, and which one the user
//  picked. OpenClicky checks for local engines and lets the user choose:
//
//    - Apple Speech           built in, on-device, works everywhere
//    - Apple SpeechAnalyzer   Apple's newer on-device model (macOS 26+)
//    - Whisper (whisper.cpp)  if `whisper-cli` is installed (brew install
//                             whisper-cpp); uses ggml models found on disk
//                             or downloaded here
//    - AssemblyAI / OpenAI    cloud, only if the user added their own key
//
//  The choice is stored in UserDefaults and read by
//  BuddyTranscriptionProviderFactory.
//

import AppKit
import Combine
import Foundation
import Speech

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case appleSpeech = "apple"
    case appleSpeechAnalyzer = "apple-analyzer"
    case whisperCpp = "whisper"
    case assemblyAI = "assemblyai"
    case openAI = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .appleSpeechAnalyzer: return "Apple SpeechAnalyzer"
        case .whisperCpp: return "Whisper (whisper.cpp)"
        case .assemblyAI: return "AssemblyAI (cloud)"
        case .openAI: return "OpenAI (cloud)"
        }
    }

    var summary: String {
        switch self {
        case .appleSpeech:
            return "Built into macOS and runs on-device. Works on every Mac, no setup."
        case .appleSpeechAnalyzer:
            return "Apple's newest on-device speech model. More accurate, especially for long or fast speech. Downloads its language model once."
        case .whisperCpp:
            return "OpenAI's Whisper running locally through whisper.cpp. Very accurate, many languages, fully offline."
        case .assemblyAI:
            return "Real-time cloud transcription with your own AssemblyAI key."
        case .openAI:
            return "Cloud transcription with your own OpenAI key."
        }
    }

    var isLocal: Bool {
        switch self {
        case .appleSpeech, .appleSpeechAnalyzer, .whisperCpp: return true
        case .assemblyAI, .openAI: return false
        }
    }
}

/// A downloadable whisper.cpp model.
nonisolated struct WhisperDownloadableModel: Identifiable {
    let fileName: String
    let title: String
    let approximateSizeText: String
    let detail: String

    var id: String { fileName }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }
}

/// A Whisper model in whisper.cpp's ggml format, found anywhere on disk.
/// Identified by its file header, not its name, so models that other apps
/// (Superwhisper, MacWhisper, VoiceInk...) store under their own names are found too.
nonisolated struct WhisperInstalledModel: Identifiable, Hashable {
    let fileURL: URL
    let sizeInBytes: Int64
    /// Which app or tool the model came from ("Superwhisper", "Hugging Face cache"...).
    let sourceName: String
    let audioLayerCount: Int
    let textLayerCount: Int
    let vocabularySize: Int
    let melBandCount: Int
    let quantizationName: String

    var id: String { fileURL.path }

    /// English-only Whisper checkpoints have a 51864-token vocabulary; multilingual ones 51865+.
    var isEnglishOnly: Bool { vocabularySize == 51864 }

    var sizeName: String {
        switch audioLayerCount {
        case 4: return "Tiny"
        case 6: return "Base"
        case 12: return "Small"
        case 24: return "Medium"
        case 32:
            if textLayerCount <= 4 { return "Large v3 Turbo" }
            return melBandCount == 128 ? "Large v3" : "Large v2"
        default: return "Whisper"
        }
    }

    var displayName: String {
        var nameParts = [sizeName + (isEnglishOnly ? " (English)" : "")]
        if quantizationName != "f16" && quantizationName != "f32" {
            nameParts.append(quantizationName)
        }
        return nameParts.joined(separator: " ")
    }

    /// Rough accuracy ranking used to pick a default: bigger encoder first, then unquantized.
    var qualityRank: Int {
        audioLayerCount * 10 + (quantizationName == "f16" || quantizationName == "f32" ? 2 : 0) + (textLayerCount > 4 ? 1 : 0)
    }
}

/// A speech model found on disk in a format whisper.cpp can't load (shown for transparency).
nonisolated struct IncompatibleSpeechModelFinding: Identifiable, Hashable {
    let name: String
    let sourceName: String
    let formatName: String
    var id: String { "\(sourceName)/\(name)/\(formatName)" }
}

/// Reads the 48-byte whisper.cpp ggml header: magic "ggml" (little-endian 0x67676d6c)
/// followed by n_vocab, n_audio_ctx, n_audio_state, n_audio_head, n_audio_layer,
/// n_text_ctx, n_text_state, n_text_head, n_text_layer, n_mels, ftype (int32 each).
nonisolated enum WhisperModelFileInspector {
    static func inspectModel(at fileURL: URL, sourceName: String) -> WhisperInstalledModel? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fileHandle.close() }
        guard let headerData = try? fileHandle.read(upToCount: 48), headerData.count == 48 else { return nil }

        let headerBytes = [UInt8](headerData)
        guard headerBytes[0] == 0x6c, headerBytes[1] == 0x6d, headerBytes[2] == 0x67, headerBytes[3] == 0x67 else {
            return nil
        }

        func headerInteger(at fieldIndex: Int) -> Int {
            let byteOffset = 4 + fieldIndex * 4
            let littleEndianValue = UInt32(headerBytes[byteOffset])
                | UInt32(headerBytes[byteOffset + 1]) << 8
                | UInt32(headerBytes[byteOffset + 2]) << 16
                | UInt32(headerBytes[byteOffset + 3]) << 24
            return Int(Int32(bitPattern: littleEndianValue))
        }

        let vocabularySize = headerInteger(at: 0)
        let audioLayerCount = headerInteger(at: 4)
        let textLayerCount = headerInteger(at: 8)
        let melBandCount = headerInteger(at: 9)
        // ftype may carry the quantization version × 1000 (e.g. 2008 = q5_0).
        let fileType = headerInteger(at: 10) % 1000

        // Sanity check so random files that happen to start with "lmgg" are ignored.
        guard (51000...52000).contains(vocabularySize), (1...64).contains(audioLayerCount) else { return nil }

        let quantizationNames: [Int: String] = [0: "f32", 1: "f16", 2: "q4_0", 3: "q4_1", 7: "q8_0", 8: "q5_0", 9: "q5_1", 10: "q2_k", 11: "q3_k", 12: "q4_k", 13: "q5_k", 14: "q6_k"]
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0

        return WhisperInstalledModel(
            fileURL: fileURL,
            sizeInBytes: fileSize,
            sourceName: sourceName,
            audioLayerCount: audioLayerCount,
            textLayerCount: textLayerCount,
            vocabularySize: vocabularySize,
            melBandCount: melBandCount,
            quantizationName: quantizationNames[fileType] ?? "q\(fileType)"
        )
    }
}

// MARK: - whisper.cpp Discovery

/// Only touches FileManager and UserDefaults (both thread-safe), so it's usable
/// from any thread, including the transcription provider and background scans.
nonisolated enum WhisperCppInstallation {
    static let selectedModelPathDefaultsKey = "selectedWhisperModelPath"
    private static let cachedExecutablePathDefaultsKey = "whisperCppExecutablePath"

    /// Homebrew installs `whisper-cli` (older formulae used `whisper-cpp`).
    private static let executableNames = ["whisper-cli", "whisper-cpp"]

    static var openClickyModelsDirectory: URL {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return applicationSupportDirectory
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("whisper-models", isDirectory: true)
    }

    /// Where speech apps and tools keep their models, labeled by source.
    /// (Folders inside ~/Documents or other apps' containers may trigger a one-time macOS permission prompt.)
    static var modelSearchLocations: [(directory: URL, sourceName: String)] {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let applicationSupport = homeDirectory.appendingPathComponent("Library/Application Support")
        let containers = homeDirectory.appendingPathComponent("Library/Containers")
        func home(_ relativePath: String) -> URL { homeDirectory.appendingPathComponent(relativePath) }

        return [
            (openClickyModelsDirectory, "OpenClicky"),
            // Superwhisper (current default is ~/superwhisper; older installs used Documents)
            (home("superwhisper"), "Superwhisper"),
            (home("Documents/superwhisper"), "Superwhisper"),
            (applicationSupport.appendingPathComponent("superwhisper"), "Superwhisper"),
            (applicationSupport.appendingPathComponent("com.superduper.superwhisper"), "Superwhisper"),
            (containers.appendingPathComponent("com.superduper.superwhisper"), "Superwhisper"),
            (URL(fileURLWithPath: "/Applications/superwhisper.app/Contents/Resources"), "Superwhisper"),
            // Other dictation / transcription apps
            (applicationSupport.appendingPathComponent("MacWhisper"), "MacWhisper"),
            (containers.appendingPathComponent("com.goodsnooze.MacWhisper"), "MacWhisper"),
            (applicationSupport.appendingPathComponent("com.prakashjoshipax.VoiceInk"), "VoiceInk"),
            (home("Library/Caches/Buzz"), "Buzz"),
            (applicationSupport.appendingPathComponent("Buzz"), "Buzz"),
            (applicationSupport.appendingPathComponent("Meetily"), "Meetily"),
            (home(".voicemode/models"), "VoiceMode"),
            // whisper.cpp itself and common download spots
            (home(".cache/whisper"), "whisper.cpp"),
            (home("whisper.cpp/models"), "whisper.cpp"),
            (home("models"), "Downloads"),
            (home("Downloads"), "Downloads"),
            (URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp"), "Homebrew"),
            (URL(fileURLWithPath: "/usr/local/share/whisper-cpp"), "Homebrew"),
            (home(".cache/huggingface/hub"), "Hugging Face cache")
        ]
    }

    /// Finds whisper-cli in well-known locations (or the path cached by the last full scan).
    static func findExecutablePath() -> String? {
        if let cachedExecutablePath = UserDefaults.standard.string(forKey: cachedExecutablePathDefaultsKey),
           FileManager.default.isExecutableFile(atPath: cachedExecutablePath) {
            return cachedExecutablePath
        }

        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let binaryDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "\(homeDirectoryPath)/.local/bin", "\(homeDirectoryPath)/whisper.cpp/build/bin"]
        for binaryDirectory in binaryDirectories {
            for executableName in executableNames {
                let candidatePath = "\(binaryDirectory)/\(executableName)"
                if FileManager.default.isExecutableFile(atPath: candidatePath) {
                    return candidatePath
                }
            }
        }
        return nil
    }

    /// Slower lookup that also asks the user's login shell. Run off the main thread.
    static func findExecutablePathIncludingLoginShell() -> String? {
        if let quickPath = findExecutablePath() {
            return quickPath
        }
        for executableName in executableNames {
            if let shellPath = ClaudeCodeCLIClient.runLoginShellCommand("command -v \(executableName)"),
               shellPath.hasPrefix("/"),
               FileManager.default.isExecutableFile(atPath: shellPath) {
                UserDefaults.standard.set(shellPath, forKey: cachedExecutablePathDefaultsKey)
                return shellPath
            }
        }
        return nil
    }

    /// Scans every known location (plus Spotlight) for Whisper models. Run off the main thread.
    static func findInstalledModels() -> (whisperModels: [WhisperInstalledModel], incompatibleModels: [IncompatibleSpeechModelFinding]) {
        var whisperModels: [WhisperInstalledModel] = []
        var incompatibleModels: [IncompatibleSpeechModelFinding] = []
        var seenResolvedPaths = Set<String>()

        func considerFile(_ fileURL: URL, sourceName: String) {
            let resolvedPath = fileURL.resolvingSymlinksInPath().path
            guard seenResolvedPaths.insert(resolvedPath).inserted else { return }
            if let inspectedModel = WhisperModelFileInspector.inspectModel(at: fileURL, sourceName: sourceName) {
                whisperModels.append(inspectedModel)
            }
        }

        for searchLocation in modelSearchLocations {
            scanDirectory(
                searchLocation.directory,
                sourceName: searchLocation.sourceName,
                considerFile: considerFile,
                recordIncompatibleModel: { incompatibleModels.append($0) }
            )
        }

        // Spotlight catches models in places we didn't think of.
        for spotlightResultPath in findCandidateModelPathsWithSpotlight() {
            considerFile(URL(fileURLWithPath: spotlightResultPath), sourceName: guessSourceName(forPath: spotlightResultPath))
        }

        let uniqueIncompatibleModels = Array(Set(incompatibleModels)).sorted { $0.id < $1.id }
        return (whisperModels.sorted { $0.qualityRank > $1.qualityRank }, uniqueIncompatibleModels)
    }

    private static func scanDirectory(
        _ rootDirectory: URL,
        sourceName: String,
        considerFile: (URL, String) -> Void,
        recordIncompatibleModel: (IncompatibleSpeechModelFinding) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: rootDirectory.path),
              let directoryEnumerator = FileManager.default.enumerator(
                at: rootDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
              ) else {
            return
        }

        let isDownloadsFolder = rootDirectory.lastPathComponent == "Downloads"
        var visitedEntryCount = 0

        for case let entryURL as URL in directoryEnumerator {
            visitedEntryCount += 1
            // Keep scans quick even in huge folders.
            if visitedEntryCount > 20_000 { break }
            if directoryEnumerator.level > (isDownloadsFolder ? 2 : 7) {
                directoryEnumerator.skipDescendants()
                continue
            }

            let entryName = entryURL.lastPathComponent
            let resourceValues = try? entryURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])

            if resourceValues?.isDirectory == true {
                // Core ML models (WhisperKit / Superwhisper's Apple-silicon builds) are folders of .mlmodelc bundles.
                if entryName == "AudioEncoder.mlmodelc" || entryName.hasSuffix("-encoder.mlmodelc") {
                    let modelFolderName = entryURL.deletingLastPathComponent().lastPathComponent
                    // whisper.cpp's own "-encoder.mlmodelc" sits next to a ggml file and is fine to ignore.
                    if entryName == "AudioEncoder.mlmodelc" {
                        recordIncompatibleModel(IncompatibleSpeechModelFinding(name: modelFolderName, sourceName: sourceName, formatName: "Core ML (WhisperKit)"))
                    }
                    directoryEnumerator.skipDescendants()
                } else if entryName.lowercased().contains("parakeet") {
                    recordIncompatibleModel(IncompatibleSpeechModelFinding(name: entryName, sourceName: sourceName, formatName: "Parakeet"))
                }
                continue
            }

            let fileSize = resourceValues?.fileSize ?? 0
            // Whisper models are at least ~30 MB (tiny is 75 MB unquantized, ~31 MB at q5).
            guard fileSize > 25_000_000 else { continue }

            let lowercasedName = entryName.lowercased()
            if lowercasedName.hasSuffix(".onnx") || lowercasedName.hasSuffix(".nemo") {
                if lowercasedName.contains("whisper") || lowercasedName.contains("parakeet") || lowercasedName.contains("encoder") {
                    recordIncompatibleModel(IncompatibleSpeechModelFinding(name: entryName, sourceName: sourceName, formatName: lowercasedName.hasSuffix(".nemo") ? "NeMo" : "ONNX"))
                }
                continue
            }
            if lowercasedName.hasSuffix(".gguf") || lowercasedName.hasSuffix(".safetensors") || lowercasedName.hasSuffix(".npz") {
                if lowercasedName.contains("whisper") {
                    recordIncompatibleModel(IncompatibleSpeechModelFinding(name: entryName, sourceName: sourceName, formatName: "MLX / safetensors"))
                }
                continue
            }

            // Anything else big enough gets a cheap 48-byte header check.
            considerFile(entryURL, sourceName)
        }
    }

    /// Asks Spotlight for large files that look like ggml models. Returns paths only; headers are checked after.
    private static func findCandidateModelPathsWithSpotlight() -> [String] {
        let spotlightProcess = Process()
        spotlightProcess.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        spotlightProcess.arguments = ["kMDItemFSSize > 25000000 && (kMDItemFSName == '*ggml*'c || kMDItemFSName == '*whisper*.bin'c || kMDItemFSName == '*.bin'c)"]
        let standardOutputPipe = Pipe()
        spotlightProcess.standardOutput = standardOutputPipe
        spotlightProcess.standardError = FileHandle.nullDevice

        let processFinishedSemaphore = DispatchSemaphore(value: 0)
        spotlightProcess.terminationHandler = { _ in processFinishedSemaphore.signal() }
        do {
            try spotlightProcess.run()
        } catch {
            return []
        }

        let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        if processFinishedSemaphore.wait(timeout: .now() + 5) == .timedOut {
            spotlightProcess.terminate()
        }

        let outputText = String(data: standardOutputData, encoding: .utf8) ?? ""
        return outputText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .prefix(200)
            .map { $0 }
    }

    private static func guessSourceName(forPath filePath: String) -> String {
        let lowercasedPath = filePath.lowercased()
        let knownSources: [(pathFragment: String, sourceName: String)] = [
            ("superwhisper", "Superwhisper"), ("macwhisper", "MacWhisper"), ("voiceink", "VoiceInk"),
            ("buzz", "Buzz"), ("huggingface", "Hugging Face cache"), ("whisper.cpp", "whisper.cpp"),
            ("homebrew", "Homebrew"), ("/downloads/", "Downloads"), ("openclicky", "OpenClicky")
        ]
        return knownSources.first { lowercasedPath.contains($0.pathFragment) }?.sourceName ?? "Found by Spotlight"
    }

    /// The model the user picked (if it still exists).
    static func selectedModelURL() -> URL? {
        guard let selectedModelPath = UserDefaults.standard.string(forKey: selectedModelPathDefaultsKey),
              FileManager.default.fileExists(atPath: selectedModelPath) else {
            return nil
        }
        return URL(fileURLWithPath: selectedModelPath)
    }
}

// MARK: - Catalog (observable, for the chooser UI)

@MainActor
final class TranscriptionEngineCatalog: ObservableObject {
    static let shared = TranscriptionEngineCatalog()

    static let selectedEngineDefaultsKey = "selectedTranscriptionEngine"
    static let hasChosenEngineDefaultsKey = "hasChosenTranscriptionEngine"

    @Published private(set) var whisperExecutablePath: String?
    @Published private(set) var installedWhisperModels: [WhisperInstalledModel] = []
    /// Speech models found in formats whisper.cpp can't load (e.g. Core ML from Superwhisper).
    @Published private(set) var incompatibleSpeechModels: [IncompatibleSpeechModelFinding] = []
    @Published private(set) var isScanning = false
    @Published private(set) var downloadingModelFileName: String?
    @Published private(set) var downloadProgressFraction: Double = 0
    @Published var downloadErrorMessage: String?

    @Published var selectedEngine: TranscriptionEngine {
        didSet { UserDefaults.standard.set(selectedEngine.rawValue, forKey: Self.selectedEngineDefaultsKey) }
    }

    @Published var selectedWhisperModelPath: String? {
        didSet { UserDefaults.standard.set(selectedWhisperModelPath, forKey: WhisperCppInstallation.selectedModelPathDefaultsKey) }
    }

    let downloadableWhisperModels: [WhisperDownloadableModel] = [
        WhisperDownloadableModel(fileName: "ggml-base.en.bin", title: "Base (English)", approximateSizeText: "148 MB", detail: "Fast, good for short commands"),
        WhisperDownloadableModel(fileName: "ggml-small.en.bin", title: "Small (English)", approximateSizeText: "488 MB", detail: "More accurate, still quick on Apple silicon"),
        WhisperDownloadableModel(fileName: "ggml-large-v3-turbo-q5_0.bin", title: "Large v3 Turbo", approximateSizeText: "574 MB", detail: "Most accurate, 99 languages")
    ]

    private var activeDownloadTask: URLSessionDownloadTask?
    private var downloadProgressTimer: Timer?

    private init() {
        let storedEngine = UserDefaults.standard.string(forKey: Self.selectedEngineDefaultsKey).flatMap(TranscriptionEngine.init(rawValue:))
        selectedEngine = storedEngine ?? .appleSpeech
        selectedWhisperModelPath = UserDefaults.standard.string(forKey: WhisperCppInstallation.selectedModelPathDefaultsKey)
    }

    var hasUserChosenEngine: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasChosenEngineDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasChosenEngineDefaultsKey) }
    }

    /// SpeechAnalyzer ships with macOS 26.
    var isSpeechAnalyzerAvailable: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    /// True when whisper.cpp is linked into the app (WhisperFramework package), so models
    /// run without Homebrew's whisper-cli.
    var isWhisperBundledInApp: Bool {
        #if canImport(whisper)
        return true
        #else
        return false
        #endif
    }

    /// Whisper can run either in-app or through whisper-cli.
    var canRunWhisper: Bool { isWhisperBundledInApp || whisperExecutablePath != nil }

    var hasAssemblyAIKey: Bool { AppBundleConfiguration.stringValue(forKey: "AssemblyAIAPIKey") != nil }
    var hasOpenAIKey: Bool { AppBundleConfiguration.stringValue(forKey: "OpenAIAPIKey") != nil }

    func isEngineReady(_ engine: TranscriptionEngine) -> Bool {
        switch engine {
        case .appleSpeech: return true
        case .appleSpeechAnalyzer: return isSpeechAnalyzerAvailable
        case .whisperCpp: return canRunWhisper && !installedWhisperModels.isEmpty
        case .assemblyAI: return hasAssemblyAIKey
        case .openAI: return hasOpenAIKey
        }
    }

    /// Best local option on this Mac, shown with a "Recommended" badge.
    var recommendedEngine: TranscriptionEngine {
        if isEngineReady(.whisperCpp) { return .whisperCpp }
        if isSpeechAnalyzerAvailable { return .appleSpeechAnalyzer }
        return .appleSpeech
    }

    func statusText(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .appleSpeech:
            return "Ready"
        case .appleSpeechAnalyzer:
            return isSpeechAnalyzerAvailable ? "Ready" : "Needs macOS 26 or later"
        case .whisperCpp:
            if !canRunWhisper {
                return installedWhisperModels.isEmpty
                    ? "whisper.cpp not installed"
                    : "Found \(installedWhisperModels.count) model(s); needs whisper.cpp to run them"
            }
            if installedWhisperModels.isEmpty { return "Ready to run, needs a model" }
            return installedWhisperModels.count == 1 ? "Ready, 1 model found" : "Ready, \(installedWhisperModels.count) models found"
        case .assemblyAI:
            return hasAssemblyAIKey ? "Key found" : "Add AssemblyAIAPIKey to Info.plist"
        case .openAI:
            return hasOpenAIKey ? "Key found" : "Add OpenAIAPIKey to Info.plist"
        }
    }

    // MARK: Scanning

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let discoveredExecutablePath = await Task.detached(priority: .utility) {
                WhisperCppInstallation.findExecutablePathIncludingLoginShell()
            }.value
            let (discoveredWhisperModels, discoveredIncompatibleModels) = await Task.detached(priority: .utility) {
                WhisperCppInstallation.findInstalledModels()
            }.value
            whisperExecutablePath = discoveredExecutablePath
            installedWhisperModels = discoveredWhisperModels
            incompatibleSpeechModels = discoveredIncompatibleModels
            print("🎙️ Found \(discoveredWhisperModels.count) Whisper model(s): \(discoveredWhisperModels.map { "\($0.displayName) [\($0.sourceName)]" }.joined(separator: ", "))")
            if selectedWhisperModelPath == nil || !installedWhisperModels.contains(where: { $0.fileURL.path == selectedWhisperModelPath }) {
                selectedWhisperModelPath = installedWhisperModels.first?.fileURL.path
            }
            isScanning = false
        }
    }

    // MARK: Model Download

    func downloadWhisperModel(_ downloadableModel: WhisperDownloadableModel) {
        guard activeDownloadTask == nil else { return }
        downloadErrorMessage = nil
        downloadingModelFileName = downloadableModel.fileName
        downloadProgressFraction = 0

        let destinationDirectory = WhisperCppInstallation.openClickyModelsDirectory
        let destinationURL = destinationDirectory.appendingPathComponent(downloadableModel.fileName)

        let downloadTask = URLSession.shared.downloadTask(with: downloadableModel.downloadURL) { [weak self] temporaryFileURL, response, error in
            // Move the file before this handler returns; the temporary file is deleted afterwards.
            var completionErrorMessage: String?
            if let error {
                completionErrorMessage = error.localizedDescription
            } else if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                completionErrorMessage = "Download failed (HTTP \(httpResponse.statusCode))."
            } else if let temporaryFileURL {
                do {
                    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.moveItem(at: temporaryFileURL, to: destinationURL)
                } catch {
                    completionErrorMessage = error.localizedDescription
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadProgressTimer?.invalidate()
                self.downloadProgressTimer = nil
                self.activeDownloadTask = nil
                self.downloadingModelFileName = nil
                if let completionErrorMessage {
                    self.downloadErrorMessage = completionErrorMessage
                } else {
                    self.selectedWhisperModelPath = destinationURL.path
                    self.refresh()
                }
            }
        }
        activeDownloadTask = downloadTask
        downloadTask.resume()

        downloadProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let activeDownloadTask = self.activeDownloadTask else { return }
                self.downloadProgressFraction = activeDownloadTask.progress.fractionCompleted
            }
        }
    }

    func cancelDownload() {
        activeDownloadTask?.cancel()
    }
}
