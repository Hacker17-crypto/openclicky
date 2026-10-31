//
//  ClaudeCodeCLIClient.swift
//  leanring-buddy
//
//  Talks to Claude through the user's locally installed Claude Code CLI
//  (`claude`) instead of a hosted proxy. Each request spawns
//  `claude -p` in headless stream-json mode, sends the screenshots and the
//  transcript as a single user message on stdin, and streams the text
//  deltas back from stdout.
//
//  Authentication, billing and model access all come from the user's own
//  Claude Code login. No API keys live in this app and no OpenClicky server
//  exists.
//

import Foundation

// The project defaults to MainActor isolation; this client does process and
// pipe I/O off the main thread, so its types opt out explicitly.
nonisolated struct ClaudeCodeCLIError: LocalizedError {
    enum Kind {
        /// The `claude` executable could not be found on this Mac.
        case executableNotFound
        /// Claude Code is installed but is not logged in / has no valid credentials.
        case notAuthenticated
        /// Claude Code ran but reported an error (rate limit, bad model, crash, etc).
        case requestFailed
    }

    let kind: Kind
    let message: String

    var errorDescription: String? { message }
}

/// Resolved location of the Claude Code CLI plus the PATH it needs to run.
/// The npm-installed `claude` is a `#!/usr/bin/env node` script, so the
/// process must be able to find `node` too. GUI apps launched from Finder
/// do not inherit the user's shell PATH, so we reconstruct it.
nonisolated struct ClaudeCodeCLIInstallation: Sendable {
    let executablePath: String
    let processSearchPath: String
}

nonisolated final class ClaudeCodeCLIClient {
    /// Model alias passed to `claude --model` (e.g. "sonnet", "opus").
    /// Claude Code resolves aliases to the latest model the user has access to.
    var model: String

    /// UserDefaults key that lets the user point OpenClicky at a specific
    /// `claude` binary: `defaults write com.openclicky.app ClaudeCodeCLIPath /path/to/claude`
    static let executablePathOverrideDefaultsKey = "ClaudeCodeCLIPath"

    private static let installationCacheLock = NSLock()
    // Guarded by installationCacheLock.
    nonisolated(unsafe) private static var cachedInstallation: ClaudeCodeCLIInstallation?

    init(model: String = "sonnet") {
        self.model = model
    }

    // MARK: - Installation Discovery

    /// Resolves the CLI on a background thread so the first push-to-talk
    /// doesn't pay for the login-shell PATH lookup.
    static func warmUpInstallationLookupInBackground() {
        Task.detached(priority: .utility) {
            _ = try? resolveInstallation()
        }
    }

    /// Returns true when a `claude` executable can be found.
    static func isInstalled() async -> Bool {
        await Task.detached(priority: .utility) {
            (try? resolveInstallation()) != nil
        }.value
    }

    static func resolveInstallation() throws -> ClaudeCodeCLIInstallation {
        installationCacheLock.lock()
        if let cachedInstallation {
            installationCacheLock.unlock()
            return cachedInstallation
        }
        installationCacheLock.unlock()

        let loginShellSearchPath = readLoginShellPATH()
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path

        let wellKnownBinaryDirectories = [
            "\(homeDirectoryPath)/.claude/local",
            "\(homeDirectoryPath)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDirectoryPath)/.npm-global/bin",
            "\(homeDirectoryPath)/.bun/bin",
            "\(homeDirectoryPath)/.volta/bin",
            "/usr/bin",
            "/bin"
        ]

        var candidateExecutablePaths: [String] = []

        if let overridePath = UserDefaults.standard.string(forKey: executablePathOverrideDefaultsKey),
           !overridePath.isEmpty {
            candidateExecutablePaths.append((overridePath as NSString).expandingTildeInPath)
        }

        candidateExecutablePaths.append(contentsOf: wellKnownBinaryDirectories.map { "\($0)/claude" })
        candidateExecutablePaths.append(contentsOf: nodeVersionManagerBinaryDirectories(homeDirectoryPath: homeDirectoryPath).map { "\($0)/claude" })

        if let loginShellSearchPath {
            let loginShellDirectories = loginShellSearchPath.split(separator: ":").map(String.init)
            candidateExecutablePaths.append(contentsOf: loginShellDirectories.map { "\($0)/claude" })
        }

        if let commandLookupPath = runLoginShellCommand("command -v claude"),
           commandLookupPath.hasPrefix("/") {
            candidateExecutablePaths.append(commandLookupPath)
        }

        guard let executablePath = candidateExecutablePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw ClaudeCodeCLIError(
                kind: .executableNotFound,
                message: "Couldn't find the Claude Code CLI. Install it from https://claude.com/claude-code, run `claude` once in Terminal to log in, then try again."
            )
        }

        // Build a PATH that contains the CLI's own directory (so a sibling
        // `node` is found), the user's login-shell PATH, and common fallbacks.
        let executableDirectory = (executablePath as NSString).deletingLastPathComponent
        var searchPathDirectories = [executableDirectory]
        if let loginShellSearchPath {
            searchPathDirectories.append(contentsOf: loginShellSearchPath.split(separator: ":").map(String.init))
        }
        searchPathDirectories.append(contentsOf: wellKnownBinaryDirectories)
        var seenDirectories = Set<String>()
        let uniqueSearchPathDirectories = searchPathDirectories.filter { seenDirectories.insert($0).inserted }

        let installation = ClaudeCodeCLIInstallation(
            executablePath: executablePath,
            processSearchPath: uniqueSearchPathDirectories.joined(separator: ":")
        )

        installationCacheLock.lock()
        cachedInstallation = installation
        installationCacheLock.unlock()

        print("🤖 Claude Code CLI: \(executablePath)")
        return installation
    }

    /// npm installs under nvm live in ~/.nvm/versions/node/<version>/bin, which a
    /// non-interactive login shell often doesn't add to PATH (nvm loads from ~/.zshrc).
    /// Newest version first.
    private static func nodeVersionManagerBinaryDirectories(homeDirectoryPath: String) -> [String] {
        let nvmNodeVersionsDirectory = "\(homeDirectoryPath)/.nvm/versions/node"
        guard let installedNodeVersions = try? FileManager.default.contentsOfDirectory(atPath: nvmNodeVersionsDirectory) else {
            return []
        }
        return installedNodeVersions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(nvmNodeVersionsDirectory)/\($0)/bin" }
    }

    private static func readLoginShellPATH() -> String? {
        guard let searchPath = runLoginShellCommand("printf '%s' \"$PATH\""),
              !searchPath.isEmpty else {
            return nil
        }
        return searchPath
    }

    /// Runs a command inside the user's login shell so PATH tweaks from
    /// ~/.zprofile, ~/.bash_profile, etc. (Homebrew, nvm, volta) apply.
    /// Returns the last non-empty line of stdout, or nil on failure/timeout.
    static func runLoginShellCommand(_ command: String) -> String? {
        let userLoginShellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let shellProcess = Process()
        shellProcess.executableURL = URL(fileURLWithPath: userLoginShellPath)
        shellProcess.arguments = ["-l", "-c", command]
        let standardOutputPipe = Pipe()
        shellProcess.standardOutput = standardOutputPipe
        shellProcess.standardError = FileHandle.nullDevice
        shellProcess.standardInput = FileHandle.nullDevice

        // Set the handler before run() so a very fast exit can't be missed.
        let processFinishedSemaphore = DispatchSemaphore(value: 0)
        shellProcess.terminationHandler = { _ in processFinishedSemaphore.signal() }

        do {
            try shellProcess.run()
        } catch {
            return nil
        }

        // Don't let a slow or interactive shell profile hang the app.
        if processFinishedSemaphore.wait(timeout: .now() + 5) == .timedOut {
            shellProcess.terminate()
            return nil
        }

        let outputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(data: outputData, encoding: .utf8) ?? ""
        let lastNonEmptyLine = outputText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        return lastNonEmptyLine
    }

    /// Claude Code is run from its own scratch directory so it never picks up
    /// a random project's CLAUDE.md or settings from wherever the app launched.
    private static func makeWorkingDirectory() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let workingDirectory = applicationSupportDirectory
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("claude-workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        return workingDirectory
    }

    // MARK: - Request Building

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    /// Builds the single stream-json user message sent on stdin. Prior
    /// exchanges are included as a text transcript (screenshots from earlier
    /// turns are not resent, same as the original hosted implementation).
    private func makeStreamJSONUserMessage(
        images: [(data: Data, label: String)],
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) throws -> Data {
        var contentBlocks: [[String: Any]] = []

        if !conversationHistory.isEmpty {
            var conversationTranscript = "for context, here's our conversation so far (oldest first):\n"
            for (userPlaceholder, assistantResponse) in conversationHistory {
                conversationTranscript += "\nuser: \(userPlaceholder)\nyou: \(assistantResponse)\n"
            }
            contentBlocks.append(["type": "text", "text": conversationTranscript])
        }

        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append(["type": "text", "text": image.label])
        }

        contentBlocks.append(["type": "text", "text": userPrompt])

        let streamJSONMessage: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": contentBlocks
            ]
        ]

        var messageData = try JSONSerialization.data(withJSONObject: streamJSONMessage)
        messageData.append(contentsOf: [UInt8(ascii: "\n")])
        return messageData
    }

    private func makeCommandLineArguments(systemPrompt: String) -> [String] {
        return [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            // Replace Claude Code's coding-agent system prompt with Clicky's persona.
            "--system-prompt", systemPrompt,
            // Talk mode is pure vision + conversation; no file/shell tools.
            "--tools", "",
            // Skip MCP servers, project settings and slash commands so startup is fast
            // and nothing from the user's coding setup leaks into the buddy.
            "--strict-mcp-config",
            "--setting-sources", "user",
            "--disable-slash-commands",
            "--no-session-persistence"
        ]
    }

    // MARK: - Streaming Request

    /// Sends a vision request to Claude through Claude Code with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        let installation = try await Task.detached(priority: .userInitiated) {
            try Self.resolveInstallation()
        }.value

        let userMessageData = try makeStreamJSONUserMessage(
            images: images,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let claudeProcess = Process()
        claudeProcess.executableURL = URL(fileURLWithPath: installation.executablePath)
        claudeProcess.arguments = makeCommandLineArguments(systemPrompt: systemPrompt)
        claudeProcess.currentDirectoryURL = Self.makeWorkingDirectory()

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["PATH"] = installation.processSearchPath
        // If OpenClicky was launched from a terminal that is itself inside a
        // Claude Code session, don't let the child think it's nested.
        processEnvironment.removeValue(forKey: "CLAUDECODE")
        processEnvironment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        claudeProcess.environment = processEnvironment

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        claudeProcess.standardInput = standardInputPipe
        claudeProcess.standardOutput = standardOutputPipe
        claudeProcess.standardError = standardErrorPipe

        let processHandle = ClaudeCodeProcessHandle(process: claudeProcess)

        let payloadMB = Double(userMessageData.count) / 1_048_576.0
        print("🤖 Claude Code request (\(model)): \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // If `claude` exits early (e.g. not logged in) before reading stdin, writing the
        // screenshot payload would raise SIGPIPE and kill the whole app. Ignore it so
        // the write just throws and the CLI's error message is reported instead.
        signal(SIGPIPE, SIG_IGN)

        return try await withTaskCancellationHandler {
            try claudeProcess.run()

            // Drain stderr concurrently so a chatty CLI can't fill the pipe buffer and stall.
            let standardErrorReadHandle = standardErrorPipe.fileHandleForReading
            let standardErrorReadTask = Task.detached(priority: .utility) { () -> String in
                let standardErrorData = standardErrorReadHandle.readDataToEndOfFile()
                return String(data: standardErrorData, encoding: .utf8) ?? ""
            }

            // Send the one user message, then close stdin so the CLI knows the turn is complete.
            let standardInputHandle = standardInputPipe.fileHandleForWriting
            // A failed write means the CLI already exited; keep going so its
            // stdout/stderr explain why instead of a generic broken-pipe error.
            await Task.detached(priority: .userInitiated) {
                try? standardInputHandle.write(contentsOf: userMessageData)
                try? standardInputHandle.close()
            }.value

            var accumulatedResponseText = ""
            var finalResultText: String?
            var finalResultErrorMessage: String?

            for try await outputLine in standardOutputPipe.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()

                guard let lineData = outputLine.data(using: .utf8),
                      let outputEvent = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let outputEventType = outputEvent["type"] as? String else {
                    continue
                }

                switch outputEventType {
                case "stream_event":
                    // Partial-message events wrap the raw Messages API SSE events.
                    if let streamEvent = outputEvent["event"] as? [String: Any],
                       (streamEvent["type"] as? String) == "content_block_delta",
                       let delta = streamEvent["delta"] as? [String: Any],
                       (delta["type"] as? String) == "text_delta",
                       let textChunk = delta["text"] as? String {
                        accumulatedResponseText += textChunk
                        let currentAccumulatedText = accumulatedResponseText
                        await onTextChunk(currentAccumulatedText)
                    }

                case "assistant":
                    // Complete assistant message. Only used if partial streaming
                    // produced nothing (e.g. an older CLI without partial messages).
                    if accumulatedResponseText.isEmpty,
                       let assistantMessage = outputEvent["message"] as? [String: Any],
                       let assistantContentBlocks = assistantMessage["content"] as? [[String: Any]] {
                        let assistantText = assistantContentBlocks
                            .filter { ($0["type"] as? String) == "text" }
                            .compactMap { $0["text"] as? String }
                            .joined()
                        if !assistantText.isEmpty {
                            accumulatedResponseText = assistantText
                            await onTextChunk(assistantText)
                        }
                    }

                case "result":
                    let isErrorResult = (outputEvent["is_error"] as? Bool) ?? false
                    let resultSubtype = outputEvent["subtype"] as? String
                    let resultText = outputEvent["result"] as? String
                    if isErrorResult || (resultSubtype != nil && resultSubtype != "success") {
                        finalResultErrorMessage = resultText ?? resultSubtype ?? "Claude Code reported an error"
                    } else {
                        finalResultText = resultText
                    }

                default:
                    break
                }
            }

            await Task.detached(priority: .utility) {
                processHandle.waitUntilExit()
            }.value
            try Task.checkCancellation()

            let standardErrorText = await standardErrorReadTask.value

            if let finalResultErrorMessage {
                throw Self.makeError(fromCLIMessage: finalResultErrorMessage)
            }

            if accumulatedResponseText.isEmpty, let finalResultText, !finalResultText.isEmpty {
                accumulatedResponseText = finalResultText
                await onTextChunk(finalResultText)
            }

            if accumulatedResponseText.isEmpty {
                let exitStatus = claudeProcess.terminationStatus
                let diagnosticText = standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
                throw Self.makeError(
                    fromCLIMessage: diagnosticText.isEmpty
                        ? "Claude Code exited with status \(exitStatus) and no response"
                        : diagnosticText
                )
            }

            let duration = Date().timeIntervalSince(startTime)
            print("🤖 Claude Code response in \(String(format: "%.1f", duration))s")
            return (text: accumulatedResponseText, duration: duration)
        } onCancel: {
            processHandle.terminateIfRunning()
        }
    }

    /// Non-streaming convenience wrapper with the same signature as the original API client.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        return try await analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: { _ in }
        )
    }

    private static func makeError(fromCLIMessage cliMessage: String) -> ClaudeCodeCLIError {
        let lowercasedMessage = cliMessage.lowercased()
        let looksLikeAuthenticationProblem = lowercasedMessage.contains("/login")
            || lowercasedMessage.contains("not logged in")
            || lowercasedMessage.contains("invalid api key")
            || lowercasedMessage.contains("authentication")
            || lowercasedMessage.contains("oauth")
        return ClaudeCodeCLIError(
            kind: looksLikeAuthenticationProblem ? .notAuthenticated : .requestFailed,
            message: "Claude Code: \(cliMessage)"
        )
    }
}

/// Lets the cancellation handler (which runs on an arbitrary thread) stop the child process.
nonisolated private final class ClaudeCodeProcessHandle: @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }

    func terminateIfRunning() {
        if process.isRunning {
            process.terminate()
        }
    }
}
