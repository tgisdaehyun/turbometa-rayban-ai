/*
 * Live Translate Models
 * 实时翻译数据模型：语种、音色、翻译记录
 */

import Foundation

// MARK: - 支持的语种

enum TranslateLanguage: String, CaseIterable, Codable, Identifiable {
    // Qwen3.5-LiveTranslate 当前应用支持的语种。
    // 目标语种的音频输出能力由 supportsAudioOutput 明确声明；其余语种仍可作为文本目标。
    case en = "en"      // 英语
    case zh = "zh"      // 中文
    case ja = "ja"      // 日语
    case ko = "ko"      // 韩语
    case fr = "fr"      // 法语
    case de = "de"      // 德语
    case ru = "ru"      // 俄语
    case es = "es"      // 西班牙语
    case pt = "pt"      // 葡萄牙语
    case it = "it"      // 意大利语
    case yue = "yue"    // 粤语

    // 其余当前应用支持的语种
    case id = "id"      // 印尼语
    case vi = "vi"      // 越南语
    case th = "th"      // 泰语
    case ar = "ar"      // 阿拉伯语
    case hi = "hi"      // 印地语
    case el = "el"      // 希腊语
    case tr = "tr"      // 土耳其语

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .en: return "livetranslate.lang.en".localized
        case .zh: return "livetranslate.lang.zh".localized
        case .ja: return "livetranslate.lang.ja".localized
        case .ko: return "livetranslate.lang.ko".localized
        case .fr: return "livetranslate.lang.fr".localized
        case .de: return "livetranslate.lang.de".localized
        case .ru: return "livetranslate.lang.ru".localized
        case .es: return "livetranslate.lang.es".localized
        case .pt: return "livetranslate.lang.pt".localized
        case .it: return "livetranslate.lang.it".localized
        case .yue: return "livetranslate.lang.yue".localized
        case .id: return "livetranslate.lang.id".localized
        case .vi: return "livetranslate.lang.vi".localized
        case .th: return "livetranslate.lang.th".localized
        case .ar: return "livetranslate.lang.ar".localized
        case .hi: return "livetranslate.lang.hi".localized
        case .el: return "livetranslate.lang.el".localized
        case .tr: return "livetranslate.lang.tr".localized
        }
    }

    var flag: String {
        switch self {
        case .en: return "🇺🇸"
        case .zh: return "🇨🇳"
        case .ja: return "🇯🇵"
        case .ko: return "🇰🇷"
        case .fr: return "🇫🇷"
        case .de: return "🇩🇪"
        case .ru: return "🇷🇺"
        case .es: return "🇪🇸"
        case .pt: return "🇵🇹"
        case .it: return "🇮🇹"
        case .yue: return "🇭🇰"
        case .id: return "🇮🇩"
        case .vi: return "🇻🇳"
        case .th: return "🇹🇭"
        case .ar: return "🇸🇦"
        case .hi: return "🇮🇳"
        case .el: return "🇬🇷"
        case .tr: return "🇹🇷"
        }
    }

    /// 是否支持作为目标语言输出音频。
    ///
    /// Qwen3.5-LiveTranslate 的粤语和希腊语在当前模型中仅支持文本输出；
    /// 其余枚举语种均在官方音频+文本语种列表中。
    var supportsAudioOutput: Bool {
        switch self {
        case .en, .zh, .ja, .ko, .fr, .de, .ru, .es, .pt, .it,
             .id, .vi, .th, .ar, .hi, .tr:
            return true
        case .yue, .el:
            return false
        }
    }

    /// 可作为目标语言的语种（音频+文本或仅文本）。
    /// 仅文本目标仍可在关闭语音输出时使用。
    static var targetLanguages: [TranslateLanguage] {
        allCases
    }

    /// 所有源语言
    static var sourceLanguages: [TranslateLanguage] {
        allCases
    }
}

// MARK: - 翻译音色

enum TranslateVoice: String, CaseIterable, Codable, Identifiable {
    case tina = "Tina"
    case cindy = "Cindy"
    case lioraMira = "Liora Mira"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tina: return "livetranslate.voice.tina".localized
        case .cindy: return "livetranslate.voice.cindy".localized
        case .lioraMira: return "livetranslate.voice.liora_mira".localized
        }
    }

    var description: String {
        switch self {
        case .tina: return "livetranslate.voice.tina.desc".localized
        case .cindy: return "livetranslate.voice.cindy.desc".localized
        case .lioraMira: return "livetranslate.voice.liora_mira.desc".localized
        }
    }

    /// Qwen3.5-LiveTranslate 三个系统音色都支持的当前应用语种子集。
    /// 粤语和希腊语为文本目标，不作为音频播报语种声明。
    var supportedLanguages: [TranslateLanguage] {
        [.zh, .en, .fr, .de, .ru, .it, .es, .pt, .ja, .ko,
         .id, .vi, .th, .ar, .hi, .tr]
    }

    /// 检查音色是否支持指定语种
    func supports(language: TranslateLanguage) -> Bool {
        supportedLanguages.contains(language)
    }
}

// MARK: - 翻译记录

struct TranslateRecord: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let sessionID: UUID?
    let sourceItemID: String?
    let responseID: String?
    let sourceLanguage: TranslateLanguage
    let targetLanguage: TranslateLanguage
    let originalText: String      // 识别的原文
    let translatedText: String    // 翻译结果

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionID: UUID? = nil,
        sourceItemID: String? = nil,
        responseID: String? = nil,
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage,
        originalText: String,
        translatedText: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.sourceItemID = sourceItemID
        self.responseID = responseID
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.originalText = originalText
        self.translatedText = translatedText
    }
}

// MARK: - 翻译会话

/// A group of bilingual turns produced by one recording session.
///
/// `TranslateRecord.sessionID` was added after the first version of history
/// storage. The builder below intentionally keeps records without a session
/// ID as one-record sessions so old history remains visible and deletable.
struct TranslationSession: Identifiable {
    let id: UUID
    let records: [TranslateRecord]

    var startDate: Date { records.first?.timestamp ?? .distantPast }
    var endDate: Date { records.last?.timestamp ?? startDate }
    var turnCount: Int { records.count }

    var previewText: String {
        records.lazy
            .map(\.translatedText)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? ""
    }

    var hasMixedLanguageDirections: Bool {
        Set(records.map {
            "\($0.sourceLanguage.rawValue)->\($0.targetLanguage.rawValue)"
        }).count > 1
    }
}

enum TranslationSessionBuilder {
    /// Groups records by their business session and applies stable ordering.
    /// Records written before `sessionID` existed intentionally do not share a
    /// synthetic session, because there is no safe way to infer boundaries.
    static func group(records: [TranslateRecord]) -> [TranslationSession] {
        var grouped: [String: (id: UUID, records: [TranslateRecord])] = [:]

        for record in records {
            let key: String
            let sessionID: UUID
            if let existingSessionID = record.sessionID {
                key = "session:\(existingSessionID.uuidString)"
                sessionID = existingSessionID
            } else {
                key = "legacy:\(record.id.uuidString)"
                sessionID = record.id
            }

            if grouped[key] == nil {
                grouped[key] = (sessionID, [])
            }
            var group = grouped[key]!
            group.records.append(record)
            grouped[key] = group
        }

        return grouped.values
            .map { value in
                TranslationSession(
                    id: value.id,
                    records: value.records.sorted(by: Self.recordAscending)
                )
            }
            .sorted { lhs, rhs in
                if lhs.endDate != rhs.endDate {
                    return lhs.endDate > rhs.endDate
                }
                return lhs.id.uuidString > rhs.id.uuidString
            }
    }

    private static func recordAscending(_ lhs: TranslateRecord, _ rhs: TranslateRecord) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

// MARK: - Structured Realtime Events

struct TranslateSourceTranscriptEvent: Equatable {
    let itemID: String
    let confirmedText: String
    let pendingText: String
    let isFinal: Bool

    var displayText: String {
        isFinal ? confirmedText : confirmedText + pendingText
    }
}

struct TranslateTextEvent: Equatable {
    let responseID: String
    let itemID: String?
    let confirmedText: String
    let pendingText: String
    let isFinal: Bool

    var displayText: String {
        isFinal ? confirmedText : confirmedText + pendingText
    }
}

struct TranslationTurnSnapshot: Identifiable, Equatable {
    let id: UUID
    let sourceItemID: String?
    let responseID: String?
    let originalText: String
    let translatedText: String
    let isSourceFinal: Bool
    let isTranslationFinal: Bool
    /// Creation order controls source-card display only. It is intentionally
    /// never used to associate or persist a bilingual record.
    let creationIndex: Int
}

/// A coordinator snapshot is deliberately richer than what the live list
/// needs. SwiftUI never renders raw coordinator snapshots directly.
struct TranslationDisplayTurn: Identifiable, Equatable {
    let id: UUID
    let sourceItemID: String?
    let responseID: String?
    let originalText: String
    let translatedText: String
    let isSourceFinal: Bool
    let isTranslationFinal: Bool
}

enum TranslationPlaybackState: Equatable {
    case idle
    case playing(responseID: String)
}

/// Buffers streaming PCM payloads by response ID. The head response can play
/// while audio deltas are still arriving; a later response cannot start until
/// the head has both received `response.audio.done` and played every locally
/// scheduled buffer.
struct TranslationAudioResponse: Equatable {
    let responseID: String
    var pendingData: Data
    var isServerFinished: Bool
    var scheduledBufferCount: Int
}

struct TranslationAudioQueue {
    private(set) var responseOrder: [String] = []
    private(set) var responses: [String: TranslationAudioResponse] = [:]
    private(set) var activeResponseID: String?
    private(set) var completedResponseIDs: Set<String> = []

    var isEmpty: Bool { responseOrder.isEmpty && activeResponseID == nil }

    /// Number of responses waiting behind the currently playing response.
    var pendingCount: Int {
        max(0, responseOrder.count - (activeResponseID == nil ? 0 : 1))
    }

    /// Registers the server's response lifecycle order before audio chunks
    /// arrive. This keeps playback order independent from which response's
    /// first PCM packet happens to reach the client first.
    mutating func register(responseID: String) {
        guard !responseID.isEmpty,
              !completedResponseIDs.contains(responseID),
              responses[responseID] == nil else { return }
        responses[responseID] = TranslationAudioResponse(
            responseID: responseID,
            pendingData: Data(),
            isServerFinished: false,
            scheduledBufferCount: 0
        )
        responseOrder.append(responseID)
    }

    mutating func append(_ data: Data, responseID: String) {
        guard !completedResponseIDs.contains(responseID) else { return }
        register(responseID: responseID)
        responses[responseID]?.pendingData.append(data)
    }

    /// Seals a response. Returns true when the active response had already
    /// played all of its buffers and can be removed immediately.
    @discardableResult
    mutating func markServerFinished(_ responseID: String) -> Bool {
        guard !completedResponseIDs.contains(responseID) else { return false }
        if responses[responseID] == nil {
            responses[responseID] = TranslationAudioResponse(
                responseID: responseID,
                pendingData: Data(),
                isServerFinished: true,
                scheduledBufferCount: 0
            )
            responseOrder.append(responseID)
        } else {
            responses[responseID]?.isServerFinished = true
        }
        return finishActiveIfDrained(responseID)
    }

    /// Used only when the session-finalization watchdog expires. Any received
    /// PCM is still played in order; this avoids dropping audio merely because
    /// the final `response.audio.done` packet was lost.
    mutating func markAllServerFinished() {
        for responseID in responseOrder {
            responses[responseID]?.isServerFinished = true
        }
    }

    /// Activates the oldest response as soon as it has streaming PCM, without
    /// waiting for `audio.done`. A sealed empty response is also activated so
    /// the owner can complete it and advance the queue.
    mutating func activateNextIfReady() -> String? {
        if let activeResponseID { return activeResponseID }
        guard let responseID = responseOrder.first,
              let response = responses[responseID],
              !response.pendingData.isEmpty || response.isServerFinished else { return nil }
        activeResponseID = responseID
        return responseID
    }

    /// Moves all currently received PCM for the active response into one
    /// scheduled player buffer. Later deltas remain eligible for another call.
    mutating func takePendingAudio(_ responseID: String) -> Data? {
        guard activeResponseID == responseID,
              var response = responses[responseID],
              !response.pendingData.isEmpty else { return nil }
        let data = response.pendingData
        response.pendingData.removeAll(keepingCapacity: true)
        response.scheduledBufferCount += 1
        responses[responseID] = response
        return data
    }

    /// Marks one scheduled PCM buffer as physically played. Returns true only
    /// when this was the final local buffer of a server-finished response.
    @discardableResult
    mutating func markBufferPlayed(_ responseID: String) -> Bool {
        guard activeResponseID == responseID,
              var response = responses[responseID],
              response.scheduledBufferCount > 0 else { return false }
        response.scheduledBufferCount -= 1
        responses[responseID] = response
        return finishActiveIfDrained(responseID)
    }

    /// Completes a sealed response that contains no pending or scheduled PCM.
    @discardableResult
    mutating func completeActiveIfDrained(_ responseID: String) -> Bool {
        finishActiveIfDrained(responseID)
    }

    /// Drops an active response after a local playback setup failure so one
    /// malformed response cannot permanently block all later translations.
    @discardableResult
    mutating func discardActive(_ responseID: String) -> Bool {
        guard activeResponseID == responseID else { return false }
        remove(responseID)
        return true
    }

    private mutating func finishActiveIfDrained(_ responseID: String) -> Bool {
        guard activeResponseID == responseID,
              let response = responses[responseID],
              response.isServerFinished,
              response.pendingData.isEmpty,
              response.scheduledBufferCount == 0 else { return false }
        remove(responseID)
        return true
    }

    private mutating func remove(_ responseID: String) {
        completedResponseIDs.insert(responseID)
        responses.removeValue(forKey: responseID)
        responseOrder.removeAll { $0 == responseID }
        activeResponseID = nil
    }

    mutating func reset() {
        responseOrder.removeAll()
        responses.removeAll()
        activeResponseID = nil
        completedResponseIDs.removeAll()
    }
}

/// Pairs realtime source and translation events exclusively through the
/// protocol's item graph:
///
///     response_id -> assistant item id -> previous_item_id (source item id)
///
/// The graph is intentionally independent from event arrival order. Every
/// event is retained until the other side of the relationship arrives. No
/// arrival ordering, timing, text similarity, or response ordering is allowed
/// to associate two turns.
struct TranslationTurnCoordinator {
    private struct SourceState {
        let recordID: UUID
        let itemID: String
        let creationIndex: Int
        var text = ""
        var isFinal = false
        var timestamp = Date()
    }

    private struct ResponseState {
        let responseID: String
        let creationIndex: Int
        var assistantItemID: String?
        var text = ""
        var isFinal = false
        var isResponseDone = false
        var timestamp = Date()
    }

    let sessionID: UUID
    private(set) var sourceLanguage: TranslateLanguage
    private(set) var targetLanguage: TranslateLanguage
    private var sourceOrder: [String] = []
    private var sources: [String: SourceState] = [:]
    private var responses: [String: ResponseState] = [:]
    private var sourceItemIDByAssistantItemID: [String: String] = [:]
    private var nextCreationIndex = 0

    init(
        sessionID: UUID = UUID(),
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage
    ) {
        self.sessionID = sessionID
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }

    mutating func updateLanguages(source: TranslateLanguage, target: TranslateLanguage) {
        sourceLanguage = source
        targetLanguage = target
    }

    mutating func receiveSpeechStarted(itemID: String? = nil) -> TranslationCoordinatorUpdate {
        if let itemID, !itemID.isEmpty {
            ensureSource(itemID: itemID)
        }
        return makeUpdate()
    }

    mutating func receiveSpeechStopped(itemID: String? = nil) -> TranslationCoordinatorUpdate {
        // speech_stopped is a lifecycle hint only. The source transcription
        // completed event remains the sole source-final signal.
        _ = itemID
        return makeUpdate()
    }

    mutating func receiveSource(_ event: TranslateSourceTranscriptEvent) -> TranslationCoordinatorUpdate {
        guard !event.itemID.isEmpty else { return makeUpdate() }
        let sourceID = ensureSource(itemID: event.itemID)
        guard var source = sources[sourceID] else { return makeUpdate() }

        // `text + stash` is a complete replacement snapshot. A final event
        // must replace an interim value even when it is shorter.
        if source.isFinal && !event.isFinal {
            return makeUpdate()
        }
        source.text = event.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        source.isFinal = source.isFinal || event.isFinal
        source.timestamp = Date()
        sources[sourceID] = source
        return makeUpdate()
    }

    mutating func receiveTranslation(_ event: TranslateTextEvent) -> TranslationCoordinatorUpdate {
        guard !event.responseID.isEmpty else { return makeUpdate() }
        ensureResponse(responseID: event.responseID)
        guard var response = responses[event.responseID] else { return makeUpdate() }

        if let itemID = event.itemID, !itemID.isEmpty {
            response.assistantItemID = itemID
        }
        if response.isFinal && !event.isFinal {
            responses[event.responseID] = response
            return makeUpdate()
        }
        response.text = event.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        response.isFinal = response.isFinal || event.isFinal
        response.timestamp = Date()
        responses[event.responseID] = response
        return makeUpdate()
    }

    mutating func receiveResponseStarted(responseID: String) -> TranslationCoordinatorUpdate {
        guard !responseID.isEmpty else { return makeUpdate() }
        ensureResponse(responseID: responseID)
        return makeUpdate()
    }

    mutating func receiveResponseFinished(responseID: String) -> TranslationCoordinatorUpdate {
        guard !responseID.isEmpty else { return makeUpdate() }
        ensureResponse(responseID: responseID)
        responses[responseID]?.isResponseDone = true
        // response.done is not a transcript completion event. Do not modify
        // `isFinal` here; audio_transcript.done/text.done owns that state.
        return makeUpdate()
    }

    /// Connects a response id to its assistant output item. This event may
    /// arrive before or after the conversation item link and transcript.
    mutating func receiveResponseItem(responseID: String, itemID: String) -> TranslationCoordinatorUpdate {
        guard !responseID.isEmpty, !itemID.isEmpty else { return makeUpdate() }
        ensureResponse(responseID: responseID)
        responses[responseID]?.assistantItemID = itemID
        return makeUpdate()
    }

    /// Stores the authoritative assistant-item -> source-item relationship
    /// carried by `conversation.item.created.previous_item_id`.
    mutating func receiveLink(sourceItemID: String, responseItemID: String) -> TranslationCoordinatorUpdate {
        guard !sourceItemID.isEmpty, !responseItemID.isEmpty else { return makeUpdate() }
        _ = ensureSource(itemID: sourceItemID)
        sourceItemIDByAssistantItemID[responseItemID] = sourceItemID
        return makeUpdate()
    }

    /// A session can only persist fully linked, fully completed bilingual
    /// turns. Unlinked responses are intentionally omitted from the update.
    mutating func finalize() -> TranslationCoordinatorUpdate {
        makeUpdate()
    }

    @discardableResult
    private mutating func ensureSource(itemID: String) -> String {
        guard let existing = sources[itemID] else {
            let source = SourceState(
                recordID: UUID(),
                itemID: itemID,
                creationIndex: takeCreationIndex()
            )
            sources[itemID] = source
            sourceOrder.append(itemID)
            return itemID
        }
        _ = existing
        return itemID
    }

    private mutating func ensureResponse(responseID: String) {
        guard responses[responseID] == nil else { return }
        responses[responseID] = ResponseState(
            responseID: responseID,
            creationIndex: takeCreationIndex()
        )
    }

    private mutating func takeCreationIndex() -> Int {
        defer { nextCreationIndex += 1 }
        return nextCreationIndex
    }

    private func linkedResponse(for sourceItemID: String) -> ResponseState? {
        responses.values
            .filter { response in
                guard let assistantItemID = response.assistantItemID,
                      let linkedSourceID = sourceItemIDByAssistantItemID[assistantItemID] else {
                    return false
                }
                return linkedSourceID == sourceItemID
            }
            .sorted {
                if $0.creationIndex != $1.creationIndex {
                    return $0.creationIndex < $1.creationIndex
                }
                return $0.responseID < $1.responseID
            }
            .first
    }

    private func makeUpdate() -> TranslationCoordinatorUpdate {
        var snapshots: [TranslationTurnSnapshot] = []
        var records: [TranslateRecord] = []

        for sourceID in sourceOrder {
            guard let source = sources[sourceID] else { continue }
            let response = linkedResponse(for: sourceID)
            // Never expose a translation-only card. A source card may remain
            // provisional while the authoritative assistant link is pending.
            guard !source.text.isEmpty else { continue }

            let snapshot = TranslationTurnSnapshot(
                id: source.recordID,
                sourceItemID: source.itemID,
                responseID: response?.responseID,
                originalText: source.text,
                translatedText: response?.text ?? "",
                isSourceFinal: source.isFinal,
                isTranslationFinal: response?.isFinal ?? false,
                creationIndex: source.creationIndex
            )
            snapshots.append(snapshot)

            guard let response,
                  source.isFinal,
                  response.isFinal,
                  !source.text.isEmpty,
                  !response.text.isEmpty else {
                continue
            }

            records.append(TranslateRecord(
                id: source.recordID,
                timestamp: max(source.timestamp, response.timestamp),
                sessionID: sessionID,
                sourceItemID: source.itemID,
                responseID: response.responseID,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                originalText: source.text,
                translatedText: response.text
            ))
        }

        return TranslationCoordinatorUpdate(turns: snapshots, recordsToUpsert: records)
    }
}

struct TranslationCoordinatorUpdate {
    let turns: [TranslationTurnSnapshot]
    let recordsToUpsert: [TranslateRecord]
}

// MARK: - WebSocket 事件

enum TranslateClientEvent: String {
    case sessionUpdate = "session.update"
    case sessionFinish = "session.finish"
    case inputAudioBufferAppend = "input_audio_buffer.append"
    case inputImageBufferAppend = "input_image_buffer.append"
}

enum TranslateServerEvent: String {
    case sessionCreated = "session.created"
    case sessionUpdated = "session.updated"
    case responseCreated = "response.created"
    case conversationItemCreated = "conversation.item.created"
    case responseOutputItemAdded = "response.output_item.added"
    case responseContentPartAdded = "response.content_part.added"
    case inputAudioBufferSpeechStarted = "input_audio_buffer.speech_started"
    case inputAudioBufferSpeechStopped = "input_audio_buffer.speech_stopped"
    case sourceTranscriptText = "conversation.item.input_audio_transcription.text"
    case sourceTranscriptCompleted = "conversation.item.input_audio_transcription.completed"
    case sourceTranscriptFailed = "conversation.item.input_audio_transcription.failed"
    case responseAudioTranscriptText = "response.audio_transcript.text"
    case responseAudioTranscriptDone = "response.audio_transcript.done"
    case responseTextText = "response.text.text"
    case responseTextDone = "response.text.done"
    case responseAudioDelta = "response.audio.delta"
    case responseAudioDone = "response.audio.done"
    case responseContentPartDone = "response.content_part.done"
    case responseOutputItemDone = "response.output_item.done"
    case responseDone = "response.done"
    case sessionFinished = "session.finished"
    case error = "error"
}
