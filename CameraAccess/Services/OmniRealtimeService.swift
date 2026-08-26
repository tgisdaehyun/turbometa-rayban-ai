/*
 * Qwen-Omni-Realtime WebSocket Service
 * Provides real-time audio and video chat with AI
 */

import Foundation
import UIKit
import AVFoundation

// MARK: - WebSocket Events

enum OmniClientEvent: String {
    case sessionUpdate = "session.update"
    case inputAudioBufferAppend = "input_audio_buffer.append"
    case inputAudioBufferCommit = "input_audio_buffer.commit"
    case inputImageBufferAppend = "input_image_buffer.append"
    case responseCreate = "response.create"
}

enum OmniServerEvent: String {
    case sessionCreated = "session.created"
    case sessionUpdated = "session.updated"
    case inputAudioBufferSpeechStarted = "input_audio_buffer.speech_started"
    case inputAudioBufferSpeechStopped = "input_audio_buffer.speech_stopped"
    case inputAudioBufferCommitted = "input_audio_buffer.committed"
    case responseCreated = "response.created"
    case responseAudioTranscriptDelta = "response.audio_transcript.delta"
    case responseAudioTranscriptDone = "response.audio_transcript.done"
    case responseAudioDelta = "response.audio.delta"
    case responseAudioDone = "response.audio.done"
    case responseDone = "response.done"
    case conversationItemCreated = "conversation.item.created"
    case conversationItemInputAudioTranscriptionCompleted = "conversation.item.input_audio_transcription.completed"
    case error = "error"
}

// MARK: - Service Class

class OmniRealtimeService: NSObject {

    static let realtimeInputSampleRate = 16000.0

    static func resampledFrameCount(
        inputFrameCount: Int,
        inputSampleRate: Double,
        targetSampleRate: Double = realtimeInputSampleRate
    ) -> Int {
        guard inputFrameCount > 0, inputSampleRate > 0, targetSampleRate > 0 else {
            return 0
        }
        return Int((Double(inputFrameCount) * targetSampleRate / inputSampleRate).rounded(.up))
    }

    /// Pure configuration builder kept internal so protocol changes can be
    /// covered without opening a real WebSocket in unit tests.
    static func sessionFields(
        instructions: String,
        voice: String = "Tina"
    ) -> [String: Any] {
        [
            "modalities": ["text", "audio"],
            "voice": voice,
            "instructions": instructions,
            "audio": [
                "input": [
                    "format": [
                            "type": "pcm",
                            "sample_rate": Int(realtimeInputSampleRate)
                    ]
                ],
                "output": [
                    "format": [
                        "type": "pcm",
                        "sample_rate": 24000
                    ]
                ]
            ],
            "enable_search": true,
            "search_options": [
                "enable_source": false
            ],
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "silence_duration_ms": 800
            ]
        ]
    }

    // WebSocket
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Configuration
    private let apiKey: String
    private let model: String
    // 根据用户设置的区域动态获取 WebSocket URL（北京/新加坡）
    private var baseURL: String {
        return APIProviderManager.staticLiveAIWebsocketURL
    }

    // Audio Engine (for recording)
    private var audioEngine: AVAudioEngine?
    private let recordTargetFormat = AVAudioFormat(
        standardFormatWithSampleRate: OmniRealtimeService.realtimeInputSampleRate,
        channels: 1
    )
    private var recordConverter: AVAudioConverter?

    // Audio Playback Engine (separate engine for playback)
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    // 使用 Float32 标准格式，兼容 iOS 18
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)

    // Audio buffer management
    private var audioBuffer = Data()
    private var isCollectingAudio = false
    private var audioChunkCount = 0
    private let minChunksBeforePlay = 2 // 首次收到2个片段后开始播放
    private var hasStartedPlaying = false
    private var isPlaybackEngineRunning = false

    // Callbacks
    var onTranscriptDelta: ((String) -> Void)?
    var onTranscriptDone: ((String) -> Void)?
    var onUserTranscript: ((String) -> Void)? // 用户语音识别结果
    var onAudioDelta: ((Data) -> Void)?
    var onAudioDone: (() -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onSpeechStopped: (() -> Void)?
    var onError: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onFirstAudioSent: (() -> Void)?
    var onResponseState: ((LiveAIResponseState) -> Void)?

    // State
    private var isRecording = false
    private var hasAudioBeenSent = false
    private var eventIdCounter = 0

    init(apiKey: String, model: String? = nil) {
        self.apiKey = apiKey
        self.model = model ?? APIProviderManager.staticLiveAIModel
        super.init()
        setupAudioEngine()
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        // Recording engine
        audioEngine = AVAudioEngine()
    }

    private func setupPlaybackEngine() {
        playbackEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let playbackEngine = playbackEngine,
              let playerNode = playerNode,
              let playbackFormat = playbackFormat else {
            print("❌ [Omni] 无法初始化播放引擎")
            return
        }

        // Attach player node
        playbackEngine.attach(playerNode)

        // Connect player node to output with explicit format
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
        playbackEngine.prepare()

        print("✅ [Omni] 播放引擎初始化完成: Float32 @ 24kHz")
    }

    private func startPlaybackEngine() {
        guard !isPlaybackEngineRunning else { return }

        // Entering Live AI should not prepare an output graph and renegotiate
        // the user's current route. Build it only for actual response audio.
        if playbackEngine == nil || playerNode == nil {
            setupPlaybackEngine()
        }
        guard let playbackEngine else { return }

        do {
            try playbackEngine.start()
            isPlaybackEngineRunning = true
            print("▶️ [Omni] 播放引擎已启动")
        } catch {
            print("❌ [Omni] 播放引擎启动失败: \(error)")
        }
    }

    private func stopPlaybackEngine() {
        guard let playbackEngine = playbackEngine, isPlaybackEngineRunning else { return }

        // 重要：先重置 playerNode 以清除所有已调度但未播放的 buffer
        playerNode?.stop()
        playerNode?.reset()  // 清除队列中的所有 buffer
        playbackEngine.stop()
        isPlaybackEngineRunning = false
        print("⏹️ [Omni] 播放引擎已停止并清除队列")
    }

    // MARK: - WebSocket Connection

    func connect() {
        guard !baseURL.isEmpty else {
            let message = "liveai.error.alibaba.workspace".localized
            print("❌ [Omni] \(message)")
            onResponseState?(.failed)
            onError?(message)
            return
        }
        let urlString = "\(baseURL)?model=\(model)"
        print("🔌 [Omni] 准备连接 WebSocket: \(urlString)")

        guard let url = URL(string: urlString) else {
            print("❌ [Omni] 无效的 URL")
            onResponseState?(.failed)
            onError?("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())

        webSocket = urlSession?.webSocketTask(with: request)
        webSocket?.resume()

        print("🔌 [Omni] WebSocket 任务已启动")
        receiveMessage()
    }

    func disconnect() {
        print("🔌 [Omni] 断开 WebSocket 连接")
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        stopRecording()
        stopPlaybackEngine()
    }

    // MARK: - Session Configuration

    private func configureSession() {
        // 根据当前语言设置获取语音和提示词
        // Tina is the Qwen3.5 Omni realtime voice used by this product. Keep
        // it independent from the standalone TTS voice preference.
        let voice = "Tina"
        // Every realtime session starts voice-only. The appended constraint
        // also explains how to treat an image if the user opts into vision
        // later without reconnecting this WebSocket.
        let instructions = LiveAIModeManager.staticSystemPrompt(inputMode: .voice)
            + LiveAIWebSearchPolicy.instructions

        let sessionConfig: [String: Any] = [
            "event_id": generateEventId(),
            "type": OmniClientEvent.sessionUpdate.rawValue,
            "session": Self.sessionFields(instructions: instructions, voice: voice)
        ]

        sendEvent(sessionConfig)
    }

    // MARK: - Audio Recording

    func startRecording() {
        guard !isRecording else {
            return
        }

        do {
            print("🎤 [Omni] 开始录音")

            // Stop engine if already running and remove any existing taps
            if let engine = audioEngine, engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }

            let audioSession = AVAudioSession.sharedInstance()

            // Prefer the glasses duplex route; if it is unavailable, never
            // let the fallback output collapse to the quiet receiver.
            let configuration = AudioSessionPolicy.glassesDuplex
            try audioSession.setCategory(
                configuration.category,
                mode: configuration.mode,
                options: configuration.options
            )
            try audioSession.setActive(true)

            guard let engine = audioEngine else {
                print("❌ [Omni] 音频引擎未初始化")
                return
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            if let recordTargetFormat {
                recordConverter = AVAudioConverter(from: inputFormat, to: recordTargetFormat)
            } else {
                recordConverter = nil
            }

            // Qwen3.5 expects 16 kHz mono PCM. iPhone input commonly runs at
            // 48 kHz, so always resample before appending the WebSocket chunk.
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer, inputFormat: inputFormat)
            }

            engine.prepare()
            try engine.start()

            isRecording = true
            print("✅ [Omni] 录音已启动")

        } catch {
            print("❌ [Omni] 启动录音失败: \(error.localizedDescription)")
            onError?("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else {
            return
        }

        print("🛑 [Omni] 停止录音")
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        isRecording = false
        hasAudioBeenSent = false
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let recordConverter, let recordTargetFormat else {
            return
        }

        let targetFrameCapacity = AVAudioFrameCount(
            max(1, Self.resampledFrameCount(
                inputFrameCount: Int(buffer.frameLength),
                inputSampleRate: inputFormat.sampleRate,
                targetSampleRate: recordTargetFormat.sampleRate
            ))
        )
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: recordTargetFormat,
            frameCapacity: targetFrameCapacity
        ) else {
            return
        }

        var hasProvidedInput = false
        var conversionError: NSError?
        let status = recordConverter.convert(to: converted, error: &conversionError) { _, outStatus in
            if hasProvidedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil, status != .error,
              let floatChannelData = converted.floatChannelData else {
            return
        }

        let frameLength = Int(converted.frameLength)
        let channel = floatChannelData.pointee

        // Convert Float32 (-1.0 to 1.0) to Int16 (-32768 to 32767)
        var int16Data = [Int16](repeating: 0, count: frameLength)
        for i in 0..<frameLength {
            let sample = channel[i]
            let clampedSample = max(-1.0, min(1.0, sample))
            int16Data[i] = Int16(clampedSample * 32767.0)
        }

        let data = Data(bytes: int16Data, count: frameLength * MemoryLayout<Int16>.size)
        let base64Audio = data.base64EncodedString()

        sendAudioAppend(base64Audio)

        // 通知第一次音频已发送
        if !hasAudioBeenSent {
            hasAudioBeenSent = true
            print("✅ [Omni] 第一次音频已发送，启用语音触发模式")
            DispatchQueue.main.async { [weak self] in
                self?.onFirstAudioSent?()
            }
        }
    }

    // MARK: - Send Events

    private func sendEvent(_ event: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ [Omni] 无法序列化事件")
            return
        }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocket?.send(message) { [weak self] error in
            if let error = error {
                print("❌ [Omni] 发送事件失败: \(error.localizedDescription)")
                self?.onError?("Send error: \(error.localizedDescription)")
            }
        }
    }

    func sendAudioAppend(_ base64Audio: String) {
        let event: [String: Any] = [
            "event_id": generateEventId(),
            "type": OmniClientEvent.inputAudioBufferAppend.rawValue,
            "audio": base64Audio
        ]
        sendEvent(event)
    }

    func sendImageAppend(_ image: UIImage) {
        guard let imageData = image.jpegData(compressionQuality: 0.6) else {
            print("❌ [Omni] 无法压缩图片")
            return
        }
        let base64Image = imageData.base64EncodedString()

        print("📸 [Omni] 发送图片: \(imageData.count) bytes")

        let event: [String: Any] = [
            "event_id": generateEventId(),
            "type": OmniClientEvent.inputImageBufferAppend.rawValue,
            "image": base64Image
        ]
        sendEvent(event)
    }

    func commitAudioBuffer() {
        let event: [String: Any] = [
            "event_id": generateEventId(),
            "type": OmniClientEvent.inputAudioBufferCommit.rawValue
        ]
        sendEvent(event)
    }

    // MARK: - Receive Messages

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage() // Continue receiving

            case .failure(let error):
                let statusCode = (self?.webSocket?.response as? HTTPURLResponse)?.statusCode
                let nsError = error as NSError
                print(
                    "❌ [Omni] 接收消息失败: \(error.localizedDescription), "
                    + "http=\(statusCode.map(String.init) ?? "unknown"), "
                    + "domain=\(nsError.domain), code=\(nsError.code)"
                )
                self?.onResponseState?(.failed)
                if statusCode == 401 || statusCode == 403 {
                    self?.onError?("Unauthorized: API Key does not match the selected region or workspace")
                } else {
                    self?.onError?("Receive error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleServerEvent(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                handleServerEvent(text)
            }
        @unknown default:
            break
        }
    }

    private func handleServerEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            switch type {
            case OmniServerEvent.sessionCreated.rawValue:
                // Wait for session.updated before allowing the caller to
                // start recording. Qwen3.5 audio/search settings must be
                // accepted before the first audio buffer is appended.
                print("✅ [Omni] 会话已创建，等待配置生效")

            case OmniServerEvent.sessionUpdated.rawValue:
                print("✅ [Omni] 会话配置已生效")
                self.onResponseState?(.idle)
                self.onConnected?()

            case OmniServerEvent.inputAudioBufferSpeechStarted.rawValue:
                print("🎤 [Omni] 检测到语音开始")
                self.onSpeechStarted?()

            case OmniServerEvent.inputAudioBufferSpeechStopped.rawValue:
                print("🛑 [Omni] 检测到语音停止")
                self.onResponseState?(.waiting)
                self.onSpeechStopped?()

            case OmniServerEvent.responseAudioTranscriptDelta.rawValue:
                if let delta = json["delta"] as? String {
                    print("💬 [Omni] AI回复片段: \(delta)")
                    self.onTranscriptDelta?(delta)
                }

            case OmniServerEvent.responseAudioTranscriptDone.rawValue:
                // Qwen3.5 uses `transcript`; `text` is retained for older
                // realtime snapshots and compatible gateways.
                let text = (json["transcript"] as? String)
                    ?? (json["text"] as? String)
                    ?? ""
                if text.isEmpty {
                    print("⚠️ [Omni] AI回复完成但done事件无text字段（使用累积的delta）")
                } else {
                    print("✅ [Omni] AI完整回复: \(text)")
                }
                // 总是调用回调，即使text为空，让ViewModel使用累积的片段
                self.onTranscriptDone?(text)

            case OmniServerEvent.responseAudioDelta.rawValue:
                if let base64Audio = json["delta"] as? String,
                   let audioData = Data(base64Encoded: base64Audio) {
                    self.onResponseState?(.playing)
                    self.onAudioDelta?(audioData)

                    // Buffer audio chunks
                    if !self.isCollectingAudio {
                        self.isCollectingAudio = true
                        self.audioBuffer = Data()
                        self.audioChunkCount = 0
                        self.hasStartedPlaying = false

                        // 清除 playerNode 队列中可能残留的旧 buffer
                        if self.isPlaybackEngineRunning {
                            // 重要：reset 会断开 playerNode，需要完全重新初始化
                            self.stopPlaybackEngine()
                            self.setupPlaybackEngine()
                            self.startPlaybackEngine()
                            self.playerNode?.play()
                            print("🔄 [Omni] 重新初始化播放引擎")
                        }
                    }

                    self.audioChunkCount += 1

                    // 流式播放策略：收集少量片段后开始流式调度
                    if !self.hasStartedPlaying {
                        // 首次播放前：先收集
                        self.audioBuffer.append(audioData)

                        if self.audioChunkCount >= self.minChunksBeforePlay {
                            // 已收集足够片段，开始播放
                            self.hasStartedPlaying = true
                            self.playAudio(self.audioBuffer)
                            self.audioBuffer = Data()
                        }
                    } else {
                        // 已开始播放：直接调度每个片段，AVAudioPlayerNode 会自动排队
                        self.playAudio(audioData)
                    }
                }

            case OmniServerEvent.responseAudioDone.rawValue:
                self.isCollectingAudio = false

                // Play remaining buffered audio (if any)
                if !self.audioBuffer.isEmpty {
                    self.playAudio(self.audioBuffer)
                    self.audioBuffer = Data()
                }

                self.audioChunkCount = 0
                self.hasStartedPlaying = false
                self.onResponseState?(.idle)
                self.onAudioDone?()

            case OmniServerEvent.conversationItemInputAudioTranscriptionCompleted.rawValue:
                // 用户语音识别完成
                if let transcript = json["transcript"] as? String {
                    print("👤 [Omni] 用户说: \(transcript)")
                    self.onUserTranscript?(transcript)
                }

            case OmniServerEvent.conversationItemCreated.rawValue:
                // 可能包含其他类型的会话项
                break

            case OmniServerEvent.error.rawValue:
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    print("❌ [Omni] 服务器错误: \(message)")
                    self.onResponseState?(.failed)
                    self.onError?(message)
                }

            default:
                break
            }
        }
    }

    // MARK: - Audio Playback (AVAudioEngine + AVAudioPlayerNode)

    private func playAudio(_ audioData: Data) {
        // Start playback engine if not running
        if !isPlaybackEngineRunning {
            startPlaybackEngine()
        }

        guard isPlaybackEngineRunning,
              let playerNode,
              let playbackFormat else { return }

        // 确保 playerNode 在运行
        if !playerNode.isPlaying {
            playerNode.play()
        }

        // Convert PCM16 Data to Float32 AVAudioPCMBuffer
        guard let pcmBuffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            return
        }

        // Schedule buffer for playback
        playerNode.scheduleBuffer(pcmBuffer)
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // 服务器发送的是 PCM16 格式，每帧 2 字节
        let frameCount = data.count / 2
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData else {
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

    // MARK: - Helpers

    private func generateEventId() -> String {
        eventIdCounter += 1
        return "event_\(eventIdCounter)_\(UUID().uuidString.prefix(8))"
    }
}

// MARK: - URLSessionWebSocketDelegate

extension OmniRealtimeService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ [Omni] WebSocket 连接已建立, protocol: \(`protocol` ?? "none")")
        DispatchQueue.main.async {
            self.configureSession()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        print("🔌 [Omni] WebSocket 已断开, closeCode: \(closeCode.rawValue), reason: \(reasonString)")
    }
}
