import XCTest
@testable import MeetingCore
final class AudioSanityTests: XCTestCase {
    func testSilentAudioReturnsWithoutCallingAPI() async throws {
        let audio = WAV.header(byteCount: 64000) + Data(repeating: 0, count: 64000)
        // Deliberately invalid model/key: reaching the request builder would fail.
        let lines = try await GeminiClient().transcribe(audio: audio, duration: 2, model: "invalid/model", key: "", glossary: "")
        XCTAssertEqual(lines, [])
    }
    func testMandarinSpeechPassesGate() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "mandarin", withExtension: "wav", subdirectory: "Fixtures"))
        XCTAssertTrue(try AudioSanity.hasSignal(Data(contentsOf: url)))
    }
    func testNoiseOnlyIsRejectedBeforeTranscription() throws {
        var state: UInt32 = 42; var pcm = Data()
        for _ in 0..<32000 {
            state = state &* 1664525 &+ 1013904223
            let value = Int16(Int(state % 1001) - 500)
            let bits = UInt16(bitPattern: value)
            pcm.append(UInt8(bits & 255)); pcm.append(UInt8(bits >> 8))
        }
        XCTAssertFalse(try AudioSanity.hasSignal(WAV.header(byteCount: pcm.count) + pcm))
    }
    func testMalformedWavIsNotSilentlyDiscarded() { XCTAssertThrowsError(try AudioSanity.hasSignal(Data(repeating: 0, count: 80))) }
    func testKoreanPlaybackDuplicateIsFilteredButChineseSpeechIsKept() {
        let spoken = ["우선 확인해 봅시다. CAN 메시지는 100밀리초마다 전송됩니다."]
        XCTAssertTrue(AudioSanity.isPlaybackEcho(original: "우선 확인해 봅시다 CAN 메시지는 100밀리초마다 전송됩니다", spoken: spoken))
        XCTAssertFalse(AudioSanity.isPlaybackEcho(original: "CAN 报文每100毫秒发送一次", spoken: spoken))
        XCTAssertFalse(AudioSanity.isPlaybackEcho(original: "이번에는 다른 부품으로 시험해 봅시다", spoken: spoken))
    }
    func testFastModelUsesMinimalThinkingWithoutChangingOtherModels() throws {
        for (model, expected) in [("gemini-3.6-flash", "MINIMAL"), ("gemini-3.8-flash", "")] {
            let request = try GeminiClient.request(audio: Data(), duration: 2, model: model, key: "fixture", glossary: "")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
            let thinking = (config["thinkingConfig"] as? [String: String])?["thinkingLevel"] ?? ""
            XCTAssertEqual(thinking, expected)
        }
    }
}
