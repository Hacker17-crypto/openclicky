//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Optional text-to-speech via ElevenLabs using the user's OWN API key
//  (set ElevenLabsAPIKey / ElevenLabsVoiceID in Info.plist). Calls the
//  ElevenLabs API directly; there is no proxy server.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient: CompanionTextToSpeechClient {
    /// ElevenLabs' stock "Rachel" voice, used when no ElevenLabsVoiceID is configured.
    static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"

    private let apiKey: String
    private let textToSpeechURL: URL
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    init(apiKey: String, voiceID: String) {
        self.apiKey = apiKey
        self.textToSpeechURL = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String) async throws {
        var request = URLRequest(url: textToSpeechURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        // Apply the 0.5x–1.5x speed setting (enableRate must be set before play()).
        player.enableRate = true
        player.rate = Float(OpenClickySettings.shared.speechRateMultiplier)
        player.play()
        print("🔊 ElevenLabs TTS: playing \(data.count / 1024)KB audio")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}
