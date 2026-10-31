//
//  OpenClickyAgents.swift
//  leanring-buddy
//
//  Voice-spawned background agents. When the user asks OpenClicky to *do*
//  something (research, write a file, build something, control an app),
//  the talk model hands off with an [AGENT:task] tag, or the user says
//  "agent, ...". Each agent is a long-running local Claude Code process
//  with its full toolset (files, terminal, web, the user's MCP servers),
//  working in its own folder under ~/OpenClicky.
//
//  Permission prompts use Claude Code's stdio permission protocol: the CLI
//  sends a `can_use_tool` control_request on stdout and waits for our
//  control_response on stdin. OpenClicky shows those as approval cards
//  (Allow once / Always allow / Not now) unless the user picked
//  "Always approve" in Settings.
//
//  After an agent finishes, its process stays alive so the user can send
//  follow-ups to the same conversation, until the card is dismissed.
//

import AppKit
import Combine
import Foundation

// MARK: - Agent Process

/// Owns one `claude` child process and its pipes. Lines from stdout are handed to
/// `onOutputLine`; all parsing and state live on the main actor in OpenClickyAgent.
nonisolated final class ClaudeCodeAgentProcess: @unchecked Sendable {
    private let process = Process()
    private let standardInputPipe = Pipe()
    private let standardOutputPipe = Pipe()
    private let standardErrorPipe = Pipe()
    private let standardInputWriteQueue = DispatchQueue(label: "com.openclicky.agent.stdin")
    private var isStandardInputClosed = false

    init(
        installation: ClaudeCodeCLIInstallation,
        workingDirectory: URL,
        appendedSystemPrompt: String
    ) {
        process.executableURL = URL(fileURLWithPath: installation.executablePath)
        process.arguments = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            // Route permission prompts to us over stdin/stdout.
            "--permission-prompt-tool", "stdio",
            "--permission-mode", "default",
            "--append-system-prompt", appendedSystemPrompt
        ]
        process.currentDirectoryURL = workingDirectory

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["PATH"] = installation.processSearchPath
        processEnvironment.removeValue(forKey: "CLAUDECODE")
        processEnvironment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        process.environment = processEnvironment

        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
    }

    var isRunning: Bool { process.isRunning }

    /// Starts the process. `onOutputLine` receives each stdout line; `onExit`
    /// receives the exit status and stderr text once the process ends.
    func start(
        onOutputLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32, String) -> Void
    ) throws {
        signal(SIGPIPE, SIG_IGN)
        try process.run()

        let standardOutputReadHandle = standardOutputPipe.fileHandleForReading
        let standardErrorReadHandle = standardErrorPipe.fileHandleForReading

        Task.detached(priority: .utility) { [self] in
            let standardErrorTask = Task.detached(priority: .utility) { () -> String in
                let standardErrorData = standardErrorReadHandle.readDataToEndOfFile()
                return String(data: standardErrorData, encoding: .utf8) ?? ""
            }

            do {
                for try await outputLine in standardOutputReadHandle.bytes.lines {
                    onOutputLine(outputLine)
                }
            } catch {
                // Pipe closed or process killed; fall through to exit handling.
            }

            self.process.waitUntilExit()
            let standardErrorText = await standardErrorTask.value
            onExit(self.process.terminationStatus, standardErrorText)
        }
    }

    /// Writes one JSON object as a line on stdin.
    func sendJSONLine(_ jsonData: Data) {
        let standardInputHandle = standardInputPipe.fileHandleForWriting
        standardInputWriteQueue.async { [weak self] in
            guard let self, !self.isStandardInputClosed else { return }
            var lineData = jsonData
            lineData.append(contentsOf: [UInt8(ascii: "\n")])
            try? standardInputHandle.write(contentsOf: lineData)
        }
    }

    /// Closing stdin tells Claude Code there will be no more messages; it exits after the current turn.
    func closeInput() {
        let standardInputHandle = standardInputPipe.fileHandleForWriting
        standardInputWriteQueue.async { [weak self] in
            guard let self, !self.isStandardInputClosed else { return }
            self.isStandardInputClosed = true
            try? standardInputHandle.close()
        }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}

// MARK: - Agent Model

enum OpenClickyAgentStatus: Equatable {
    /// Short grace period before starting, so a misheard request can be cancelled.
    case startingSoon(secondsRemaining: Int)
    case working
    case needsApproval
    case finished
    case failed(message: String)
    case stopped

    var isActive: Bool {
        switch self {
        case .startingSoon, .working, .needsApproval: return true
        case .finished, .failed, .stopped: return false
        }
    }
}

/// A tool call Claude Code wants permission for.
struct OpenClickyAgentApprovalRequest: Equatable {
    let requestIdentifier: String
    let toolName: String
    /// Human-readable summary, e.g. "Run: npm install" or "Write report.md".
    let actionSummary: String
    /// The tool input as JSON, echoed back unchanged when approved.
    let toolInputJSONData: Data
}

@MainActor
final class OpenClickyAgent: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let taskDescription: String
    let workspaceDirectory: URL
    let createdAt = Date()

    @Published private(set) var status: OpenClickyAgentStatus = .startingSoon(secondsRemaining: 5)
    /// Most recent thing the agent did, shown on the card ("Searching the web: ...").
    @Published private(set) var latestActivityText: String = "Getting ready..."
    /// Final summary from the agent, read aloud when it finishes.
    @Published private(set) var finalSummaryText: String?
    @Published private(set) var pendingApprovalRequest: OpenClickyAgentApprovalRequest?
    /// Files the agent created in its workspace folder.
    @Published private(set) var createdFileNames: [String] = []

    /// Called when a run (initial task or follow-up) ends successfully.
    var onFinished: ((OpenClickyAgent) -> Void)?

    private let initialScreenshotImages: [(data: Data, label: String)]
    private var agentProcess: ClaudeCodeAgentProcess?
    private var countdownTask: Task<Void, Never>?

    init(name: String, taskDescription: String, workspaceDirectory: URL, screenshotImages: [(data: Data, label: String)]) {
        self.name = name
        self.taskDescription = taskDescription
        self.workspaceDirectory = workspaceDirectory
        self.initialScreenshotImages = screenshotImages
    }

    // MARK: Lifecycle

    /// Counts down for a few seconds (so the user can cancel), then launches Claude Code.
    func beginAfterCountdown(seconds countdownSeconds: Int = 5) {
        countdownTask?.cancel()
        status = .startingSoon(secondsRemaining: countdownSeconds)
        countdownTask = Task { [weak self] in
            for secondsRemaining in stride(from: countdownSeconds, to: 0, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.status = .startingSoon(secondsRemaining: secondsRemaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.launchClaudeCodeProcess()
        }
    }

    /// Skips the countdown and starts immediately.
    func startNow() {
        countdownTask?.cancel()
        launchClaudeCodeProcess()
    }

    func stop() {
        countdownTask?.cancel()
        agentProcess?.closeInput()
        agentProcess?.terminate()
        agentProcess = nil
        pendingApprovalRequest = nil
        status = .stopped
        latestActivityText = "Stopped"
    }

    /// Starts the same task again from scratch (after a failure or stop).
    func retry() {
        agentProcess?.terminate()
        agentProcess = nil
        finalSummaryText = nil
        latestActivityText = "Retrying..."
        launchClaudeCodeProcess()
    }

    /// Sends a follow-up message to the same conversation.
    func sendFollowUp(_ followUpText: String) {
        let trimmedFollowUpText = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFollowUpText.isEmpty else { return }

        guard let agentProcess, agentProcess.isRunning else {
            latestActivityText = "This agent's session ended. Start a new agent instead."
            return
        }

        finalSummaryText = nil
        status = .working
        latestActivityText = "Working on your follow-up..."
        sendUserMessage(contentBlocks: [["type": "text", "text": trimmedFollowUpText]])
    }

    /// Ends the session for good (card dismissed or app quitting).
    func shutDown() {
        countdownTask?.cancel()
        agentProcess?.closeInput()
        let processToTerminate = agentProcess
        agentProcess = nil
        // Give Claude Code a moment to exit cleanly after stdin closes.
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            processToTerminate?.terminate()
        }
    }

    // MARK: Approvals

    func approvePendingRequest(alwaysAllowThisTool: Bool) {
        guard let pendingApprovalRequest else { return }
        if alwaysAllowThisTool {
            OpenClickySettings.shared.alwaysAllowedAgentToolNames.insert(pendingApprovalRequest.toolName)
        }
        respondToApprovalRequest(pendingApprovalRequest, isAllowed: true)
    }

    func denyPendingRequest() {
        guard let pendingApprovalRequest else { return }
        respondToApprovalRequest(pendingApprovalRequest, isAllowed: false)
    }

    private func respondToApprovalRequest(_ approvalRequest: OpenClickyAgentApprovalRequest, isAllowed: Bool) {
        let decision: [String: Any]
        if isAllowed {
            let toolInput = (try? JSONSerialization.jsonObject(with: approvalRequest.toolInputJSONData)) ?? [String: Any]()
            decision = ["behavior": "allow", "updatedInput": toolInput]
        } else {
            decision = [
                "behavior": "deny",
                "message": "The user chose not to allow this action. Try a different approach that doesn't need it, or finish and explain what you couldn't do."
            ]
        }

        sendJSONObject([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": approvalRequest.requestIdentifier,
                "response": decision
            ]
        ])

        if pendingApprovalRequest == approvalRequest {
            pendingApprovalRequest = nil
            status = .working
            latestActivityText = isAllowed ? "Approved: \(approvalRequest.actionSummary)" : "Skipped: \(approvalRequest.actionSummary)"
        }
    }

    // MARK: Process

    private func launchClaudeCodeProcess() {
        status = .working
        latestActivityText = "Starting Claude Code..."

        let installation: ClaudeCodeCLIInstallation
        do {
            installation = try ClaudeCodeCLIClient.resolveInstallation()
        } catch {
            status = .failed(message: error.localizedDescription)
            return
        }

        try? FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)

        let newAgentProcess = ClaudeCodeAgentProcess(
            installation: installation,
            workingDirectory: workspaceDirectory,
            appendedSystemPrompt: Self.makeAgentSystemPrompt(workspaceDirectory: workspaceDirectory)
        )
        agentProcess = newAgentProcess

        do {
            try newAgentProcess.start(
                onOutputLine: { [weak self] outputLine in
                    Task { @MainActor [weak self] in
                        self?.handleOutputLine(outputLine, fromProcess: newAgentProcess)
                    }
                },
                onExit: { [weak self] exitStatus, standardErrorText in
                    Task { @MainActor [weak self] in
                        self?.handleProcessExit(exitStatus: exitStatus, standardErrorText: standardErrorText, fromProcess: newAgentProcess)
                    }
                }
            )
        } catch {
            status = .failed(message: "Couldn't start Claude Code: \(error.localizedDescription)")
            return
        }

        // The SDK handshake; enables the stdio permission prompt tool.
        sendJSONObject([
            "type": "control_request",
            "request_id": "openclicky-initialize",
            "request": ["subtype": "initialize"]
        ])

        var firstMessageContentBlocks: [[String: Any]] = []
        for screenshotImage in initialScreenshotImages {
            firstMessageContentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": screenshotImage.data.base64EncodedString()
                ]
            ])
            firstMessageContentBlocks.append(["type": "text", "text": "the user's screen when they asked: \(screenshotImage.label)"])
        }
        firstMessageContentBlocks.append(["type": "text", "text": taskDescription])
        sendUserMessage(contentBlocks: firstMessageContentBlocks)
    }

    private static func makeAgentSystemPrompt(workspaceDirectory: URL) -> String {
        var agentSystemPrompt = """
        You are an OpenClicky agent: a background helper the user launched by voice from OpenClicky, a buddy app on their Mac. The user is not watching your work step by step; they see a small card with your latest action, and approve sensitive actions there.

        - Your working directory (\(workspaceDirectory.path)) is a folder made for this task. Save files you create there unless the user asked for a specific location.
        - Use web search, the terminal, and any MCP tools the user has connected when they help.
        - You can control Mac apps when needed: `open` for apps, files and URLs, and `osascript` (AppleScript or JavaScript for Automation) for things like creating notes, reminders, calendar events, controlling Music, or clicking menu items and typing via System Events. Prefer app scripting and APIs over simulated clicks.
        - Don't ask clarifying questions unless the task is truly impossible without an answer; make sensible assumptions and mention them.
        - Never do anything destructive or irreversible (deleting files outside your folder, sending emails or messages, purchases, posting publicly) unless the user explicitly asked for exactly that.
        - When you finish, reply with a short plain-language summary (one to three sentences, no markdown, no lists) of what you did and where the results are. It will be read aloud.
        """

        let profileText = OpenClickySettings.shared.isMemoryEnabled ? OpenClickyMemoryStore.readProfileText() : ""
        if !profileText.isEmpty {
            agentSystemPrompt += "\n\nWhat you know about the user:\n\(profileText)"
        }
        return agentSystemPrompt
    }

    private func sendUserMessage(contentBlocks: [[String: Any]]) {
        sendJSONObject([
            "type": "user",
            "message": ["role": "user", "content": contentBlocks]
        ])
    }

    private func sendJSONObject(_ jsonObject: [String: Any]) {
        guard let agentProcess,
              let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject) else { return }
        agentProcess.sendJSONLine(jsonData)
    }

    private func handleOutputLine(_ outputLine: String, fromProcess sourceProcess: ClaudeCodeAgentProcess) {
        // Ignore stragglers from a process we've already replaced (retry/stop).
        guard sourceProcess === agentProcess else { return }

        guard let lineData = outputLine.data(using: .utf8),
              let outputEvent = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let outputEventType = outputEvent["type"] as? String else {
            return
        }

        switch outputEventType {
        case "assistant":
            guard let assistantMessage = outputEvent["message"] as? [String: Any],
                  let contentBlocks = assistantMessage["content"] as? [[String: Any]] else { return }
            for contentBlock in contentBlocks {
                switch contentBlock["type"] as? String {
                case "tool_use":
                    let toolName = contentBlock["name"] as? String ?? "tool"
                    let toolInput = contentBlock["input"] as? [String: Any] ?? [:]
                    latestActivityText = Self.describeToolUse(toolName: toolName, toolInput: toolInput)
                case "text":
                    if let assistantText = contentBlock["text"] as? String {
                        let trimmedAssistantText = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedAssistantText.isEmpty {
                            latestActivityText = String(trimmedAssistantText.prefix(160))
                        }
                    }
                default:
                    break
                }
            }

        case "control_request":
            guard let controlRequest = outputEvent["request"] as? [String: Any],
                  (controlRequest["subtype"] as? String) == "can_use_tool",
                  let requestIdentifier = outputEvent["request_id"] as? String else { return }

            let toolName = controlRequest["tool_name"] as? String ?? "tool"
            let toolInput = controlRequest["input"] as? [String: Any] ?? [:]
            let toolInputJSONData = (try? JSONSerialization.data(withJSONObject: toolInput)) ?? Data("{}".utf8)
            let approvalRequest = OpenClickyAgentApprovalRequest(
                requestIdentifier: requestIdentifier,
                toolName: toolName,
                actionSummary: Self.describeToolUse(toolName: toolName, toolInput: toolInput),
                toolInputJSONData: toolInputJSONData
            )

            let settings = OpenClickySettings.shared
            if settings.agentApprovalMode == .alwaysApprove || settings.alwaysAllowedAgentToolNames.contains(toolName) {
                respondToApprovalRequest(approvalRequest, isAllowed: true)
            } else {
                pendingApprovalRequest = approvalRequest
                status = .needsApproval
                latestActivityText = "Wants to: \(approvalRequest.actionSummary)"
            }

        case "result":
            let isErrorResult = (outputEvent["is_error"] as? Bool) ?? false
            let resultText = (outputEvent["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            refreshCreatedFileNames()
            if isErrorResult {
                status = .failed(message: resultText.isEmpty ? "Claude Code reported an error." : resultText)
                latestActivityText = "Failed"
            } else {
                finalSummaryText = resultText.isEmpty ? "Done." : resultText
                latestActivityText = "Done"
                status = .finished
                onFinished?(self)
            }

        default:
            break
        }
    }

    private func handleProcessExit(exitStatus: Int32, standardErrorText: String, fromProcess sourceProcess: ClaudeCodeAgentProcess) {
        guard sourceProcess === agentProcess else { return }
        agentProcess = nil

        // Exiting after a finished run (stdin closed) is normal.
        guard status.isActive else { return }

        let diagnosticText = standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
        status = .failed(message: diagnosticText.isEmpty
            ? "Claude Code exited unexpectedly (status \(exitStatus))."
            : String(diagnosticText.suffix(300)))
        pendingApprovalRequest = nil
    }

    private func refreshCreatedFileNames() {
        let workspaceContents = (try? FileManager.default.contentsOfDirectory(atPath: workspaceDirectory.path)) ?? []
        createdFileNames = workspaceContents.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Turns a tool call into a short, friendly line for the card.
    static func describeToolUse(toolName: String, toolInput: [String: Any]) -> String {
        func inputString(_ key: String) -> String? {
            (toolInput[key] as? String).map { String($0.prefix(120)) }
        }
        func fileName(_ key: String) -> String? {
            inputString(key).map { ($0 as NSString).lastPathComponent }
        }

        switch toolName {
        case "Bash":
            if let commandDescription = inputString("description") { return commandDescription }
            return "Run: \(inputString("command") ?? "a command")"
        case "Write":
            return "Write \(fileName("file_path") ?? "a file")"
        case "Edit", "MultiEdit":
            return "Edit \(fileName("file_path") ?? "a file")"
        case "Read":
            return "Read \(fileName("file_path") ?? "a file")"
        case "Glob", "Grep":
            return "Search files for \(inputString("pattern") ?? "matches")"
        case "WebSearch":
            return "Search the web: \(inputString("query") ?? "")"
        case "WebFetch":
            return "Read \(inputString("url") ?? "a web page")"
        case "TodoWrite":
            return "Plan the steps"
        default:
            if toolName.hasPrefix("mcp__") {
                let toolNameParts = toolName.split(separator: "_", omittingEmptySubsequences: true)
                let serverName = toolNameParts.count > 1 ? String(toolNameParts[1]) : "app"
                let actionName = toolNameParts.last.map(String.init) ?? "tool"
                return "Use \(serverName): \(actionName.replacingOccurrences(of: "-", with: " "))"
            }
            return "Use \(toolName)"
        }
    }
}

// MARK: - Agent Manager

@MainActor
final class OpenClickyAgentManager: ObservableObject {
    @Published private(set) var agents: [OpenClickyAgent] = []

    /// Called when any agent finishes, so CompanionManager can announce it.
    var onAgentFinished: ((OpenClickyAgent) -> Void)?

    /// Where agent folders live: ~/OpenClicky/<date> <name>/
    /// (Not ~/Documents, which would trigger a macOS folder-access prompt.)
    static var agentsRootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OpenClicky", isDirectory: true)
    }

    private var agentChangeCancellables: [UUID: AnyCancellable] = [:]

    var hasAnyAgents: Bool { !agents.isEmpty }

    @discardableResult
    func launchAgent(taskDescription: String, screenshotImages: [(data: Data, label: String)]) -> OpenClickyAgent {
        let agentName = Self.makeShortAgentName(from: taskDescription, existingAgentCount: agents.count)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HHmm"
        let workspaceFolderName = "\(dateFormatter.string(from: Date())) \(agentName)"
            .replacingOccurrences(of: "/", with: "-")
        let workspaceDirectory = Self.agentsRootDirectory.appendingPathComponent(workspaceFolderName, isDirectory: true)

        let newAgent = OpenClickyAgent(
            name: agentName,
            taskDescription: taskDescription,
            workspaceDirectory: workspaceDirectory,
            screenshotImages: screenshotImages
        )
        newAgent.onFinished = { [weak self] finishedAgent in
            self?.onAgentFinished?(finishedAgent)
        }

        // Re-publish nested changes so the cards panel redraws when any agent updates.
        agentChangeCancellables[newAgent.id] = newAgent.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        agents.insert(newAgent, at: 0)
        newAgent.beginAfterCountdown()
        print("🤖 Agent \"\(agentName)\" queued: \(taskDescription)")
        return newAgent
    }

    func dismissAgent(_ agentToDismiss: OpenClickyAgent) {
        agentToDismiss.shutDown()
        agentChangeCancellables[agentToDismiss.id] = nil
        agents.removeAll { $0.id == agentToDismiss.id }
    }

    func dismissAllFinishedAgents() {
        for agent in agents where !agent.status.isActive {
            dismissAgent(agent)
        }
    }

    func shutDownAllAgents() {
        for agent in agents {
            agent.shutDown()
        }
    }

    /// The most recently finished agent still on screen, for voice follow-ups.
    var mostRecentFinishedAgent: OpenClickyAgent? {
        agents.first { $0.status == .finished }
    }

    /// Two-word card names like "Video Editors" from the task description.
    static func makeShortAgentName(from taskDescription: String, existingAgentCount: Int) -> String {
        let wordsToSkip: Set<String> = [
            "a", "an", "the", "and", "or", "to", "for", "of", "in", "on", "with", "my", "me", "i", "it", "this", "that",
            "please", "can", "you", "could", "would", "find", "make", "create", "write", "research", "build", "do",
            "get", "go", "look", "up", "into", "about", "some", "best", "new", "user's", "users", "save", "file",
            "markdown", "agent", "help", "from", "at", "is", "are", "be", "all", "them", "their", "then", "set"
        ]

        let significantWords = taskDescription
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !wordsToSkip.contains($0) }

        let nameWords = significantWords.prefix(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        if nameWords.isEmpty {
            return "Agent \(existingAgentCount + 1)"
        }
        return nameWords.joined(separator: " ")
    }
}
