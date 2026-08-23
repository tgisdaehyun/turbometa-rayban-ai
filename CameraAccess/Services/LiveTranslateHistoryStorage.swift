/*
 * Live Translate History Storage
 * Persists bilingual translation turns in Application Support.
 */

import Foundation

extension Notification.Name {
    static let liveTranslateHistoryDidChange = Notification.Name("liveTranslateHistoryDidChange")
}

final class LiveTranslateHistoryStorage {
    static let shared = LiveTranslateHistoryStorage()
    /// Bumping this version intentionally invalidates the pre-protocol-graph
    /// history. Those records were paired with FIFO/text heuristics and are
    /// unsafe to display after the coordinator rewrite.
    static let currentSchemaVersion = 2

    private struct Envelope: Codable {
        let schemaVersion: Int
        let records: [TranslateRecord]
    }

    /// Decode only the version first so a future envelope is preserved even
    /// when its record payload uses fields this app does not understand yet.
    private struct EnvelopeVersion: Decodable {
        let schemaVersion: Int
    }

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("TurboMeta", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("live-translate-history.json")
        }
    }

    func loadAll() -> [TranslateRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()

        if let version = try? decoder.decode(EnvelopeVersion.self, from: data) {
            if version.schemaVersion < Self.currentSchemaVersion {
                discardLegacyFile()
                return []
            }
            guard version.schemaVersion == Self.currentSchemaVersion,
                  let envelope = try? decoder.decode(Envelope.self, from: data) else {
                // Future schemas are intentionally preserved for a newer app
                // version. A malformed current envelope is also left intact
                // so loadAll remains non-destructive for unknown data.
                return []
            }
            return envelope.records.sorted { $0.timestamp < $1.timestamp }
        }

        // The first storage format was a raw [TranslateRecord] array. It is
        // unsafe after the protocol graph rewrite, so remove it once rather
        // than repeatedly parsing and ignoring the same file. Do not post a
        // notification here: the caller is already handling this load, and a
        // synchronous notification would re-enter RecordsView.load().
        if (try? decoder.decode([TranslateRecord].self, from: data)) != nil {
            discardLegacyFile()
        }
        return []
    }

    @discardableResult
    func upsert(_ record: TranslateRecord) -> [TranslateRecord] {
        var records = loadAll()
        if let index = records.firstIndex(where: { existing in
            existing.id == record.id ||
                (record.sessionID != nil && existing.sessionID == record.sessionID &&
                    record.responseID != nil && existing.responseID == record.responseID) ||
                (record.sessionID != nil && existing.sessionID == record.sessionID &&
                    record.sourceItemID != nil && existing.sourceItemID == record.sourceItemID)
        }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.timestamp < $1.timestamp }
        persist(records)
        return records
    }

    /// Removes all turns whose IDs are in `ids` and returns the remaining
    /// history. The replacement is written atomically, so a session delete
    /// cannot leave a partially updated JSON document behind.
    @discardableResult
    func deleteRecords(ids: [UUID]) -> [TranslateRecord] {
        guard !ids.isEmpty else { return loadAll() }
        let idsToDelete = Set(ids)
        let records = loadAll().filter { !idsToDelete.contains($0.id) }
        persist(records)
        return records
    }

    @discardableResult
    func deleteRecords(ids: Set<UUID>) -> [TranslateRecord] {
        deleteRecords(ids: Array(ids))
    }

    func deleteAll() {
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            NotificationCenter.default.post(name: .liveTranslateHistoryDidChange, object: self)
        } catch {
            print("❌ [TranslateStorage] 清空历史失败: \(error.localizedDescription)")
        }
    }

    private func persist(_ records: [TranslateRecord]) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, records: records)
            try encoder.encode(envelope).write(to: fileURL, options: .atomic)
            NotificationCenter.default.post(name: .liveTranslateHistoryDidChange, object: self)
        } catch {
            print("❌ [TranslateStorage] 保存历史失败: \(error.localizedDescription)")
        }
    }

    private func discardLegacyFile() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            print("❌ [TranslateStorage] 删除旧历史失败: \(error.localizedDescription)")
        }
    }
}
