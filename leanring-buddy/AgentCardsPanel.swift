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
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            statusBody

            actionButtons
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(statusAccentColor.opacity(0.45), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusAccentColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusAccentColor.opacity(0.7), radius: 4)

            Text(agent.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            Text(statusLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: { agentManager.dismissAgent(agent) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
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
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wants to:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(pendingApprovalRequest.actionSummary)
                        .font(.system(size: 12, weight: .medium, design: pendingApprovalRequest.toolName == "Bash" ? .monospaced : .default))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        default:
            HStack(spacing: 6) {
                if agent.status == .working {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                }
                Text(agent.latestActivityText)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isProminent ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isProminent ? DS.Colors.accent : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: Status Styling

    private var statusLabel: String {
        switch agent.status {
        case .startingSoon(let secondsRemaining): return "starting in \(secondsRemaining)s"
        case .working: return "working"
        case .needsApproval: return "needs you"
        case .finished: return "done"
        case .failed: return "failed"
        case .stopped: return "stopped"
        }
    }

    private var statusAccentColor: Color {
        switch agent.status {
        case .startingSoon: return Color.gray
        case .working: return DS.Colors.accent
        case .needsApproval: return Color.orange
        case .finished: return Color.green
        case .failed: return Color.red
        case .stopped: return Color.gray
        }
    }
}
