import XCTest
@testable import MeetingCore
final class GeminiIntegrationTests: XCTestCase {
    func testActualMandarinAudioToKorean() async throws {
        guard let key = ProcessInfo.processInfo.environment["METAMEET_TEST_API_KEY"], !key.isEmpty else { throw XCTSkip("Live API test requires explicit key injection") }
        let file = try XCTUnwrap(Bundle.module.url(forResource: "mandarin", withExtension: "wav", subdirectory: "Fixtures"))
        let audio = try Data(contentsOf: file)
        let duration = Double(audio.count - 44) / Double(WAV.bytesPerSecond)
        let segments = try await GeminiClient().transcribe(audio: audio, duration: duration, model: GeminiModels.defaultModel, key: key, glossary: "CAN, 报文, 100毫秒, 100밀리초")
        XCTAssertFalse(segments.isEmpty)
        let original = segments.map(\.original).joined(separator: " ")
        let korean = segments.map(\.korean).joined(separator: " ")
        XCTAssertTrue(original.contains("百") || original.contains("100"), "Must preserve the spoken interval")
        XCTAssertTrue(korean.contains("100") || korean.contains("백"), "Must translate the interval")
        XCTAssertTrue(korean.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) })
        print("Live Mandarin source: \(original)")
        print("Live Korean translation: \(korean)")
    }
}
final class GeminiAvailabilityTests: XCTestCase {
    func testMigratesOldModelAndPreservesUserChoice() {
        XCTAssertEqual(GeminiModels.migrated("gemini-2.5-flash"), GeminiModels.defaultModel)
        XCTAssertEqual(GeminiModels.migrated("gemini-3.8-flash"), "gemini-3.8-flash")
    }
    func testFiltersNonAudioGenerationModels() throws {
        let data = Data(#"{"models":[{"name":"models/gemini-3.6-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-3.1-flash-image","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"next"}"#.utf8)
        let page = try GeminiModels.candidates(from: data)
        XCTAssertEqual(page.models, ["gemini-3.6-flash"]); XCTAssertEqual(page.nextPage, "next")
    }
    func testServerFailureIsActionableAndKeyRedacted() {
        let data = Data(#"{"error":{"message":"new users cannot use this model: fixture-secret"}}"#.utf8)
        let error = GeminiClient.apiFailure(data: data, code: 404, key: "fixture-secret")
        XCTAssertTrue(error.message.contains("new users")); XCTAssertFalse(error.message.contains("fixture-secret")); XCTAssertFalse(error.retryable)
    }
}
