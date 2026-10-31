//
//  StatusPillPanel.swift
//  leanring-buddy
//
//  A black status pill hanging from the top-center of the screen, in the
//  style of a notch / Dynamic Island. It shows what OpenClicky is doing:
//
//    Listening  (coral dot + live mic waveform)
//    Thinking   (pulsing dots)
//    Speaking   (animated waveform) and expands to show captions
//    "2 agents" badge while background agents are running
//
//  On Macs with a notch, the pill wraps around it: status on the left of
//  the notch, waveform on the right, captions below the menu bar. The panel
//  is click-through and never takes focus.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusPillViewModel: ObservableObject {
    /// Polled from the TTS client, which doesn't publish its playing state.
    @Published var isSpeakingAloud = false
    /// Width of the camera notch on the pill's screen, or 0 when there's none.
    @Published var notchWidth: CGFloat = 0
    /// Height of the menu bar on the pill's screen.
    @Published var menuBarHeight: CGFloat = 32
}

@MainActor
final class StatusPillPanelManager {
    private let companionManager: CompanionManager
    private let statusPillViewModel = StatusPillViewModel()
    private var pillPanel: NSPanel?
    private var speakingPollTimer: Timer?
    private var voiceStateCancellable: AnyCancellable?

    private let panelSize = CGSize(width: 640, height: 240)

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        createPanel()
        moveToScreenWithMouse()

        // Follow the user to whichever screen they're on when they start talking.
        voiceStateCancellable = companionManager.$voiceState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newVoiceState in
                if newVoiceState == .listening {
                    self?.moveToScreenWithMouse()
                }
            }

        speakingPollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isSpeakingNow = self.companionManager.isSpeakingAloud
                if self.statusPillViewModel.isSpeakingAloud != isSpeakingNow {
                    self.statusPillViewModel.isSpeakingAloud = isSpeakingNow
                }
            }
        }
    }

    private func createPanel() {
        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        // Above the menu bar, so the pill can sit in (and around) the notch.
        newPanel.level = .statusBar
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.ignoresMouseEvents = true
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: StatusPillView(
            companionManager: companionManager,
            agentManager: companionManager.agentManager,
            statusPillViewModel: statusPillViewModel
        ))
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        newPanel.contentView = hostingView
        newPanel.orderFrontRegardless()
        pillPanel = newPanel
    }

    private func moveToScreenWithMouse() {
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else { return }

        let screenFrame = targetScreen.frame
        var notchWidth: CGFloat = 0
        if let leftOfNotchArea = targetScreen.auxiliaryTopLeftArea,
           let rightOfNotchArea = targetScreen.auxiliaryTopRightArea {
            notchWidth = max(0, screenFrame.width - leftOfNotchArea.width - rightOfNotchArea.width)
        }
        let menuBarHeight = max(targetScreen.safeAreaInsets.top, screenFrame.maxY - targetScreen.visibleFrame.maxY, 24)

        statusPillViewModel.notchWidth = notchWidth
        statusPillViewModel.menuBarHeight = menuBarHeight

        let panelFrame = NSRect(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
        pillPanel?.setFrame(panelFrame, display: true)
        pillPanel?.orderFrontRegardless()
    }
}

// MARK: - View

private struct StatusPillView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var agentManager: OpenClickyAgentManager
    @ObservedObject var statusPillViewModel: StatusPillViewModel

    private enum PillState: Equatable {
        case hidden
        case listening
        case thinking
        case speaking
        case agentsOnly
    }

    private var pillState: PillState {
        if companionManager.voiceState == .listening { return .listening }
        if statusPillViewModel.isSpeakingAloud || companionManager.currentCaptionText != nil { return .speaking }
        if companionManager.voiceState == .processing { return .thinking }
        if activeAgentCount > 0 { return .agentsOnly }
        return .hidden
    }

    private var activeAgentCount: Int {
        agentManager.agents.filter { $0.status.isActive }.count
    }

    private var captionText: String? {
        guard pillState == .speaking, let currentCaptionText = companionManager.currentCaptionText else { return nil }
        return currentCaptionText
    }

    /// Wide enough to clear the notch with room for content on each side.
    private var pillWidth: CGFloat {
        if captionText != nil { return max(520, statusPillViewModel.notchWidth + 300) }
        return statusPillViewModel.notchWidth > 0 ? statusPillViewModel.notchWidth + 260 : 300
    }

    var body: some View {
        VStack(spacing: 0) {
            if pillState != .hidden {
                pillBody
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.8, anchor: .top).combined(with: .opacity)
                    ))
            }
            Spacer(minLength: 0)
        }
        .frame(width: 640, height: 240, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: pillState)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: captionText)
    }

    private var pillBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                stateIndicator
                Text(stateTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .fixedSize()

                if activeAgentCount > 0 && pillState != .agentsOnly {
                    Text(activeAgentCount == 1 ? "1 agent" : "\(activeAgentCount) agents")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.7))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .fixedSize()
                }

                // Leave the middle empty where the hardware notch is.
                Spacer(minLength: statusPillViewModel.notchWidth > 0 ? statusPillViewModel.notchWidth + 12 : 12)

                trailingActivityIndicator
            }
            .frame(height: max(22, statusPillViewModel.menuBarHeight - 8))

            if let captionText {
                Text(captionText)
                    .font(.system(size: 14.5, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.94))
                    .lineSpacing(3)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(width: pillWidth)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 20,
                bottomTrailingRadius: 20,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
            .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 8)
        )
    }

    private var stateTitle: String {
        switch pillState {
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .agentsOnly: return activeAgentCount == 1 ? "1 agent working" : "\(activeAgentCount) agents working"
        case .hidden: return ""
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch pillState {
        case .listening:
            Circle()
                .fill(OpenClickyInkStyle.userInkColor)
                .frame(width: 8, height: 8)
                .shadow(color: OpenClickyInkStyle.userInkColor.opacity(0.8), radius: 4)
        case .agentsOnly:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .colorScheme(.dark)
        default:
            Triangle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 9, height: 9)
                .rotationEffect(.degrees(-35))
        }
    }

    @ViewBuilder
    private var trailingActivityIndicator: some View {
        switch pillState {
        case .listening:
            PillWaveformView(
                barColor: Color.white,
                liveAudioLevel: companionManager.currentAudioPowerLevel,
                isDrivenByMicrophone: true
            )
        case .speaking:
            PillWaveformView(
                barColor: Color(red: 0.49, green: 0.77, blue: 1.0),
                liveAudioLevel: 0,
                isDrivenByMicrophone: false
            )
        case .thinking:
            PillThinkingDotsView()
        default:
            EmptyView()
        }
    }
}

/// Seven rounded bars. Driven by the mic level while listening, or a gentle
/// synthetic motion while speaking.
private struct PillWaveformView: View {
    let barColor: Color
    let liveAudioLevel: CGFloat
    let isDrivenByMicrophone: Bool

    private let barCount = 7
    private let barShapeWeights: [CGFloat] = [0.45, 0.75, 1.0, 0.65, 0.9, 0.55, 0.7]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timelineContext in
            let elapsedSeconds = timelineContext.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(barColor)
                        .frame(width: 3, height: barHeight(barIndex: barIndex, elapsedSeconds: elapsedSeconds))
                }
            }
            .frame(height: 18)
        }
    }

    private func barHeight(barIndex: Int, elapsedSeconds: TimeInterval) -> CGFloat {
        let wobble = CGFloat((sin(elapsedSeconds * 7.0 + Double(barIndex) * 0.9) + 1) / 2)
        let level: CGFloat
        if isDrivenByMicrophone {
            level = min(1, liveAudioLevel * 1.6) * (0.55 + 0.45 * wobble)
        } else {
            level = 0.35 + 0.65 * wobble
        }
        return max(3, 18 * level * barShapeWeights[barIndex])
    }
}

private struct PillThinkingDotsView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timelineContext in
            let elapsedSeconds = timelineContext.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { dotIndex in
                    let pulse = (sin(elapsedSeconds * 5.0 - Double(dotIndex) * 0.8) + 1) / 2
                    Circle()
                        .fill(Color.white.opacity(0.35 + 0.6 * pulse))
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.8 + 0.3 * pulse)
                }
            }
            .frame(height: 18)
        }
    }
}
