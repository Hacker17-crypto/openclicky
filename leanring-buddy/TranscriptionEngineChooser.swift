//
//  TranscriptionEngineChooser.swift
//  leanring-buddy
//
//  "How should OpenClicky hear you?" Lists the speech-to-text engines this
//  Mac can use (detected by TranscriptionEngineCatalog), recommends the
//  best local one, and lets the user pick. Whisper gets inline setup: the
//  Homebrew install command and one-click model downloads.
//
//  Shown as a window on first launch, and embedded in Settings.
//

import AppKit
import SwiftUI

@MainActor
final class TranscriptionEngineChooserWindowManager {
    static let shared = TranscriptionEngineChooserWindowManager()

    private var chooserWindow: NSWindow?

    /// `onEngineConfirmed` runs after the user confirms, so the dictation pipeline can reload.
    func showChooserWindow(onEngineConfirmed: @escaping () -> Void) {
        TranscriptionEngineCatalog.shared.refresh()

        if chooserWindow == nil {
            let newChooserWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newChooserWindow.title = "Choose a voice engine"
            newChooserWindow.titlebarAppearsTransparent = true
            newChooserWindow.isReleasedWhenClosed = false
            newChooserWindow.center()
            chooserWindow = newChooserWindow
        }

        chooserWindow?.contentView = NSHostingView(rootView: TranscriptionEngineChooserView(
            presentation: .firstRunWindow,
            onEngineApplied: { [weak self] in
                TranscriptionEngineCatalog.shared.hasUserChosenEngine = true
                onEngineConfirmed()
                self?.chooserWindow?.close()
            }
        ))

        NSApp.activate(ignoringOtherApps: true)
        chooserWindow?.makeKeyAndOrderFront(nil)
    }
}

struct TranscriptionEngineChooserView: View {
    enum Presentation {
        /// Standalone window with a header and a confirm button.
        case firstRunWindow
        /// Inside Settings: selecting an engine applies it immediately.
        case settingsSection
    }

    let presentation: Presentation
    let onEngineApplied: () -> Void

    @ObservedObject private var catalog = TranscriptionEngineCatalog.shared
    @State private var hasCopiedInstallCommand = false

    private var enginesToShow: [TranscriptionEngine] {
        var engines: [TranscriptionEngine] = [.appleSpeechAnalyzer, .whisperCpp, .appleSpeech]
        if catalog.hasAssemblyAIKey { engines.append(.assemblyAI) }
        if catalog.hasOpenAIKey { engines.append(.openAI) }
        return engines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if presentation == .firstRunWindow {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How should OpenClicky hear you?")
                        .font(.system(size: 22, weight: .bold))
                    Text("On-device engines never upload what you say. OpenClicky found these on your Mac; you can change this anytime in Settings.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 18)
            }

            VStack(spacing: 10) {
                ForEach(enginesToShow) { engine in
                    engineRow(engine)
                }
            }

            if presentation == .firstRunWindow {
                Spacer(minLength: 0)
                HStack {
                    if catalog.isScanning {
                        ProgressView().controlSize(.small)
                        Text("Looking for local models...").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: onEngineApplied) {
                        Text("Use \(catalog.selectedEngine.displayName)")
                            .frame(minWidth: 160)
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!catalog.isEngineReady(catalog.selectedEngine))
                }
            }
        }
        .padding(presentation == .firstRunWindow ? 24 : 0)
        .frame(width: presentation == .firstRunWindow ? 560 : nil)
        .onAppear {
            // Pre-select the recommendation the first time.
            if presentation == .firstRunWindow && !catalog.hasUserChosenEngine {
                catalog.selectedEngine = catalog.recommendedEngine
            }
        }
        .onChange(of: catalog.isScanning) { isScanning in
            if !isScanning && presentation == .firstRunWindow && !catalog.hasUserChosenEngine {
                catalog.selectedEngine = catalog.recommendedEngine
            }
        }
    }

    // MARK: Rows

    private func engineRow(_ engine: TranscriptionEngine) -> some View {
        let isSelected = catalog.selectedEngine == engine
        let isReady = catalog.isEngineReady(engine)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                    }
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(engine.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        if engine == catalog.recommendedEngine {
                            badge("Recommended", color: .accentColor)
                        }
                        badge(engine.isLocal ? "On-device" : "Cloud", color: engine.isLocal ? .green : .orange)
                    }
                    Text(engine.summary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isReady ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(catalog.statusText(for: engine))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(isReady ? .secondary : .orange)
                    }
                }
                Spacer(minLength: 0)
            }

            if isSelected && engine == .whisperCpp {
                whisperSetupSection
                    .padding(.leading, 30)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                catalog.selectedEngine = engine
            }
            if presentation == .settingsSection {
                onEngineApplied()
            }
        }
        .pointerCursor()
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: Whisper Setup

    @ViewBuilder
    private var whisperSetupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if catalog.whisperExecutablePath == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install whisper.cpp with Homebrew, then re-check:")
                        .font(.system(size: 12))
                    HStack(spacing: 8) {
                        Text("brew install whisper-cpp")
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                            .textSelection(.enabled)
                        Button(hasCopiedInstallCommand ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install whisper-cpp", forType: .string)
                            hasCopiedInstallCommand = true
                        }
                        Button("Re-check") { catalog.refresh() }
                    }
                }
            }

            if !catalog.installedWhisperModels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { catalog.selectedWhisperModelPath ?? "" },
                        set: { newModelPath in
                            catalog.selectedWhisperModelPath = newModelPath
                            if presentation == .settingsSection { onEngineApplied() }
                        }
                    )) {
                        ForEach(catalog.installedWhisperModels) { installedModel in
                            Text("\(installedModel.displayName)  ·  \(ByteCountFormatter.string(fromByteCount: installedModel.sizeInBytes, countStyle: .file))")
                                .tag(installedModel.fileURL.path)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(catalog.installedWhisperModels.isEmpty ? "Download a model:" : "Get another model:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(catalog.downloadableWhisperModels.filter { downloadableModel in
                    !catalog.installedWhisperModels.contains { $0.fileURL.lastPathComponent == downloadableModel.fileName }
                }) { downloadableModel in
                    whisperDownloadRow(downloadableModel)
                }
                if let downloadErrorMessage = catalog.downloadErrorMessage {
                    Text(downloadErrorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }

    private func whisperDownloadRow(_ downloadableModel: WhisperDownloadableModel) -> some View {
        let isDownloadingThisModel = catalog.downloadingModelFileName == downloadableModel.fileName

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(downloadableModel.title)  ·  \(downloadableModel.approximateSizeText)")
                    .font(.system(size: 12, weight: .medium))
                Text(downloadableModel.detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isDownloadingThisModel {
                ProgressView(value: catalog.downloadProgressFraction)
                    .frame(width: 90)
                Button("Cancel") { catalog.cancelDownload() }
                    .controlSize(.small)
            } else {
                Button("Download") { catalog.downloadWhisperModel(downloadableModel) }
                    .controlSize(.small)
                    .disabled(catalog.downloadingModelFileName != nil)
            }
        }
    }
}
