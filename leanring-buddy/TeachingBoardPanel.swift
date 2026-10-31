//
//  TeachingBoardPanel.swift
//  leanring-buddy
//
//  The teaching board: a whiteboard panel that fills in live while Claude
//  writes a <board> block (worked steps, math, code, diagrams, the answer
//  and a check). It stays on screen for follow-up questions until the user
//  closes it (× or Escape) or a new board replaces it.
//
//  Rendering lives in TeachingBoard.html (bundled). This file owns the
//  floating panel, streams text into window.updateBoard(text, isComplete),
//  and resizes/moves the panel when the page asks.
//

import AppKit
import WebKit

// MARK: - Parsing

enum TeachingBoardParser {
    /// The board text written so far (from "<board" to "</board>" or the end), or nil if none has started.
    static func streamingBoardText(in responseText: String) -> String? {
        guard let boardStart = responseText.range(of: "<board", options: .caseInsensitive) else { return nil }
        let textFromBoardStart = responseText[boardStart.lowerBound...]
        if let boardEnd = textFromBoardStart.range(of: "</board>", options: .caseInsensitive) {
            return String(textFromBoardStart[..<boardEnd.upperBound])
        }
        return String(textFromBoardStart)
    }

    /// Removes the board block (complete or cut off) so it's never spoken or parsed for tags.
    static func extractBoard(from responseText: String) -> (textWithoutBoard: String, boardText: String?) {
        guard let boardText = streamingBoardText(in: responseText),
              let boardRange = responseText.range(of: boardText) else {
            return (responseText, nil)
        }
        var textWithoutBoard = responseText
        textWithoutBoard.removeSubrange(boardRange)
        return (textWithoutBoard.trimmingCharacters(in: .whitespacesAndNewlines), boardText)
    }

    /// A compact version of the board for conversation history, so follow-ups like
    /// "why step 2?" have the board's content as context.
    static func summaryForConversationHistory(_ boardText: String) -> String {
        let condensedBoardText = boardText
            .replacingOccurrences(of: #"<svg[\s\S]*?</svg>"#, with: "[diagram]", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n"#, with: "\n", options: .regularExpression)
        return "[board you showed:\n" + String(condensedBoardText.prefix(1800)) + "\n]"
    }
}

// MARK: - Panel

/// Accepts the first click even though the panel never becomes key, so buttons and
/// scrolling work without the user's app losing focus.
private final class FirstClickWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class TeachingBoardHostPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TeachingBoardPanelManager: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var boardPanel: TeachingBoardHostPanel?
    private var boardWebView: FirstClickWebView?
    private var isPageLoaded = false
    private var pendingBoardText: String?
    private var pendingIsComplete = false
    private var isUpdateScheduled = false

    private let panelWidth: CGFloat = 500
    private let screenEdgeMargin: CGFloat = 18

    var isShowingBoard: Bool { boardPanel?.isVisible == true }

    /// Opens a fresh, empty board on the screen the user is working on (replacing any old board).
    /// It goes on the side away from the cursor so it doesn't cover what's being explained.
    func beginNewBoard(nearScreenPoint focusPoint: CGPoint, preferLeftSide: Bool = false) {
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(focusPoint) }) ?? NSScreen.main
        guard let visibleFrame = targetScreen?.visibleFrame else { return }

        createPanelIfNeeded()
        guard let boardPanel, let boardWebView else { return }

        let isCursorOnRightSide = focusPoint.x > visibleFrame.midX
        let shouldPlaceOnLeft = preferLeftSide || isCursorOnRightSide
        let initialHeight: CGFloat = 160
        let originX = shouldPlaceOnLeft ? visibleFrame.minX + screenEdgeMargin : visibleFrame.maxX - panelWidth - screenEdgeMargin
        boardPanel.setFrame(NSRect(x: originX, y: visibleFrame.maxY - initialHeight - screenEdgeMargin, width: panelWidth, height: initialHeight), display: true)

        isPageLoaded = false
        pendingBoardText = nil
        if let templateURL = Bundle.main.url(forResource: "TeachingBoard", withExtension: "html") {
            boardWebView.loadFileURL(templateURL, allowingReadAccessTo: templateURL.deletingLastPathComponent())
        }

        boardPanel.alphaValue = 1
        boardPanel.orderFrontRegardless()
    }

    /// Streams the board text so far. Updates are coalesced to ~12 per second.
    func updateBoard(boardText: String, isComplete: Bool) {
        pendingBoardText = boardText
        pendingIsComplete = pendingIsComplete || isComplete
        guard isPageLoaded, !isUpdateScheduled else { return }
        isUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.flushPendingBoardUpdate()
        }
    }

    private func flushPendingBoardUpdate() {
        isUpdateScheduled = false
        guard let boardWebView, let pendingBoardText else { return }
        let boardTextLiteral = Self.javaScriptStringLiteral(pendingBoardText)
        boardWebView.evaluateJavaScript("window.updateBoard(\(boardTextLiteral), \(pendingIsComplete ? "true" : "false"))")
    }

    func closeBoard() {
        guard let boardPanel, boardPanel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ animationContext in
            animationContext.duration = 0.2
            boardPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.boardPanel?.orderOut(nil)
                self?.boardPanel?.alphaValue = 1
            }
        })
    }

    private func createPanelIfNeeded() {
        guard boardPanel == nil else { return }

        let newBoardPanel = TeachingBoardHostPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newBoardPanel.isFloatingPanel = true
        newBoardPanel.level = .floating
        newBoardPanel.isOpaque = false
        newBoardPanel.backgroundColor = .clear
        newBoardPanel.hasShadow = false
        newBoardPanel.hidesOnDeactivate = false
        newBoardPanel.isReleasedWhenClosed = false
        newBoardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.userContentController.add(WeakTeachingBoardMessageHandler(target: self), name: "openclicky")
        let newBoardWebView = FirstClickWebView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 160), configuration: webViewConfiguration)
        newBoardWebView.setValue(false, forKey: "drawsBackground")
        newBoardWebView.autoresizingMask = [.width, .height]
        newBoardWebView.navigationDelegate = self
        newBoardPanel.contentView = newBoardWebView

        boardPanel = newBoardPanel
        boardWebView = newBoardWebView
    }

    // MARK: Page → app messages

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        if pendingBoardText != nil {
            updateBoard(boardText: pendingBoardText ?? "", isComplete: pendingIsComplete)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let messageText = message.body as? String, let boardPanel else { return }

        if messageText == "close" {
            closeBoard()
        } else if messageText.hasPrefix("height:"), let contentHeight = Double(messageText.dropFirst("height:".count)) {
            resizePanelKeepingTopEdge(toContentHeight: CGFloat(contentHeight) + 20)
        } else if messageText.hasPrefix("drag:") {
            let dragDeltas = messageText.dropFirst("drag:".count).split(separator: ",").compactMap { Double($0) }
            guard dragDeltas.count == 2 else { return }
            var panelFrame = boardPanel.frame
            panelFrame.origin.x += CGFloat(dragDeltas[0])
            panelFrame.origin.y -= CGFloat(dragDeltas[1]) // screen y grows down in the page, up in AppKit
            boardPanel.setFrameOrigin(panelFrame.origin)
        }
    }

    private func resizePanelKeepingTopEdge(toContentHeight requestedHeight: CGFloat) {
        guard let boardPanel else { return }
        let screenVisibleFrame = boardPanel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? boardPanel.frame
        let maximumHeight = screenVisibleFrame.height - screenEdgeMargin * 2
        let newHeight = min(max(requestedHeight, 120), maximumHeight)
        guard abs(newHeight - boardPanel.frame.height) > 1 else { return }

        let topEdge = boardPanel.frame.maxY
        let newFrame = NSRect(x: boardPanel.frame.minX, y: topEdge - newHeight, width: panelWidth, height: newHeight)
        boardPanel.setFrame(newFrame, display: true, animate: false)
    }

    private static func javaScriptStringLiteral(_ text: String) -> String {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: [text]),
              var jsonArrayText = String(data: jsonData, encoding: .utf8) else {
            return "\"\""
        }
        jsonArrayText.removeFirst()
        jsonArrayText.removeLast()
        return jsonArrayText
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakTeachingBoardMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
