/*
 * Live Translate Models
 * 实时翻译数据模型：语种、音色、翻译记录
 */

import Foundation

// MARK: - 支持的语种

enum TranslateLanguage: String, CaseIterable, Codable, Identifiable {
    // 支持音频+文本输出的语种
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

    // 仅支持输入（作为源语言）的语种
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

    /// 是否支持作为目标语言（输出音频+文本）
    var supportsAudioOutput: Bool {
        switch self {
        case .en, .zh, .ja, .ko, .fr, .de, .ru, .es, .pt, .it, .yue:
            return true
        case .id, .vi, .th, .ar, .hi, .el, .tr:
            return false
        }
    }

    /// 可作为目标语言的语种
    static var targetLanguages: [TranslateLanguage] {
        allCases.filter { $0.supportsAudioOutput }
    }

    /// 所有源语言
    static var sourceLanguages: [TranslateLanguage] {
        allCases
    }
}

// MARK: - 翻译音色

enum TranslateVoice: String, CaseIterable, Codable, Identifiable {
    case cherry = "Cherry"
    case nofish = "Nofish"
    case jada = "Jada"
    case dylan = "Dylan"
    case sunny = "Sunny"
    case peter = "Peter"
    case kiki = "Kiki"
    case eric = "Eric"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cherry: return "livetranslate.voice.cherry".localized
        case .nofish: return "livetranslate.voice.nofish".localized
        case .jada: return "livetranslate.voice.jada".localized
        case .dylan: return "livetranslate.voice.dylan".localized
        case .sunny: return "livetranslate.voice.sunny".localized
        case .peter: return "livetranslate.voice.peter".localized
        case .kiki: return "livetranslate.voice.kiki".localized
        case .eric: return "livetranslate.voice.eric".localized
        }
    }

    var description: String {
        switch self {
        case .cherry: return "livetranslate.voice.cherry.desc".localized
        case .nofish: return "livetranslate.voice.nofish.desc".localized
        case .jada: return "livetranslate.voice.jada.desc".localized
        case .dylan: return "livetranslate.voice.dylan.desc".localized
        case .sunny: return "livetranslate.voice.sunny.desc".localized
        case .peter: return "livetranslate.voice.peter.desc".localized
        case .kiki: return "livetranslate.voice.kiki.desc".localized
        case .eric: return "livetranslate.voice.eric.desc".localized
        }
    }

    /// 支持的语种（音色可能只支持部分语种）
    var supportedLanguages: [TranslateLanguage] {
        switch self {
        case .cherry, .nofish:
            // 支持多语种
            return [.zh, .en, .fr, .de, .ru, .it, .es, .pt, .ja, .ko]
        case .jada, .dylan, .sunny, .peter, .eric:
            // 仅支持中文
            return [.zh]
        case .kiki:
            // 仅支持粤语
            return [.yue]
        }
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
}

enum TranslationPlaybackState: Equatable {
    case idle
    case playing(responseID: String)
}

/// Buffers complete PCM payloads by response ID and advances only after the
/// server has sent `response.audio.done`. The owner (the AVAudioPlayerNode
/// service) calls `complete(_:)` from its `dataPlayedBack` callback, so a
/// server completion can never interrupt local playback.
struct TranslationAudioResponse: Equatable {
    let responseID: String
    var data: Data
    var isServerFinished: Bool
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

    mutating func append(_ data: Data, responseID: String) {
        guard !completedResponseIDs.contains(responseID) else { return }
        if responses[responseID] == nil {
            responses[responseID] = TranslationAudioResponse(
                responseID: responseID,
                data: Data(),
                isServerFinished: false
            )
            responseOrder.append(responseID)
        }
        responses[responseID]?.data.append(data)
    }

    mutating func markServerFinished(_ responseID: String) {
        guard !completedResponseIDs.contains(responseID) else { return }
        if responses[responseID] == nil {
            responses[responseID] = TranslationAudioResponse(
                responseID: responseID,
                data: Data(),
                isServerFinished: true
            )
            responseOrder.append(responseID)
        } else {
            responses[responseID]?.isServerFinished = true
        }
    }

    /// Used only when the session-finalization watchdog expires. Any received
    /// PCM is still played in order; this avoids dropping audio merely because
    /// the final `response.audio.done` packet was lost.
    mutating func markAllServerFinished() {
        for responseID in responseOrder {
            responses[responseID]?.isServerFinished = true
        }
    }

    /// Claims the oldest sealed response for playback. Calling this while a
    /// response is active or while the head is not server-finished is a no-op.
    mutating func beginNextIfReady() -> TranslationAudioResponse? {
        guard activeResponseID == nil,
              let responseID = responseOrder.first,
              let response = responses[responseID],
              response.isServerFinished else {
            return nil
        }
        activeResponseID = responseID
        return response
    }

    /// Marks the active response as physically played back and removes it.
    @discardableResult
    mutating func complete(_ responseID: String) -> Bool {
        guard activeResponseID == responseID else { return false }
        completedResponseIDs.insert(responseID)
        responses.removeValue(forKey: responseID)
        responseOrder.removeAll { $0 == responseID }
        activeResponseID = nil
        return true
    }

    mutating func reset() {
        responseOrder.removeAll()
        responses.removeAll()
        activeResponseID = nil
        completedResponseIDs.removeAll()
    }
}

/// Pairs source-ASR and translated-response events using the server-provided
/// item link, with stable arrival order as a fallback for older event streams.
struct TranslationTurnCoordinator {
    private struct SourceState {
        var recordID = UUID()
        let itemID: String
        let creationIndex: Int
        var text = ""
        var isFinal = false
        var timestamp = Date()
    }

    private struct ResponseState {
        var recordID = UUID()
        let responseID: String
        let creationIndex: Int
        var itemID: String?
        var sourceItemID: String?
        var text = ""
        var isFinal = false
        var timestamp = Date()
    }

    let sessionID: UUID
    private(set) var sourceLanguage: TranslateLanguage
    private(set) var targetLanguage: TranslateLanguage
    private var sourceOrder: [String] = []
    private var responseOrder: [String] = []
    private var sources: [String: SourceState] = [:]
    private var responses: [String: ResponseState] = [:]
    private var sourceItemIDByResponseItemID: [String: String] = [:]
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

    mutating func receiveSource(_ event: TranslateSourceTranscriptEvent) -> TranslationCoordinatorUpdate {
        if sources[event.itemID] == nil {
            sources[event.itemID] = SourceState(
                itemID: event.itemID,
                creationIndex: takeCreationIndex()
            )
            sourceOrder.append(event.itemID)
        }
        sources[event.itemID]?.text = event.displayText
        sources[event.itemID]?.isFinal = event.isFinal
        reconcileRecordIDs()
        return makeUpdate()
    }

    mutating func receiveTranslation(_ event: TranslateTextEvent) -> TranslationCoordinatorUpdate {
        if responses[event.responseID] == nil {
            responses[event.responseID] = ResponseState(
                responseID: event.responseID,
                creationIndex: takeCreationIndex()
            )
            responseOrder.append(event.responseID)
        }
        responses[event.responseID]?.itemID = event.itemID
        if let itemID = event.itemID {
            responses[event.responseID]?.sourceItemID = sourceItemIDByResponseItemID[itemID]
        }
        responses[event.responseID]?.text = event.displayText
        responses[event.responseID]?.isFinal = event.isFinal
        reconcileRecordIDs()
        return makeUpdate()
    }

    /// Associates the assistant output item with the source ASR item using
    /// `conversation.item.created.previous_item_id`. This is authoritative;
    /// arrival order is used only when the server omits the linkage event.
    mutating func receiveLink(sourceItemID: String, responseItemID: String) -> TranslationCoordinatorUpdate {
        sourceItemIDByResponseItemID[responseItemID] = sourceItemID
        for responseID in responseOrder where responses[responseID]?.itemID == responseItemID {
            responses[responseID]?.sourceItemID = sourceItemID
        }
        reconcileRecordIDs()
        return makeUpdate()
    }

    private mutating func takeCreationIndex() -> Int {
        defer { nextCreationIndex += 1 }
        return nextCreationIndex
    }

    private mutating func reconcileRecordIDs() {
        var claimedSourceIDs = Set(responses.values.compactMap(\.sourceItemID))
        var unlinkedSourceIDs = sourceOrder.filter { !claimedSourceIDs.contains($0) }

        for responseID in responseOrder where responses[responseID]?.sourceItemID == nil {
            guard !unlinkedSourceIDs.isEmpty else { break }
            let sourceID = unlinkedSourceIDs.removeFirst()
            responses[responseID]?.sourceItemID = sourceID
            claimedSourceIDs.insert(sourceID)
        }

        for responseID in responseOrder {
            guard var response = responses[responseID],
                  let sourceID = response.sourceItemID,
                  var source = sources[sourceID] else { continue }
            let stableID = source.creationIndex < response.creationIndex
                ? source.recordID
                : response.recordID
            source.recordID = stableID
            response.recordID = stableID
            sources[sourceID] = source
            responses[responseID] = response
        }
    }

    private func makeUpdate() -> TranslationCoordinatorUpdate {
        var snapshots: [TranslationTurnSnapshot] = []
        var records: [TranslateRecord] = []
        var consumedResponseIDs = Set<String>()

        for sourceID in sourceOrder {
            let source = sources[sourceID]
            let response = responseOrder.compactMap { responses[$0] }.first {
                $0.sourceItemID == sourceID
            }
            if let response { consumedResponseIDs.insert(response.responseID) }
            appendTurn(source: source, response: response, snapshots: &snapshots, records: &records)
        }

        for responseID in responseOrder where !consumedResponseIDs.contains(responseID) {
            appendTurn(source: nil, response: responses[responseID], snapshots: &snapshots, records: &records)
        }

        return TranslationCoordinatorUpdate(turns: snapshots, recordsToUpsert: records)
    }

    private func appendTurn(
        source: SourceState?,
        response: ResponseState?,
        snapshots: inout [TranslationTurnSnapshot],
        records: inout [TranslateRecord]
    ) {
        let recordID = response?.recordID ?? source?.recordID ?? UUID()
        let snapshot = TranslationTurnSnapshot(
            id: recordID,
            sourceItemID: source?.itemID,
            responseID: response?.responseID,
            originalText: source?.text ?? "",
            translatedText: response?.text ?? "",
            isSourceFinal: source?.isFinal ?? false,
            isTranslationFinal: response?.isFinal ?? false
        )
        snapshots.append(snapshot)

        if let response, response.isFinal, !response.text.isEmpty {
            records.append(TranslateRecord(
                id: recordID,
                timestamp: source?.timestamp ?? response.timestamp,
                sessionID: sessionID,
                sourceItemID: source?.itemID,
                responseID: response.responseID,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                originalText: source?.text ?? "",
                translatedText: response.text
            ))
        }
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
