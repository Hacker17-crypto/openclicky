//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while OpenClicky is running in the
//  background, so modifier-only shortcuts like ctrl + option behave like a real
//  system-wide voice tool.
//
//  The tap is an active (not listen-only) tap for one reason: while the talk
//  shortcut is held, mouse drags become ink the user draws on screen to show
//  OpenClicky what they mean. Those mouse events are swallowed so the app
//  underneath doesn't also select text or drag windows. Every other event,
//  and all mouse events while the shortcut is up, pass through untouched.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Fn + Control (without Option): dictate into the focused app.
    let dictationShortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Tracks the dictation chord separately from the talk chord.
    private var isDictationShortcutCurrentlyPressed = false

    /// A point of user ink, in global AppKit coordinates (bottom-left origin).
    enum InkEvent {
        case strokeBegan(CGPoint)
        case strokeMoved(CGPoint)
        case strokeEnded(CGPoint)
    }
    /// Mouse drags made while the talk shortcut is held.
    let inkEventPublisher = PassthroughSubject<InkEvent, Never>()
    /// Escape pressed anywhere (passed through to the app too). Used to stop OpenClicky talking.
    let escapeKeyPublisher = PassthroughSubject<Void, Never>()
    private static let escapeKeyCode: UInt16 = 53

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [
            .flagsChanged, .keyDown, .keyUp,
            .leftMouseDown, .leftMouseDragged, .leftMouseUp
        ]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Active tap so ink drags can be swallowed (see file header).
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        isDictationShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private var isInkStrokeInProgress = false

    /// While the talk shortcut is held, mouse drags draw ink and are swallowed.
    /// Otherwise mouse events pass straight through.
    private func handleMouseEventForInk(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let isDrawingAllowed = isShortcutCurrentlyPressed
        guard isDrawingAllowed || isInkStrokeInProgress else {
            return Unmanaged.passUnretained(event)
        }

        let inkPoint = Self.convertQuartzGlobalPointToAppKit(event.location)

        switch eventType {
        case .leftMouseDown:
            isInkStrokeInProgress = true
            inkEventPublisher.send(.strokeBegan(inkPoint))
        case .leftMouseDragged:
            guard isInkStrokeInProgress else { return Unmanaged.passUnretained(event) }
            inkEventPublisher.send(.strokeMoved(inkPoint))
        case .leftMouseUp:
            guard isInkStrokeInProgress else { return Unmanaged.passUnretained(event) }
            isInkStrokeInProgress = false
            inkEventPublisher.send(.strokeEnded(inkPoint))
        default:
            return Unmanaged.passUnretained(event)
        }

        // Swallow: the click/drag was for drawing, not for the app underneath.
        return nil
    }

    /// CGEvent locations use a top-left origin at the primary display; AppKit uses bottom-left.
    private static func convertQuartzGlobalPointToAppKit(_ quartzPoint: CGPoint) -> CGPoint {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: quartzPoint.x, y: primaryScreenHeight - quartzPoint.y)
    }

    /// Fn + Control held together (and Option not held, so it never collides with
    /// the Control + Option talk shortcut) means "dictate".
    private func handleDictationShortcut(eventType: CGEventType, modifierFlagsRawValue: UInt64) {
        guard eventType == .flagsChanged else { return }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        let isDictationChordHeld = modifierFlags.contains(.function)
            && modifierFlags.contains(.control)
            && !modifierFlags.contains(.option)

        if isDictationChordHeld && !isDictationShortcutCurrentlyPressed {
            isDictationShortcutCurrentlyPressed = true
            dictationShortcutTransitionPublisher.send(.pressed)
        } else if !isDictationChordHeld && isDictationShortcutCurrentlyPressed {
            isDictationShortcutCurrentlyPressed = false
            dictationShortcutTransitionPublisher.send(.released)
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if eventType == .leftMouseDown || eventType == .leftMouseDragged || eventType == .leftMouseUp {
            return handleMouseEventForInk(eventType: eventType, event: event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if eventType == .keyDown && eventKeyCode == Self.escapeKeyCode {
            escapeKeyPublisher.send(())
        }
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        handleDictationShortcut(eventType: eventType, modifierFlagsRawValue: event.flags.rawValue)

        return Unmanaged.passUnretained(event)
    }
}
