import Foundation

public enum AudioSanity {
    /// Conservative PCM signal gate, not speech recognition. Keeps original WAVs untouched.
    public static func hasSignal(_ wav: Data) throws -> Bool {
        let b = [UInt8](wav)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard b.count >= 44, String(bytes: b[0..<4], encoding: .ascii) == "RIFF", String(bytes: b[8..<12], encoding: .ascii) == "WAVE" else { throw TranscriptError.invalidResponse }
        var offset = 12; var validFormat = false; var samples: Range<Int>?
        while offset + 8 <= b.count {
            let size = u32(offset + 4), start = offset + 8
            guard size <= b.count - start else { throw TranscriptError.invalidResponse }
            let name = String(bytes: b[offset..<(offset + 4)], encoding: .ascii)
            if name == "fmt " {
                guard size >= 16, u16(start) == 1, u16(start + 2) == 1, u32(start + 4) == 16000, u16(start + 14) == 16 else { throw TranscriptError.invalidResponse }
                validFormat = true
            }
            if name == "data" { samples = start..<(start + size) }
            offset = start + size + size % 2
        }
        guard validFormat, let samples, samples.count % 2 == 0 else { throw TranscriptError.invalidResponse }
        var activeFrames = 0
        for start in stride(from: samples.lowerBound, to: samples.upperBound, by: 640) {
            let end = min(start + 640, samples.upperBound)
            var energy = 0.0; var peak = 0; var count = 0
            for i in stride(from: start, to: end, by: 2) {
                let value = Int(Int16(bitPattern: UInt16(u16(i))))
                energy += Double(value) * Double(value); peak = max(peak, abs(value)); count += 1
            }
            if count > 0 && sqrt(energy / Double(count)) >= 50 && peak >= 150 { activeFrames += count }
            if activeFrames >= 960 { return true } // At least 60 ms above a deliberately low floor.
        }
        return false
    }
    public static func isPlaybackEcho(original: String, spoken: [String]) -> Bool {
        guard original.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) else { return false }
        func normalized(_ value: String) -> String { String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        let text = normalized(original)
        guard text.count >= 8 else { return false }
        return spoken.contains { phrase in
            let candidate = normalized(phrase)
            let shortest = min(text.count, candidate.count), longest = max(text.count, candidate.count)
            return shortest >= 8 && Double(shortest) / Double(max(1, longest)) >= 0.8 && (text.contains(candidate) || candidate.contains(text))
        }
    }
}
