/*
 * Live AI Manager
 * 后台管理 Live AI 会话 - 支持 Siri 和快捷指令无需解锁手机
 */

import Foundation
import SwiftUI
import AVFoundation

// MARK: - Live AI Manager

@MainActor
class LiveAIManager: ObservableObject {
    static let shared = LiveAIManager()

    @Published var isRunning = false
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published private(set) var inputMode: LiveAIInputMode = .voice
    @Published private(set) var sentImageCount = 0
    @Published private(set) var isSwitchingInputMode = false

    // 依赖
    private(set) var streamViewModel: StreamSessionViewModel?
    private var omniService: OmniRealtimeService?
    private var geminiService: GeminiLiveService?
    private var provider: LiveAIProvider = .alibaba

    // 视频帧
    private var currentVideoFrame: UIImage?
    private var hasSentFirstAudio = false
    private var isImageSendingEnabled = false
    private var frameUpdateTimer: Timer?

    // 对话历史
    private var conversationHistory: [ConversationMessage] = []
    private var initialInputMode: LiveAIInputMode = .voice

    // TTS
    private let tts = TTSService.shared

    private init() {
        // 监听 Intent 触发
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLiveAITrigger(_:)),
            name: .liveAITriggered,
            object: nil
        )
    }

    /// 设置 StreamSessionViewModel 引用
    func setStreamViewModel(_ viewModel: StreamSessionViewModel) {
        self.streamViewModel = viewModel
    }

    @objc private func handleLiveAITrigger(_ notification: Notification) {
        Task { @MainActor in
            await startLiveAISession()
        }
    }

    // MARK: - Start Session

    /// 启动 Live AI 会话（后台模式）
    func startLiveAISession() async {
        guard !isRunning else {
            print("⚠️ [LiveAIManager] Already running")
            return
        }

        // 获取 API Key
        let apiKey = APIProviderManager.staticLiveAIAPIKey
        guard !apiKey.isEmpty else {
            errorMessage = "请先在设置中配置 API Key"
            tts.speak("请先在设置中配置 API Key")
            return
        }

        isRunning = true
        errorMessage = nil
        conversationHistory = []
        inputMode = .voice
        initialInputMode = .voice
        sentImageCount = 0
        hasSentFirstAudio = false
        isImageSendingEnabled = false
        currentVideoFrame = nil

        // 获取当前 provider
        provider = APIProviderManager.staticLiveAIProvider

        print("🚀 [LiveAIManager] Starting Live AI session...")

        do {
            // 1. 检查设备是否已连接. This is only a hardware/microphone
            // guard; no DAT camera session is created in voice mode.
            if let streamViewModel, !streamViewModel.hasActiveDevice {
                print("❌ [LiveAIManager] No active device connected")
                throw LiveAIError.noDevice
            }

            // 2. 预配置音频会话（后台模式需要）
            try configureAudioSessionForBackground()

            // 3. 初始化 AI 服务
            initializeService(apiKey: apiKey)

            // 4. 连接 AI 服务
            print("🔌 [LiveAIManager] Connecting to AI service...")
            connectService()

            // 等待连接成功（最多 10 秒）
            let connected = await waitForCondition(timeout: 10.0) {
                self.isConnected
            }

            if !connected {
                print("❌ [LiveAIManager] Failed to connect to AI service")
                throw LiveAIError.connectionFailed
            }

            // 5. 直接开始录音（不播放 TTS，避免音频会话冲突）
            print("🎤 [LiveAIManager] About to start recording...")
            startRecording()

            print("✅ [LiveAIManager] Live AI session started, ready to talk")

        } catch let error as LiveAIError {
            errorMessage = error.localizedDescription
            print("❌ [LiveAIManager] LiveAIError: \(error)")
            await stopSession()
        } catch {
            errorMessage = error.localizedDescription
            print("❌ [LiveAIManager] Error: \(error)")
            await stopSession()
        }
    }

    // MARK: - Audio Session Configuration

    /// 预配置音频会话（后台模式需要在初始化音频引擎之前配置）
    private func configureAudioSessionForBackground() throws {
        let audioSession = AVAudioSession.sharedInstance()

        // 先停用再重新激活，确保干净的状态
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            print("✅ [LiveAIManager] 音频会话已停用")
        } catch {
            print("⚠️ [LiveAIManager] 停用音频会话失败: \(error)")
        }

        // 配置音频会话
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
        )
        try audioSession.setActive(true)
        print("✅ [LiveAIManager] 后台音频会话已配置: category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")
    }

    // MARK: - Initialize Service

    private func initializeService(apiKey: String) {
        switch provider {
        case .alibaba:
            omniService = OmniRealtimeService(apiKey: apiKey)
            setupOmniCallbacks()
        case .google:
            geminiService = GeminiLiveService(apiKey: apiKey)
            setupGeminiCallbacks()
        }
    }

    private func setupOmniCallbacks() {
        guard let omniService = omniService else { return }

        omniService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
                print("✅ [LiveAIManager] Omni connected")
            }
        }

        omniService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hasSentFirstAudio = true
                self.isImageSendingEnabled = self.inputMode == .vision
                print("✅ [LiveAIManager] 收到第一次音频发送回调，图片权限=\(self.isImageSendingEnabled)")
            }
        }

        omniService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                if let strongSelf = self,
                   strongSelf.canSendImages,
                   let frame = strongSelf.currentVideoFrame {
                    print("🎤📸 [LiveAIManager] 检测到用户语音，发送当前视频帧")
                    strongSelf.omniService?.sendImageAppend(frame)
                    strongSelf.sentImageCount += 1
                }
            }
        }

        omniService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self = self else { return }
                print("💬 [LiveAIManager] 用户: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        omniService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                guard let self = self, !fullText.isEmpty else { return }
                print("💬 [LiveAIManager] AI: \(fullText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: fullText)
                )
            }
        }

        omniService.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                print("❌ [LiveAIManager] Omni error: \(error)")
            }
        }
    }

    private func setupGeminiCallbacks() {
        guard let geminiService = geminiService else { return }

        geminiService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
                print("✅ [LiveAIManager] Gemini connected")
            }
        }

        geminiService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hasSentFirstAudio = true
                self.isImageSendingEnabled = self.inputMode == .vision
                print("✅ [LiveAIManager] 收到第一次音频发送回调，图片权限=\(self.isImageSendingEnabled)")
            }
        }

        geminiService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                if let strongSelf = self,
                   strongSelf.canSendImages,
                   let frame = strongSelf.currentVideoFrame {
                    print("🎤📸 [LiveAIManager] 检测到用户语音，发送当前视频帧")
                    strongSelf.geminiService?.sendImageInput(frame)
                    strongSelf.sentImageCount += 1
                }
            }
        }

        geminiService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self = self else { return }
                print("💬 [LiveAIManager] 用户: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        geminiService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                guard let self = self, !fullText.isEmpty else { return }
                print("💬 [LiveAIManager] AI: \(fullText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: fullText)
                )
            }
        }

        geminiService.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                print("❌ [LiveAIManager] Gemini error: \(error)")
            }
        }
    }

    /// Whether the background Live AI session is currently permitted to send
    /// a still frame. Voice mode always returns false.
    var canSendImages: Bool {
        inputMode == .vision &&
            isImageSendingEnabled &&
            streamViewModel?.streamingStatus == .streaming &&
            currentVideoFrame != nil
    }

    /// Opts into or out of camera access without interrupting the realtime
    /// audio WebSocket. This is also used by UI-driven sessions when Live AI
    /// is running in the background.
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
            frameUpdateTimer?.invalidate()
            frameUpdateTimer = nil
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
            startFrameUpdateTimer()
        }
    }

    func switchInputMode(to mode: LiveAIInputMode) async {
        await setInputMode(mode)
    }

    private func fallbackToVoice(_ message: String) {
        inputMode = .voice
        isImageSendingEnabled = false
        currentVideoFrame = nil
        frameUpdateTimer?.invalidate()
        frameUpdateTimer = nil
        errorMessage = message
        tts.speak(message)
    }

    private func handleVisionStreamFailure() {
        guard inputMode == .vision else { return }
        isImageSendingEnabled = false
        inputMode = .voice
        currentVideoFrame = nil
        frameUpdateTimer?.invalidate()
        frameUpdateTimer = nil
        errorMessage = "视觉流已断开，已切回纯语音"
        tts.speak(errorMessage ?? "视觉流已断开，已切回纯语音")
    }

    // MARK: - Connection

    private func connectService() {
        switch provider {
        case .alibaba:
            omniService?.connect()
        case .google:
            geminiService?.connect()
        }
    }

    private func startRecording() {
        print("🎤 [LiveAIManager] 开始录音")
        switch provider {
        case .alibaba:
            omniService?.startRecording()
        case .google:
            geminiService?.startRecording()
        }
    }

    private func stopRecording() {
        print("🛑 [LiveAIManager] 停止录音")
        switch provider {
        case .alibaba:
            omniService?.stopRecording()
        case .google:
            geminiService?.stopRecording()
        }
    }

    // MARK: - Frame Update

    private func startFrameUpdateTimer() {
        frameUpdateTimer?.invalidate()
        frameUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateVideoFrame()
            }
        }
    }

    private func updateVideoFrame() {
        guard inputMode == .vision else { return }
        guard streamViewModel?.streamingStatus == .streaming else {
            handleVisionStreamFailure()
            return
        }
        if let frame = streamViewModel?.currentVideoFrame {
            currentVideoFrame = frame
        }
    }

    // MARK: - Stop Session

    /// 停止 Live AI 会话
    func stopSession() async {
        guard isRunning else { return }

        print("🛑 [LiveAIManager] Stopping session...")

        // 停止定时器
        frameUpdateTimer?.invalidate()
        frameUpdateTimer = nil

        // 停止录音
        stopRecording()

        // 保存对话
        saveConversation()

        // 断开连接
        switch provider {
        case .alibaba:
            omniService?.disconnect()
        case .google:
            geminiService?.disconnect()
        }

        // 停止视频流
        await streamViewModel?.stopSession()

        // 重置状态
        omniService = nil
        geminiService = nil
        isConnected = false
        isRunning = false
        inputMode = .voice
        hasSentFirstAudio = false
        isImageSendingEnabled = false
        currentVideoFrame = nil

        print("✅ [LiveAIManager] Session stopped")
    }

    /// 保存对话到历史记录
    private func saveConversation() {
        guard !conversationHistory.isEmpty else {
            print("💬 [LiveAIManager] 无对话内容，跳过保存")
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
            language: "zh-CN",
            initialInputMode: initialInputMode,
            visionFrameCount: sentImageCount
        )

        ConversationStorage.shared.saveConversation(record)
        print("💾 [LiveAIManager] 对话已保存: \(conversationHistory.count) 条消息")
    }

    /// 等待条件满足或超时
    private func waitForCondition(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return false }
        }
        return true
    }

    /// 手动触发停止（从 UI 调用）
    func triggerStop() {
        Task { @MainActor in
            await stopSession()
        }
    }
}

// MARK: - Live AI Error

enum LiveAIError: LocalizedError {
    case noDevice
    case streamNotReady
    case connectionFailed
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "眼镜未连接，请先在 Meta View 中配对眼镜"
        case .streamNotReady:
            return "视频流启动失败，请检查眼镜连接状态"
        case .connectionFailed:
            return "AI 服务连接失败，请检查网络"
        case .noAPIKey:
            return "请先在设置中配置 API Key"
        }
    }
}
