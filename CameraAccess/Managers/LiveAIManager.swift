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
    @Published var showError = false
    @Published private(set) var isRecording = false
    @Published private(set) var currentTranscript = ""
    @Published private(set) var isSpeaking = false
    @Published private(set) var responseState: LiveAIResponseState = .idle
    @Published private(set) var inputMode: LiveAIInputMode = .voice
    @Published private(set) var sentImageCount = 0
    @Published private(set) var isSwitchingInputMode = false
    /// 会话结束原因，供 UI 区分"正常停止"与"失败"
    @Published private(set) var stopReason: LiveAIStopReason?

    // 依赖
    private(set) var streamViewModel: StreamSessionViewModel?
    private var omniService: OmniRealtimeService?
    private var geminiService: GeminiLiveService?
    private var provider: LiveAIProvider = .alibaba
    private var sessionModel = LiveAIProvider.alibaba.defaultModel

    // 视频帧
    private var currentVideoFrame: UIImage?
    private var hasSentFirstAudio = false
    private var isImageSendingEnabled = false
    private var frameUpdateTimer: Timer?

    // 对话历史
    @Published private(set) var conversationHistory: [ConversationMessage] = []
    private var initialInputMode: LiveAIInputMode = .voice

    // TTS
    private let tts = TTSService.shared
    private var lastSpokenErrorAt: Date?

    /// 清理进行中标志：防止停止按钮/onDisappear/停止指令并发触发重复清理，
    /// 同时让主动断开后服务上报的取消类错误被静默忽略
    private var isStopping = false

    /// 会话代次：每次 startLiveAISession 递增。所有服务回调携带启动时的代次，
    /// 旧会话已排队的延迟回调（含取消类错误）到达时代次不匹配即丢弃，
    /// 避免污染新会话状态
    private var sessionGeneration = 0

    private init() {}

    /// 设置 StreamSessionViewModel 引用
    func setStreamViewModel(_ viewModel: StreamSessionViewModel) {
        self.streamViewModel = viewModel
    }

    // MARK: - Start Session

    /// 启动 Live AI 会话（后台模式）
    func startLiveAISession() async {
        guard !isRunning else {
            print("⚠️ [LiveAIManager] Already running")
            return
        }

        // 上一次会话的清理（stopSession/failFatal）尚未完成：等待清理结束再启动，
        // 避免新会话的服务引用、DAT 会话被旧清理尾部覆盖（"停止后立即再次 Siri 启动"场景）
        if isStopping {
            let cleanupFinished = await waitForCondition(timeout: 5.0) { !self.isStopping }
            guard cleanupFinished else {
                print("⚠️ [LiveAIManager] Previous cleanup did not finish in time, skip starting new session")
                return
            }
            // 等待期间可能已有其它路径启动了会话：重新检查运行状态
            guard !isRunning else {
                print("⚠️ [LiveAIManager] Session already started during cleanup wait")
                return
            }
        }

        // 启动前校验：失败不进入运行态，仅弹窗 + TTS 提示
        let apiKey = APIProviderManager.staticLiveAIAPIKey
        guard !apiKey.isEmpty else {
            failBeforeStart("请先在设置中配置 API Key")
            return
        }

        if let configurationError = APIProviderManager.shared.liveAIConfigurationError {
            failBeforeStart(configurationError)
            return
        }

        // 新会话代次：旧会话残留的延迟回调将因代次不匹配被全部丢弃
        sessionGeneration += 1

        isRunning = true
        stopReason = nil
        errorMessage = nil
        conversationHistory = []
        inputMode = .voice
        responseState = .idle
        initialInputMode = .voice
        sentImageCount = 0
        hasSentFirstAudio = false
        isImageSendingEnabled = false
        currentVideoFrame = nil
        currentTranscript = ""

        // 获取当前 provider
        provider = APIProviderManager.staticLiveAIProvider
        sessionModel = APIProviderManager.staticLiveAIModel

        print("🚀 [LiveAIManager] Starting Live AI session...")

        do {
            // 1. 强校验 streamViewModel 与设备连接状态
            guard let streamViewModel else {
                throw LiveAIError.notInitialized
            }
            guard streamViewModel.hasActiveDevice else {
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

            // 连接阶段用户主动关闭页面（.task 被取消）或会话已被其它路径停止：
            // 静默退出，不上报为连接失败；资源由 stopSession 统一清理
            if Task.isCancelled || !isRunning {
                print("ℹ️ [LiveAIManager] Session cancelled during connection, skip error handling")
                return
            }

            if !connected {
                print("❌ [LiveAIManager] Failed to connect to AI service")
                throw LiveAIError.connectionFailed
            }

            // 5. 直接开始录音（不播放 TTS，避免音频会话冲突）
            print("🎤 [LiveAIManager] About to start recording...")
            startRecording()

            print("✅ [LiveAIManager] Live AI session started, ready to talk")

        } catch {
            print("❌ [LiveAIManager] Start failed: \(error)")
            await failFatal(error.localizedDescription)
        }
    }

    /// 启动前校验失败：此时尚未进入运行态，无会话资源需要清理，
    /// 仅弹出错误提示 + TTS 播报，避免 UI 停留在中间状态
    private func failBeforeStart(_ message: String) {
        errorMessage = message
        showError = true
        responseState = .failed
        stopReason = .failed
        speakError(message)
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
            omniService = OmniRealtimeService(apiKey: apiKey, model: sessionModel)
            setupOmniCallbacks()
        case .google:
            geminiService = GeminiLiveService(apiKey: apiKey, model: sessionModel)
            setupGeminiCallbacks()
        }
    }

    private func setupOmniCallbacks() {
        guard let omniService = omniService else { return }
        // 携带本次会话的代次：停止后立即重启时，旧服务已排队的延迟回调
        // 到达时代次不匹配，一律丢弃，不污染新会话
        let generation = sessionGeneration

        omniService.onConnected = { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.isConnected = true
                print("✅ [LiveAIManager] Omni connected")
            }
        }

        omniService.onResponseState = { [weak self] state in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.applyResponseState(state)
            }
        }

        omniService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.hasSentFirstAudio = true
                self.isImageSendingEnabled = self.inputMode == .vision
                print("✅ [LiveAIManager] 收到第一次音频发送回调，图片权限=\(self.isImageSendingEnabled)")
            }
        }

        omniService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.isSpeaking = true
                if self.canSendImages,
                   let frame = self.currentVideoFrame {
                    print("🎤📸 [LiveAIManager] 检测到用户语音，发送当前视频帧")
                    self.omniService?.sendImageAppend(frame)
                    self.sentImageCount += 1
                }
            }
        }

        omniService.onSpeechStopped = { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.isSpeaking = false
            }
        }

        omniService.onTranscriptDelta = { [weak self] delta in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.currentTranscript += delta
            }
        }

        omniService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                print("💬 [LiveAIManager] 用户: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        omniService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                let textToSave = fullText.isEmpty ? self.currentTranscript : fullText
                guard !textToSave.isEmpty else { return }
                print("💬 [LiveAIManager] AI: \(textToSave)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: textToSave)
                )
                self.currentTranscript = ""
            }
        }

        omniService.onError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else {
                    print("ℹ️ [LiveAIManager] Ignoring stale Omni error: \(error)")
                    return
                }
                self.handleServiceError(error)
            }
        }
    }

    private func setupGeminiCallbacks() {
        guard let geminiService = geminiService else { return }
        // 携带本次会话的代次：停止后立即重启时，旧服务已排队的延迟回调
        // 到达时代次不匹配，一律丢弃，不污染新会话
        let generation = sessionGeneration

        geminiService.onConnected = { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.isConnected = true
                print("✅ [LiveAIManager] Gemini connected")
            }
        }

        geminiService.onResponseState = { [weak self] state in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.applyResponseState(state)
            }
        }

        geminiService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.hasSentFirstAudio = true
                self.isImageSendingEnabled = self.inputMode == .vision
                print("✅ [LiveAIManager] 收到第一次音频发送回调，图片权限=\(self.isImageSendingEnabled)")
            }
        }

        geminiService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.isSpeaking = true
                if self.canSendImages,
                   let frame = self.currentVideoFrame {
                    print("🎤📸 [LiveAIManager] 检测到用户语音，发送当前视频帧")
                    self.geminiService?.sendImageInput(frame)
                    self.sentImageCount += 1
                }
            }
        }

        geminiService.onSpeechStopped = { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.isSpeaking = false
            }
        }

        geminiService.onTranscriptDelta = { [weak self] delta in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.currentTranscript += delta
            }
        }

        geminiService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                print("💬 [LiveAIManager] 用户: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        geminiService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                let textToSave = fullText.isEmpty ? self.currentTranscript : fullText
                guard !textToSave.isEmpty else { return }
                print("💬 [LiveAIManager] AI: \(textToSave)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: textToSave)
                )
                self.currentTranscript = ""
            }
        }

        geminiService.onAudioDone = { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.isSpeaking = false
            }
        }

        geminiService.onError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else {
                    print("ℹ️ [LiveAIManager] Ignoring stale Gemini error: \(error)")
                    return
                }
                self.handleServiceError(error)
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
            notifyModelOfInputMode(.voice)

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
            notifyModelOfInputMode(.vision)
        }
    }

    /// The session always starts with the voice-mode system prompt, and the
    /// prompt cannot change afterwards, so tell the model in-conversation
    /// when the user switches modes. Without this Gemini keeps answering
    /// "I cannot see, please switch to Vision Chat" while it is already
    /// receiving images.
    private func notifyModelOfInputMode(_ mode: LiveAIInputMode) {
        guard provider == .google else { return }
        let note: String
        switch mode {
        case .vision:
            note = "[Client notice] Vision Chat is now ON. From now on the client attaches one latest camera image as the user begins speaking. Describe the surroundings only from the image received for the current turn; if none arrived, say you cannot see it right now. Do not reply to this notice."
        case .voice:
            note = "[Client notice] Vision Chat is now OFF. No images accompany the user's speech from now on; if a request needs visual information, say you cannot see it right now and suggest switching to Vision Chat. Do not reply to this notice."
        }
        geminiService?.sendContextNote(note)
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
        responseState = .failed
        speakError(message)
    }

    private func handleVisionStreamFailure() {
        guard inputMode == .vision else { return }
        isImageSendingEnabled = false
        inputMode = .voice
        currentVideoFrame = nil
        frameUpdateTimer?.invalidate()
        frameUpdateTimer = nil
        errorMessage = "视觉流已断开，已切回纯语音"
        responseState = .failed
        speakError(errorMessage ?? "视觉流已断开，已切回纯语音")
        // 视觉流已异常，释放 DAT 会话；语音会话保持不变
        Task { @MainActor in
            await streamViewModel?.stopSession()
        }
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
        guard isConnected else {
            print("⚠️ [LiveAIManager] 未连接，无法开始录音")
            return
        }
        print("🎤 [LiveAIManager] 开始录音")
        switch provider {
        case .alibaba:
            omniService?.startRecording()
        case .google:
            geminiService?.startRecording()
        }
        isRecording = true
    }

    private func stopRecording() {
        print("🛑 [LiveAIManager] 停止录音")
        switch provider {
        case .alibaba:
            omniService?.stopRecording()
        case .google:
            geminiService?.stopRecording()
        }
        isRecording = false
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

    /// 停止 Live AI 会话（幂等：并发调用只会执行一次清理）
    func stopSession() async {
        guard isRunning, !isStopping else { return }
        isStopping = true
        // 立即失效当前代次：本会话已排队的回调在清理窗口内全部丢弃，
        // 避免对话保存后仍有迟到转写追加等状态污染
        sessionGeneration += 1

        print("🛑 [LiveAIManager] Stopping session...")

        // 先发布停止原因再翻转 isRunning，保证 UI 在 isRunning 变化回调中能读到有效的 stopReason
        stopReason = .stopped
        isRunning = false

        // 停止定时器
        frameUpdateTimer?.invalidate()
        frameUpdateTimer = nil
        waitingWatchdog?.cancel()
        waitingWatchdog = nil

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
        responseState = .idle
        inputMode = .voice
        hasSentFirstAudio = false
        isImageSendingEnabled = false
        currentVideoFrame = nil
        currentTranscript = ""
        isSpeaking = false
        showError = false
        isStopping = false

        print("✅ [LiveAIManager] Session stopped")
    }

    /// 保存对话到历史记录
    private func saveConversation() {
        guard !conversationHistory.isEmpty else {
            print("💬 [LiveAIManager] 无对话内容，跳过保存")
            return
        }

        let record = ConversationRecord(
            messages: conversationHistory,
            aiModel: sessionModel,
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

    /// Stop microphone capture before speaking an error so the phone/eyeglass
    /// output cannot be fed back into the realtime model. Successful model
    /// responses never pass through this path: they use native provider audio.
    /// A turn that stays in `.waiting` (user transcribed, nothing back from
    /// the model) this long is released so the UI is not stuck on
    /// "Getting the latest information..." forever.
    private let waitingTimeout: TimeInterval = 30
    private var waitingWatchdog: Task<Void, Never>?

    private func applyResponseState(_ state: LiveAIResponseState) {
        responseState = state
        waitingWatchdog?.cancel()
        waitingWatchdog = nil
        guard state == .waiting else { return }
        let generation = sessionGeneration
        let timeout = waitingTimeout
        waitingWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled,
                  self.sessionGeneration == generation,
                  self.responseState == .waiting else { return }
            print("⏱️ [LiveAIManager] 模型 \(Int(timeout)) 秒无响应，释放等待状态")
            self.errorMessage = "AI 没有响应，请再说一次 / No reply from the model, please try again"
            self.responseState = .idle
        }
    }

    private func handleServiceError(_ message: String) {
        // 先停录音防回声，再走致命错误的全量清理
        stopRecording()
        Task { @MainActor in
            await failFatal(message)
        }
    }

    /// 致命错误统一出口：停止整个会话并清理全部资源。
    /// 覆盖：设备未连接/未初始化、服务连接失败或超时、运行期服务错误。
    /// 视觉模式的可恢复失败不走这里，走 fallbackToVoice 保留语音会话。
    private func failFatal(_ message: String) async {
        // 正常停止进行中或已完成：主动 disconnect 后服务上报的取消类错误是预期行为，
        // 不能把正常停止覆盖为失败（避免误弹错误、误播 TTS、并发重复清理）
        guard isRunning, !isStopping else {
            print("ℹ️ [LiveAIManager] Ignoring error during stopping: \(message)")
            return
        }
        isStopping = true
        // 立即失效当前代次：本会话已排队的回调在清理窗口内全部丢弃
        sessionGeneration += 1

        print("❌ [LiveAIManager] Fatal: \(message)")

        // 先停录音，避免错误播报被回采进模型
        stopRecording()

        // 保存已产生的对话历史，避免致命错误（如运行中断网）丢失多轮对话
        saveConversation()

        errorMessage = message
        showError = true
        responseState = .failed
        // 先发布停止原因再翻转 isRunning，保证 UI 在变化回调中读到有效的 stopReason
        stopReason = .failed
        isRunning = false

        // 停止帧定时器
        frameUpdateTimer?.invalidate()
        frameUpdateTimer = nil

        // 断开服务
        switch provider {
        case .alibaba:
            omniService?.disconnect()
        case .google:
            geminiService?.disconnect()
        }

        // 停止视频流
        await streamViewModel?.stopSession()

        // 重置会话状态
        omniService = nil
        geminiService = nil
        isConnected = false
        inputMode = .voice
        hasSentFirstAudio = false
        isImageSendingEnabled = false
        currentVideoFrame = nil
        currentTranscript = ""
        isSpeaking = false
        isStopping = false

        speakError(message)
    }

    /// 清除错误提示（UI 确认弹窗后调用）
    func dismissError() {
        showError = false
        errorMessage = nil
    }

    private func speakError(_ message: String) {
        let now = Date()
        if let lastSpokenErrorAt,
           now.timeIntervalSince(lastSpokenErrorAt) < 3 {
            return
        }
        lastSpokenErrorAt = now
        tts.prepareAudioSession(mode: .automatic)
        tts.speak(LiveAIErrorMessage.speech(for: message), mode: .automatic)
    }
}

// MARK: - Live AI Error

enum LiveAIError: LocalizedError {
    case notInitialized
    case noDevice
    case streamNotReady
    case connectionFailed
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "功能未初始化，请重新打开应用"
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

// MARK: - Live AI Stop Reason

/// 会话结束原因：stopped 为正常停止（UI 可自动关闭页面），
/// failed 为失败终止（UI 应保留页面展示错误弹窗）
enum LiveAIStopReason {
    case stopped
    case failed
}
