import Foundation

public struct Utterance: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public var original: String
    public var korean: String
    public init(start: Double, end: Double, speaker: String, original: String, korean: String) {
        self.start = start; self.end = end; self.speaker = speaker; self.original = original; self.korean = korean
    }
}
public enum ChunkState: String, Codable, Sendable { case recording, queued, processing, complete, failed }
public struct AudioChunk: Codable, Identifiable, Sendable {
    public var id: Int
    public var filename: String
    public var start: Double
    public var duration: Double
    public var state: ChunkState
    public var utterances: [Utterance] = []
    public var error: String?
    public init(id: Int, filename: String, start: Double, duration: Double = 0, state: ChunkState = .recording) {
        self.id = id; self.filename = filename; self.start = start; self.duration = duration; self.state = state
    }
}
public struct Meeting: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var title: String
    public var created = Date()
    public var ended: Date?
    public var chunks: [AudioChunk] = []
    public var events: [String] = []
    public var notes = ""
    public init(title: String) { self.title = title }
    public var pending: Int { chunks.filter { $0.state != .complete }.count }
    public var duration: Double { chunks.map { $0.start + $0.duration }.max() ?? 0 }
    public var markdown: String {
        var lines = ["# \(title)", "", "\(created.formatted())", "", "중국어 등 발화 원문 · 한국어 번역", "화자 표시는 각 녹음 구간 안에서만 구분합니다. 타임스탬프는 AI 추정값입니다.", ""]
        if !notes.isEmpty { lines += ["## 메모", notes, ""] }
        for chunk in chunks.sorted(by: { $0.id < $1.id }) {
            if chunk.state != .complete { lines += ["> \(Self.timestamp(chunk.start)) · 전사 미완료: \(chunk.error ?? chunk.state.rawValue)", ""] }
            for u in chunk.utterances {
                lines += ["### \(Self.timestamp(chunk.start + u.start)) · \(u.speaker)", "", u.original, "", u.korean, ""]
            }
        }
        if !events.isEmpty { lines += ["## 녹음 상태 기록"] + events.map { "- \($0)" } }
        return lines.joined(separator: "\n")
    }
    public static func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}
public enum TranscriptError: Error, LocalizedError {
    case invalidResponse
    case invalidTime
    public var errorDescription: String? {
        switch self { case .invalidResponse: return "전사 응답 형식이 올바르지 않습니다. 녹음은 보관돼 있습니다."
        case .invalidTime: return "전사 시간 정보가 녹음 구간과 맞지 않습니다. 다시 시도해 주세요." }
    }
}
public enum TranscriptDecoder {
    public static func decode(_ data: Data, duration: Double) throws -> [Utterance] {
        struct Response: Decodable { var segments: [Utterance] }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.segments.count <= 200 else { throw TranscriptError.invalidResponse }
        return try response.segments.filter { !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { item in
            guard item.start.isFinite, item.end.isFinite, item.start >= 0, item.start <= duration, item.end >= item.start, item.end <= duration + 0.5, !item.korean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptError.invalidTime }
            var normalized = item
            normalized.end = min(duration, item.end)
            return normalized
        }.sorted { $0.start < $1.start }
    }
}
public enum WAV {
    public static let sampleRate = 16_000
    public static let bytesPerSecond = 32_000
    public static func header(byteCount: Int) -> Data {
        precondition(byteCount >= 0 && byteCount <= Int(UInt32.max) - 36)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { data.append(UInt8(value & 255)); data.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> shift) & 255)) } }
        text("RIFF"); u32(UInt32(byteCount + 36)); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(bytesPerSecond)); u16(2); u16(16); text("data"); u32(UInt32(byteCount))
        return data
    }
    @discardableResult public static func repair(_ url: URL) throws -> Double {
        let handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 44, size < UInt32.max else { throw TranscriptError.invalidResponse }
        let count = Int(size - 44) / 2 * 2
        try handle.truncate(atOffset: UInt64(count + 44)); try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(byteCount: count)); try handle.synchronize()
        return Double(count) / Double(bytesPerSecond)
    }
}
