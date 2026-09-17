import XCTest
@testable import MeetingCore
final class HostTransferTests: XCTestCase {
    func testOnlyPrivateTailscaleDestinations() {
        XCTAssertNotNil(HostDestination.validate("https://100.126.27.18:8766"))
        XCTAssertNotNil(HostDestination.validate("https://host.tail123.ts.net"))
        for value in ["http://example.com", "http://100.63.1.1", "http://100.128.1.1", "http://100.126.27.18.evil.com", "http://100.126.27.18/path", "http://user:pass@100.126.27.18", "http://100.126.27.18?token=x", "https://evilts.net", "file:///tmp/x"] {
            XCTAssertNil(HostDestination.validate(value), value)
        }
    }
    func testFinalizationWaitsForAudioCloseAndExcludesTranscripts() throws {
        var meeting = Meeting(title: "회의")
        var closed = AudioChunk(id: 0, filename: "000000.wav", start: 0, duration: 15, state: .queued)
        meeting.chunks = [closed, AudioChunk(id: 1, filename: "000001.wav", start: 15)]
        meeting.ended = Date()
        let snapshot = TransferMeeting(meeting)
        XCTAssertNil(snapshot.ended); XCTAssertEqual(snapshot.chunks.count, 1)
        closed.utterances = [Utterance(start: 0, end: 1, speaker: "미상", original: "hello", korean: "안녕")]
        meeting.chunks[0] = closed
        XCTAssertEqual(snapshot, TransferMeeting(meeting))
        meeting.chunks[1].state = .queued; meeting.chunks[1].duration = 0.8
        XCTAssertNotNil(TransferMeeting(meeting).ended)
    }
    func testRecoveryIsBoundedAndNeverRetriesDuringInterruption() {
        var policy = AudioRecoveryPolicy()
        policy.interruptionBegan(); XCTAssertNil(policy.nextDelay())
        policy.interruptionEnded()
        XCTAssertEqual((0..<5).compactMap { _ in policy.nextDelay() }, [1, 2, 4, 8, 15])
        XCTAssertNil(policy.nextDelay()); policy.succeeded(); XCTAssertEqual(policy.nextDelay(), 1)
    }
}
