/*
 * Live Translate ViewModel
 * 实时翻译状态管理
 */

import Foundation
import SwiftUI
import UIKit

@MainActor
class LiveTranslateViewModel: ObservableObject {

    // MARK: - Connection State
    @Published var isConnected = false
    @Published var isRecording = false

    // MARK: - Translation State
    @Published var currentTranslation = ""       // 当前翻译结果
    @Published var currentOriginal = ""          // 当前原文（暂不支持，保留字段）
    @Published var streamingTranslation = ""     // 流式翻译片段
    /// Records belonging to the currently active/most recently stopped
    /// recording session. Historical sessions stay in Records and are not
    /// rendered on the live workspace.
    @Published var currentSessionRecords: [TranslateRecord] = []
    @Published var translationHistory: [TranslateRecord] = []
    @Published private(set) var historyRecordCount = 0
    /// Display-reduced provisional turns. The view intentionally does not
    /// render raw coordinator snapshots because one speech turn can produce
    /// several interim ASR packets before the authoritative item link arrives.
    @Published var activeTurns: [TranslationDisplayTurn] = []
    @Published var playbackState: TranslationPlaybackState = .idle
    @Published var pendingPlaybackCount = 0
    @Published var isFinalizing = false

    // MARK: - Error State
    @Published var errorMessage: String?
    @Published var showError = false

    // MARK: - Settings (持久化)
    @Published var sourceLanguage: TranslateLanguage {
        didSet {
            UserDefaults.standard.set(sourceLanguage.rawValue, forKey: "translate_source_language")
            updateServiceSettings()
        }
    }

    @Published var targetLanguage: TranslateLanguage {
        didSet {
            UserDefaults.standard.set(targetLanguage.rawValue, forKey: "translate_target_language")
            updateServiceSettings()
        }
    }

    @Published var selectedVoice: TranslateVoice {
        didSet {
            UserDefaults.standard.set(selectedVoice.rawValue, forKey: "translate_voice")
            updateServiceSettings()
        }
    }

    @Published var audioOutputEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioOutputEnabled, forKey: "translate_audio_enabled")
            updateServiceSettings()
        }
    }

    @Published var imageEnhanceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(imageEnhanceEnabled, forKey: "translate_image_enhance")
            if !imageEnhanceEnabled {
                currentVideoFrame = nil
            }
        }
    }

    /// 使用 iPhone 麦克风（而非眼镜麦克风）
    /// 眼镜麦克风适合翻译自己说的话，iPhone 麦克风适合翻译对方说的话
    @Published var usePhoneMic: Bool {
        didSet {
            UserDefaults.standard.set(usePhoneMic, forKey: "translate_use_phone_mic")
        }
    }

    // MARK: - Video Frame (for image enhancement)
    var currentVideoFrame: UIImage?

    // MARK: - Private
    private var translateService: LiveTranslateService?
    private let historyStorage: LiveTranslateHistoryStorage
    private var turnCoordinator: TranslationTurnCoordinator
    private var currentSessionID: UUID?
    private var persistedRecordSignatures: [UUID: String] = [:]
    private var finalizationTask: Task<Void, Never>?
    private var shouldMaintainConnection = false
    private var hasFinalizedCurrentSession = false

    // MARK: - Init

    init(historyStorage: LiveTranslateHistoryStorage = .shared) {
        self.historyStorage = historyStorage
        // 从 UserDefaults 加载设置
        let savedSource = UserDefaults.standard.string(forKey: "translate_source_language") ?? "en"
        self.sourceLanguage = TranslateLanguage(rawValue: savedSource) ?? .en

        let savedTarget = UserDefaults.standard.string(forKey: "translate_target_language") ?? "zh"
        self.targetLanguage = TranslateLanguage(rawValue: savedTarget) ?? .zh

        let savedVoice = UserDefaults.standard.string(forKey: "translate_voice") ?? "Cherry"
        self.selectedVoice = TranslateVoice(rawValue: savedVoice) ?? .cherry

        self.audioOutputEnabled = UserDefaults.standard.object(forKey: "translate_audio_enabled") as? Bool ?? true
        let privacyMigrationKey = "translate_image_privacy_default_off_v1"
        if !UserDefaults.standard.bool(forKey: privacyMigrationKey) {
            self.imageEnhanceEnabled = false
            UserDefaults.standard.set(false, forKey: "translate_image_enhance")
            UserDefaults.standard.set(true, forKey: privacyMigrationKey)
        } else {
            self.imageEnhanceEnabled = UserDefaults.standard.object(forKey: "translate_image_enhance") as? Bool ?? false
        }
        self.usePhoneMic = UserDefaults.standard.object(forKey: "translate_use_phone_mic") as? Bool ?? false
        // Use the local values here because `self` is not fully initialized
        // until every stored property has been assigned.
        self.turnCoordinator = TranslationTurnCoordinator(
            sourceLanguage: TranslateLanguage(rawValue: savedSource) ?? .en,
            targetLanguage: TranslateLanguage(rawValue: savedTarget) ?? .zh
        )
        self.translationHistory = historyStorage.loadAll()
        self.historyRecordCount = translationHistory.count
        self.currentSessionID = nil
        self.persistedRecordSignatures = Dictionary(uniqueKeysWithValues: translationHistory.map {
            ($0.id, Self.signature(for: $0))
        })
    }

    // MARK: - Connection

    func connect() {
        shouldMaintainConnection = true
        let apiKey = APIProviderManager.staticLiveAIAPIKey
        guard !apiKey.isEmpty else {
            errorMessage = "livetranslate.error.noApiKey".localized
            showError = true
            return
        }

        activeTurns = []
        translateService = LiveTranslateService(apiKey: apiKey)
        setupCallbacks()

        translateService?.updateSettings(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            voice: selectedVoice,
            audioEnabled: audioOutputEnabled
        )

        translateService?.connect()
    }

    func disconnect() {
        shouldMaintainConnection = false
        finalizationTask?.cancel()
        finalizationTask = nil
        translateService?.disconnect()
        translateService = nil
        isConnected = false
        isRecording = false
        isFinalizing = false
        playbackState = .idle
        pendingPlaybackCount = 0
    }

    // MARK: - Recording

    func toggleRecording() {
        guard !isFinalizing else { return }
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard isConnected, !isFinalizing else { return }
        guard let service = translateService,
              service.startRecording(usePhoneMic: usePhoneMic) else {
            isRecording = false
            return
        }

        // A business session starts only after the audio engine has actually
        // started. Reconnecting the WebSocket never reaches this branch and
        // therefore cannot create or clear a session.
        let sessionID = UUID()
        currentSessionID = sessionID
        hasFinalizedCurrentSession = false
        turnCoordinator = TranslationTurnCoordinator(
            sessionID: sessionID,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        currentSessionRecords.removeAll()
        activeTurns.removeAll()
        currentTranslation = ""
        currentOriginal = ""
        streamingTranslation = ""
        isRecording = true
    }

    func stopRecording() {
        guard isRecording, !isFinalizing, let service = translateService else { return }
        isRecording = false
        isFinalizing = true
        service.stopRecording()

        finalizationTask = Task { @MainActor [weak self, weak service] in
            guard let self, let service else { return }
            await service.finishSession()
            guard !Task.isCancelled else { return }
            self.finalizeCurrentSession()
            service.disconnect()
            self.translateService = nil
            self.isConnected = false
            self.isFinalizing = false
            self.finalizationTask = nil
            if self.shouldMaintainConnection {
                self.connect()
            }
        }
    }

    // MARK: - Language Swap

    func swapLanguages() {
        // 只有当两种语言都支持作为目标语言时才能交换
        guard sourceLanguage.supportsAudioOutput && targetLanguage.supportsAudioOutput else {
            errorMessage = "livetranslate.error.cannotSwap".localized
            showError = true
            return
        }

        let temp = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = temp

        // 清空当前翻译
        currentTranslation = ""
        streamingTranslation = ""
    }

    // MARK: - Video Frame

    func updateVideoFrame(_ frame: UIImage) {
        currentVideoFrame = frame
    }

    // MARK: - Private Methods

    private func setupCallbacks() {
        guard let service = translateService else { return }

        service.onConnected = { [weak self, weak service] in
            DispatchQueue.main.async {
                guard let self, let service, self.translateService === service else { return }
                self.isConnected = true
                print("✅ [TranslateVM] 已连接")
            }
        }

        service.onSourceTranscript = { [weak self, weak service] event in
            Task { @MainActor in
                guard let self, let service,
                      self.translateService === service,
                      self.currentSessionID != nil else { return }
                var coordinator = self.turnCoordinator
                let update = coordinator.receiveSource(event)
                self.turnCoordinator = coordinator
                self.apply(update)
            }
        }

        service.onTranslation = { [weak self, weak service] event in
            Task { @MainActor in
                guard let self, let service,
                      self.translateService === service,
                      self.currentSessionID != nil else { return }
                var coordinator = self.turnCoordinator
                let update = coordinator.receiveTranslation(event)
                self.turnCoordinator = coordinator
                self.apply(update)
            }
        }

        service.onResponseItem = { [weak self, weak service] responseID, responseItemID in
            Task { @MainActor in
                guard let self, let service,
                      self.translateService === service,
                      self.currentSessionID != nil else { return }
                var coordinator = self.turnCoordinator
                let update = coordinator.receiveResponseItem(
                    responseID: responseID,
                    itemID: responseItemID
                )
                self.turnCoordinator = coordinator
                self.apply(update)
            }
        }

        service.onTurnLink = { [weak self, weak service] sourceItemID, responseItemID in
            Task { @MainActor in
                guard let self, let service,
                      self.translateService === service,
                      self.currentSessionID != nil else { return }
                var coordinator = self.turnCoordinator
                let update = coordinator.receiveLink(
                    sourceItemID: sourceItemID,
                    responseItemID: responseItemID
                )
                self.turnCoordinator = coordinator
                self.apply(update)
            }
        }

        service.onPlaybackStateChanged = { [weak self, weak service] state, pendingCount in
            Task { @MainActor in
                guard let self, let service, self.translateService === service else { return }
                self.playbackState = state
                self.pendingPlaybackCount = pendingCount
            }
        }

        service.onSpeechStarted = { [weak self, weak service] itemID in
            Task { @MainActor in
                guard let self, let service, self.translateService === service else { return }
                var coordinator = self.turnCoordinator
                let update = coordinator.receiveSpeechStarted(itemID: itemID)
                self.turnCoordinator = coordinator
                self.apply(update)
                self.sendCurrentFrameForSpeechTurn()
            }
        }

        service.onSpeechStopped = { [weak self, weak service] itemID in
            Task { @MainActor in
                guard let self, let service,
                      self.translateService === service,
                      self.currentSessionID != nil else { return }
                var coordinator = self.turnCoordinator
                let update = coordinator.receiveSpeechStopped(itemID: itemID)
                self.turnCoordinator = coordinator
                self.apply(update)
            }
        }

        service.onResponseStarted = { [weak self, weak service] responseID in
            Task { @MainActor in
                guard let self, let service,
                      self.translateService === service,
                      self.currentSessionID != nil else { return }
                var coordinator = self.turnCoordinator
                let update = coordinator.receiveResponseStarted(responseID: responseID)
                self.turnCoordinator = coordinator
                self.apply(update)
            }
        }

        service.onResponseFinished = { [weak self, weak service] responseID in
            Task { @MainActor in
                guard let self, let service,
                      self.translateService === service,
                      self.currentSessionID != nil else { return }
                var coordinator = self.turnCoordinator
                let update = coordinator.receiveResponseFinished(responseID: responseID)
                self.turnCoordinator = coordinator
                self.apply(update)
            }
        }

        service.onSessionFinished = { [weak self, weak service] in
            Task { @MainActor in
                guard let self, let service,
                      self.translateService === service,
                      self.currentSessionID != nil else { return }
                self.finalizeCurrentSession()
            }
        }

        service.onError = { [weak self, weak service] error in
            DispatchQueue.main.async {
                guard let self, let service, self.translateService === service else { return }
                self.errorMessage = error
                self.showError = true
            }
        }
    }

    private func updateServiceSettings() {
        turnCoordinator.updateLanguages(source: sourceLanguage, target: targetLanguage)
        translateService?.updateSettings(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            voice: selectedVoice,
            audioEnabled: audioOutputEnabled
        )
    }

    // MARK: - Turn and Image Handling

    /// Realtime updates stay provisional until the server has emitted
    /// `session.finished` (or the finish timeout expires). The coordinator
    /// omits any response that is not connected through the authoritative
    /// assistant-item/previous-item chain.
    private func finalizeCurrentSession() {
        guard currentSessionID != nil, !hasFinalizedCurrentSession else { return }
        hasFinalizedCurrentSession = true
        var coordinator = turnCoordinator
        let update = coordinator.finalize()
        turnCoordinator = coordinator
        apply(update)
        activeTurns.removeAll()
        currentOriginal = ""
        streamingTranslation = ""
    }

    private func sendCurrentFrameForSpeechTurn() {
        guard isRecording, imageEnhanceEnabled, let frame = currentVideoFrame else { return }
        translateService?.sendImageFrame(frame)
    }

    private func apply(_ update: TranslationCoordinatorUpdate) {
        guard currentSessionID != nil else {
            activeTurns = []
            return
        }
        // A finalized translation is rendered from persisted history. Later
        // source-ASR updates upsert that same row instead of showing a duplicate.
        let persistedIDs = Set(update.recordsToUpsert.map(\.id))
        let persistedSourceItemIDs = Set(update.recordsToUpsert.compactMap(\.sourceItemID))
        let persistedResponseIDs = Set(update.recordsToUpsert.compactMap(\.responseID))
        let provisionalSnapshots = update.turns.filter { snapshot in
            guard !persistedIDs.contains(snapshot.id),
                  snapshot.sourceItemID.map({ !persistedSourceItemIDs.contains($0) }) ?? true,
                  snapshot.responseID.map({ !persistedResponseIDs.contains($0) }) ?? true else {
                return false
            }

            return true
        }
        activeTurns = hasFinalizedCurrentSession
            ? []
            : provisionalSnapshots.map { snapshot in
                TranslationDisplayTurn(
                    id: snapshot.id,
                    sourceItemID: snapshot.sourceItemID,
                    responseID: snapshot.responseID,
                    originalText: snapshot.originalText,
                    translatedText: snapshot.translatedText,
                    isSourceFinal: snapshot.isSourceFinal,
                    isTranslationFinal: snapshot.isTranslationFinal
                )
            }
        if let latest = activeTurns.last {
            currentOriginal = latest.originalText
            streamingTranslation = latest.translatedText
        } else {
            currentOriginal = ""
            streamingTranslation = ""
        }

        for record in update.recordsToUpsert {
            let signature = Self.signature(for: record)
            guard persistedRecordSignatures[record.id] != signature else { continue }
            persistedRecordSignatures[record.id] = signature
            translationHistory = historyStorage.upsert(record)
            historyRecordCount = translationHistory.count
            currentSessionRecords = translationHistory.filter { $0.sessionID == currentSessionID }
            currentTranslation = record.translatedText
        }
    }

    private static func signature(for record: TranslateRecord) -> String {
        [record.sourceItemID ?? "", record.responseID ?? "", record.originalText, record.translatedText]
            .joined(separator: "\u{1F}")
    }

    // MARK: - Clear

    func clearTranslation() {
        currentTranslation = ""
        streamingTranslation = ""
        currentOriginal = ""
    }

    func clearHistory() {
        historyStorage.deleteAll()
        translationHistory.removeAll()
        currentSessionRecords.removeAll()
        historyRecordCount = 0
        persistedRecordSignatures.removeAll()
    }
}
