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

/// A ggml model file found on disk.
nonisolated struct WhisperInstalledModel: Identifiable, Hashable {
    let fileURL: URL
    let sizeInBytes: Int64

    var id: String { fileURL.path }
    var displayName: String {
        fileURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
    }
    /// English-only models end in ".en"; the rest detect the language.
    var isEnglishOnly: Bool { displayName.hasSuffix(".en") || displayName.contains(".en-") }
}

// MARK: - whisper.cpp Discovery (synchronous, file checks only)

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

    /// Places ggml models commonly live: ours, whisper.cpp checkouts, Homebrew shares, the HF cache dir some tools use.
    static var modelSearchDirectories: [URL] {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        return [
            openClickyModelsDirectory,
            homeDirectory.appendingPathComponent(".cache/whisper"),
            homeDirectory.appendingPathComponent("whisper.cpp/models"),
            homeDirectory.appendingPathComponent("models"),
            URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp"),
            URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp/models"),
            URL(fileURLWithPath: "/usr/local/share/whisper-cpp"),
            URL(fileURLWithPath: "/usr/local/share/whisper-cpp/models")
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

    static func findInstalledModels() -> [WhisperInstalledModel] {
        var installedModels: [WhisperInstalledModel] = []
        var seenModelPaths = Set<String>()

        for searchDirectory in modelSearchDirectories {
            guard let directoryContents = try? FileManager.default.contentsOfDirectory(
                at: searchDirectory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for fileURL in directoryContents
            where fileURL.lastPathComponent.hasPrefix("ggml-") && fileURL.pathExtension == "bin" {
                let resolvedPath = fileURL.resolvingSymlinksInPath().path
                guard seenModelPaths.insert(resolvedPath).inserted else { continue }
                let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                // Skip tiny files (failed downloads, test fixtures).
                guard fileSize > 10_000_000 else { continue }
                installedModels.append(WhisperInstalledModel(fileURL: fileURL, sizeInBytes: fileSize))
            }
        }

        return installedModels.sorted { $0.sizeInBytes > $1.sizeInBytes }
    }

    /// The model the user picked, or the largest installed one.
    static func selectedModelURL() -> URL? {
        if let selectedModelPath = UserDefaults.standard.string(forKey: selectedModelPathDefaultsKey),
           FileManager.default.fileExists(atPath: selectedModelPath) {
            return URL(fileURLWithPath: selectedModelPath)
        }
        return findInstalledModels().first?.fileURL
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

    var hasAssemblyAIKey: Bool { AppBundleConfiguration.stringValue(forKey: "AssemblyAIAPIKey") != nil }
    var hasOpenAIKey: Bool { AppBundleConfiguration.stringValue(forKey: "OpenAIAPIKey") != nil }

    func isEngineReady(_ engine: TranscriptionEngine) -> Bool {
        switch engine {
        case .appleSpeech: return true
        case .appleSpeechAnalyzer: return isSpeechAnalyzerAvailable
        case .whisperCpp: return whisperExecutablePath != nil && !installedWhisperModels.isEmpty
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
            if whisperExecutablePath == nil { return "whisper.cpp not installed" }
            if installedWhisperModels.isEmpty { return "Installed, needs a model" }
            return installedWhisperModels.count == 1 ? "Ready, 1 model found" : "Ready, \(installedWhisperModels.count) models found"
        case .assemblyAI:
            return hasAssemblyAIKey ? "Key found" : "Add AssemblyAIAPIKey to Info.plist"
        case .openAI:
            return hasOpenAIKey ? "Key found" : "Add OpenAIAPIKey to Info.plist"
        }
    }

    // MARK: Scanning

    func refresh() {
        isScanning = true
        Task {
            let discoveredExecutablePath = await Task.detached(priority: .utility) {
                WhisperCppInstallation.findExecutablePathIncludingLoginShell()
            }.value
            whisperExecutablePath = discoveredExecutablePath
            installedWhisperModels = WhisperCppInstallation.findInstalledModels()
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
