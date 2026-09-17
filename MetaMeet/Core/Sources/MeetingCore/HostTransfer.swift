import Foundation

/// The upload format contains original audio and recording metadata, never API credentials.
public struct TransferChunk: Codable, Equatable, Sendable {
    public var id: Int
    public var filename: String
    public var start: Double
    public var duration: Double
    public init(_ chunk: AudioChunk) {
        id = chunk.id; filename = chunk.filename; start = chunk.start; duration = chunk.duration
    }
}
public struct TransferMeeting: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var created: Date
    public var ended: Date?
    public var events: [String]
    public var notes: String
    public var chunks: [TransferChunk]
    public init(_ meeting: Meeting) {
        id = meeting.id; title = meeting.title; created = meeting.created
        // A stop callback may still have a final open chunk. Do not finalize early.
        ended = meeting.chunks.contains { $0.state == .recording } ? nil : meeting.ended
        events = meeting.events; notes = meeting.notes
        chunks = meeting.chunks.filter { $0.state != .recording && $0.duration > 0 }.sorted { $0.id < $1.id }.map(TransferChunk.init)
    }
}
public struct TransferAudio: Codable, Sendable {
    public var id: Int
    public var sha256: String
    public var audio: Data
    public init(id: Int, sha256: String, audio: Data) { self.id = id; self.sha256 = sha256; self.audio = audio }
}
public struct TransferEnvelope: Codable, Sendable {
    public var version = 1
    public var revision: Double
    public var meeting: TransferMeeting
    public var audio: [TransferAudio]
    public init(revision: Double, meeting: TransferMeeting, audio: [TransferAudio]) {
        self.revision = revision; self.meeting = meeting; self.audio = audio
    }
}
public enum HostDestination {
    /// Only HTTPS Tailscale destinations are permitted; the app also pins its host certificate.
    public static func validate(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              url.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        if url.scheme == "https", host.hasSuffix(".ts.net") { return url }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard url.scheme == "https", octets.count == 4, octets[0] == 100,
              (64...127).contains(octets[1]), octets.allSatisfy({ (0...255).contains($0) }),
              host == octets.map(String.init).joined(separator: ".") else { return nil }
        return url
    }
}
public struct AudioRecoveryPolicy: Sendable {
    public private(set) var interrupted = false
    public private(set) var attempts = 0
    public init() {}
    public mutating func interruptionBegan() { interrupted = true; attempts = 0 }
    public mutating func interruptionEnded() { interrupted = false; attempts = 0 }
    public mutating func succeeded() { attempts = 0 }
    public mutating func nextDelay() -> Double? {
        guard !interrupted, attempts < 5 else { return nil }
        let delay = [1.0, 2, 4, 8, 15][attempts]; attempts += 1; return delay
    }
}
