/*
 * Live Translate History Storage
 * Persists bilingual translation turns in Application Support.
 */

import Foundation

final class LiveTranslateHistoryStorage {
    static let shared = LiveTranslateHistoryStorage()

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
        do {
            return try JSONDecoder().decode([TranslateRecord].self, from: data)
                .sorted { $0.timestamp < $1.timestamp }
        } catch {
            print("❌ [TranslateStorage] 读取历史失败: \(error.localizedDescription)")
            return []
        }
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

    func deleteAll() {
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
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
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            print("❌ [TranslateStorage] 保存历史失败: \(error.localizedDescription)")
        }
    }
}
