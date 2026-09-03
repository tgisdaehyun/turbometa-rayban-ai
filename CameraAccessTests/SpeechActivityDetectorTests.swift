import XCTest
@testable import CameraAccess

final class SpeechActivityDetectorTests: XCTestCase {
    /// 20 ms buffers at 16 kHz, the shape GeminiLiveService feeds the detector.
    private let buffer: TimeInterval = 0.02

    private func feed(_ detector: inout SpeechActivityDetector, rms: Float, seconds: TimeInterval) -> [SpeechActivityDetector.Event] {
        var events: [SpeechActivityDetector.Event] = []
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            if let event = detector.process(rms: rms, duration: buffer) {
                events.append(event)
            }
            elapsed += buffer
        }
        return events
    }

    func testSilenceNeverStartsSpeech() {
        var detector = SpeechActivityDetector()
        XCTAssertTrue(feed(&detector, rms: 0.003, seconds: 5).isEmpty)
        XCTAssertFalse(detector.isSpeaking)
    }

    func testShortClickIsIgnored() {
        var detector = SpeechActivityDetector()
        XCTAssertTrue(feed(&detector, rms: 0.2, seconds: 0.06).isEmpty)
        XCTAssertTrue(feed(&detector, rms: 0.003, seconds: 1).isEmpty)
    }

    func testSpeechStartsOnceAndStopsAfterSilence() {
        var detector = SpeechActivityDetector()
        _ = feed(&detector, rms: 0.003, seconds: 1)
        let started = feed(&detector, rms: 0.1, seconds: 1.5)
        XCTAssertEqual(started, [.started])
        XCTAssertTrue(detector.isSpeaking)

        // A pause shorter than minSilenceDuration does not end the turn.
        XCTAssertTrue(feed(&detector, rms: 0.003, seconds: 0.4).isEmpty)
        XCTAssertTrue(feed(&detector, rms: 0.1, seconds: 0.5).isEmpty)

        let stopped = feed(&detector, rms: 0.003, seconds: 1)
        XCTAssertEqual(stopped, [.stopped])
        XCTAssertFalse(detector.isSpeaking)
    }

    func testNoiseFloorRaisesThresholdButIsCapped() {
        var detector = SpeechActivityDetector()
        // Constant moderate noise adapts the floor; the same level must not
        // count as speech afterwards.
        XCTAssertTrue(feed(&detector, rms: 0.012, seconds: 5).isEmpty)
        // Noise floor is capped at maxNoiseFloor, so clearly loud speech still
        // triggers even in a noisy room.
        XCTAssertEqual(feed(&detector, rms: 0.4, seconds: 1), [.started])
    }

    func testResetClearsSpeakingState() {
        var detector = SpeechActivityDetector()
        _ = feed(&detector, rms: 0.1, seconds: 1)
        XCTAssertTrue(detector.isSpeaking)
        detector.reset()
        XCTAssertFalse(detector.isSpeaking)
    }
}
