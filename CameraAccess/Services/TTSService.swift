/*
 * TTS Service
 * 文本转语音服务 - 使用阿里云 qwen3-tts-flash API
 * 使用和 OmniRealtimeService 相同的 AVAudioEngine 方式播放
 */

import AVFoundation
import Foundation

enum TTSPlaybackMode: Equatable {
    /// Preserve an already active play-and-record session.  This is used by
    /// Live AI status/error prompts so TTS cannot steal the glasses route.
    case automatic
    /// Use a standalone output-only session (Quick Vision and manual TTS).
    case standalonePlayback
}

@MainActor
class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published var isSpeaking = false

    private let baseURL = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
    private let model = "qwen3-tts-flash"

    // 根据当前语言设置获取语音
    private var voice: String {
        return LanguageManager.staticTtsVoice
    }

    // 根据当前语言设置获取语言类型
    private var languageType: String {
        return LanguageManager.staticApiLanguageCode
    }

    // 使用和 OmniRealtimeService 一样的 AVAudioEngine 方式
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    // 使用 Float32 标准格式，兼容 iOS 18+
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)
    private var isPlaybackEngineRunning = false

    private var currentTask: Task<Void, Never>?
    private var systemSynthesizer: AVSpeechSynthesizer?
    private var ownsAudioSession = false
    private var routeChangeObserver: NSObjectProtocol?
    private var pendingPlaybackMode: TTSPlaybackMode = .automatic
    private var activePlaybackMode: TTSPlaybackMode = .automatic

    private override init() {
        super.init()
        observeAudioRouteChanges()
    }

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    // MARK: - Audio Engine Setup (和 OmniRealtimeService 一样)

    private func setupPlaybackEngine() {
        playbackEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let playbackEngine = playbackEngine,
              let playerNode = playerNode,
              let playbackFormat = playbackFormat else {
            print("❌ [TTS] 无法初始化播放引擎")
            return
        }

        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
        playbackEngine.prepare()

        print("✅ [TTS] 播放引擎初始化完成: Float32 @ 24kHz")
    }

    /// 配置音频会话（需要在启动播放引擎之前调用）。 Automatic 模式
    /// 会复用正在进行的双工会话；只有没有双工会话时才切换到 playback。
    @discardableResult
    private func configureAudioSession(for mode: TTSPlaybackMode) -> Bool {
        do {
            let audioSession = AVAudioSession.sharedInstance()

            if mode == .automatic && audioSession.category == .playAndRecord {
                // Live AI/Realtime Translate owns the duplex session.  Do not
                // call setCategory here; reactivating it is enough for a
                // prompt to share the current Bluetooth route.
                try audioSession.setActive(true)
                ownsAudioSession = false
                logAudioRoute(audioSession, reason: "preserved_duplex")
                return true
            }

            let configuration = AudioSessionPolicy.standalonePlayback
            try audioSession.setCategory(
                configuration.category,
                mode: configuration.mode,
                options: configuration.options
            )
            try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
            ownsAudioSession = true
            logAudioRoute(audioSession, reason: "standalone_playback")
            return true
        } catch {
            print("⚠️ [TTS] Audio session 配置失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func startPlaybackEngine(mode: TTSPlaybackMode? = nil) -> Bool {
        // Keep screen entry route-neutral. Constructing and preparing an
        // output engine can itself make iOS renegotiate the current route.
        if playbackEngine == nil || playerNode == nil {
            setupPlaybackEngine()
        }
        guard let playbackEngine = playbackEngine else { return false }
        if isPlaybackEngineRunning { return true }

        let mode = mode ?? activePlaybackMode
        guard configureAudioSession(for: mode) else { return false }
        do {
            try playbackEngine.start()
            playerNode?.play()
            isPlaybackEngineRunning = true
            print("✅ [TTS] 播放引擎已启动")
            return true
        } catch {
            print("❌ [TTS] 播放引擎启动失败: \(error)")
            return false
        }
    }

    private func stopPlaybackEngine() {
        playerNode?.stop()
        playerNode?.reset()
        playbackEngine?.stop()
        isPlaybackEngineRunning = false
    }

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            print("⚠️ [TTS] 释放音频会话失败: \(error.localizedDescription)")
        }
        ownsAudioSession = false
    }

    // MARK: - API Request Models

    struct TTSRequest: Codable {
        let model: String
        let input: Input

        struct Input: Codable {
            let text: String
            let voice: String
            let language_type: String
        }
    }

    // MARK: - Public Methods

    /// 记录下一次播报的会话模式。在 Quick Vision 停止视频流前调用时，
    /// 不会提前抢占仍由视频/录音链路使用的音频会话。
    func prepareAudioSession(mode: TTSPlaybackMode = .automatic) {
        pendingPlaybackMode = mode
        if mode == .automatic {
            _ = configureAudioSession(for: mode)
        }
        print("🔊 [TTS] 音频会话模式已准备: \(String(describing: mode))")
    }

    /// 播报文本
    /// - 阿里云 API：使用阿里云 qwen3-tts-flash
    /// - OpenRouter API：使用系统 TTS
    func speak(_ text: String, apiKey: String? = nil, mode: TTSPlaybackMode? = nil) {
        let playbackMode = mode ?? pendingPlaybackMode
        pendingPlaybackMode = .automatic
        activePlaybackMode = playbackMode

        // 取消之前的任务
        currentTask?.cancel()
        stop()

        // OpenRouter 使用系统 TTS
        if APIProviderManager.staticCurrentProvider == .openrouter {
            print("🔊 [TTS] OpenRouter mode, using system TTS")
            isSpeaking = true
            currentTask = Task {
                await fallbackToSystemTTS(text: text, mode: playbackMode)
                isSpeaking = false
            }
            return
        }

        // 阿里云：使用阿里云 TTS
        let key = apiKey ?? APIKeyManager.shared.getAPIKey(for: .alibaba)

        guard let finalKey = key, !finalKey.isEmpty else {
            print("❌ [TTS] No Alibaba API key, falling back to system TTS")
            isSpeaking = true
            currentTask = Task {
                await fallbackToSystemTTS(text: text, mode: playbackMode)
                isSpeaking = false
            }
            return
        }

        print("🔊 [TTS] Speaking with qwen3-tts-flash: \(text.prefix(50))...")

        isSpeaking = true

        currentTask = Task {
            do {
                try await synthesizeAndPlay(text: text, apiKey: finalKey, mode: playbackMode)
            } catch {
                if !Task.isCancelled {
                    print("❌ [TTS] Error: \(error)")
                    // 失败时回退到系统 TTS
                    await fallbackToSystemTTS(text: text, mode: playbackMode)
                }
            }
            if !Task.isCancelled {
                isSpeaking = false
            }
        }
    }

    /// 停止播报
    func stop() {
        currentTask?.cancel()
        currentTask = nil
        stopPlaybackEngine()
        releaseAudioSession()
        isSpeaking = false
        print("🔊 [TTS] Stopped")
    }

    // MARK: - Private Methods

    private func synthesizeAndPlay(text: String, apiKey: String, mode: TTSPlaybackMode) async throws {
        guard let url = URL(string: baseURL) else {
            throw TTSError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE")
        request.timeoutInterval = 30

        let ttsRequest = TTSRequest(
            model: model,
            input: TTSRequest.Input(
                text: text,
                voice: voice,
                language_type: languageType
            )
        )

        request.httpBody = try JSONEncoder().encode(ttsRequest)

        print("📡 [TTS] Sending request to qwen3-tts-flash...")

        // 使用 URLSession 的 bytes API 处理 SSE
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            print("❌ [TTS] API error: \(httpResponse.statusCode)")
            throw TTSError.apiError(statusCode: httpResponse.statusCode)
        }

        // 停止当前播放并重置 playerNode 队列
        playerNode?.stop()
        playerNode?.reset()

        // 确保播放引擎在运行
        if !isPlaybackEngineRunning {
            guard startPlaybackEngine(mode: mode) else {
                throw TTSError.playbackFailed
            }
        }

        // 提前调用 play()，让 playerNode 准备好接收 buffer
        playerNode?.play()
        print("▶️ [TTS] 播放引擎和 playerNode 已就绪")

        guard isPlaybackEngineRunning else {
            print("❌ [TTS] 播放引擎未运行")
            throw TTSError.playbackFailed
        }

        var chunkCount = 0
        var totalBytes = 0

        for try await line in bytes.lines {
            if Task.isCancelled { return }

            // SSE 格式: "data: {...}"
            if line.hasPrefix("data:") {
                let jsonString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)

                if jsonString == "[DONE]" {
                    break
                }

                if let jsonData = jsonString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let output = json["output"] as? [String: Any],
                   let audio = output["audio"] as? [String: Any],
                   let audioString = audio["data"] as? String,
                   !audioString.isEmpty,
                   let audioData = Data(base64Encoded: audioString),
                   !audioData.isEmpty {
                    chunkCount += 1
                    totalBytes += audioData.count
                    if chunkCount == 1 {
                        print("🔊 [TTS] 收到第一个音频片段: \(audioData.count) bytes")
                    }
                    // 流式播放每个音频片段
                    playAudioChunk(audioData)
                }
            }
        }

        if Task.isCancelled { return }

        print("🔊 [TTS] Received \(chunkCount) chunks, \(totalBytes) bytes total")

        // 等待播放完成
        await waitForPlaybackCompletion()
        stopPlaybackEngine()
        releaseAudioSession()

        print("🔊 [TTS] Finished playing")
    }

    private func playAudioChunk(_ audioData: Data) {
        // 跳过空数据
        guard !audioData.isEmpty else {
            return
        }

        guard let playerNode = playerNode,
              let playbackFormat = playbackFormat else {
            print("⚠️ [TTS] playerNode 或 playbackFormat 未初始化")
            return
        }

        guard let pcmBuffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            print("⚠️ [TTS] 无法创建 PCM buffer, audioData.count=\(audioData.count)")
            return
        }

        // 确保播放引擎运行中
        if !isPlaybackEngineRunning {
            guard startPlaybackEngine() else { return }
        }

        // 确保 playerNode 在播放状态（和 OmniRealtimeService 一致）
        if !playerNode.isPlaying {
            playerNode.play()
            print("▶️ [TTS] playerNode.play() 已调用")
        }

        // 调度音频缓冲区播放
        playerNode.scheduleBuffer(pcmBuffer)
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // 服务器发送的是 PCM16 格式，每帧 2 字节
        let frameCount = data.count / 2
        guard frameCount > 0 else {
            print("⚠️ [TTS] createPCMBuffer: frameCount is 0, data.count=\(data.count)")
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            print("⚠️ [TTS] createPCMBuffer: Failed to create AVAudioPCMBuffer, format=\(format), frameCount=\(frameCount)")
            return nil
        }

        guard let channelData = buffer.floatChannelData else {
            print("⚠️ [TTS] createPCMBuffer: floatChannelData is nil")
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        // 将 PCM16 转换为 Float32（兼容 iOS 18+）
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            let floatData = channelData[0]
            for i in 0..<frameCount {
                // Int16 范围 -32768 到 32767，转换为 -1.0 到 1.0
                floatData[i] = Float(int16Pointer[i]) / 32768.0
            }
        }

        return buffer
    }

    private func waitForPlaybackCompletion() async {
        guard let playerNode = playerNode else { return }

        // 等待所有音频播放完成
        while playerNode.isPlaying {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        }

        // 额外等待确保完全播放
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3秒
    }

    /// 回退到系统 TTS
    private func fallbackToSystemTTS(text: String, mode: TTSPlaybackMode) async {
        print("🔊 [TTS] Falling back to system TTS")

        guard configureAudioSession(for: mode) else { return }

        // 使用实例变量保持强引用，防止被释放
        systemSynthesizer = AVSpeechSynthesizer()

        guard let synthesizer = systemSynthesizer else { return }

        let utterance = AVSpeechUtterance(string: text)
        // 根据当前语言设置选择系统语音
        let voiceLanguage = LanguageManager.staticIsChinese ? "zh-CN" : "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLanguage)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.0
        utterance.volume = 1.0
        utterance.pitchMultiplier = 1.0

        print("🔊 [TTS] System TTS speaking: \(text.prefix(30))...")
        synthesizer.speak(utterance)

        // 等待一小段时间让播放开始
        try? await Task.sleep(nanoseconds: 100_000_000)

        // 等待播放完成
        while synthesizer.isSpeaking {
            if Task.isCancelled {
                synthesizer.stopSpeaking(at: .immediate)
                systemSynthesizer = nil
                releaseAudioSession()
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        print("✅ [TTS] System TTS finished")
        systemSynthesizer = nil
        releaseAudioSession()
    }

    private func observeAudioRouteChanges() {
        let session = AVAudioSession.sharedInstance()
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            // Route notifications are delivered on a secondary thread.
            DispatchQueue.main.async { [weak self] in
                self?.handleAudioRouteChange(notification)
            }
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard ownsAudioSession, isPlaybackEngineRunning else { return }
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)
            .map { AVAudioSession.RouteChangeReason(rawValue: $0.uintValue) }
            .map { String(describing: $0) } ?? "unknown"
        let session = AVAudioSession.sharedInstance()
        logAudioRoute(session, reason: "route_changed_\(reason)")
        do {
            // Never force a speaker/BT route.  Reactivation lets iOS select a
            // valid replacement after an accessory disconnects.
            try session.setActive(true)
            logAudioRoute(session, reason: "route_reactivated")
        } catch {
            print("⚠️ [TTS] 路由变化后恢复音频会话失败: \(error.localizedDescription)")
        }
    }

    private func logAudioRoute(_ session: AVAudioSession, reason: String) {
        let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("🔊 [TTS] 音频路由 reason=\(reason) category=\(session.category.rawValue) mode=\(session.mode.rawValue) input=\(inputs.isEmpty ? "none" : inputs) output=\(outputs.isEmpty ? "none" : outputs)")
    }
}

// MARK: - Error Types

enum TTSError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(statusCode: Int)
    case noAudioData
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "未配置 API Key"
        case .invalidResponse:
            return "无效的响应"
        case .apiError(let statusCode):
            return "API 错误: \(statusCode)"
        case .noAudioData:
            return "未收到音频数据"
        case .playbackFailed:
            return "音频播放失败"
        }
    }
}
