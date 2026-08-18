/*
 * Omni Realtime ViewModel
 * Manages real-time multimodal conversation with AI
 * Supports both Alibaba Qwen Omni and Google Gemini Live
 */

import Foundation
import SwiftUI
import AVFoundation

@MainActor
class OmniRealtimeViewModel: ObservableObject {

    // Published state
    @Published var isConnected = false
    @Published var isRecording = false
    @Published var isSpeaking = false
    @Published var currentTranscript = ""
    @Published var conversationHistory: [ConversationMessage] = []
    @Published var errorMessage: String?
    @Published var showError = false
    /// Realtime sessions start in voice-only mode. Camera access is opt-in.
    @Published private(set) var inputMode: LiveAIInputMode = .voice
    @Published private(set) var sentImageCount = 0
    @Published private(set) var isSwitchingInputMode = false

    // Services (use one based on provider)
    private var omniService: OmniRealtimeService?
    private var geminiService: GeminiLiveService?
    private let provider: LiveAIProvider
    private let apiKey: String
    private weak var streamViewModel: StreamSessionViewModel?

    // Video frame
    private var currentVideoFrame: UIImage?
    private var hasSentFirstAudio = false
    private var isImageSendingEnabled = false
    private var initialInputMode: LiveAIInputMode = .voice

    init(apiKey: String, streamViewModel: StreamSessionViewModel? = nil) {
        self.apiKey = apiKey
        self.provider = APIProviderManager.staticLiveAIProvider
        self.streamViewModel = streamViewModel

        // Initialize appropriate service based on provider
        switch provider {
        case .alibaba:
            self.omniService = OmniRealtimeService(apiKey: apiKey)
        case .google:
            self.geminiService = GeminiLiveService(apiKey: apiKey)
        }

        setupCallbacks()
    }

    /// Whether the current realtime session is allowed to append images.
    /// Keeping this as a derived guard prevents a stale frame from being sent
    /// while a mode switch or DAT teardown is in flight.
    var canSendImages: Bool {
        inputMode == .vision &&
            isImageSendingEnabled &&
            streamViewModel?.streamingStatus == .streaming &&
            currentVideoFrame != nil
    }

    // MARK: - Setup

    private func setupCallbacks() {
        switch provider {
        case .alibaba:
            setupOmniCallbacks()
        case .google:
            setupGeminiCallbacks()
        }
    }

    private func setupOmniCallbacks() {
        guard let omniService = omniService else { return }

        omniService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
            }
        }

        omniService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hasSentFirstAudio = true
                self.isImageSendingEnabled = self.inputMode == .vision
                print("✅ [OmniVM] 收到第一次音频发送回调，图片权限=\(self.isImageSendingEnabled)")
            }
        }

        omniService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = true

                if let strongSelf = self,
                   strongSelf.canSendImages,
                   let frame = strongSelf.currentVideoFrame {
                    print("🎤📸 [OmniVM] 检测到用户语音，发送当前视频帧")
                    strongSelf.omniService?.sendImageAppend(frame)
                    strongSelf.sentImageCount += 1
                }
            }
        }

        omniService.onSpeechStopped = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
            }
        }

        omniService.onTranscriptDelta = { [weak self] delta in
            Task { @MainActor in
                print("📝 [OmniVM] AI回复片段: \(delta)")
                self?.currentTranscript += delta
            }
        }

        omniService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self = self else { return }
                print("💬 [OmniVM] 保存用户语音: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        omniService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                guard let self = self else { return }
                let textToSave = fullText.isEmpty ? self.currentTranscript : fullText
                guard !textToSave.isEmpty else {
                    print("⚠️ [OmniVM] AI回复为空，跳过保存")
                    return
                }
                print("💬 [OmniVM] 保存AI回复: \(textToSave)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: textToSave)
                )
                self.currentTranscript = ""
            }
        }

        omniService.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                self?.showError = true
            }
        }
    }

    private func setupGeminiCallbacks() {
        guard let geminiService = geminiService else { return }

        geminiService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
            }
        }

        geminiService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hasSentFirstAudio = true
                self.isImageSendingEnabled = self.inputMode == .vision
                print("✅ [GeminiVM] 收到第一次音频发送回调，图片权限=\(self.isImageSendingEnabled)")
            }
        }

        geminiService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = true

                if let strongSelf = self,
                   strongSelf.canSendImages,
                   let frame = strongSelf.currentVideoFrame {
                    print("🎤📸 [GeminiVM] 检测到用户语音，发送当前视频帧")
                    strongSelf.geminiService?.sendImageInput(frame)
                    strongSelf.sentImageCount += 1
                }
            }
        }

        geminiService.onSpeechStopped = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
            }
        }

        geminiService.onTranscriptDelta = { [weak self] (delta: String) in
            Task { @MainActor in
                print("📝 [GeminiVM] AI回复片段: \(delta)")
                self?.currentTranscript += delta
            }
        }

        geminiService.onUserTranscript = { [weak self] (userText: String) in
            Task { @MainActor in
                guard let self = self else { return }
                print("💬 [GeminiVM] 保存用户语音: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        geminiService.onTranscriptDone = { [weak self] (fullText: String) in
            Task { @MainActor in
                guard let self = self else { return }
                let textToSave = fullText.isEmpty ? self.currentTranscript : fullText
                guard !textToSave.isEmpty else {
                    print("⚠️ [GeminiVM] AI回复为空，跳过保存")
                    return
                }
                print("💬 [GeminiVM] 保存AI回复: \(textToSave)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: textToSave)
                )
                self.currentTranscript = ""
            }
        }

        geminiService.onAudioDone = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
            }
        }

        geminiService.onError = { [weak self] (error: String) in
            Task { @MainActor in
                self?.errorMessage = error
                self?.showError = true
            }
        }
    }

    // MARK: - Connection

    /// Switches camera access without reconnecting the realtime model.
    ///
    /// Voice mode first disables image sending, clears the cached frame, and
    /// then tears down DAT. The WebSocket, recorder, transcript history, and
    /// audio playback remain untouched.
    func setInputMode(_ mode: LiveAIInputMode) async {
        guard mode != inputMode else { return }
        guard !isSwitchingInputMode else { return }

        isSwitchingInputMode = true
        defer { isSwitchingInputMode = false }

        switch mode {
        case .voice:
            isImageSendingEnabled = false
            inputMode = .voice
            currentVideoFrame = nil
            await streamViewModel?.stopSession()

        case .vision:
            guard let streamViewModel else {
                fallbackToVoice("视觉模式需要已连接的眼镜")
                return
            }

            guard streamViewModel.hasActiveDevice else {
                fallbackToVoice("未连接眼镜，已切回纯语音")
                return
            }

            if streamViewModel.streamingStatus != .streaming {
                await streamViewModel.handleStartStreaming()
            }

            let streamReady = await waitForCondition(timeout: 5.0) {
                streamViewModel.streamingStatus == .streaming
            }

            guard streamReady else {
                await streamViewModel.stopSession()
                fallbackToVoice("视觉流启动失败，已切回纯语音")
                return
            }

            inputMode = .vision
            isImageSendingEnabled = hasSentFirstAudio
        }
    }

    /// Alias used by UI callers that express the action as a toggle.
    func switchInputMode(to mode: LiveAIInputMode) async {
        await setInputMode(mode)
    }

    private func fallbackToVoice(_ message: String) {
        inputMode = .voice
        isImageSendingEnabled = false
        currentVideoFrame = nil
        errorMessage = message
        showError = true
    }

    /// Called by the UI when DAT reports a stopped/waiting stream while the
    /// realtime session is in vision mode. It prevents another speech event
    /// from sending a stale cached frame and keeps the audio session alive.
    func handleVisionStreamFailure() {
        guard inputMode == .vision else { return }
        isImageSendingEnabled = false
        inputMode = .voice
        currentVideoFrame = nil
        errorMessage = "视觉流已断开，已切回纯语音"
        showError = true
        let streamViewModel = streamViewModel
        Task { @MainActor in
            await streamViewModel?.stopSession()
        }
    }

    private func waitForCondition(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    func connect() {
        // Every new realtime session starts voice-only. A caller must opt in
        // to visual context through setInputMode(.vision).
        inputMode = .voice
        isImageSendingEnabled = false
        hasSentFirstAudio = false
        sentImageCount = 0
        currentVideoFrame = nil
        initialInputMode = .voice
        switch provider {
        case .alibaba:
            omniService?.connect()
        case .google:
            geminiService?.connect()
        }
    }

    func disconnect() {
        // Save conversation before disconnecting
        saveConversation()

        stopRecording()

        switch provider {
        case .alibaba:
            omniService?.disconnect()
        case .google:
            geminiService?.disconnect()
        }

        // Camera teardown is intentionally independent from the realtime
        // socket. If the user was in vision mode, close DAT asynchronously;
        // voice sessions never started it in the first place.
        isImageSendingEnabled = false
        inputMode = .voice
        currentVideoFrame = nil
        let streamViewModel = streamViewModel
        Task { @MainActor in
            await streamViewModel?.stopSession()
        }

        isConnected = false
        hasSentFirstAudio = false
    }

    private func saveConversation() {
        // Only save if there's meaningful conversation
        guard !conversationHistory.isEmpty else {
            print("💬 [LiveAI] 无对话内容，跳过保存")
            return
        }

        let aiModel: String
        switch provider {
        case .alibaba:
            aiModel = "qwen3-omni-flash-realtime"
        case .google:
            aiModel = "gemini-2.0-flash-exp"
        }

        let record = ConversationRecord(
            messages: conversationHistory,
            aiModel: aiModel,
            language: "zh-CN", // TODO: 从设置中获取
            initialInputMode: initialInputMode,
            visionFrameCount: sentImageCount
        )

        ConversationStorage.shared.saveConversation(record)
        print("💾 [LiveAI] 对话已保存: \(conversationHistory.count) 条消息")
    }

    // MARK: - Recording

    func startRecording() {
        guard isConnected else {
            print("⚠️ [LiveAI] 未连接，无法开始录音")
            errorMessage = "请先连接服务器"
            showError = true
            return
        }

        print("🎤 [LiveAI] 开始录音（语音触发模式）- Provider: \(provider.displayName)")

        switch provider {
        case .alibaba:
            omniService?.startRecording()
        case .google:
            geminiService?.startRecording()
        }

        isRecording = true
    }

    func stopRecording() {
        print("🛑 [LiveAI] 停止录音")

        switch provider {
        case .alibaba:
            omniService?.stopRecording()
        case .google:
            geminiService?.stopRecording()
        }

        isRecording = false
    }

    // MARK: - Video Frames

    func updateVideoFrame(_ frame: UIImage) {
        guard inputMode == .vision else { return }
        currentVideoFrame = frame
    }

    // MARK: - Manual Mode (if needed)

    func sendMessage() {
        omniService?.commitAudioBuffer()
    }

    // MARK: - Cleanup

    func dismissError() {
        showError = false
    }

    nonisolated deinit {
        Task { @MainActor [weak omniService, weak geminiService] in
            omniService?.disconnect()
            geminiService?.disconnect()
        }
    }
}

// MARK: - Conversation Message

struct ConversationMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp = Date()

    enum MessageRole {
        case user
        case assistant
    }
}
