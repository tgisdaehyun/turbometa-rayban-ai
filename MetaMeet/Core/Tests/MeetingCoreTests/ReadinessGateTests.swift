import XCTest
@testable import MeetingCore
@MainActor
final class ReadinessGateTests: XCTestCase {
    func testWaitsForDelayedDeviceWithoutCreatingEarlySession() async throws {
        var discoveries = 0; var sessions = 0
        let result: String = try await ReadinessGate.run(attempts: 5, intervalNanoseconds: 0) {
            discoveries += 1
            guard discoveries >= 3 else { return nil }
            sessions += 1; return "glasses"
        }
        XCTAssertEqual(result, "glasses"); XCTAssertEqual(discoveries, 3); XCTAssertEqual(sessions, 1)
    }
    func testMissingDeviceHasBoundedTimeout() async {
        var attempts = 0
        do {
            let _: String = try await ReadinessGate.run(attempts: 3, intervalNanoseconds: 0) { attempts += 1; return nil }
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error is ReadinessFailure); XCTAssertEqual(attempts, 3) }
    }
    func testPermanentFailureDoesNotRetry() async {
        enum Failure: Error { case denied }
        var attempts = 0
        do {
            let _: String = try await ReadinessGate.run(attempts: 5, intervalNanoseconds: 0) { attempts += 1; throw Failure.denied }
            XCTFail("Expected failure")
        } catch { XCTAssertTrue(error is Failure); XCTAssertEqual(attempts, 1) }
    }
    func testCancelledStartCannotCreateSession() async {
        var attempts = 0
        let task = Task { @MainActor in
            let _: String = try await ReadinessGate.run(attempts: 5, intervalNanoseconds: 0) { attempts += 1; return "glasses" }
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError); XCTAssertEqual(attempts, 0) }
    }
}
