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
    @Published var translationHistory: [TranslateRecord] = []
    @Published var activeTurns: [TranslationTurnSnapshot] = []
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
    private var persistedRecordSignatures: [UUID: String] = [:]
    private var finalizationTask: Task<Void, Never>?
    private var shouldMaintainConnection = false

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

        turnCoordinator = TranslationTurnCoordinator(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
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
        isRecording = translateService?.startRecording(usePhoneMic: usePhoneMic) ?? false
    }

    func stopRecording() {
        guard isRecording, !isFinalizing, let service = translateService else { return }
        isRecording = false
        isFinalizing = true
        service.stopRecording()

        finalizationTask = Task { @MainActor [weak self, weak service] in
            guard let self, let service else { return }
            await service.finishSession()
            service.disconnect()
            guard !Task.isCancelled else { return }
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
        translateService?.onConnected = { [weak self] in
            DispatchQueue.main.async {
                self?.isConnected = true
                print("✅ [TranslateVM] 已连接")
            }
        }

        translateService?.onSourceTranscript = { [weak self] event in
            Task { @MainActor in
                guard var coordinator = self?.turnCoordinator else { return }
                let update = coordinator.receiveSource(event)
                self?.turnCoordinator = coordinator
                self?.apply(update)
            }
        }

        translateService?.onTranslation = { [weak self] event in
            Task { @MainActor in
                guard var coordinator = self?.turnCoordinator else { return }
                let update = coordinator.receiveTranslation(event)
                self?.turnCoordinator = coordinator
                self?.apply(update)
            }
        }

        translateService?.onTurnLink = { [weak self] sourceItemID, responseItemID in
            Task { @MainActor in
                guard var coordinator = self?.turnCoordinator else { return }
                let update = coordinator.receiveLink(
                    sourceItemID: sourceItemID,
                    responseItemID: responseItemID
                )
                self?.turnCoordinator = coordinator
                self?.apply(update)
            }
        }

        translateService?.onPlaybackStateChanged = { [weak self] state, pendingCount in
            Task { @MainActor in
                self?.playbackState = state
                self?.pendingPlaybackCount = pendingCount
            }
        }

        translateService?.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                self?.sendCurrentFrameForSpeechTurn()
            }
        }

        translateService?.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.errorMessage = error
                self?.showError = true
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

    private func sendCurrentFrameForSpeechTurn() {
        guard isRecording, imageEnhanceEnabled, let frame = currentVideoFrame else { return }
        translateService?.sendImageFrame(frame)
    }

    private func apply(_ update: TranslationCoordinatorUpdate) {
        // A finalized translation is rendered from persisted history. Later
        // source-ASR updates upsert that same row instead of showing a duplicate.
        let persistedIDs = Set(update.recordsToUpsert.map(\.id))
        activeTurns = update.turns.filter { !persistedIDs.contains($0.id) }
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
        persistedRecordSignatures.removeAll()
    }
}
