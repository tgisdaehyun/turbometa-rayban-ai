/*
 * SpeechActivityDetector
 *
 * Small energy-based voice activity detector used by GeminiLiveService.
 *
 * The Alibaba Omni realtime API tells the client when the user starts and
 * stops speaking (`input_audio_buffer.speech_started` / `speech_stopped`), and
 * LiveAIManager uses that "speech started" moment to send the current glasses
 * frame to the model. The Gemini Live API has no such server event, so without
 * a local detector the Google provider never sends a single frame in vision
 * mode. This detector reproduces the Omni behaviour from the microphone
 * samples the service already captures.
 *
 * Pure value type: feed it the RMS of each captured buffer plus the buffer
 * duration and it returns a `.started` / `.stopped` event on transitions.
 */

import Foundation

struct SpeechActivityDetector {
    enum Event: Equatable {
        case started
        case stopped
    }

    /// Absolute RMS (of samples in -1...1) below which audio is never speech.
    /// 0.015 is roughly -36 dBFS: quiet room noise stays well under it.
    var startThreshold: Float = 0.015
    /// Speech must be this many times louder than the adaptive noise floor.
    var noiseFloorRatio: Float = 3.0
    /// The noise floor never adapts above this, so a noisy street cannot lock
    /// detection out completely.
    var maxNoiseFloor: Float = 0.05
    /// Sustained loudness required before `.started` fires (filters clicks).
    var minSpeechDuration: TimeInterval = 0.12
    /// Sustained quiet required before `.stopped` fires (bridges pauses
    /// between words).
    var minSilenceDuration: TimeInterval = 0.8

    private(set) var isSpeaking = false
    private var noiseFloor: Float = 0.005
    private var loudDuration: TimeInterval = 0
    private var quietDuration: TimeInterval = 0

    /// Returns a transition event, or nil while the state is unchanged.
    mutating func process(rms: Float, duration: TimeInterval) -> Event? {
        guard rms.isFinite, duration > 0 else { return nil }
        let threshold = max(startThreshold, noiseFloor * noiseFloorRatio)
        let isLoud = rms > threshold

        if isSpeaking {
            if isLoud {
                quietDuration = 0
            } else {
                quietDuration += duration
                if quietDuration >= minSilenceDuration {
                    isSpeaking = false
                    quietDuration = 0
                    loudDuration = 0
                    return .stopped
                }
            }
            return nil
        }

        if isLoud {
            loudDuration += duration
            if loudDuration >= minSpeechDuration {
                isSpeaking = true
                loudDuration = 0
                quietDuration = 0
                return .started
            }
        } else {
            loudDuration = 0
            // Track the ambient level slowly while nobody is talking.
            noiseFloor = min(maxNoiseFloor, noiseFloor * 0.95 + rms * 0.05)
        }
        return nil
    }

    mutating func reset() {
        isSpeaking = false
        loudDuration = 0
        quietDuration = 0
    }
}
