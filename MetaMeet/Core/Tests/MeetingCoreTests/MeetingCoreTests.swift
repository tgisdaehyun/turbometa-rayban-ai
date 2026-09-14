import XCTest
@testable import MeetingCore
final class MeetingCoreTests: XCTestCase {
    func testBilingualDecodeAndOrdering() throws {
        let data = Data(#"{"segments":[{"start":3,"end":4,"speaker":"B","original":"CAN 报文","korean":"CAN 메시지"},{"start":0,"end":2,"speaker":"A","original":"温度是85度","korean":"온도는 85도입니다"}]}"#.utf8)
        let segments = try TranscriptDecoder.decode(data, duration: 15)
        XCTAssertEqual(segments.first?.original, "温度是85度"); XCTAssertEqual(segments.last?.korean, "CAN 메시지")
    }
    func testRejectsHallucinatedTimestamps() {
        let data = Data(#"{"segments":[{"start":20,"end":23,"speaker":"A","original":"测试","korean":"시험"}]}"#.utf8)
        XCTAssertThrowsError(try TranscriptDecoder.decode(data, duration: 15))
    }
    func testSilenceCanBeEmpty() throws { XCTAssertEqual(try TranscriptDecoder.decode(Data(#"{"segments":[]}"#.utf8), duration: 15), []) }
    func testCrashRecoveryRepairsWavHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try (WAV.header(byteCount: 0) + Data(repeating: 0, count: 32001)).write(to: url)
        XCTAssertEqual(try WAV.repair(url), 1)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 32044); XCTAssertEqual(data.prefix(44), WAV.header(byteCount: 32000))
    }
    func testExportKeepsAbsoluteTimesAndIncompleteAudio() throws {
        var meeting = Meeting(title: "ECU 회의")
        var chunk = AudioChunk(id: 1, filename: "1.wav", start: 30, duration: 15, state: .complete)
        chunk.utterances = [Utterance(start: 2, end: 4, speaker: "A", original: "六百", korean: "600")]
        meeting.chunks = [chunk, AudioChunk(id: 2, filename: "2.wav", start: 45, state: .failed)]
        XCTAssertTrue(meeting.markdown.contains("00:00:32")); XCTAssertTrue(meeting.markdown.contains("전사 미완료"))
        let recovered = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(recovered.id, meeting.id); XCTAssertEqual(recovered.chunks.count, 2)
    }
}
extension MeetingCoreTests {
    func testRequestUsesHeaderAndStructuredAudio() throws {
        let r = try GeminiClient.request(audio: WAV.header(byteCount: 0), duration: 15, model: "gemini-2.5-flash", key: "fixture-key", glossary: "0x643, R818")
        XCTAssertFalse(r.url!.absoluteString.contains("fixture-key")); XCTAssertEqual(r.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: r.httpBody!) as? [String: Any])
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let inline = try XCTUnwrap(parts.first?["inlineData"] as? [String: String])
        XCTAssertEqual(inline["mimeType"], "audio/wav")
        XCTAssertEqual(inline["data"], WAV.header(byteCount: 0).base64EncodedString())
        XCTAssertNotNil((body["generationConfig"] as? [String: Any])?["responseSchema"])
        XCTAssertEqual(parts.count, 1)
        XCTAssertFalse(String(data: r.httpBody!, encoding: .utf8)!.contains("0x643"))
    }
    func testRejectsTruncatedModelResponse() {
        XCTAssertThrowsError(try GeminiClient.decode(Data(#"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"{}"}]}}]}"#.utf8), duration: 15))
    }
    func testDoesNotSendKeyToCustomHost() {
        XCTAssertThrowsError(try GeminiClient.request(audio: Data(), duration: 15, model: "../../other?key=oops", key: "key", glossary: ""))
    }
}
