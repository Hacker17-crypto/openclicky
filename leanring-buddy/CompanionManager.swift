//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Claude is reached through the user's locally installed Claude Code CLI,
    /// so there is no server, no proxy and no API key in OpenClicky.
    private lazy var claudeAPI: ClaudeCodeCLIClient = {
        return ClaudeCodeCLIClient(model: selectedModel)
    }()

    /// macOS on-device voice by default; ElevenLabs only if the user adds their own key.
    private lazy var elevenLabsTTSClient: any CompanionTextToSpeechClient = {
        return CompanionTextToSpeechClientFactory.makeDefaultClient()
    }()

    /// Background Claude Code agents launched by voice, and their on-screen cards.
    let agentManager = OpenClickyAgentManager()
    private lazy var agentCardsPanelManager = AgentCardsPanelManager(agentManager: agentManager)

    /// Fn + Control dictation into the focused app.
    private lazy var dictationController = OpenClickyDictationController(
        buddyDictationManager: buddyDictationManager,
        setProcessingIndicatorVisible: { [weak self] isVisible in
            guard let self else { return }
            if isVisible {
                self.voiceState = .processing
            } else if self.voiceState == .processing {
                self.voiceState = .idle
            }
        }
    )
    private var dictationShortcutTransitionCancellable: AnyCancellable?

    /// Whiteboard diagrams and 3D models Claude draws on screen.
    private let visualExplainerCardManager = VisualExplainerCardManager()

    /// Shows the spoken words next to the cursor while OpenClicky talks.
    private let captionsOverlayManager = CompanionResponseOverlayManager()

    /// Circles, arrows, highlights, callout labels and sticky notes currently drawn on screen.
    /// Rendered by ScreenAnnotationLayerView inside each screen's overlay window.
    @Published private(set) var activeScreenAnnotations: [ScreenAnnotation] = []
    private var screenAnnotationClearTask: Task<Void, Never>?

    /// Text already handed to TTS while a visual was still streaming in, so the
    /// reply isn't spoken twice when the full response arrives.
    private var earlySpokenResponseText: String?

    /// nil until checked on launch. False means `claude` couldn't be found,
    /// and the panel shows setup instructions.
    @Published private(set) var isClaudeCodeCLIInstalled: Bool?

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    /// Persisted to disk (see OpenClickyMemoryStore) when memory is on, so it survives restarts.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] =
        OpenClickySettings.shared.isMemoryEnabled ? OpenClickyMemoryStore.loadConversationHistory() : []

    /// Forgets the conversation (in memory and on disk). PROFILE.md is kept.
    func clearConversationHistory() {
        conversationHistory.removeAll()
        OpenClickyMemoryStore.clearConversationHistory()
    }

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude Code model alias used for voice responses ("sonnet" or "opus").
    /// Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "sonnet"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Checks whether the Claude Code CLI is installed and publishes the result
    /// for the panel. Called on launch and whenever the panel wants to re-check.
    func refreshClaudeCodeCLIAvailability() {
        Task {
            let isInstalled = await ClaudeCodeCLIClient.isInstalled()
            self.isClaudeCodeCLIInstalled = isInstalled
            print("🤖 Claude Code CLI installed: \(isInstalled)")
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 OpenClicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindDictationShortcutTransitions()
        bindAgentNotifications()
        // Locate the `claude` binary (and the user's login-shell PATH) up front
        // so the first push-to-talk doesn't pay for the lookup.
        ClaudeCodeCLIClient.warmUpInstallationLookupInBackground()
        refreshClaudeCodeCLIAvailability()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Plays onboarding.mp3 if you add one to the bundle (none ships with OpenClicky)
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        // Upstream Clicky bundled a copyrighted game soundtrack here. OpenClicky
        // doesn't redistribute it — drop your own onboarding.mp3 into the
        // leanring-buddy folder if you want onboarding music.
        guard let musicURL = Bundle.main.url(forResource: "onboarding", withExtension: "mp3") else {
            print("🎵 OpenClicky: no onboarding.mp3 in bundle, skipping music")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ OpenClicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        agentManager.shutDownAllAgents()
        visualExplainerCardManager.closeAllCards()
        dictationShortcutTransitionCancellable?.cancel()
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            guard !dictationController.isBusy else { return }
            clearScreenAnnotations()
            captionsOverlayManager.hideOverlay()
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're openclicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        earlySpokenResponseText = nil

        // "agent, ..." skips the conversation and goes straight to an agent.
        if let explicitAgentTask = Self.explicitAgentTask(fromTranscript: transcript) {
            launchAgentFromVoice(taskDescription: explicitAgentTask)
            return
        }

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: makeVoiceResponseSystemPrompt(),
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { [weak self] accumulatedResponseText in
                        // Spinner stays until TTS plays. If Claude starts drawing a
                        // visual, speak the explanation now instead of waiting for it.
                        self?.speakEarlyIfVisualHasStarted(accumulatedResponseText)
                    }
                )

                guard !Task.isCancelled else { return }

                // Pull out visuals first (they can contain brackets), then the
                // drawing/agent/memory tags, then the [POINT:...] tag.
                let (responseTextWithoutVisuals, visualRequests) = VisualExplainerParser.extractVisuals(from: fullResponseText)
                let parsedResponseTags = ScreenAnnotationTagParser.parseExtraTags(from: responseTextWithoutVisuals)
                let parseResult = Self.parsePointingCoordinates(from: parsedResponseTags.textWithoutExtraTags)
                let spokenText = parseResult.spokenText

                for factToRemember in parsedResponseTags.factsToRemember where OpenClickySettings.shared.isMemoryEnabled {
                    OpenClickyMemoryStore.rememberFact(factToRemember)
                }

                for agentTaskDescription in parsedResponseTags.agentTaskDescriptions {
                    agentManager.launchAgent(taskDescription: agentTaskDescription, screenshotImages: labeledImages)
                }

                if let firstVisualRequest = visualRequests.first {
                    visualExplainerCardManager.showVisual(firstVisualRequest, screenCaptures: screenCaptures)
                }

                let newScreenAnnotations = ScreenAnnotationFactory.makeAnnotations(
                    from: parsedResponseTags.drawingRequests,
                    screenCaptures: screenCaptures
                )
                if !newScreenAnnotations.isEmpty {
                    showScreenAnnotations(newScreenAnnotations)
                }

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep the last 20 exchanges (40 messages) to bound context growth
                let maximumExchangeCount = OpenClickyMemoryStore.maximumStoredExchangeCount
                if conversationHistory.count > maximumExchangeCount {
                    conversationHistory.removeFirst(conversationHistory.count - maximumExchangeCount)
                }
                if OpenClickySettings.shared.isMemoryEnabled {
                    OpenClickyMemoryStore.saveConversationHistory(conversationHistory)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                let wasAlreadySpokenEarly = earlySpokenResponseText != nil
                if !wasAlreadySpokenEarly && !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                        showCaptions(for: spokenText)
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ TTS error: \(error)")
                        speakErrorFallback(for: error)
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakErrorFallback(for: error)
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a short, actionable error using macOS system TTS. Uses
    /// NSSpeechSynthesizer directly so it works even if the TTS client failed.
    private func speakErrorFallback(for error: Error) {
        let utterance: String
        if let claudeCodeError = error as? ClaudeCodeCLIError {
            switch claudeCodeError.kind {
            case .executableNotFound:
                utterance = "I can't find Claude Code on this Mac. Install it, run claude once in Terminal to log in, then try again."
                isClaudeCodeCLIInstalled = false
            case .notAuthenticated:
                utterance = "Claude Code isn't logged in. Open Terminal, run claude, and log in, then try again."
            case .requestFailed:
                utterance = "Claude Code ran into a problem. Check that you haven't hit your usage limit, then try again."
            }
        } else {
            utterance = "Something went wrong talking to Claude Code. Try again in a moment."
        }
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - OpenClicky Extensions (drawing, agents, memory, visuals)

    /// Drawing, agent hand-off, memory and visual-card instructions appended to the
    /// original companion prompt. Verified against Claude Code: replies use these
    /// tags exactly as described.
    private static let companionCapabilitiesSystemPromptExtension = """
    drawing on screen:
    besides pointing, you can draw on the user's screen to show them things. use drawings when they genuinely help, for example circling the exact spot to click, underlining the line of text you're talking about, or an arrow from one thing to another. draw at most three shapes plus up to six labels or notes per reply. use the same screenshot pixel coordinate space as the point tag, and add :screenN for other screens. put drawing tags at the end of your reply, before the point tag. formats:
    - [CIRCLE:x,y,radius:label] circles something
    - [HIGHLIGHT:x,y,width,height:label] boxes a rectangular area (x,y is its top-left corner)
    - [UNDERLINE:x1,x2,y:label] underlines text running from x1 to x2 at height y
    - [ARROW:x1,y1,x2,y2:label] draws an arrow from the first point to the second
    - [LABEL:x,y:text] puts a short callout tag with a leader line pointing at x,y, great for naming the parts of something (use several to label a diagram, a product photo or a machine)
    - [NOTE:x,y:text] sticks a yellow sticky note near x,y for a warning or a key tip, like "power off first". keep notes under ten words

    agents:
    you can't click, type, or run things yourself, but you can hand work off to an agent that runs in the background on the user's mac with full tools (files, terminal, web search, and any apps the user has connected). when the user asks you to actually do something rather than explain it, like research a topic, write or edit a file, build something, organize files, or send or draft something, say one short spoken line acknowledging it (like "on it, i'll have an agent handle that") and append [AGENT:<a complete, self-contained description of the task, including any details from the screen the agent will need>]. don't use an agent for things you can answer by talking.

    memory:
    if the user tells you something about themselves that would be useful to remember in future conversations (their name, job, projects, preferences, tools they use), append [REMEMBER:<the fact, written in third person, like "the user's name is alex">]. only remember things they'd want remembered.

    visual explainer cards:
    when a picture would teach far better than words (how something works, a process or pipeline, a comparison, the structure of an idea, or the parts of a physical object), you can draw an explainer card that pops up on screen next to what you're talking about. at most one per reply, and only when it genuinely helps. your spoken reply must still make sense on its own. write the card after your spoken text, before any drawing or point tags.

    diagram card format:
    <visual kind="diagram" title="2-5 word title" x="X" y="Y" width="W" height="H">
    <svg viewBox="0 0 W H-30" xmlns="http://www.w3.org/2000/svg">...</svg>
    </visual>
    - x,y is where the card's top-left corner should go, in screenshot pixel coordinates. pick empty-ish space that doesn't cover what you're explaining or pointing at. width 420-640, height 300-480.
    - it renders as a hand-drawn whiteboard sketch on grid paper, and elements draw themselves in document order, so order them the way you'd explain out loud.
    - style: big handwritten text (font-size 20-30, fill #2b2b2b), a bold heading at the top, boxes as rect with rx="3" stroke="#2b2b2b" stroke-width="2" and soft fills (#dbeafe blue, #fde2e2 red, #dcfce7 green, #fef3c7 yellow, #ede9fe purple), arrows as line or path with stroke="#2b2b2b" stroke-width="2" marker-end="url(#arrow)" (that marker already exists), numbered steps as small circles with a number.
    - keep it simple and roomy: under 30 elements, no tiny text, no gradients, no images, no scripts.

    3d model card format, for physical objects (machines, engines, devices, anatomy, buildings):
    <visual kind="3d" title="2-5 word title" x="X" y="Y" width="560" height="440">
    javascript
    </visual>
    - the javascript runs with these ready: THREE (three.js r160), model (a THREE.Group already in the scene, add everything to it), material(colorHex) for a nice standard material, addPart(mesh, "name") to add a clickable named part, addLabel([x,y,z], "text") for a callout label pointing at a spot, addArrow([x1,y1,z1], [x2,y2,z2], colorHex) for flow or force arrows. lights, camera framing, and drag-to-rotate are handled for you.
    - build a recognizable simplified model from primitives (BoxGeometry, CylinderGeometry, SphereGeometry, ConeGeometry, TorusGeometry), sized roughly 2 to 6 units overall. label the 3 to 6 parts that matter for your explanation. plain javascript statements only, no imports, under 80 lines.
    """

    /// The full talk-mode system prompt, including what OpenClicky remembers about the user.
    private func makeVoiceResponseSystemPrompt() -> String {
        var systemPrompt = Self.companionVoiceResponseSystemPrompt + "\n" + Self.companionCapabilitiesSystemPromptExtension

        if OpenClickySettings.shared.isMemoryEnabled {
            let profileText = OpenClickyMemoryStore.readProfileText()
            if !profileText.isEmpty {
                systemPrompt += "\n\nwhat you already know about the user (from earlier conversations):\n\(profileText)"
            }
        }

        let runningOrRecentAgents = agentManager.agents.prefix(5)
        if !runningOrRecentAgents.isEmpty {
            let agentSummaries = runningOrRecentAgents.map { agent in
                "- \(agent.name): \(agent.taskDescription.prefix(120)) (\(agent.latestActivityText.prefix(80)))"
            }.joined(separator: "\n")
            systemPrompt += "\n\nagents currently on the user's screen:\n\(agentSummaries)"
        }

        return systemPrompt
    }

    /// Called on every streamed chunk. Once Claude starts a <visual> block, the
    /// spoken part is complete, so start talking while the visual keeps generating.
    private func speakEarlyIfVisualHasStarted(_ accumulatedResponseText: String) {
        guard earlySpokenResponseText == nil,
              let spokenPrefix = VisualExplainerParser.spokenPrefixBeforeVisual(in: accumulatedResponseText) else {
            return
        }

        let prefixWithoutTags = ScreenAnnotationTagParser.parseExtraTags(from: spokenPrefix).textWithoutExtraTags
        let speakableText = Self.parsePointingCoordinates(from: prefixWithoutTags).spokenText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speakableText.isEmpty else { return }

        earlySpokenResponseText = speakableText
        Task {
            do {
                try await elevenLabsTTSClient.speakText(speakableText)
                voiceState = .responding
                showCaptions(for: speakableText)
            } catch {
                print("⚠️ Early TTS error: \(error)")
            }
        }
    }

    /// Shows what OpenClicky is saying next to the cursor, then fades it out
    /// a few seconds after speech ends.
    private func showCaptions(for spokenText: String) {
        guard OpenClickySettings.shared.showsCaptionsWhileTalking else { return }
        captionsOverlayManager.showOverlayAndBeginStreaming()
        captionsOverlayManager.updateStreamingText(spokenText)

        Task {
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            captionsOverlayManager.finishStreaming()
        }
    }

    /// Draws annotations and removes them a few seconds after OpenClicky stops talking.
    private func showScreenAnnotations(_ newScreenAnnotations: [ScreenAnnotation]) {
        screenAnnotationClearTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            activeScreenAnnotations = newScreenAnnotations
        }

        screenAnnotationClearTask = Task {
            // Give TTS a moment to start, then wait for it to finish.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            clearScreenAnnotations()
        }
    }

    private func clearScreenAnnotations() {
        screenAnnotationClearTask?.cancel()
        screenAnnotationClearTask = nil
        guard !activeScreenAnnotations.isEmpty else { return }
        withAnimation(.easeIn(duration: 0.5)) {
            activeScreenAnnotations = []
        }
    }

    /// "agent, find me..." / "hey openclicky agent ..." → the task; otherwise nil.
    static func explicitAgentTask(fromTranscript transcript: String) -> String? {
        var remainingText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let ignorableLeadingWords = ["hey", "hi", "okay", "ok", "open clicky", "openclicky", "clicky", "heyclicky", "hey clicky"]
        var didStripLeadingWord = true
        while didStripLeadingWord {
            didStripLeadingWord = false
            for ignorableLeadingWord in ignorableLeadingWords where remainingText.lowercased().hasPrefix(ignorableLeadingWord) {
                remainingText = String(remainingText.dropFirst(ignorableLeadingWord.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!:").union(.whitespaces))
                didStripLeadingWord = true
                break
            }
        }

        let lowercasedRemainingText = remainingText.lowercased()
        guard lowercasedRemainingText.hasPrefix("agent") else { return nil }
        // "agents are cool" isn't a command; require "agent" followed by a separator.
        let textAfterAgentWord = remainingText.dropFirst("agent".count)
        guard let firstCharacterAfterAgentWord = textAfterAgentWord.first,
              firstCharacterAfterAgentWord == "," || firstCharacterAfterAgentWord == " " || firstCharacterAfterAgentWord == ":" else {
            return nil
        }

        let agentTask = textAfterAgentWord.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:").union(.whitespaces))
        return agentTask.count >= 3 ? agentTask : nil
    }

    /// Launches an agent directly from an "agent, ..." voice command, with the current screen as context.
    private func launchAgentFromVoice(taskDescription: String) {
        currentResponseTask = Task {
            voiceState = .processing
            let screenCaptures = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()) ?? []
            let labeledImages = screenCaptures.filter { $0.isCursorScreen }.map { capture in
                (data: capture.imageData, label: capture.label)
            }
            let launchedAgent = agentManager.launchAgent(taskDescription: taskDescription, screenshotImages: labeledImages)
            try? await elevenLabsTTSClient.speakText("on it. your \(launchedAgent.name.lowercased()) agent starts in a few seconds.")
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    private func bindDictationShortcutTransitions() {
        dictationShortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .dictationShortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dictationShortcutTransition in
                guard let self else { return }
                // Don't start dictating while a talk-mode press is in progress.
                guard !self.globalPushToTalkShortcutMonitor.isShortcutCurrentlyPressed else { return }
                self.dictationController.handleDictationShortcutTransition(dictationShortcutTransition)
            }
    }

    /// Announces finished agents out loud (unless OpenClicky is busy talking).
    private func bindAgentNotifications() {
        _ = agentCardsPanelManager
        agentManager.onAgentFinished = { [weak self] finishedAgent in
            guard let self else { return }
            NSSound(named: "Glass")?.play()
            guard self.voiceState == .idle, !self.elevenLabsTTSClient.isPlaying else { return }
            let summaryText = finishedAgent.finalSummaryText ?? "it's done."
            Task {
                try? await self.elevenLabsTTSClient.speakText("your \(finishedAgent.name.lowercased()) agent finished. \(summaryText)")
            }
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Runs the onboarding sequence after the welcome animation. Upstream
    /// Clicky streamed a personal intro video from the original author's
    /// video host here; OpenClicky has no server, so instead it goes
    /// straight to the pointing demo and then the "try talking" prompt.
    /// Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        showOnboardingVideo = false

        // Give the welcome animation a moment to finish, then show off pointing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Once the demo has had time to fly, point and return, invite the user to talk.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
            self?.startOnboardingPromptStream()
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're openclicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
