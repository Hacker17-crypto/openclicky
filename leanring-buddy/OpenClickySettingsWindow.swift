//
//  OpenClickySettingsWindow.swift
//  leanring-buddy
//
//  Settings window (opened from the menu bar panel): voice, dictation,
//  agents, memory and general options. A regular titled window, since a
//  menu bar app has no Settings menu item of its own.
//

import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class OpenClickySettingsWindowManager {
    static let shared = OpenClickySettingsWindowManager()

    private var settingsWindow: NSWindow?

    func showSettingsWindow(companionManager: CompanionManager) {
        if settingsWindow == nil {
            let newSettingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 760),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            newSettingsWindow.title = "OpenClicky Settings"
            newSettingsWindow.isReleasedWhenClosed = false
            newSettingsWindow.contentView = NSHostingView(
                rootView: OpenClickySettingsView(companionManager: companionManager)
            )
            newSettingsWindow.center()
            settingsWindow = newSettingsWindow
        }

        // Menu bar apps aren't active by default; bring the window to the front.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct OpenClickySettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var settings = OpenClickySettings.shared

    @State private var personalDictionaryDraftText: String = OpenClickySettings.shared.personalDictionaryWords.joined(separator: ", ")
    @State private var hasConfirmedClearConversation = false

    private let voicePreviewClient = LocalSpeechTTSClient()

    var body: some View {
        Form {
            generalSection
            transcriptionSection
            voiceSection
            dictationSection
            agentsSection
            memorySection
            shortcutsSection
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 760)
        .onAppear { TranscriptionEngineCatalog.shared.refresh() }
    }

    // MARK: General

    private var generalSection: some View {
        Section("General") {
            LabeledContent("Claude Code") {
                switch companionManager.isClaudeCodeCLIInstalled {
                case .some(true):
                    Label("Found", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                case .some(false):
                    HStack {
                        Label("Not found", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Button("Re-check") { companionManager.refreshClaudeCodeCLIAvailability() }
                    }
                case .none:
                    Text("Checking...").foregroundColor(.secondary)
                }
            }

            Picker("Talk model", selection: Binding(
                get: { companionManager.selectedModel },
                set: { companionManager.setSelectedModel($0) }
            )) {
                Text("Haiku (fastest)").tag("haiku")
                Text("Sonnet").tag("sonnet")
                Text("Opus (smartest)").tag("opus")
            }

            Button("Watch onboarding again") { companionManager.replayOnboarding() }
        }
    }

    // MARK: Transcription

    private var transcriptionSection: some View {
        Section {
            TranscriptionEngineChooserView(presentation: .settingsSection) {
                TranscriptionEngineCatalog.shared.hasUserChosenEngine = true
                companionManager.buddyDictationManager.reloadTranscriptionProvider()
            }
            .padding(.vertical, 4)
        } header: {
            Text("Transcription")
        } footer: {
            Text("Now using: \(companionManager.buddyDictationManager.transcriptionProviderDisplayName). Changes apply on your next press.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Voice

    private var voiceSection: some View {
        Section("Voice") {
            HStack {
                Picker("Voice", selection: $settings.localSpeechVoiceIdentifier) {
                    Text("Best installed voice").tag("")
                    ForEach(LocalSpeechTTSClient.installedEnglishVoices(), id: \.identifier) { installedVoice in
                        Text(Self.voiceMenuTitle(installedVoice)).tag(installedVoice.identifier)
                    }
                }
                Button {
                    voicePreviewClient.previewVoice(identifier: settings.localSpeechVoiceIdentifier)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Preview this voice")
            }

            LabeledContent("Speed") {
                HStack {
                    Slider(value: $settings.speechRateMultiplier, in: 0.5...1.5, step: 0.05)
                    Text(String(format: "%.2fx", settings.speechRateMultiplier))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }

            Toggle("Show captions while OpenClicky talks", isOn: $settings.showsCaptionsWhileTalking)

            Text("Nicer voices: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, then download a Premium or Enhanced voice.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private static func voiceMenuTitle(_ installedVoice: AVSpeechSynthesisVoice) -> String {
        let qualityName: String
        switch installedVoice.quality {
        case .premium: qualityName = " (Premium)"
        case .enhanced: qualityName = " (Enhanced)"
        default: qualityName = ""
        }
        return "\(installedVoice.name)\(qualityName) — \(installedVoice.language)"
    }

    // MARK: Dictation

    private var dictationSection: some View {
        Section("Dictation") {
            Toggle("Hold Fn + Control to dictate into any app", isOn: $settings.isDictationEnabled)
            Toggle("Polish dictated text with Claude", isOn: $settings.polishesDictationWithClaude)
                .help("Fixes punctuation, removes filler words and applies self-corrections. Adds a couple of seconds.")

            VStack(alignment: .leading, spacing: 4) {
                Text("Personal dictionary")
                TextField("Names, jargon, product names (comma separated)", text: $personalDictionaryDraftText)
                    .onSubmit(savePersonalDictionary)
                Text("Helps speech recognition get these words right. Press Return to save.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Double-tap Fn + Control for hands-free dictation; press again to finish. Start with \"draft a reply saying...\" and OpenClicky writes it from what's on screen.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func savePersonalDictionary() {
        settings.personalDictionaryWords = personalDictionaryDraftText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Agents

    private var agentsSection: some View {
        Section("Agents") {
            Picker("Permissions", selection: $settings.agentApprovalMode) {
                ForEach(AgentApprovalMode.allCases) { approvalMode in
                    Text(approvalMode.displayName).tag(approvalMode)
                }
            }

            if settings.agentApprovalMode == .alwaysApprove {
                Text("Agents can edit files and run commands without asking. Only use this if you trust what you ask them to do.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if !settings.alwaysAllowedAgentToolNames.isEmpty {
                LabeledContent("Always allowed") {
                    HStack {
                        Text(settings.alwaysAllowedAgentToolNames.sorted().joined(separator: ", "))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        Button("Reset") { settings.alwaysAllowedAgentToolNames = [] }
                    }
                }
            }

            Button("Open agents folder") {
                let agentsRootDirectory = OpenClickyAgentManager.agentsRootDirectory
                try? FileManager.default.createDirectory(at: agentsRootDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(agentsRootDirectory)
            }

            Text("Say \"agent, ...\" or just ask OpenClicky to do something. Agents run Claude Code with its full toolset, plus any MCP servers you've added to Claude Code (Gmail, Notion, Linear and so on).")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        Section("Memory") {
            Toggle("Remember me and our conversation", isOn: $settings.isMemoryEnabled)

            HStack {
                Button("Open PROFILE.md") { OpenClickyMemoryStore.openProfileInDefaultEditor() }
                Button(hasConfirmedClearConversation ? "Cleared" : "Clear conversation") {
                    companionManager.clearConversationHistory()
                    hasConfirmedClearConversation = true
                }
                .disabled(hasConfirmedClearConversation)
            }

            Text("PROFILE.md holds facts OpenClicky has learned about you (edit freely). Conversation history keeps the last 40 messages.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        Section("Shortcuts") {
            LabeledContent("Talk", value: "Hold Control + Option")
            LabeledContent("Draw on screen", value: "Hold Control + Option and drag")
            LabeledContent("Agent", value: "Hold Control + Option, say \"agent, ...\"")
            LabeledContent("Dictate", value: "Hold Fn + Control")
            LabeledContent("Hands-free dictation", value: "Double-tap Fn + Control")
        }
    }
}
