/*
 * Gemini Live WebSocket Service
 * Provides real-time audio chat with Google Gemini AI
 * Uses Gemini 3.1 Flash Live with Google Search for real-time audio conversation
 */

import Foundation
import UIKit
import AVFoundation

// MARK: - Gemini Live Service

class GeminiLiveService: NSObject {

    static func realtimeAudioInput(_ base64Audio: String) -> [String: Any] {
        [
            "realtimeInput": [
                "audio": [
                    "data": base64Audio,
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ]
    }

    static func realtimeVideoInput(_ base64Image: String) -> [String: Any] {
        [
            "realtimeInput": [
                "video": [
                    "data": base64Image,
                    "mimeType": "image/jpeg"
                ]
            ]
        ]
    }

    /// Pure setup builder for protocol tests. The native audio response and
    /// output transcription are intentionally configured together so search
    /// answers can be spoken and also persisted as text.
    static func setupFields(model: String, instructions: String) -> [String: Any] {
        [
            "model": "models/\(model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": "Aoede"
                        ]
                    ]
                ]
            ],
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
            "systemInstruction": [
                "parts": [
                    ["text": instructions]
                ]
            ],
            "tools": [
                ["googleSearch": [String: Any]()]
            ]
        ]
    }

    // WebSocket
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Configuration
    private let apiKey: String
    private let model: String

    // Audio Engine (for recording)
    private var audioEngine: AVAudioEngine?

    // Audio Playback Engine (separate engine for playback)
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)
    private let recordTargetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
    private var recordConverter: AVAudioConverter?

    // Audio buffer management
    private var audioBuffer = Data()
    private var isCollectingAudio = false
    private var audioChunkCount = 0
    private let minChunksBeforePlay = 2
    private var hasStartedPlaying = false
    private var isPlaybackEngineRunning = false

    // Callbacks
    var onTranscriptDelta: ((String) -> Void)?
    var onTranscriptDone: ((String) -> Void)?
    var onUserTranscript: ((String) -> Void)?
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
    /// Local voice activity detection. Gemini Live sends no speech-start
    /// event, and LiveAIManager only forwards a glasses frame from the
    /// `onSpeechStarted` callback, so without this the Google provider never
    /// sends any video.
    private var speechDetector = SpeechActivityDetector()
    private var isSessionConfigured = false
    private var ownsAudioSession = false
    private var routeChangeObserver: NSObjectProtocol?

    init(apiKey: String, model: String? = nil) {
        self.apiKey = apiKey
        self.model = model ?? APIProviderManager.staticLiveAIModel
        super.init()
        setupAudioEngine()
        observeAudioRouteChanges()
    }

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
    }

    private func setupPlaybackEngine() {
        playbackEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let playbackEngine = playbackEngine,
              let playerNode = playerNode else {
            print("❌ [Gemini] 无法初始化播放引擎")
            return
        }

        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackAudioFormat)
        playbackEngine.prepare()
        print("✅ [Gemini] 播放引擎初始化完成")
    }

    @discardableResult
    private func configureAudioSession() -> Bool {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            let configuration = AudioSessionPolicy.glassesDuplex
            try audioSession.setCategory(
                configuration.category,
                mode: configuration.mode,
                options: configuration.options
            )
            try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
            ownsAudioSession = true
            logAudioRoute(audioSession, reason: "duplex_activated")
            return true
        } catch {
            print("⚠️ [Gemini] Audio session 配置失败: \(error.localizedDescription)")
            return false
        }
    }

    private func startPlaybackEngine() {
        guard !isPlaybackEngineRunning else { return }

        // Do not prepare an output engine merely by entering Live AI; delay
        // it until the first audio response is actually ready to play.
        if playbackEngine == nil || playerNode == nil {
            setupPlaybackEngine()
        }
        guard let playbackEngine = playbackEngine else { return }

        do {
            guard configureAudioSession() else { return }
            try playbackEngine.start()
            isPlaybackEngineRunning = true
            print("▶️ [Gemini] 播放引擎已启动")
        } catch {
            print("❌ [Gemini] 播放引擎启动失败: \(error)")
        }
    }

    private func stopPlaybackEngine() {
        guard let playbackEngine = playbackEngine, isPlaybackEngineRunning else { return }

        playerNode?.stop()
        playerNode?.reset()
        playbackEngine.stop()
        isPlaybackEngineRunning = false
        print("⏹️ [Gemini] 播放引擎已停止并清除队列")
    }

    // MARK: - WebSocket Connection

    func connect() {
        // Gemini Live WebSocket URL with API key
        let baseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        let urlString = "\(baseURL)?key=\(apiKey)"

        print("🔌 [Gemini] 准备连接 WebSocket")

        guard let url = URL(string: urlString) else {
            print("❌ [Gemini] 无效的 URL")
            onError?("Invalid URL")
            return
        }

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())

        webSocket = urlSession?.webSocketTask(with: url)
        webSocket?.resume()

        print("🔌 [Gemini] WebSocket 任务已启动")
        receiveMessage()
    }

    func disconnect() {
        print("🔌 [Gemini] 断开 WebSocket 连接")
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        stopRecording()
        stopPlaybackEngine()
        releaseAudioSession()
        isSessionConfigured = false
    }

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            print("⚠️ [Gemini] 释放音频会话失败: \(error.localizedDescription)")
        }
        ownsAudioSession = false
    }

    private func observeAudioRouteChanges() {
        let session = AVAudioSession.sharedInstance()
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            DispatchQueue.main.async { [weak self] in
                self?.handleAudioRouteChange(notification)
            }
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard ownsAudioSession else { return }
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)
            .map { AVAudioSession.RouteChangeReason(rawValue: $0.uintValue) }
            .map { String(describing: $0) } ?? "unknown"
        let session = AVAudioSession.sharedInstance()
        logAudioRoute(session, reason: "route_changed_\(reason)")
        guard isRecording || isPlaybackEngineRunning else { return }
        do {
            // Do not force a speaker or Bluetooth route after a disconnect;
            // the system route policy remains authoritative.
            try session.setActive(true)
            logAudioRoute(session, reason: "route_reactivated")
        } catch {
            print("⚠️ [Gemini] 路由变化后恢复音频会话失败: \(error.localizedDescription)")
        }
    }

    private func logAudioRoute(_ session: AVAudioSession, reason: String) {
        let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("🔊 [Gemini] 音频路由 reason=\(reason) category=\(session.category.rawValue) mode=\(session.mode.rawValue) input=\(inputs.isEmpty ? "none" : inputs) output=\(outputs.isEmpty ? "none" : outputs)")
    }

    // MARK: - Session Configuration

    private func configureSession() {
        guard !isSessionConfigured else { return }

        // 根据当前 Live AI 模式获取系统提示词
        // Every realtime session starts voice-only. The appended constraint
        // remains valid if individual images arrive after an in-session mode
        // switch, so Gemini does not need a second setup message.
        let instructions = LiveAIModeManager.staticSystemPrompt(inputMode: .voice)

        // Gemini Live API setup message. The WebSocket API uses camelCase
        // field names; output transcription keeps the UI/history in sync
        // while the model still returns native audio.
        let setupMessage: [String: Any] = [
            "setup": Self.setupFields(
                model: model,
                instructions: instructions + LiveAIWebSearchPolicy.instructions
            )
        ]

        sendJSON(setupMessage)
        print("⚙️ [Gemini] 发送会话配置")
    }

    // MARK: - Audio Recording

    func startRecording() {
        guard !isRecording else { return }

        do {
            print("🎤 [Gemini] 开始录音")

            let audioApplication = AVAudioApplication.shared
            switch audioApplication.recordPermission {
            case .undetermined:
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted {
                            self?.startRecording()
                        } else {
                            self?.onError?("Microphone permission denied")
                        }
                    }
                }
                return
            case .denied:
                onError?("Microphone permission denied")
                return
            case .granted:
                break
            @unknown default:
                break
            }

            if let engine = audioEngine, engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }

            guard configureAudioSession() else {
                return
            }

            guard let engine = audioEngine else {
                print("❌ [Gemini] 音频引擎未初始化")
                return
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            if let recordTargetFormat {
                recordConverter = AVAudioConverter(from: inputFormat, to: recordTargetFormat)
            } else {
                recordConverter = nil
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer, inputFormat: inputFormat)
            }

            engine.prepare()
            try engine.start()

            isRecording = true
            print("✅ [Gemini] 录音已启动")

        } catch {
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            releaseAudioSession()
            print("❌ [Gemini] 启动录音失败: \(error.localizedDescription)")
            onError?("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        print("🛑 [Gemini] 停止录音")
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        isRecording = false
        hasAudioBeenSent = false
        if speechDetector.isSpeaking {
            DispatchQueue.main.async { [weak self] in
                self?.onSpeechStopped?()
            }
        }
        speechDetector.reset()
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let recordConverter, let recordTargetFormat else { return }

        let ratio = recordTargetFormat.sampleRate / inputFormat.sampleRate
        let targetFrameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))

        guard let converted = AVAudioPCMBuffer(pcmFormat: recordTargetFormat, frameCapacity: max(1, targetFrameCapacity)) else {
            return
        }

        var hasProvidedInput = false
        var error: NSError?

        let status = recordConverter.convert(to: converted, error: &error) { _, outStatus in
            if hasProvidedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, status != .error else { return }
        guard let floatChannelData = converted.floatChannelData else { return }

        let frameLength = Int(converted.frameLength)
        let channel = floatChannelData.pointee

        var int16Data = [Int16](repeating: 0, count: frameLength)
        var sumOfSquares: Float = 0
        for i in 0..<frameLength {
            let sample = channel[i]
            let clampedSample = max(-1.0, min(1.0, sample))
            int16Data[i] = Int16(clampedSample * 32767.0)
            sumOfSquares += clampedSample * clampedSample
        }

        let data = Data(bytes: int16Data, count: frameLength * MemoryLayout<Int16>.size)
        let base64Audio = data.base64EncodedString()

        sendRealtimeInput(audioData: base64Audio)

        if frameLength > 0 {
            let rms = (sumOfSquares / Float(frameLength)).squareRoot()
            let duration = Double(frameLength) / recordTargetFormat.sampleRate
            if let event = speechDetector.process(rms: rms, duration: duration) {
                DispatchQueue.main.async { [weak self] in
                    switch event {
                    case .started:
                        print("🎤 [Gemini] 检测到语音开始")
                        self?.onSpeechStarted?()
                    case .stopped:
                        print("🛑 [Gemini] 检测到语音停止")
                        self?.onSpeechStopped?()
                    }
                }
            }
        }

        if !hasAudioBeenSent {
            hasAudioBeenSent = true
            print("✅ [Gemini] 第一次音频已发送")
            DispatchQueue.main.async { [weak self] in
                self?.onFirstAudioSent?()
            }
        }
    }

    // MARK: - Send Events

    private func sendJSON(_ json: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ [Gemini] 无法序列化 JSON")
            return
        }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocket?.send(message) { [weak self] error in
            if let error = error {
                print("❌ [Gemini] 发送失败: \(error.localizedDescription)")
                self?.onError?("Send error: \(error.localizedDescription)")
            }
        }
    }

    private func sendRealtimeInput(audioData: String) {
        // `mediaChunks` is deprecated by the current Live WebSocket API.
        sendJSON(Self.realtimeAudioInput(audioData))
    }

    func sendImageInput(_ image: UIImage) {
        guard let imageData = image.jpegData(compressionQuality: 0.6) else {
            print("❌ [Gemini] 无法压缩图片")
            return
        }
        let base64Image = imageData.base64EncodedString()

        print("📸 [Gemini] 发送图片: \(imageData.count) bytes")

        sendJSON(Self.realtimeVideoInput(base64Image))
    }

    // MARK: - Receive Messages

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage()

            case .failure(let error):
                print("❌ [Gemini] 接收消息失败: \(error.localizedDescription)")
                self?.onError?("Receive error: \(error.localizedDescription)")
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Handle setup complete
            if json["setupComplete"] != nil {
                print("✅ [Gemini] 会话配置完成")
                self.isSessionConfigured = true
                self.onResponseState?(.idle)
                self.onConnected?()
                return
            }

            // Handle server content (audio/text responses)
            if let serverContent = json["serverContent"] as? [String: Any] {
                self.handleServerContent(serverContent)
                return
            }

            // Handle tool calls (if any)
            if let toolCall = json["toolCall"] as? [String: Any] {
                print("🔧 [Gemini] Tool call: \(toolCall)")
                return
            }

            // Handle errors
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown error"
                print("❌ [Gemini] 服务器错误: \(message)")
                self.onResponseState?(.failed)
                self.onError?(message)
                return
            }
        }
    }

    private func handleServerContent(_ content: [String: Any]) {
        // Check for model turn
        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {

            for part in parts {
                // Handle text response
                if let text = part["text"] as? String {
                    print("💬 [Gemini] AI回复: \(text)")
                    onTranscriptDelta?(text)
                }

                // Handle inline audio data
                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   mimeType.contains("audio"),
                   let base64Audio = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: base64Audio) {

                    onResponseState?(.playing)
                    onAudioDelta?(audioData)
                    handleAudioChunk(audioData)
                }
            }
        }

        // Check if turn is complete
        if let turnComplete = content["turnComplete"] as? Bool, turnComplete {
            print("✅ [Gemini] AI回复完成")
            finishAudioPlayback()
            onResponseState?(.idle)
            onTranscriptDone?("")
        }

        // Check for interrupted flag
        if let interrupted = content["interrupted"] as? Bool, interrupted {
            print("⚠️ [Gemini] 回复被中断")
            stopPlaybackEngine()
            setupPlaybackEngine()
        }

        // Handle input transcription (user speech)
        if let inputTranscription = content["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String {
            print("👤 [Gemini] 用户说: \(text)")
            onResponseState?(.waiting)
            onUserTranscript?(text)
        }

        // Handle output transcription (AI speech text)
        if let outputTranscription = content["outputTranscription"] as? [String: Any],
           let text = outputTranscription["text"] as? String {
            print("💬 [Gemini] AI文字: \(text)")
            onTranscriptDelta?(text)
        }
    }

    // MARK: - Audio Playback

    private func handleAudioChunk(_ audioData: Data) {
        if !isCollectingAudio {
            isCollectingAudio = true
            audioBuffer = Data()
            audioChunkCount = 0
            hasStartedPlaying = false

            if isPlaybackEngineRunning {
                stopPlaybackEngine()
                setupPlaybackEngine()
                startPlaybackEngine()
                playerNode?.play()
                print("🔄 [Gemini] 重新初始化播放引擎")
            }
        }

        audioChunkCount += 1

        if !hasStartedPlaying {
            audioBuffer.append(audioData)

            if audioChunkCount >= minChunksBeforePlay {
                hasStartedPlaying = true
                playAudio(audioBuffer)
                audioBuffer = Data()
            }
        } else {
            playAudio(audioData)
        }
    }

    private func finishAudioPlayback() {
        isCollectingAudio = false

        if !audioBuffer.isEmpty {
            playAudio(audioBuffer)
            audioBuffer = Data()
        }

        audioChunkCount = 0
        hasStartedPlaying = false
        onAudioDone?()
    }

    private func playAudio(_ audioData: Data) {
        if !isPlaybackEngineRunning {
            startPlaybackEngine()
        }

        guard isPlaybackEngineRunning,
              let playerNode,
              let playbackAudioFormat else { return }

        if !playerNode.isPlaying {
            playerNode.play()
        }

        guard let pcmBuffer = createPCMBuffer(from: audioData, format: playbackAudioFormat) else {
            return
        }

        playerNode.scheduleBuffer(pcmBuffer)
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = data.count / 2

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            let dst = channelData.pointee
            for i in 0..<frameCount {
                dst[i] = Float(int16Pointer[i]) / 32768.0
            }
        }

        return buffer
    }
}

// MARK: - URLSessionWebSocketDelegate

extension GeminiLiveService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ [Gemini] WebSocket 连接已建立")
        DispatchQueue.main.async {
            self.configureSession()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        print("🔌 [Gemini] WebSocket 已断开, closeCode: \(closeCode.rawValue), reason: \(reasonString)")
    }
}
