//
//  OpenClickySettings.swift
//  leanring-buddy
//
//  User preferences (voice, dictation, agents, memory) persisted to
//  UserDefaults, plus OpenClicky's on-disk memory: a PROFILE.md file of
//  facts about the user and the recent conversation history, so the buddy
//  remembers things across launches.
//

import AppKit
import Combine
import Foundation

/// How agents handle tool calls that Claude Code wants permission for
/// (writing files, running shell commands, etc).
enum AgentApprovalMode: String, CaseIterable, Identifiable {
    /// Show an Allow once / Always allow / Not now card for each new kind of action.
    case askEachTime
    /// Approve everything automatically. Agents can change files and run commands unattended.
    case alwaysApprove

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .askEachTime: return "Ask before acting"
        case .alwaysApprove: return "Always approve"
        }
    }
}

@MainActor
final class OpenClickySettings: ObservableObject {
    static let shared = OpenClickySettings()

    private let userDefaults = UserDefaults.standard

    // MARK: - Voice

    /// AVSpeechSynthesisVoice identifier. Empty means "pick the best installed voice".
    @Published var localSpeechVoiceIdentifier: String {
        didSet { userDefaults.set(localSpeechVoiceIdentifier, forKey: LocalSpeechTTSClient.voiceIdentifierOverrideDefaultsKey) }
    }

    /// 0.5x – 1.5x multiplier on the normal speaking rate.
    @Published var speechRateMultiplier: Double {
        didSet { userDefaults.set(speechRateMultiplier, forKey: "speechRateMultiplier") }
    }

    /// Shows the spoken words next to the cursor while OpenClicky talks.
    @Published var showsCaptionsWhileTalking: Bool {
        didSet { userDefaults.set(showsCaptionsWhileTalking, forKey: "showsCaptionsWhileTalking") }
    }

    // MARK: - Dictation

    /// Hold Fn+Control to dictate into whatever app is focused.
    @Published var isDictationEnabled: Bool {
        didSet { userDefaults.set(isDictationEnabled, forKey: "isDictationEnabled") }
    }

    /// Runs dictated text through Claude (Haiku) to fix punctuation, filler words and
    /// self-corrections before inserting. Adds a couple of seconds of latency.
    @Published var polishesDictationWithClaude: Bool {
        didSet { userDefaults.set(polishesDictationWithClaude, forKey: "polishesDictationWithClaude") }
    }

    /// Names, jargon and other words the speech recognizer should favor.
    @Published var personalDictionaryWords: [String] {
        didSet { userDefaults.set(personalDictionaryWords, forKey: "personalDictionaryWords") }
    }

    // MARK: - Agents

    @Published var agentApprovalMode: AgentApprovalMode {
        didSet { userDefaults.set(agentApprovalMode.rawValue, forKey: "agentApprovalMode") }
    }

    /// Tool names the user picked "Always allow" for (e.g. "Write", "Bash").
    @Published var alwaysAllowedAgentToolNames: Set<String> {
        didSet { userDefaults.set(Array(alwaysAllowedAgentToolNames).sorted(), forKey: "alwaysAllowedAgentToolNames") }
    }

    // MARK: - Memory

    /// When on, PROFILE.md and recent conversation are sent with each request
    /// and conversation history survives app restarts.
    @Published var isMemoryEnabled: Bool {
        didSet { userDefaults.set(isMemoryEnabled, forKey: "isMemoryEnabled") }
    }

    private init() {
        localSpeechVoiceIdentifier = userDefaults.string(forKey: LocalSpeechTTSClient.voiceIdentifierOverrideDefaultsKey) ?? ""
        speechRateMultiplier = userDefaults.object(forKey: "speechRateMultiplier") as? Double ?? 1.0
        showsCaptionsWhileTalking = userDefaults.object(forKey: "showsCaptionsWhileTalking") as? Bool ?? true
        isDictationEnabled = userDefaults.object(forKey: "isDictationEnabled") as? Bool ?? true
        polishesDictationWithClaude = userDefaults.object(forKey: "polishesDictationWithClaude") as? Bool ?? false
        personalDictionaryWords = userDefaults.stringArray(forKey: "personalDictionaryWords") ?? []
        agentApprovalMode = AgentApprovalMode(rawValue: userDefaults.string(forKey: "agentApprovalMode") ?? "") ?? .askEachTime
        alwaysAllowedAgentToolNames = Set(userDefaults.stringArray(forKey: "alwaysAllowedAgentToolNames") ?? [])
        isMemoryEnabled = userDefaults.object(forKey: "isMemoryEnabled") as? Bool ?? true
    }
}

// MARK: - Memory Store

/// OpenClicky's long-term memory, kept as plain files the user can read and edit:
///   ~/Library/Application Support/OpenClicky/PROFILE.md       facts about the user
///   ~/Library/Application Support/OpenClicky/conversation.json  recent exchanges
@MainActor
enum OpenClickyMemoryStore {
    /// Maximum exchanges kept (each exchange = one user message + one reply, so 40 messages).
    static let maximumStoredExchangeCount = 20

    static var applicationSupportDirectory: URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let openClickyDirectory = baseDirectory.appendingPathComponent("OpenClicky", isDirectory: true)
        try? FileManager.default.createDirectory(at: openClickyDirectory, withIntermediateDirectories: true)
        return openClickyDirectory
    }

    static var profileFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("PROFILE.md")
    }

    private static var conversationHistoryFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("conversation.json")
    }

    // MARK: Profile

    /// Returns the profile facts, or an empty string if there are none yet.
    static func readProfileText() -> String {
        guard let profileText = try? String(contentsOf: profileFileURL, encoding: .utf8) else { return "" }
        return profileText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Appends a fact as a bullet, skipping exact duplicates.
    static func rememberFact(_ fact: String) {
        let trimmedFact = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFact.isEmpty else { return }

        var existingProfileText = readProfileText()
        if existingProfileText.isEmpty {
            existingProfileText = "# What OpenClicky knows about you\n\n<!-- Edit freely. Each bullet is sent to Claude with your questions. -->\n"
        }

        let factBulletLine = "- \(trimmedFact)"
        guard !existingProfileText.lowercased().contains(factBulletLine.lowercased()) else { return }

        let updatedProfileText = existingProfileText + "\n" + factBulletLine + "\n"
        try? updatedProfileText.write(to: profileFileURL, atomically: true, encoding: .utf8)
        print("🧠 Remembered: \(trimmedFact)")
    }

    static func openProfileInDefaultEditor() {
        if !FileManager.default.fileExists(atPath: profileFileURL.path) {
            let starterProfileText = "# What OpenClicky knows about you\n\n<!-- Edit freely. Each bullet is sent to Claude with your questions. -->\n"
            try? starterProfileText.write(to: profileFileURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(profileFileURL)
    }

    // MARK: Conversation History

    private struct StoredExchange: Codable {
        let userTranscript: String
        let assistantResponse: String
    }

    static func loadConversationHistory() -> [(userTranscript: String, assistantResponse: String)] {
        guard let historyData = try? Data(contentsOf: conversationHistoryFileURL),
              let storedExchanges = try? JSONDecoder().decode([StoredExchange].self, from: historyData) else {
            return []
        }
        return storedExchanges.suffix(maximumStoredExchangeCount).map { storedExchange in
            (userTranscript: storedExchange.userTranscript, assistantResponse: storedExchange.assistantResponse)
        }
    }

    static func saveConversationHistory(_ conversationHistory: [(userTranscript: String, assistantResponse: String)]) {
        let storedExchanges = conversationHistory.suffix(maximumStoredExchangeCount).map { exchange in
            StoredExchange(userTranscript: exchange.userTranscript, assistantResponse: exchange.assistantResponse)
        }
        guard let historyData = try? JSONEncoder().encode(storedExchanges) else { return }
        try? historyData.write(to: conversationHistoryFileURL, options: .atomic)
    }

    static func clearConversationHistory() {
        try? FileManager.default.removeItem(at: conversationHistoryFileURL)
    }
}
