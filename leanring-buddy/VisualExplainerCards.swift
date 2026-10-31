//
//  VisualExplainerCards.swift
//  leanring-buddy
//
//  "Real-time graphics": explainer cards Claude draws on screen while it
//  talks. A reply can contain one block like
//
//    <visual kind="diagram" title="tensors and targets" x="900" y="120" width="520" height="380">
//      <svg viewBox="0 0 520 340">...</svg>
//    </visual>
//
//    <visual kind="3d" title="f-35 lift system" x="..." y="...">
//      const body = addPart(new THREE.Mesh(...), "fuselage"); ...
//    </visual>
//
//  Diagrams render as a hand-drawn whiteboard card on grid paper whose
//  strokes draw themselves in, in document order. 3D visuals run a short
//  three.js script against a prepared scene (lights, orbit controls,
//  addPart/addLabel/addArrow helpers); the user can drag to rotate and
//  click parts. Cards float above other apps without stealing focus and
//  close with their × button or when a new visual replaces them.
//

import AppKit
import WebKit

// MARK: - Parsing

struct VisualExplainerRequest {
    enum Kind: String {
        case diagram
        case threeDimensionalModel = "3d"
    }

    let kind: Kind
    let title: String
    /// Card content: SVG markup for diagrams, JavaScript for 3D.
    let content: String
    /// Requested top-left corner in screenshot pixel coordinates, if given.
    let requestedTopLeftInScreenshotPixels: CGPoint?
    let requestedSizeInPoints: CGSize?
    let screenNumber: Int?
}

enum VisualExplainerParser {
    /// Pulls `<visual ...>...</visual>` blocks out of a reply. Must run before
    /// bracket-tag parsing, since diagrams and code can contain brackets.
    static func extractVisuals(from responseText: String) -> (textWithoutVisuals: String, visualRequests: [VisualExplainerRequest]) {
        let visualBlockPattern = #"<visual\b([^>]*)>(.*?)</visual\s*>"#
        guard let visualBlockRegex = try? NSRegularExpression(
            pattern: visualBlockPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return (responseText, [])
        }

        var visualRequests: [VisualExplainerRequest] = []
        let fullRange = NSRange(responseText.startIndex..., in: responseText)

        for match in visualBlockRegex.matches(in: responseText, range: fullRange) {
            guard let attributesRange = Range(match.range(at: 1), in: responseText),
                  let contentRange = Range(match.range(at: 2), in: responseText) else { continue }

            let attributes = parseAttributes(String(responseText[attributesRange]))
            let content = stripMarkdownCodeFence(String(responseText[contentRange]))
            guard !content.isEmpty else { continue }

            let kind = VisualExplainerRequest.Kind(rawValue: (attributes["kind"] ?? "diagram").lowercased()) ?? .diagram

            var requestedTopLeft: CGPoint?
            if let xText = attributes["x"], let yText = attributes["y"],
               let xValue = Double(xText), let yValue = Double(yText) {
                requestedTopLeft = CGPoint(x: xValue, y: yValue)
            }

            var requestedSize: CGSize?
            if let widthText = attributes["width"], let heightText = attributes["height"],
               let widthValue = Double(widthText), let heightValue = Double(heightText) {
                requestedSize = CGSize(width: widthValue, height: heightValue)
            }

            let screenNumber = attributes["screen"].flatMap { Int($0.replacingOccurrences(of: "screen", with: "")) }

            visualRequests.append(VisualExplainerRequest(
                kind: kind,
                title: attributes["title"] ?? "",
                content: content,
                requestedTopLeftInScreenshotPixels: requestedTopLeft,
                requestedSizeInPoints: requestedSize,
                screenNumber: screenNumber
            ))
        }

        // A reply cut off mid-visual: drop the unfinished block so it isn't spoken.
        var textWithoutVisuals = visualBlockRegex.stringByReplacingMatches(in: responseText, range: fullRange, withTemplate: "")
        if let unfinishedVisualStart = textWithoutVisuals.range(of: "<visual", options: .caseInsensitive) {
            textWithoutVisuals = String(textWithoutVisuals[..<unfinishedVisualStart.lowerBound])
        }

        return (textWithoutVisuals.trimmingCharacters(in: .whitespacesAndNewlines), visualRequests)
    }

    /// The speakable text before a visual starts streaming, or nil if no visual has begun yet.
    /// Lets OpenClicky start talking while the diagram is still being generated.
    static func spokenPrefixBeforeVisual(in partialResponseText: String) -> String? {
        let visualStart = partialResponseText.range(of: "<visual", options: .caseInsensitive)?.lowerBound
        let boardStart = partialResponseText.range(of: "<board", options: .caseInsensitive)?.lowerBound
        guard let firstBlockStart = [visualStart, boardStart].compactMap({ $0 }).min() else { return nil }
        return String(partialResponseText[..<firstBlockStart])
    }

    private static func parseAttributes(_ attributeText: String) -> [String: String] {
        guard let attributeRegex = try? NSRegularExpression(pattern: #"(\w+)\s*=\s*["']([^"']*)["']"#) else { return [:] }
        var attributes: [String: String] = [:]
        let fullRange = NSRange(attributeText.startIndex..., in: attributeText)
        for match in attributeRegex.matches(in: attributeText, range: fullRange) {
            guard let nameRange = Range(match.range(at: 1), in: attributeText),
                  let valueRange = Range(match.range(at: 2), in: attributeText) else { continue }
            attributes[attributeText[nameRange].lowercased()] = String(attributeText[valueRange])
        }
        return attributes
    }

    private static func stripMarkdownCodeFence(_ content: String) -> String {
        var trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.hasPrefix("```") {
            if let firstNewline = trimmedContent.firstIndex(of: "\n") {
                trimmedContent = String(trimmedContent[trimmedContent.index(after: firstNewline)...])
            }
            if trimmedContent.hasSuffix("```") {
                trimmedContent = String(trimmedContent.dropLast(3))
            }
        }
        return trimmedContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Card Panels

/// Floating panel hosting one card. Non-activating so the user's app keeps focus,
/// but it still receives mouse events (drag to rotate 3D, click the × button).
private final class VisualExplainerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class VisualExplainerCardManager: NSObject, WKScriptMessageHandler {
    private var openCardPanels: [VisualExplainerPanel] = []

    /// Shows a card for `visualRequest`, replacing any card already on screen.
    func showVisual(_ visualRequest: VisualExplainerRequest, screenCaptures: [CompanionScreenCapture]) {
        closeAllCards()

        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber = visualRequest.screenNumber, screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
        }()
        let displayFrame = targetScreenCapture?.displayFrame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let defaultSize = visualRequest.kind == .threeDimensionalModel ? CGSize(width: 560, height: 440) : CGSize(width: 540, height: 420)
        let requestedSize = visualRequest.requestedSizeInPoints ?? defaultSize
        let cardSize = CGSize(
            width: min(max(requestedSize.width, 300), min(900, displayFrame.width - 40)),
            height: min(max(requestedSize.height, 220), min(720, displayFrame.height - 60))
        )

        // Top-left in global AppKit coordinates; default to the right side of the screen.
        var cardTopLeft = CGPoint(x: displayFrame.maxX - cardSize.width - 40, y: displayFrame.maxY - 120)
        if let requestedTopLeftInScreenshotPixels = visualRequest.requestedTopLeftInScreenshotPixels,
           let targetScreenCapture {
            cardTopLeft = targetScreenCapture.globalAppKitPoint(fromScreenshotPixelPoint: requestedTopLeftInScreenshotPixels)
        }
        let clampedOriginX = min(max(cardTopLeft.x, displayFrame.minX + 20), displayFrame.maxX - cardSize.width - 20)
        let clampedTopY = min(max(cardTopLeft.y, displayFrame.minY + cardSize.height + 20), displayFrame.maxY - 40)
        let cardFrame = NSRect(x: clampedOriginX, y: clampedTopY - cardSize.height, width: cardSize.width, height: cardSize.height)

        let cardPanel = VisualExplainerPanel(
            contentRect: cardFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        cardPanel.isFloatingPanel = true
        cardPanel.level = .floating
        cardPanel.isOpaque = false
        cardPanel.backgroundColor = .clear
        cardPanel.hasShadow = true
        cardPanel.hidesOnDeactivate = false
        cardPanel.isReleasedWhenClosed = false
        cardPanel.isMovableByWindowBackground = true
        cardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.userContentController.add(WeakScriptMessageHandler(target: self), name: "openclicky")
        let cardWebView = WKWebView(frame: NSRect(origin: .zero, size: cardSize), configuration: webViewConfiguration)
        cardWebView.setValue(false, forKey: "drawsBackground")
        cardWebView.autoresizingMask = [.width, .height]
        cardPanel.contentView = cardWebView

        let cardHTML = VisualExplainerHTMLTemplate.makeHTML(for: visualRequest)
        cardWebView.loadHTMLString(cardHTML, baseURL: URL(string: "https://openclicky.local/"))

        cardPanel.alphaValue = 0
        cardPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = 0.25
            cardPanel.animator().alphaValue = 1
        }

        openCardPanels.append(cardPanel)
        print("🖼️ Visual card: \(visualRequest.kind.rawValue) \"\(visualRequest.title)\"")
    }

    func closeAllCards() {
        for cardPanel in openCardPanels {
            if let cardWebView = cardPanel.contentView as? WKWebView {
                cardWebView.configuration.userContentController.removeScriptMessageHandler(forName: "openclicky")
            }
            cardPanel.orderOut(nil)
            cardPanel.contentView = nil
        }
        openCardPanels.removeAll()
    }

    var hasOpenCards: Bool { !openCardPanels.isEmpty }

    // The card's × button posts "close".
    // WebKit delivers script messages on the main thread.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if (message.body as? String) == "close" {
            closeAllCards()
        }
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - HTML

enum VisualExplainerHTMLTemplate {
    /// JSON-encodes a string for safe embedding inside a <script> tag.
    private static func javaScriptStringLiteral(_ text: String) -> String {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: [text]),
              var jsonArrayText = String(data: jsonData, encoding: .utf8) else {
            return "\"\""
        }
        // Strip the surrounding [ ] and stop "</script>" inside content from closing our tag.
        jsonArrayText.removeFirst()
        jsonArrayText.removeLast()
        return jsonArrayText.replacingOccurrences(of: "</", with: "<\\/")
    }

    static func makeHTML(for visualRequest: VisualExplainerRequest) -> String {
        let titleLiteral = javaScriptStringLiteral(visualRequest.title)
        let contentLiteral = javaScriptStringLiteral(visualRequest.content)

        let sharedHead = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          :root { --ink: #2b2b2b; --paper: #fbfaf6; --grid: #e9e6dc; }
          html, body { margin: 0; height: 100%; background: transparent; overflow: hidden;
            font-family: "Noteworthy", "Marker Felt", "Chalkboard SE", "Comic Sans MS", cursive; color: var(--ink); }
          .card { position: absolute; inset: 8px; border-radius: 12px; overflow: hidden;
            background-color: var(--paper);
            background-image: linear-gradient(var(--grid) 1px, transparent 1px), linear-gradient(90deg, var(--grid) 1px, transparent 1px);
            background-size: 22px 22px;
            box-shadow: 0 10px 30px rgba(0,0,0,.35), 0 0 0 1px rgba(0,0,0,.08);
            transform-origin: 50% 0%; animation: cardIn .5s cubic-bezier(.2,.9,.3,1.15) both; }
          @keyframes cardIn { from { opacity: 0; transform: translateY(-10px) scale(.96) rotate(-.6deg); }
                              to { opacity: 1; transform: none; } }
          .title { position: absolute; top: 0; left: 0; right: 0; height: 26px; line-height: 26px; text-align: center;
            font: 500 12px -apple-system, system-ui, sans-serif; color: #8a877e; background: rgba(240,237,228,.85);
            border-bottom: 1px solid #e3dfd2; cursor: move; }
          .close { position: absolute; top: 3px; right: 6px; width: 20px; height: 20px; border-radius: 10px; border: 0;
            background: rgba(0,0,0,.06); color: #777; font: 600 13px -apple-system, sans-serif; cursor: pointer; z-index: 5; }
          .close:hover { background: rgba(0,0,0,.14); color: #333; }
          .stage { position: absolute; top: 27px; left: 0; right: 0; bottom: 0; }
          .stage svg { width: 100%; height: 100%; }
          .error { padding: 24px; font: 13px -apple-system, sans-serif; color: #a33; }
        </style>
        </head><body>
        <div class="card">
          <div class="title" id="title"></div>
          <button class="close" onclick="window.webkit.messageHandlers.openclicky.postMessage('close')">×</button>
          <div class="stage" id="stage"></div>
        </div>
        <script>document.getElementById('title').textContent = \(titleLiteral);</script>
        """

        switch visualRequest.kind {
        case .diagram:
            return sharedHead + """
            <script>
            const stage = document.getElementById('stage');
            const svgMarkup = \(contentLiteral);
            stage.innerHTML = svgMarkup;
            const svg = stage.querySelector('svg');
            if (!svg) {
              stage.innerHTML = '<div class="error">couldn\\'t draw this one.</div>';
            } else {
              svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
              // Predefined arrowhead so Claude can use marker-end="url(#arrow)".
              const defs = document.createElementNS('http://www.w3.org/2000/svg', 'defs');
              defs.innerHTML = '<marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#2b2b2b"/></marker>';
              svg.insertBefore(defs, svg.firstChild);
              // Handwriting font everywhere unless the element sets its own.
              svg.querySelectorAll('text').forEach(t => { if (!t.getAttribute('font-family')) t.setAttribute('font-family', 'Noteworthy, Marker Felt, cursive'); });

              // "Draw" each element in document order: strokes trace in, fills and text fade in.
              const drawable = Array.from(svg.querySelectorAll('path, line, polyline, polygon, rect, circle, ellipse, text'))
                .filter(el => !el.closest('defs') && !el.closest('marker'));
              let delay = 150;
              drawable.forEach(el => {
                const isText = el.tagName.toLowerCase() === 'text';
                el.style.opacity = '0';
                setTimeout(() => {
                  el.style.transition = 'opacity .25s ease';
                  el.style.opacity = '1';
                  if (!isText && typeof el.getTotalLength === 'function') {
                    try {
                      const len = el.getTotalLength();
                      if (len > 0) {
                        el.style.strokeDasharray = len;
                        el.style.strokeDashoffset = len;
                        el.getBoundingClientRect();
                        el.style.transition = 'stroke-dashoffset .45s ease-out, opacity .2s ease';
                        el.style.strokeDashoffset = '0';
                      }
                    } catch (e) {}
                  }
                }, delay);
                delay += isText ? 120 : 160;
              });
            }
            </script>
            </body></html>
            """

        case .threeDimensionalModel:
            return sharedHead + """
            <style>
              .label3d { font-family: "Noteworthy", "Marker Felt", cursive; font-size: 15px; font-weight: 700; color: #1f1f22;
                padding: 2px 9px; border-radius: 3px; border-left: 4px solid var(--edge); background: var(--fill);
                box-shadow: 0 2px 6px rgba(0,0,0,.25); white-space: nowrap; pointer-events: none; }
              .stage { background: radial-gradient(ellipse at 50% 40%, #ffffff 0%, #eef0f3 70%); }
              .hint { position: absolute; bottom: 8px; left: 0; right: 0; text-align: center; font: 11px -apple-system, sans-serif; color: #999; pointer-events: none; }
            </style>
            <div class="hint" id="hint">drag to rotate · scroll to zoom · click a part</div>
            <script type="importmap">
            { "imports": {
                "three": "https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.js",
                "three/addons/": "https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/"
            } }
            </script>
            <script type="module">
            import * as THREE from 'three';
            import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
            import { CSS2DRenderer, CSS2DObject } from 'three/addons/renderers/CSS2DRenderer.js';

            const stage = document.getElementById('stage');
            const width = stage.clientWidth, height = stage.clientHeight;

            const scene = new THREE.Scene();
            const camera = new THREE.PerspectiveCamera(40, width / height, 0.1, 1000);
            camera.position.set(6, 4, 8);

            const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
            renderer.setPixelRatio(window.devicePixelRatio);
            renderer.setSize(width, height);
            stage.appendChild(renderer.domElement);

            const labelRenderer = new CSS2DRenderer();
            labelRenderer.setSize(width, height);
            labelRenderer.domElement.style.position = 'absolute';
            labelRenderer.domElement.style.top = '0';
            labelRenderer.domElement.style.pointerEvents = 'none';
            stage.appendChild(labelRenderer.domElement);

            scene.add(new THREE.HemisphereLight(0xffffff, 0xb0b4bb, 1.6));
            const sun = new THREE.DirectionalLight(0xffffff, 1.6);
            sun.position.set(5, 10, 7);
            scene.add(sun);

            const controls = new OrbitControls(camera, renderer.domElement);
            controls.enableDamping = true;
            controls.autoRotate = true;
            controls.autoRotateSpeed = 0.8;
            controls.addEventListener('start', () => { controls.autoRotate = false; });

            const palette = [['#dcf7dc', '#5abf66'], ['#dfeeff', '#598ce6'], ['#ffe1ea', '#e6668c'], ['#fff5c7', '#e6b833']];
            let labelCount = 0;
            const model = new THREE.Group();
            scene.add(model);
            const parts = [];

            // Helpers available to Claude's script:
            function material(color) { return new THREE.MeshStandardMaterial({ color: color ?? 0xb8bcc4, metalness: 0.25, roughness: 0.55 }); }
            function addPart(mesh, name) { mesh.userData.partName = name; model.add(mesh); parts.push(mesh); return mesh; }
            function addLabel(position, text) {
              const labelIndex = labelCount++;
              const [fill, edge] = palette[labelIndex % palette.length];
              const el = document.createElement('div');
              el.className = 'label3d'; el.textContent = text;
              el.style.setProperty('--fill', fill); el.style.setProperty('--edge', edge);
              const label = new CSS2DObject(el);
              const p = position.isVector3 ? position : new THREE.Vector3(...position);
              // Alternate labels above and below at staggered heights so neighbors don't overlap.
              const isAbove = labelIndex % 2 === 0;
              const lift = (Math.floor(labelIndex / 2) % 2 === 0 ? 1.0 : 1.7) * (isAbove ? 1 : -1);
              label.position.copy(p).add(new THREE.Vector3(0, lift, 0));
              model.add(label);
              const lineGeometry = new THREE.BufferGeometry().setFromPoints([p, label.position.clone()]);
              model.add(new THREE.Line(lineGeometry, new THREE.LineBasicMaterial({ color: 0x222222 })));
              const dot = new THREE.Mesh(new THREE.SphereGeometry(0.05, 12, 12), new THREE.MeshBasicMaterial({ color: 0xffffff }));
              dot.position.copy(p); model.add(dot);
              return label;
            }
            function addArrow(from, to, color) {
              const start = from.isVector3 ? from : new THREE.Vector3(...from);
              const end = to.isVector3 ? to : new THREE.Vector3(...to);
              const direction = end.clone().sub(start);
              const arrow = new THREE.ArrowHelper(direction.clone().normalize(), start, direction.length(), color ?? 0x3d8bfd, 0.35, 0.22);
              model.add(arrow);
              return arrow;
            }

            try {
              const runUserScript = new Function('THREE', 'scene', 'camera', 'controls', 'model', 'material', 'addPart', 'addLabel', 'addArrow', \(contentLiteral));
              runUserScript(THREE, scene, camera, controls, model, material, addPart, addLabel, addArrow);
            } catch (error) {
              stage.innerHTML = '<div class="error">couldn\\'t build this model: ' + String(error).replace(/</g, '&lt;') + '</div>';
              throw error;
            }

            // Frame the model.
            const bounds = new THREE.Box3().setFromObject(model);
            const center = bounds.getCenter(new THREE.Vector3());
            const size = bounds.getSize(new THREE.Vector3()).length() || 4;
            model.position.sub(center);
            camera.position.set(size * 0.7, size * 0.45, size * 0.9);
            controls.target.set(0, 0, 0);

            // Click a part to see its name.
            const raycaster = new THREE.Raycaster();
            const pointer = new THREE.Vector2();
            renderer.domElement.addEventListener('click', (event) => {
              const rect = renderer.domElement.getBoundingClientRect();
              pointer.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
              pointer.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;
              raycaster.setFromCamera(pointer, camera);
              const hit = raycaster.intersectObjects(parts, true)[0];
              let target = hit?.object;
              while (target && !target.userData.partName && target.parent) target = target.parent;
              if (target?.userData.partName) {
                document.getElementById('hint').textContent = target.userData.partName;
                parts.forEach(p => p.material?.emissive?.setHex(0x000000));
                target.material?.emissive?.setHex(0x334466);
              }
            });

            (function animate() {
              requestAnimationFrame(animate);
              controls.update();
              renderer.render(scene, camera);
              labelRenderer.render(scene, camera);
            })();
            </script>
            </body></html>
            """
        }
    }
}
