import Foundation

public enum ReadinessFailure: Error { case timedOut }
/// Bounded readiness checks. Cancellation and permanent errors stop immediately.
@MainActor
public enum ReadinessGate {
    public static func run<T>(attempts: Int, intervalNanoseconds: UInt64, operation: () async throws -> T?) async throws -> T {
        for attempt in 0..<max(0, attempts) {
            try Task.checkCancellation()
            if let value = try await operation() { try Task.checkCancellation(); return value }
            if attempt + 1 < attempts { try await Task.sleep(nanoseconds: intervalNanoseconds) }
        }
        throw ReadinessFailure.timedOut
    }
}
