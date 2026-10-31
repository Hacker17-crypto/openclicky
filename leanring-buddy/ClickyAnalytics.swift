//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Upstream Clicky sent these events (including full transcripts and
//  responses) to the original author's PostHog project. OpenClicky sends
//  nothing anywhere: every event is a local no-op, kept only so call sites
//  stay identical to upstream. Plug in your own analytics in `capture` if
//  you want them.
//

import Foundation

enum ClickyAnalytics {

    // MARK: - Setup

    static func configure() {
        // Intentionally empty: no telemetry.
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        capture("app_opened", properties: [
            "app_version": version
        ])
    }

    // MARK: - Onboarding

    /// User clicked the Start button to begin onboarding for the first time.
    static func trackOnboardingStarted() {
        capture("onboarding_started")
    }

    /// User clicked "Watch Onboarding Again" from the panel footer.
    static func trackOnboardingReplayed() {
        capture("onboarding_replayed")
    }

    /// The onboarding video finished playing to the end.
    static func trackOnboardingVideoCompleted() {
        capture("onboarding_video_completed")
    }

    /// The 40s onboarding demo interaction where Clicky points at something.
    static func trackOnboardingDemoTriggered() {
        capture("onboarding_demo_triggered")
    }

    // MARK: - Permissions

    /// All three permissions (accessibility, screen recording, mic) are granted.
    static func trackAllPermissionsGranted() {
        capture("all_permissions_granted")
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
        capture("permission_granted", properties: [
            "permission": permission
        ])
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
        capture("push_to_talk_started")
    }

    /// User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {
        capture("push_to_talk_released")
    }

    /// Transcription completed and the user's message is being sent to the AI.
    static func trackUserMessageSent(transcript: String) {
        capture("user_message_sent", properties: [
            "transcript": transcript,
            "character_count": transcript.count
        ])
    }

    /// Claude responded and the response is being spoken via TTS.
    static func trackAIResponseReceived(response: String) {
        capture("ai_response_received", properties: [
            "response": response,
            "character_count": response.count
        ])
    }

    /// Claude's response included a [POINT:x,y:label] coordinate tag,
    /// so the buddy is flying to point at a UI element.
    static func trackElementPointed(elementLabel: String?) {
        capture("element_pointed", properties: [
            "element_label": elementLabel ?? "unknown"
        ])
    }

    // MARK: - Errors

    /// An error occurred during the AI response pipeline.
    static func trackResponseError(error: String) {
        capture("response_error", properties: [
            "error": error
        ])
    }

    /// An error occurred during TTS playback.
    static func trackTTSError(error: String) {
        capture("tts_error", properties: [
            "error": error
        ])
    }

    // MARK: - Local Sink

    /// Events stay on this Mac. Logged in debug builds only.
    private static func capture(_ eventName: String, properties: [String: Any] = [:]) {
        #if DEBUG
        print("📊 analytics (local only): \(eventName)")
        #endif
    }
}
