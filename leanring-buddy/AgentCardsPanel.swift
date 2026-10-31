//
//  AgentCardsPanel.swift
//  leanring-buddy
//
//  Floating stack of agent cards in the top-right corner of the main
//  screen. Each card shows the agent's name, task, live activity, and the
//  actions that make sense for its state: cancel during the countdown,
//  stop while working, Allow once / Always allow / Not now when it needs
//  approval, and open folder / reply / dismiss when it's done.
//
//  The panel is non-activating (clicking it doesn't steal focus from the
//  user's app) but can become key, so the follow-up text field accepts typing.
//

import AppKit
import Combine
import SwiftUI

/// Borderless panel that may become key so its text field can take input.
private final class AgentCardsHostPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AgentCardsPanelManager {
    private let agentManager: OpenClickyAgentManager
    private var cardsPanel: NSPanel?
    private var hostingView: NSHostingView<AgentCardsStackView>?
    private var agentListCancellable: AnyCancellable?

    private let panelWidth: CGFloat = 340
    private let screenEdgeMargin: CGFloat = 14

    init(agentManager: OpenClickyAgentManager) {
        self.agentManager = agentManager

        // Show the panel while there are agents, hide it when the last one is dismissed,
        // and resize whenever card contents change.
        agentListCancellable = agentManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the change lands; update on the next run loop pass.
                DispatchQueue.main.async {
                    self?.updatePanelVisibilityAndSize()
                }
            }
    }

    private func updatePanelVisibilityAndSize() {
        guard agentManager.hasAnyAgents else {
            cardsPanel?.orderOut(nil)
            return
        }

        createPanelIfNeeded()
        guard let cardsPanel, let hostingView else { return }

        let fittingHeight = min(hostingView.fittingSize.height, (NSScreen.main?.visibleFrame.height ?? 900) - 40)
        guard let mainScreen = NSScreen.main else { return }
        let visibleFrame = mainScreen.visibleFrame
        let panelFrame = NSRect(
            x: visibleFrame.maxX - panelWidth - screenEdgeMargin,
            y: visibleFrame.maxY - fittingHeight - screenEdgeMargin,
            width: panelWidth,
            height: fittingHeight
        )
        cardsPanel.setFrame(panelFrame, display: true)
        hostingView.frame = NSRect(origin: .zero, size: panelFrame.size)

        if !cardsPanel.isVisible {
            cardsPanel.orderFrontRegardless()
        }
    }

    private func createPanelIfNeeded() {
        guard cardsPanel == nil else { return }

        let newPanel = AgentCardsHostPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let newHostingView = NSHostingView(rootView: AgentCardsStackView(agentManager: agentManager))
        newHostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: 200)
        newPanel.contentView = newHostingView

        cardsPanel = newPanel
        hostingView = newHostingView
    }
}

// MARK: - Views

struct AgentCardsStackView: View {
    @ObservedObject var agentManager: OpenClickyAgentManager

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(agentManager.agents) { agent in
                AgentCardView(agent: agent, agentManager: agentManager)
            }

            if agentManager.agents.contains(where: { !$0.status.isActive }) && agentManager.agents.count > 1 {
                Button(action: { agentManager.dismissAllFinishedAgents() }) {
                    Text("Clear finished")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DS.Colors.surface1.opacity(0.92)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(6)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: agentManager.agents.map(\.id))
        .frame(width: 340, alignment: .topTrailing)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AgentCardView: View {
    @ObservedObject var agent: OpenClickyAgent
    let agentManager: OpenClickyAgentManager

    @State private var isShowingFollowUpField = false
    @State private var followUpDraftText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Text(agent.taskDescription)
                .font(.system(size: 11.5))
                .foregroundColor(Color.white.opacity(0.55))
                .lineSpacing(1.5)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            statusBody

            actionButtons
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                // Frosted glass: blur of whatever is behind the card, tinted dark.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.72))
            }
            .environment(\.colorScheme, .dark)
        )
        .overlay(alignment: .bottom) {
            if agent.status == .working {
                AgentWorkingShimmerBar()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(agent.status == .needsApproval ? Color.orange.opacity(0.45) : Color.white.opacity(0.09), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.4), radius: 18, x: 0, y: 8)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity.combined(with: .scale(scale: 0.95))
        ))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(agent.name)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.95))
                .lineLimit(1)

            Spacer()

            TimelineView(.periodic(from: .now, by: 1)) { timelineContext in
                Text(statusLabel(at: timelineContext.date))
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(statusAccentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(statusAccentColor.opacity(0.15)))
            }

            Button(action: { agentManager.dismissAgent(agent) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.55))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(agent.status.isActive ? "Stop and dismiss" : "Dismiss")
        }
    }

    // MARK: Body

    @ViewBuilder
    private var statusBody: some View {
        switch agent.status {
        case .finished:
            if let finalSummaryText = agent.finalSummaryText {
                Text(finalSummaryText)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color.white.opacity(0.85))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !agent.createdFileNames.isEmpty {
                Text(agent.createdFileNames.prefix(4).joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
            }

        case .failed(let failureMessage):
            Text(failureMessage)
                .font(.system(size: 11))
                .foregroundColor(Color(red: 0.95, green: 0.5, blue: 0.5))
                .lineLimit(4)
                .textSelection(.enabled)

        case .needsApproval:
            if let pendingApprovalRequest = agent.pendingApprovalRequest {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pendingApprovalRequest.toolName == "Bash" ? "Wants to run:" : "Wants to:")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.7))
                    Text(pendingApprovalRequest.actionSummary)
                        .font(.system(size: 12, weight: .medium, design: pendingApprovalRequest.toolName == "Bash" ? .monospaced : .default))
                        .foregroundColor(Color.white.opacity(0.95))
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.black.opacity(0.35))
                        )
                }
            }

        default:
            HStack(spacing: 6) {
                if agent.status == .working {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                }
                Text(agent.latestActivityText)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color.white.opacity(0.85))
                    .lineLimit(2)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actionButtons: some View {
        switch agent.status {
        case .startingSoon:
            HStack(spacing: 8) {
                cardButton("Start now", isProminent: true) { agent.startNow() }
                cardButton("Cancel") { agentManager.dismissAgent(agent) }
            }

        case .working:
            HStack(spacing: 8) {
                cardButton("Stop") { agent.stop() }
                cardButton("Open folder") { openWorkspaceFolder() }
            }

        case .needsApproval:
            HStack(spacing: 6) {
                cardButton("Allow once", isProminent: true) { agent.approvePendingRequest(alwaysAllowThisTool: false) }
                cardButton("Always allow") { agent.approvePendingRequest(alwaysAllowThisTool: true) }
                cardButton("Not now") { agent.denyPendingRequest() }
            }

        case .finished:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    cardButton("Open folder", isProminent: true) { openWorkspaceFolder() }
                    cardButton(isShowingFollowUpField ? "Cancel reply" : "Reply") {
                        isShowingFollowUpField.toggle()
                    }
                }
                if isShowingFollowUpField {
                    HStack(spacing: 6) {
                        TextField("Ask a follow-up...", text: $followUpDraftText, onCommit: submitFollowUp)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                        cardButton("Send", isProminent: true) { submitFollowUp() }
                    }
                }
            }

        case .failed, .stopped:
            HStack(spacing: 8) {
                cardButton("Retry", isProminent: true) { agent.retry() }
                cardButton("Open folder") { openWorkspaceFolder() }
            }
        }
    }

    private func submitFollowUp() {
        let followUpText = followUpDraftText
        followUpDraftText = ""
        isShowingFollowUpField = false
        agent.sendFollowUp(followUpText)
    }

    private func openWorkspaceFolder() {
        try? FileManager.default.createDirectory(at: agent.workspaceDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(agent.workspaceDirectory)
    }

    private func cardButton(_ title: String, isProminent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(isProminent ? Color.white : Color.white.opacity(0.82))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isProminent ? DS.Colors.accent : Color.white.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(AgentCardButtonPressStyle())
        .pointerCursor()
    }

    // MARK: Status Styling

    private func statusLabel(at currentDate: Date) -> String {
        switch agent.status {
        case .startingSoon(let secondsRemaining): return "starting in \(secondsRemaining)s"
        case .working:
            let elapsedSeconds = max(0, Int(currentDate.timeIntervalSince(agent.createdAt)))
            return String(format: "working · %d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
        case .needsApproval: return "needs you"
        case .finished: return "done"
        case .failed: return "failed"
        case .stopped: return "stopped"
        }
    }

    private var statusAccentColor: Color {
        switch agent.status {
        case .startingSoon: return Color(white: 0.7)
        case .working: return Color(red: 0.49, green: 0.77, blue: 1.0)
        case .needsApproval: return Color(red: 0.98, green: 0.75, blue: 0.14)
        case .finished: return Color(red: 0.29, green: 0.87, blue: 0.5)
        case .failed: return Color(red: 0.97, green: 0.44, blue: 0.44)
        case .stopped: return Color(white: 0.6)
        }
    }
}

/// Thin light sweep along the bottom edge while an agent works.
private struct AgentWorkingShimmerBar: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timelineContext in
            GeometryReader { geometry in
                let sweepProgress = CGFloat(timelineContext.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6)
                let sweepWidth = geometry.size.width * 0.45
                LinearGradient(
                    colors: [Color.clear, Color(red: 0.49, green: 0.77, blue: 1.0), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: sweepWidth, height: 2)
                .offset(x: -sweepWidth + sweepProgress * (geometry.size.width + sweepWidth))
            }
        }
        .frame(height: 2)
    }
}

/// Slight dim and shrink on press so buttons feel tactile.
private struct AgentCardButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
