//
//  ScreenAnnotations.swift
//  leanring-buddy
//
//  On-screen drawing. Besides [POINT:...], Claude can append drawing,
//  agent and memory tags to a reply:
//
//    [CIRCLE:x,y,radius:label(:screenN)]
//    [HIGHLIGHT:x,y,width,height:label(:screenN)]
//    [UNDERLINE:x1,x2,y:label(:screenN)]
//    [ARROW:x1,y1,x2,y2:label(:screenN)]
//    [LABEL:x,y:text(:screenN)]      callout tag with a leader line to (x,y)
//    [NOTE:x,y:text(:screenN)]       sticky note centered near (x,y)
//    [AGENT:task description]
//    [REMEMBER:fact about the user]
//
//  This file parses those tags out of the reply (so they're never spoken),
//  converts drawing coordinates from screenshot pixels to global screen
//  points, and renders the drawings as hand-drawn strokes in each
//  screen's overlay window. Drawings animate in, linger, then fade out.
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

enum ScreenAnnotationShape: Equatable {
    /// Center and radius in global AppKit coordinates (bottom-left origin).
    case circle(center: CGPoint, radius: CGFloat)
    /// Rectangle in global AppKit coordinates.
    case highlight(rect: CGRect)
    /// Horizontal line in global AppKit coordinates.
    case underline(start: CGPoint, end: CGPoint)
    /// Arrow from start to end in global AppKit coordinates.
    case arrow(start: CGPoint, end: CGPoint)
    /// Callout tag whose leader line ends at `anchor` (global AppKit coordinates).
    case calloutLabel(anchor: CGPoint)
    /// Sticky note placed near `center` (global AppKit coordinates).
    case stickyNote(center: CGPoint)
}

struct ScreenAnnotation: Identifiable, Equatable {
    let id = UUID()
    let shape: ScreenAnnotationShape
    let label: String?
    /// Frame of the display this annotation belongs to (global AppKit coordinates).
    let displayFrame: CGRect
}

/// Everything extracted from one Claude reply, besides the POINT tag.
struct ParsedResponseTags {
    /// Reply text with drawing/agent/memory tags removed (POINT tag still present).
    let textWithoutExtraTags: String
    let drawingRequests: [DrawingRequest]
    let agentTaskDescriptions: [String]
    let factsToRemember: [String]

    /// A drawing tag still in screenshot pixel coordinates.
    struct DrawingRequest {
        enum Kind: String {
            case circle = "CIRCLE"
            case highlight = "HIGHLIGHT"
            case underline = "UNDERLINE"
            case arrow = "ARROW"
            case calloutLabel = "LABEL"
            case stickyNote = "NOTE"
        }

        let kind: Kind
        let numbers: [CGFloat]
        let label: String?
        /// 1-based screen number from `:screenN`, or nil for the cursor's screen.
        let screenNumber: Int?
    }
}

enum ScreenAnnotationTagParser {
    /// Extracts drawing, agent and memory tags from anywhere in the reply.
    static func parseExtraTags(from responseText: String) -> ParsedResponseTags {
        var remainingText = responseText
        var drawingRequests: [ParsedResponseTags.DrawingRequest] = []
        var agentTaskDescriptions: [String] = []
        var factsToRemember: [String] = []

        // [AGENT:...] and [REMEMBER:...] — free text up to the closing bracket.
        agentTaskDescriptions = extractFreeTextTags(named: "AGENT", from: &remainingText)
        factsToRemember = extractFreeTextTags(named: "REMEMBER", from: &remainingText)

        // Drawing tags: [KIND:n,n,n(,n):label(:screenN)]
        let drawingTagPattern = #"\[(CIRCLE|HIGHLIGHT|UNDERLINE|ARROW):\s*(-?\d+(?:\.\d+)?(?:\s*,\s*-?\d+(?:\.\d+)?){2,3})(?::([^\]:]*))?(?::screen(\d+))?\]"#
        if let drawingTagRegex = try? NSRegularExpression(pattern: drawingTagPattern, options: [.caseInsensitive]) {
            let fullRange = NSRange(remainingText.startIndex..., in: remainingText)
            let matches = drawingTagRegex.matches(in: remainingText, range: fullRange)

            for match in matches {
                guard let kindRange = Range(match.range(at: 1), in: remainingText),
                      let numbersRange = Range(match.range(at: 2), in: remainingText),
                      let kind = ParsedResponseTags.DrawingRequest.Kind(rawValue: remainingText[kindRange].uppercased()) else {
                    continue
                }

                let numbers = remainingText[numbersRange]
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    .map { CGFloat($0) }

                var label: String?
                if let labelRange = Range(match.range(at: 3), in: remainingText) {
                    let trimmedLabel = remainingText[labelRange].trimmingCharacters(in: .whitespaces)
                    label = trimmedLabel.isEmpty ? nil : trimmedLabel
                }

                var screenNumber: Int?
                if let screenRange = Range(match.range(at: 4), in: remainingText) {
                    screenNumber = Int(remainingText[screenRange])
                }

                let expectedNumberCount: Int
                switch kind {
                case .circle, .underline: expectedNumberCount = 3
                case .highlight, .arrow: expectedNumberCount = 4
                case .calloutLabel, .stickyNote: expectedNumberCount = 2
                }
                guard numbers.count == expectedNumberCount else { continue }

                drawingRequests.append(.init(kind: kind, numbers: numbers, label: label, screenNumber: screenNumber))
            }

            remainingText = drawingTagRegex.stringByReplacingMatches(
                in: remainingText,
                range: NSRange(remainingText.startIndex..., in: remainingText),
                withTemplate: ""
            )
        }

        // Text tags: [LABEL:x,y:text(:screenN)] and [NOTE:x,y:text(:screenN)].
        // The text may contain colons, so only a trailing ":screenN" is treated as a screen number.
        let textTagPattern = #"\[(LABEL|NOTE):\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*:(.+?)(?::screen(\d+))?\]"#
        if let textTagRegex = try? NSRegularExpression(pattern: textTagPattern, options: [.caseInsensitive]) {
            let fullRange = NSRange(remainingText.startIndex..., in: remainingText)
            for match in textTagRegex.matches(in: remainingText, range: fullRange) {
                guard let kindRange = Range(match.range(at: 1), in: remainingText),
                      let xRange = Range(match.range(at: 2), in: remainingText),
                      let yRange = Range(match.range(at: 3), in: remainingText),
                      let textRange = Range(match.range(at: 4), in: remainingText),
                      let kind = ParsedResponseTags.DrawingRequest.Kind(rawValue: remainingText[kindRange].uppercased()),
                      let xValue = Double(remainingText[xRange]),
                      let yValue = Double(remainingText[yRange]) else {
                    continue
                }

                var screenNumber: Int?
                if let screenRange = Range(match.range(at: 5), in: remainingText) {
                    screenNumber = Int(remainingText[screenRange])
                }

                let tagText = remainingText[textRange]
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .trimmingCharacters(in: .whitespaces)
                guard !tagText.isEmpty else { continue }

                drawingRequests.append(.init(
                    kind: kind,
                    numbers: [CGFloat(xValue), CGFloat(yValue)],
                    label: tagText,
                    screenNumber: screenNumber
                ))
            }

            remainingText = textTagRegex.stringByReplacingMatches(
                in: remainingText,
                range: NSRange(remainingText.startIndex..., in: remainingText),
                withTemplate: ""
            )
        }

        // Collapse blank lines left behind by removed tags.
        let cleanedText = remainingText
            .replacingOccurrences(of: #"[ \t]*\n[ \t\n]*"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedResponseTags(
            textWithoutExtraTags: cleanedText,
            drawingRequests: Array(drawingRequests.prefix(8)),
            agentTaskDescriptions: agentTaskDescriptions,
            factsToRemember: factsToRemember
        )
    }

    /// Finds `[NAME:anything]` tags, returns their contents and removes them from the text.
    private static func extractFreeTextTags(named tagName: String, from text: inout String) -> [String] {
        // Ends at the first "]" that is followed by another tag or the end of the
        // reply, so task descriptions may themselves contain brackets.
        let freeTextTagPattern = "\\[\(tagName):(.+?)\\](?=\\s*(?:\\[|$))"
        guard let freeTextTagRegex = try? NSRegularExpression(
            pattern: freeTextTagPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let fullRange = NSRange(text.startIndex..., in: text)
        let tagContents = freeTextTagRegex.matches(in: text, range: fullRange).compactMap { match -> String? in
            guard let contentRange = Range(match.range(at: 1), in: text) else { return nil }
            let trimmedContent = text[contentRange].trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedContent.isEmpty ? nil : trimmedContent
        }

        text = freeTextTagRegex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
        return tagContents
    }
}

// MARK: - Coordinate Conversion

extension CompanionScreenCapture {
    /// Converts a point in this screenshot's pixel space (top-left origin) to
    /// global AppKit screen coordinates (bottom-left origin), clamped to the display.
    func globalAppKitPoint(fromScreenshotPixelPoint screenshotPixelPoint: CGPoint) -> CGPoint {
        let screenshotWidth = CGFloat(screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenshotHeightInPixels)
        let displayWidth = CGFloat(displayWidthInPoints)
        let displayHeight = CGFloat(displayHeightInPoints)

        let clampedX = max(0, min(screenshotPixelPoint.x, screenshotWidth))
        let clampedY = max(0, min(screenshotPixelPoint.y, screenshotHeight))

        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        return CGPoint(x: displayLocalX + displayFrame.origin.x, y: appKitY + displayFrame.origin.y)
    }

    /// Scales a length (e.g. a radius) from screenshot pixels to display points.
    func displayPointLength(fromScreenshotPixelLength screenshotPixelLength: CGFloat) -> CGFloat {
        screenshotPixelLength * (CGFloat(displayWidthInPoints) / CGFloat(screenshotWidthInPixels))
    }
}

enum ScreenAnnotationFactory {
    /// Turns parsed drawing tags into screen annotations, picking the right capture
    /// for each (explicit :screenN, otherwise the screen the cursor is on).
    static func makeAnnotations(
        from drawingRequests: [ParsedResponseTags.DrawingRequest],
        screenCaptures: [CompanionScreenCapture]
    ) -> [ScreenAnnotation] {
        drawingRequests.compactMap { drawingRequest in
            let targetScreenCapture: CompanionScreenCapture? = {
                if let screenNumber = drawingRequest.screenNumber,
                   screenNumber >= 1 && screenNumber <= screenCaptures.count {
                    return screenCaptures[screenNumber - 1]
                }
                return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
            }()
            guard let targetScreenCapture else { return nil }

            let numbers = drawingRequest.numbers
            let shape: ScreenAnnotationShape

            switch drawingRequest.kind {
            case .circle:
                let center = targetScreenCapture.globalAppKitPoint(fromScreenshotPixelPoint: CGPoint(x: numbers[0], y: numbers[1]))
                let radius = max(14, targetScreenCapture.displayPointLength(fromScreenshotPixelLength: numbers[2]))
                shape = .circle(center: center, radius: radius)

            case .highlight:
                let topLeft = targetScreenCapture.globalAppKitPoint(fromScreenshotPixelPoint: CGPoint(x: numbers[0], y: numbers[1]))
                let bottomRight = targetScreenCapture.globalAppKitPoint(
                    fromScreenshotPixelPoint: CGPoint(x: numbers[0] + numbers[2], y: numbers[1] + numbers[3])
                )
                // AppKit y grows upward, so the screenshot's bottom edge has the smaller y.
                let highlightRect = CGRect(
                    x: min(topLeft.x, bottomRight.x),
                    y: min(topLeft.y, bottomRight.y),
                    width: abs(bottomRight.x - topLeft.x),
                    height: abs(bottomRight.y - topLeft.y)
                )
                shape = .highlight(rect: highlightRect)

            case .underline:
                let start = targetScreenCapture.globalAppKitPoint(fromScreenshotPixelPoint: CGPoint(x: numbers[0], y: numbers[2]))
                let end = targetScreenCapture.globalAppKitPoint(fromScreenshotPixelPoint: CGPoint(x: numbers[1], y: numbers[2]))
                shape = .underline(start: start, end: end)

            case .arrow:
                let start = targetScreenCapture.globalAppKitPoint(fromScreenshotPixelPoint: CGPoint(x: numbers[0], y: numbers[1]))
                let end = targetScreenCapture.globalAppKitPoint(fromScreenshotPixelPoint: CGPoint(x: numbers[2], y: numbers[3]))
                shape = .arrow(start: start, end: end)

            case .calloutLabel:
                let anchor = targetScreenCapture.globalAppKitPoint(fromScreenshotPixelPoint: CGPoint(x: numbers[0], y: numbers[1]))
                shape = .calloutLabel(anchor: anchor)

            case .stickyNote:
                let center = targetScreenCapture.globalAppKitPoint(fromScreenshotPixelPoint: CGPoint(x: numbers[0], y: numbers[1]))
                shape = .stickyNote(center: center)
            }

            return ScreenAnnotation(shape: shape, label: drawingRequest.label, displayFrame: targetScreenCapture.displayFrame)
        }
    }
}

// MARK: - Overlay Rendering

/// Shared timing so every drawing feels like it comes from the same pen.
enum OpenClickyDrawingTiming {
    /// Pause between consecutive drawings, like a person moving the pen to the next spot.
    static let staggerBetweenDrawings: Double = 0.38

    /// Pen speed: longer strokes take longer, within limits.
    static func strokeDuration(forApproximateLength approximateLength: CGFloat) -> Double {
        min(1.0, max(0.35, 0.25 + Double(approximateLength) / 1400))
    }

    /// Quick start, gentle landing: how a confident marker stroke moves.
    static func penAnimation(duration: Double) -> Animation {
        .timingCurve(0.45, 0.05, 0.2, 1.0, duration: duration)
    }
}

/// Draws the user's ink and the current annotations that belong to one screen.
/// Lives inside that screen's click-through overlay window (see BlueCursorView).
struct ScreenAnnotationLayerView: View {
    @ObservedObject var companionManager: CompanionManager
    let screenFrame: CGRect

    var body: some View {
        ZStack {
            // What the user drew while holding the talk shortcut (drawn live, no animation).
            ForEach(Array(userInkStrokesOnThisScreen.enumerated()), id: \.offset) { _, inkStrokeLocalPoints in
                FeltTipStrokeView(
                    strokePath: UserInkStrokeShape(localPoints: inkStrokeLocalPoints).path(in: .zero),
                    inkColor: OpenClickyInkStyle.userInkColor,
                    coreLineWidth: 4
                )
            }

            ForEach(Array(annotationsOnThisScreen.enumerated()), id: \.element.id) { annotationIndex, screenAnnotation in
                let appearanceDelay = Double(annotationIndex) * OpenClickyDrawingTiming.staggerBetweenDrawings
                Group {
                    switch screenAnnotation.shape {
                    case .calloutLabel(let globalAnchor):
                        CalloutLabelAnnotationView(
                            labelText: screenAnnotation.label ?? "",
                            anchorPoint: convertGlobalPointToLocal(globalAnchor),
                            screenSize: screenFrame.size,
                            paletteIndex: annotationIndex,
                            appearanceDelay: appearanceDelay
                        )
                    case .stickyNote(let globalCenter):
                        StickyNoteAnnotationView(
                            noteText: screenAnnotation.label ?? "",
                            centerPoint: convertGlobalPointToLocal(globalCenter),
                            screenSize: screenFrame.size,
                            appearanceDelay: appearanceDelay
                        )
                    default:
                        HandDrawnAnnotationView(
                            screenAnnotation: screenAnnotation,
                            screenFrame: screenFrame,
                            appearanceDelay: appearanceDelay
                        )
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .allowsHitTesting(false)
    }

    private func convertGlobalPointToLocal(_ globalPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: globalPoint.x - screenFrame.origin.x,
            y: (screenFrame.origin.y + screenFrame.height) - globalPoint.y
        )
    }

    private var userInkStrokesOnThisScreen: [[CGPoint]] {
        companionManager.userInkStrokes
            .filter { inkStroke in
                guard let firstInkPoint = inkStroke.first else { return false }
                return screenFrame.contains(firstInkPoint)
            }
            .map { inkStroke in inkStroke.map(convertGlobalPointToLocal) }
    }

    private var annotationsOnThisScreen: [ScreenAnnotation] {
        companionManager.activeScreenAnnotations.filter { screenAnnotation in
            screenAnnotation.displayFrame == screenFrame
                || screenFrame.contains(CGPoint(x: screenAnnotation.displayFrame.midX, y: screenAnnotation.displayFrame.midY))
        }
    }
}

/// A marker stroke with real-ink texture: a soft bleed underneath, the solid
/// core, and a thin sheen on top. `drawProgress` trims it for the draw-in animation.
private struct FeltTipStrokeView: View {
    let strokePath: Path
    let inkColor: Color
    var coreLineWidth: CGFloat = 3.4
    var drawProgress: CGFloat = 1

    var body: some View {
        ZStack {
            strokePath
                .trimmedPath(from: 0, to: drawProgress)
                .stroke(inkColor.opacity(0.22), style: StrokeStyle(lineWidth: coreLineWidth * 3, lineCap: .round, lineJoin: .round))
                .blur(radius: 1.5)
            strokePath
                .trimmedPath(from: 0, to: drawProgress)
                .stroke(inkColor, style: StrokeStyle(lineWidth: coreLineWidth, lineCap: .round, lineJoin: .round))
                .shadow(color: Color.black.opacity(0.28), radius: 1.5, x: 0, y: 1)
            strokePath
                .trimmedPath(from: 0, to: drawProgress)
                .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: max(0.8, coreLineWidth * 0.28), lineCap: .round, lineJoin: .round))
                .offset(x: -0.6, y: -0.7)
        }
    }
}

/// Animates `drawProgress` frame by frame so the felt-tip trim and the pen nib
/// travel along the path together (plain state interpolation can't follow a curve).
private struct AnimatedPenStroke: View, Animatable {
    let strokePath: Path
    let inkColor: Color
    var drawProgress: CGFloat

    // nonisolated: SwiftUI drives animation through the Animatable protocol outside
    // the main-actor default this project uses.
    nonisolated var animatableData: CGFloat {
        get { drawProgress }
        set { drawProgress = newValue }
    }

    var body: some View {
        ZStack {
            FeltTipStrokeView(strokePath: strokePath, inkColor: inkColor, drawProgress: drawProgress)

            // Glowing pen tip while the stroke is being drawn.
            if drawProgress > 0.002 && drawProgress < 0.995,
               let nibPoint = strokePath.trimmedPath(from: 0, to: drawProgress).currentPoint {
                Circle()
                    .fill(Color.white)
                    .frame(width: 7, height: 7)
                    .shadow(color: inkColor, radius: 6)
                    .shadow(color: inkColor.opacity(0.6), radius: 12)
                    .position(nibPoint)
            }
        }
    }
}

/// Circles, highlights, underlines and arrows, drawn in with a pen motion.
private struct HandDrawnAnnotationView: View {
    let screenAnnotation: ScreenAnnotation
    let screenFrame: CGRect
    let appearanceDelay: Double

    @State private var strokeDrawProgress: CGFloat = 0
    @State private var highlightSweepProgress: CGFloat = 0
    @State private var labelAppearanceProgress: CGFloat = 0

    private let markerColor = OpenClickyInkStyle.claudeMarkerColor

    var body: some View {
        ZStack {
            if case .highlight(let globalRect) = screenAnnotation.shape {
                let localRect = convertGlobalRectToLocal(globalRect).insetBy(dx: -6, dy: -4)
                // Highlighter wash sweeping left to right.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(markerColor.opacity(0.24))
                    .frame(width: localRect.width, height: localRect.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: localRect.width * highlightSweepProgress)
                    }
                    .position(x: localRect.midX, y: localRect.midY)
            }

            AnimatedPenStroke(strokePath: annotationStrokePath, inkColor: markerColor, drawProgress: strokeDrawProgress)

            if let label = screenAnnotation.label, !label.isEmpty {
                Text(label)
                    .font(handwrittenFont(size: 15))
                    .foregroundColor(Color(red: 0.16, green: 0.13, blue: 0.04))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(markerColor)
                            .shadow(color: Color.black.opacity(0.28), radius: 4, x: 0, y: 2)
                    )
                    .fixedSize()
                    .rotationEffect(.degrees(-2 - 4 * Double(1 - labelAppearanceProgress)))
                    .scaleEffect(0.6 + 0.4 * labelAppearanceProgress)
                    .opacity(Double(labelAppearanceProgress))
                    .position(labelPosition)
            }
        }
        .onAppear {
            let strokeDuration = OpenClickyDrawingTiming.strokeDuration(forApproximateLength: approximateStrokeLength)
            withAnimation(OpenClickyDrawingTiming.penAnimation(duration: strokeDuration).delay(appearanceDelay)) {
                strokeDrawProgress = 1
            }
            withAnimation(.easeOut(duration: strokeDuration * 0.9).delay(appearanceDelay + strokeDuration * 0.35)) {
                highlightSweepProgress = 1
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.6).delay(appearanceDelay + strokeDuration * 0.8)) {
                labelAppearanceProgress = 1
            }
        }
    }

    // MARK: Geometry

    private func convertGlobalPointToLocal(_ globalPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: globalPoint.x - screenFrame.origin.x,
            y: (screenFrame.origin.y + screenFrame.height) - globalPoint.y
        )
    }

    private func convertGlobalRectToLocal(_ globalRect: CGRect) -> CGRect {
        let localTopLeft = convertGlobalPointToLocal(CGPoint(x: globalRect.minX, y: globalRect.maxY))
        return CGRect(x: localTopLeft.x, y: localTopLeft.y, width: globalRect.width, height: globalRect.height)
    }

    /// Small deterministic wobble so strokes look hand-drawn rather than vector-perfect.
    private func wobble(_ index: Int, amplitude: CGFloat) -> CGFloat {
        let seed = Double(abs(screenAnnotation.id.hashValue % 997)) + Double(index) * 1.7
        return CGFloat(sin(seed)) * amplitude
    }

    /// Rough on-screen length, used to pace the pen.
    private var approximateStrokeLength: CGFloat {
        switch screenAnnotation.shape {
        case .circle(_, let radius):
            return 2 * .pi * radius * 1.15
        case .highlight(let globalRect):
            return 2 * (globalRect.width + globalRect.height)
        case .underline(let globalStart, let globalEnd), .arrow(let globalStart, let globalEnd):
            return hypot(globalEnd.x - globalStart.x, globalEnd.y - globalStart.y) + 40
        case .calloutLabel, .stickyNote:
            return 0
        }
    }

    private var annotationStrokePath: Path {
        switch screenAnnotation.shape {
        case .circle(let globalCenter, let radius):
            let center = convertGlobalPointToLocal(globalCenter)
            return Path { path in
                // A loose loop that overshoots its start, like a quick marker circle.
                let segmentCount = 56
                let totalSweepRadians = 2 * Double.pi * 1.12
                let startAngleRadians = -Double.pi * 0.65
                for segmentIndex in 0...segmentCount {
                    let segmentProgress = Double(segmentIndex) / Double(segmentCount)
                    let angleRadians = startAngleRadians + segmentProgress * totalSweepRadians
                    let wobbledRadius = radius * (1.0 + 0.07 * CGFloat(segmentProgress)) + wobble(segmentIndex / 8, amplitude: 1.6)
                    let point = CGPoint(
                        x: center.x + wobbledRadius * 1.15 * CGFloat(cos(angleRadians)),
                        y: center.y + wobbledRadius * CGFloat(sin(angleRadians))
                    )
                    if segmentIndex == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }

        case .highlight(let globalRect):
            let localRect = convertGlobalRectToLocal(globalRect).insetBy(dx: -6, dy: -4)
            return Path { path in
                path.move(to: CGPoint(x: localRect.minX + wobble(1, amplitude: 2), y: localRect.minY))
                path.addLine(to: CGPoint(x: localRect.maxX, y: localRect.minY + wobble(2, amplitude: 2)))
                path.addLine(to: CGPoint(x: localRect.maxX + wobble(3, amplitude: 2), y: localRect.maxY))
                path.addLine(to: CGPoint(x: localRect.minX, y: localRect.maxY + wobble(4, amplitude: 2)))
                path.addLine(to: CGPoint(x: localRect.minX + wobble(5, amplitude: 2), y: localRect.minY - 3))
            }

        case .underline(let globalStart, let globalEnd):
            let start = convertGlobalPointToLocal(globalStart)
            let end = convertGlobalPointToLocal(globalEnd)
            return Path { path in
                // A gentle double-curve, like underlining fast with a marker.
                let underlineY = start.y + 4
                let underlineWidth = end.x - start.x
                path.move(to: CGPoint(x: start.x - 2, y: underlineY))
                path.addCurve(
                    to: CGPoint(x: end.x + 2, y: underlineY - 1),
                    control1: CGPoint(x: start.x + underlineWidth * 0.33, y: underlineY + 4 + wobble(1, amplitude: 1.5)),
                    control2: CGPoint(x: start.x + underlineWidth * 0.66, y: underlineY - 3 + wobble(2, amplitude: 1.5))
                )
            }

        case .arrow(let globalStart, let globalEnd):
            let start = convertGlobalPointToLocal(globalStart)
            let end = convertGlobalPointToLocal(globalEnd)
            return Path { path in
                // Slightly curved shaft, then the head, so the pen draws it in that order.
                let shaftControlPoint = CGPoint(
                    x: (start.x + end.x) / 2 + (end.y - start.y) * 0.12,
                    y: (start.y + end.y) / 2 - (end.x - start.x) * 0.12
                )
                path.move(to: start)
                path.addQuadCurve(to: end, control: shaftControlPoint)

                let arrowAngleRadians = atan2(end.y - shaftControlPoint.y, end.x - shaftControlPoint.x)
                let arrowheadLength: CGFloat = 17
                let arrowheadSpreadRadians: CGFloat = .pi / 7
                path.addLine(to: CGPoint(
                    x: end.x - arrowheadLength * cos(arrowAngleRadians - arrowheadSpreadRadians),
                    y: end.y - arrowheadLength * sin(arrowAngleRadians - arrowheadSpreadRadians)
                ))
                path.move(to: end)
                path.addLine(to: CGPoint(
                    x: end.x - arrowheadLength * cos(arrowAngleRadians + arrowheadSpreadRadians),
                    y: end.y - arrowheadLength * sin(arrowAngleRadians + arrowheadSpreadRadians)
                ))
            }

        case .calloutLabel, .stickyNote:
            // Rendered by their own views (see ScreenAnnotationLayerView).
            return Path()
        }
    }

    private var labelPosition: CGPoint {
        switch screenAnnotation.shape {
        case .circle(let globalCenter, let radius):
            let center = convertGlobalPointToLocal(globalCenter)
            return CGPoint(x: center.x + radius * 0.9, y: center.y + radius + 20)
        case .highlight(let globalRect):
            let localRect = convertGlobalRectToLocal(globalRect)
            return CGPoint(x: localRect.maxX - 30, y: localRect.maxY + 20)
        case .underline(let globalStart, let globalEnd):
            let start = convertGlobalPointToLocal(globalStart)
            let end = convertGlobalPointToLocal(globalEnd)
            return CGPoint(x: (start.x + end.x) / 2, y: start.y + 24)
        case .arrow(let globalStart, _):
            let start = convertGlobalPointToLocal(globalStart)
            return CGPoint(x: start.x, y: start.y - 16)
        case .calloutLabel(let globalAnchor):
            return convertGlobalPointToLocal(globalAnchor)
        case .stickyNote(let globalCenter):
            return convertGlobalPointToLocal(globalCenter)
        }
    }
}

// MARK: - Callout Labels & Sticky Notes

/// macOS ships "Noteworthy" (a handwritten face); fall back to rounded system text.
private func handwrittenFont(size: CGFloat) -> Font {
    if NSFont(name: "Noteworthy-Bold", size: size) != nil {
        return .custom("Noteworthy-Bold", size: size)
    }
    return .system(size: size, weight: .semibold, design: .rounded)
}

/// A pastel tag connected to the thing it names by a thin leader line with a dot,
/// like the "Lift fan" / "22-pin end" callouts. Builds itself in three beats:
/// the dot pops, the line draws out, then the tag springs into place.
private struct CalloutLabelAnnotationView: View {
    let labelText: String
    let anchorPoint: CGPoint
    let screenSize: CGSize
    let paletteIndex: Int
    let appearanceDelay: Double

    @State private var anchorDotProgress: CGFloat = 0
    @State private var leaderLineProgress: CGFloat = 0
    @State private var tagAppearanceProgress: CGFloat = 0

    private static let pastelPalette: [(fill: Color, edge: Color)] = [
        (Color(red: 0.86, green: 0.97, blue: 0.86), Color(red: 0.35, green: 0.75, blue: 0.40)),
        (Color(red: 0.87, green: 0.93, blue: 1.00), Color(red: 0.35, green: 0.55, blue: 0.90)),
        (Color(red: 1.00, green: 0.88, blue: 0.92), Color(red: 0.90, green: 0.40, blue: 0.55)),
        (Color(red: 1.00, green: 0.96, blue: 0.78), Color(red: 0.90, green: 0.72, blue: 0.20))
    ]

    /// Put the tag above and away from the screen center so it doesn't cover the anchor.
    private var labelCenter: CGPoint {
        let horizontalOffset: CGFloat = anchorPoint.x > screenSize.width / 2 ? 46 : -46
        let verticalOffset: CGFloat = anchorPoint.y < 110 ? 72 : -72
        return CGPoint(x: anchorPoint.x + horizontalOffset, y: anchorPoint.y + verticalOffset)
    }

    /// Alternate a slight tilt left/right so a group of labels looks hand-placed.
    private var restingTiltDegrees: Double {
        paletteIndex % 2 == 0 ? -1.5 : 1.5
    }

    var body: some View {
        let palette = Self.pastelPalette[paletteIndex % Self.pastelPalette.count]

        ZStack {
            Path { path in
                path.move(to: anchorPoint)
                path.addLine(to: labelCenter)
            }
            .trimmedPath(from: 0, to: leaderLineProgress)
            .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .shadow(color: Color.black.opacity(0.5), radius: 2)

            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                .frame(width: 9, height: 9)
                .shadow(color: Color.black.opacity(0.35), radius: 2)
                .scaleEffect(anchorDotProgress)
                .position(anchorPoint)

            Text(labelText)
                .font(handwrittenFont(size: 16))
                .foregroundColor(Color(red: 0.12, green: 0.12, blue: 0.14))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(palette.fill)
                        Rectangle().fill(palette.edge).frame(width: 4)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                )
                .shadow(color: Color.black.opacity(0.3), radius: 5, x: 0, y: 3)
                .fixedSize()
                .rotationEffect(.degrees(restingTiltDegrees + 8 * Double(1 - tagAppearanceProgress)))
                .scaleEffect(0.5 + 0.5 * tagAppearanceProgress)
                .opacity(Double(tagAppearanceProgress))
                .position(labelCenter)
        }
        .onAppear {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5).delay(appearanceDelay)) {
                anchorDotProgress = 1
            }
            withAnimation(OpenClickyDrawingTiming.penAnimation(duration: 0.3).delay(appearanceDelay + 0.12)) {
                leaderLineProgress = 1
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.58).delay(appearanceDelay + 0.36)) {
                tagAppearanceProgress = 1
            }
        }
    }
}

/// A yellow sticky note that drops onto the screen and lands slightly askew.
private struct StickyNoteAnnotationView: View {
    let noteText: String
    let centerPoint: CGPoint
    let screenSize: CGSize
    let appearanceDelay: Double

    @State private var landingProgress: CGFloat = 0

    var body: some View {
        Text(noteText)
            .font(handwrittenFont(size: 17))
            .foregroundColor(Color(red: 0.18, green: 0.16, blue: 0.10))
            .multilineTextAlignment(.leading)
            .lineSpacing(2)
            .frame(width: 170, alignment: .topLeading)
            .frame(minHeight: 120, alignment: .topLeading)
            .padding(16)
            .padding(.top, 4)
            .background(
                ZStack(alignment: .top) {
                    StickyNoteBodyShape(foldSize: 26).fill(Color(red: 1.0, green: 0.92, blue: 0.55))
                    // Darker strip where the note's adhesive is
                    Rectangle().fill(Color(red: 0.98, green: 0.86, blue: 0.40)).frame(height: 14)
                    // Curled bottom-right corner
                    StickyNoteFoldShape(foldSize: 26).fill(Color(red: 0.91, green: 0.79, blue: 0.33))
                }
            )
            // The shadow tightens as the note "lands" on the screen.
            .shadow(
                color: Color.black.opacity(0.18 + 0.17 * Double(landingProgress)),
                radius: 22 - 12 * landingProgress,
                x: 2,
                y: 14 - 8 * landingProgress
            )
            .rotationEffect(.degrees(-3 - 9 * Double(1 - landingProgress)))
            .scaleEffect(1.18 - 0.18 * landingProgress)
            .offset(y: -36 * (1 - landingProgress))
            .opacity(Double(min(1, landingProgress * 2.5)))
            .position(clampedCenter)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(appearanceDelay)) {
                    landingProgress = 1
                }
            }
    }

    /// Keep the whole note on screen.
    private var clampedCenter: CGPoint {
        CGPoint(
            x: min(max(centerPoint.x, 120), screenSize.width - 120),
            y: min(max(centerPoint.y, 100), screenSize.height - 100)
        )
    }
}

// MARK: - Ink Style & Shapes

enum OpenClickyInkStyle {
    /// The user's own marks (drawn while holding the talk shortcut): coral, like a felt pen.
    static let userInkColor = Color(red: 1.0, green: 0.42, blue: 0.24)
    static let userInkNSColor = NSColor(red: 1.0, green: 0.42, blue: 0.24, alpha: 1)
    /// Claude's marks: warm gold highlighter, so the two are easy to tell apart.
    static let claudeMarkerColor = Color(red: 0.91, green: 0.72, blue: 0.23)
}

/// A freehand stroke smoothed with quadratic curves through segment midpoints.
private struct UserInkStrokeShape: Shape {
    let localPoints: [CGPoint]

    func path(in rect: CGRect) -> Path {
        Path { path in
            guard let firstPoint = localPoints.first else { return }
            path.move(to: firstPoint)
            if localPoints.count < 3 {
                for point in localPoints.dropFirst() { path.addLine(to: point) }
                return
            }
            for pointIndex in 1..<localPoints.count {
                let previousPoint = localPoints[pointIndex - 1]
                let currentPoint = localPoints[pointIndex]
                let midpoint = CGPoint(x: (previousPoint.x + currentPoint.x) / 2, y: (previousPoint.y + currentPoint.y) / 2)
                path.addQuadCurve(to: midpoint, control: previousPoint)
            }
            if let lastPoint = localPoints.last { path.addLine(to: lastPoint) }
        }
    }
}

/// Sticky note paper with its bottom-right corner cut off (the fold covers it).
private struct StickyNoteBodyShape: Shape {
    let foldSize: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - foldSize))
            path.addLine(to: CGPoint(x: rect.maxX - foldSize, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// The curled-up corner triangle.
private struct StickyNoteFoldShape: Shape {
    let foldSize: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - foldSize))
            path.addLine(to: CGPoint(x: rect.maxX - foldSize, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - foldSize, y: rect.maxY - foldSize))
            path.closeSubpath()
        }
    }
}

// MARK: - Burning Ink Into Screenshots

extension CompanionScreenCapture {
    /// Inverse of globalAppKitPoint(fromScreenshotPixelPoint:): global AppKit point → screenshot pixel (top-left origin).
    func screenshotPixelPoint(fromGlobalAppKitPoint globalPoint: CGPoint) -> CGPoint {
        let horizontalScale = CGFloat(screenshotWidthInPixels) / CGFloat(displayWidthInPoints)
        let verticalScale = CGFloat(screenshotHeightInPixels) / CGFloat(displayHeightInPoints)
        return CGPoint(
            x: (globalPoint.x - displayFrame.minX) * horizontalScale,
            y: (displayFrame.maxY - globalPoint.y) * verticalScale
        )
    }

    /// Returns a copy of this capture with the user's ink strokes drawn onto the image,
    /// so Claude sees exactly what the user circled or pointed at. Our own overlay
    /// windows are excluded from screen capture, which is why this is done by hand.
    func drawingInkStrokes(_ inkStrokesInGlobalAppKitPoints: [[CGPoint]]) -> CompanionScreenCapture {
        let strokesOnThisDisplay = inkStrokesInGlobalAppKitPoints.filter { inkStroke in
            inkStroke.contains(where: { displayFrame.contains($0) })
        }
        guard !strokesOnThisDisplay.isEmpty,
              let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let screenshotImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return self
        }

        let pixelWidth = screenshotImage.width
        let pixelHeight = screenshotImage.height
        guard let drawingContext = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return self
        }

        drawingContext.draw(screenshotImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        drawingContext.setStrokeColor(OpenClickyInkStyle.userInkNSColor.cgColor)
        drawingContext.setLineWidth(max(4, CGFloat(pixelWidth) / 320))
        drawingContext.setLineCap(.round)
        drawingContext.setLineJoin(.round)

        for inkStroke in strokesOnThisDisplay {
            // Screenshot pixels have a top-left origin; CGContext has bottom-left.
            let contextPoints = inkStroke.map { globalPoint -> CGPoint in
                let pixelPoint = screenshotPixelPoint(fromGlobalAppKitPoint: globalPoint)
                return CGPoint(x: pixelPoint.x, y: CGFloat(pixelHeight) - pixelPoint.y)
            }
            guard let firstContextPoint = contextPoints.first else { continue }
            drawingContext.beginPath()
            drawingContext.move(to: firstContextPoint)
            for contextPoint in contextPoints.dropFirst() {
                drawingContext.addLine(to: contextPoint)
            }
            drawingContext.strokePath()
        }

        guard let annotatedImage = drawingContext.makeImage() else { return self }

        let encodedImageData = NSMutableData()
        guard let imageDestination = CGImageDestinationCreateWithData(
            encodedImageData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return self
        }
        CGImageDestinationAddImage(imageDestination, annotatedImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else { return self }

        return CompanionScreenCapture(
            imageData: encodedImageData as Data,
            label: label,
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: displayWidthInPoints,
            displayHeightInPoints: displayHeightInPoints,
            displayFrame: displayFrame,
            screenshotWidthInPixels: screenshotWidthInPixels,
            screenshotHeightInPixels: screenshotHeightInPixels
        )
    }
}
