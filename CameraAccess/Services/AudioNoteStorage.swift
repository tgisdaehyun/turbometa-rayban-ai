import Foundation

final class AudioNoteStorage {
    static let shared = AudioNoteStorage()

    private struct Envelope: Codable {
        let version: Int
        let notes: [AudioNote]
    }

    private let fileManager: FileManager
    private let baseURL: URL
    private let indexURL: URL
    private let queue = DispatchQueue(label: "com.turbometa.audio-note-storage")

    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager
        let root = baseURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurboMeta", isDirectory: true)
        self.baseURL = root.appendingPathComponent("AudioNotes", isDirectory: true)
        self.indexURL = root.appendingPathComponent("audio-notes.json")
        try? fileManager.createDirectory(at: self.baseURL, withIntermediateDirectories: true)
    }

    func loadAll() -> [AudioNote] {
        queue.sync { loadUnlocked().sorted { $0.createdAt > $1.createdAt } }
    }

    @discardableResult
    func upsert(_ note: AudioNote) -> [AudioNote] {
        queue.sync {
            var notes = loadUnlocked()
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes[index] = note
            } else {
                notes.append(note)
            }
            persistUnlocked(notes)
            return notes.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func note(id: UUID) -> AudioNote? {
        queue.sync { loadUnlocked().first { $0.id == id } }
    }

    func directory(for id: UUID) throws -> URL {
        let url = baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func audioURL(for note: AudioNote) -> URL {
        baseURL.appendingPathComponent(note.audioRelativePath)
    }

    @discardableResult
    func delete(id: UUID) -> [AudioNote] {
        queue.sync {
            var notes = loadUnlocked()
            notes.removeAll { $0.id == id }
            try? fileManager.removeItem(at: baseURL.appendingPathComponent(id.uuidString, isDirectory: true))
            persistUnlocked(notes)
            return notes.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func deleteAll() {
        queue.sync {
            try? fileManager.removeItem(at: baseURL)
            try? fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
            persistUnlocked([])
        }
    }

    func storageSize() -> Int64 {
        queue.sync {
            guard let enumerator = fileManager.enumerator(at: baseURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            return enumerator.reduce(into: Int64(0)) { result, value in
                guard let url = value as? URL,
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
                result += Int64(size)
            }
        }
    }

    private func loadUnlocked() -> [AudioNote] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Envelope.self, from: data).notes) ?? []
    }

    private func persistUnlocked(_ notes: [AudioNote]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Envelope(version: 1, notes: notes)) else { return }
        try? fileManager.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }
}
