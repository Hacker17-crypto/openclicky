//
//  FocusedAppContextReader.swift
//  leanring-buddy
//
//  Reads what the user is working in, through the Accessibility API
//  OpenClicky already has permission for: the frontmost app's name, its
//  focused window title, and any selected text. Sent to Claude with the
//  screenshot so "what does this mean?" about a highlighted sentence, or
//  "rewrite this" with text selected, works precisely.
//

import AppKit
import ApplicationServices

struct FocusedAppContext {
    let applicationName: String?
    let windowTitle: String?
    let selectedText: String?

    /// A short line appended to the user's question, or nil when there's nothing useful.
    var promptDescription: String? {
        var contextParts: [String] = []
        if let applicationName {
            if let windowTitle, !windowTitle.isEmpty {
                contextParts.append("i'm in \(applicationName), window \"\(windowTitle)\"")
            } else {
                contextParts.append("i'm in \(applicationName)")
            }
        }
        if let selectedText {
            contextParts.append("i have this text selected: \"\(selectedText)\"")
        }
        guard !contextParts.isEmpty else { return nil }
        return "(context: " + contextParts.joined(separator: ". ") + ")"
    }
}

@MainActor
enum FocusedAppContextReader {
    /// Caps the selection so a select-all on a long document doesn't flood the prompt.
    private static let maximumSelectedTextLength = 3_000

    static func readCurrentContext() -> FocusedAppContext {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return FocusedAppContext(applicationName: nil, windowTitle: nil, selectedText: nil)
        }

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)

        var windowTitle: String?
        if let focusedWindowElement = copyElementAttribute(kAXFocusedWindowAttribute, from: applicationElement) {
            windowTitle = copyStringAttribute(kAXTitleAttribute, from: focusedWindowElement)
        }

        var selectedText: String?
        if let focusedElement = copyElementAttribute(kAXFocusedUIElementAttribute, from: applicationElement),
           let rawSelectedText = copyStringAttribute(kAXSelectedTextAttribute, from: focusedElement) {
            let trimmedSelectedText = rawSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSelectedText.isEmpty {
                selectedText = trimmedSelectedText.count > maximumSelectedTextLength
                    ? String(trimmedSelectedText.prefix(maximumSelectedTextLength)) + "…"
                    : trimmedSelectedText
            }
        }

        return FocusedAppContext(
            applicationName: frontmostApplication.localizedName,
            windowTitle: windowTitle.map { String($0.prefix(200)) },
            selectedText: selectedText
        )
    }

    private static func copyElementAttribute(_ attributeName: String, from element: AXUIElement) -> AXUIElement? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success,
              let attributeValue,
              CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (attributeValue as! AXUIElement)
    }

    private static func copyStringAttribute(_ attributeName: String, from element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else {
            return nil
        }
        return attributeValue as? String
    }
}
