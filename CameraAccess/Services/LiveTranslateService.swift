/*
 * Live Translate WebSocket Service
 * 基于 qwen3.5-livetranslate-flash-realtime 的实时翻译服务
 */

import Foundation
import UIKit
import AVFoundation

enum LiveTranslateSessionState: Hashable {
    case disconnected
    case connecting
    case configuring
    case ready
    case recording
    case finishing
    case finished
    case failed
}

/// Thread-safe protocol lifecycle. A LiveTranslate WebSocket owns exactly one
/// server session; configuration is legal only between open and ready.
final class LiveTranslateSessionLifecycle {
    private let lock = NSLock()
    private var storedState: LiveTranslateSessionState = .disconnected

    var state: LiveTranslateSessionState {
        lock.withLock { storedState }
    }

    @discardableResult
    func transition(from allowed: Set<LiveTranslateSessionState>, to newState: LiveTranslateSessionState) -> Bool {
        lock.withLock {
            guard allowed.contains(storedState) else { return false }
            storedState = newState
            return true
        }
    }

    func reset() {
        lock.withLock { storedState = .disconnected }
    }
}

/// The audio-session choices used by the realtime audio services.
///
/// Keep these values as data so they can be tested without requiring an
/// attached Bluetooth device. Duplex sessions default to the loudspeaker
/// whenever no Bluetooth route is available; this prevents iOS from silently
/// falling back to the receiver.
struct AudioSessionConfiguration {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
}

enum AudioSessionPolicy {
    /// The microphone preference only controls input selection. Output routing
    /// is identical for both modes: iOS may use an available Bluetooth output
    /// (A2DP/HFP), otherwise `.defaultToSpeaker` provides the phone fallback.
    static func liveTranslate(usePhoneMic: Bool) -> AudioSessionConfiguration {
        if usePhoneMic {
            return AudioSessionConfiguration(
                category: .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
        }

        // A glasses microphone requires the bidirectional HFP profile. Keep
        // A2DP available for accessories exposing a separate high-quality
        // output route; iOS still chooses HFP for the active input profile.
        return AudioSessionConfiguration(
            category: .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
    }

    /// Qwen Omni and Gemini Live both use the glasses microphone for duplex
    /// conversations.
    static let glassesDuplex = AudioSessionConfiguration(
        category: .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
    )

    /// Standalone TTS/Quick Vision only needs an output session.  `.playback`
    /// routes to Bluetooth A2DP without an A2DP category option.
    static let standalonePlayback = AudioSessionConfiguration(
        category: .playback,
        mode: .spokenAudio,
        options: [.duckOthers]
    )
}

// MARK: - Service Class

class LiveTranslateService: NSObject {

    /// Builds the output-related session fields shared by configuration and
    /// tests. Qwen3.5 accepts a voice only when audio is one of the requested
    /// modalities; text-only sessions must omit the key altogether.
    static func sessionOutputFields(
        audioEnabled: Bool,
        voice: TranslateVoice
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "modalities": audioEnabled ? ["text", "audio"] : ["text"]
        ]
        if audioEnabled {
            fields["voice"] = voice.rawValue
        }
        return fields
    }

    // WebSocket
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Configuration
    private let apiKey: String
    /// Alibaba's current recommended LiveTranslate model. The old qwen3
    /// endpoint could emit cumulative responses without a reliable item graph.
    private let model = "qwen3.5-livetranslate-flash-realtime"
    // Live Translate is always backed by Alibaba. Do not reuse the general
    // Live AI provider URL because that may point to Gemini or require the
    // Qwen web-search workspace host.
    private var baseURL: String {
        APIProviderManager.staticLiveTranslateWebsocketURL
    }

    // Audio Engine (for recording)
    private var audioEngine: AVAudioEngine?

    // Audio Playback Engine (separate engine for playback)
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)

    // The head response streams to the player as PCM deltas arrive. Response
    // order remains strict: the next response starts only after audio.done and
    // dataPlayedBack have both completed for the current response.
    private var audioQueue = TranslationAudioQueue()
    private var isPlaybackEngineRunning = false

    // Translation settings
    private var sourceLanguage: TranslateLanguage = .en
    private var targetLanguage: TranslateLanguage = .zh
    private var voice: TranslateVoice = .tina
    private var audioOutputEnabled = true

    // Audio resampling
    private var audioConverter: AVAudioConverter?
    private let targetSampleRate: Double = 16000  // API expects 16kHz

    // Callbacks
    var onConnected: (() -> Void)?
    var onSourceTranscript: ((TranslateSourceTranscriptEvent) -> Void)?
    var onTranslation: ((TranslateTextEvent) -> Void)?
    /// Emits the authoritative response-id → assistant item-id association.
    /// The coordinator keeps it even when the transcript arrives first.
    var onResponseItem: ((_ responseID: String, _ responseItemID: String) -> Void)?
    var onTurnLink: ((_ sourceItemID: String, _ responseItemID: String) -> Void)?
    var onPlaybackStateChanged: ((TranslationPlaybackState, Int) -> Void)?
    var onPlaybackCompleted: ((String) -> Void)?
    var onSpeechStarted: ((_ itemID: String?) -> Void)?
    var onSpeechStopped: ((_ itemID: String?) -> Void)?
    var onResponseStarted: ((_ responseID: String) -> Void)?
    var onResponseFinished: ((_ responseID: String) -> Void)?
    var onSessionFinished: (() -> Void)?
    /// `expected` is true for an explicit close or the mandatory close after
    /// `session.finished`; false means the caller should recover/reconnect.
    var onDisconnected: ((_ expected: Bool, _ reason: String?) -> Void)?
    var onError: ((String) -> Void)?

    // State
    private var isRecording = false
    private let lifecycle = LiveTranslateSessionLifecycle()
    private let transportLock = NSLock()
    private var hasPublishedDisconnect = false
    private var eventIdCounter = 0
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var finishTimeoutWorkItem: DispatchWorkItem?
    private var hasReceivedSessionFinished = false
    private var ownsAudioSession = false
    private var usePhoneMic = false
    private var preferredInputUID: String?
    private var routeChangeObserver: NSObjectProtocol?
    private var diagnosticEventLog: [String] = []
    private let diagnosticEventLogCapacity = 200

    // Image sending. The view model invokes `sendImageFrame` once per server
    // VAD speech-start event; this guard makes the one-frame-per-turn contract
    // robust even if a callback is delivered more than once.
    private var hasSentImageForSpeechTurn = false

    init(apiKey: String) {
        self.apiKey = apiKey
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
              let playerNode = playerNode,
              let playbackFormat = playbackFormat else {
            print("❌ [Translate] 无法初始化播放引擎")
            return
        }

        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
        playbackEngine.prepare()

        print("✅ [Translate] 播放引擎初始化完成: Float32 @ 24kHz")
    }

    @discardableResult
    private func startPlaybackEngine() -> Bool {
        guard audioOutputEnabled else {
            // A text-only translation must never activate or start an output
            // engine.  This is also important when the setting is toggled
            // while a websocket session is still connected.
            return false
        }

        // Creating/preparing an output engine can make iOS renegotiate the
        // current route. Keep connection and screen entry route-neutral by
        // delaying this work until translated audio is actually ready.
        if playbackEngine == nil || playerNode == nil {
            setupPlaybackEngine()
        }
        guard let playbackEngine = playbackEngine else { return false }
        if isPlaybackEngineRunning { return true }

        do {
            try playbackEngine.start()
            isPlaybackEngineRunning = true
            print("▶️ [Translate] 播放引擎已启动")
            return true
        } catch {
            print("❌ [Translate] 播放引擎启动失败: \(error)")
            return false
        }
    }

    private func stopPlaybackEngine() {
        guard let playbackEngine = playbackEngine, isPlaybackEngineRunning else { return }

        playerNode?.stop()
        playerNode?.reset()
        playbackEngine.stop()
        isPlaybackEngineRunning = false
        print("⏹️ [Translate] 播放引擎已停止")
    }

    // MARK: - WebSocket Connection

    func connect() {
        guard lifecycle.transition(from: [.disconnected, .finished, .failed], to: .connecting) else {
            print("⚠️ [Translate] 忽略重复连接，当前状态: \(lifecycle.state)")
            return
        }
        transportLock.withLock { hasPublishedDisconnect = false }
        let urlString = "\(baseURL)?model=\(model)"
        print("🔌 [Translate] 准备连接 WebSocket: \(urlString)")

        guard let url = URL(string: urlString) else {
            print("❌ [Translate] 无效的 URL")
            _ = lifecycle.transition(from: [.connecting], to: .failed)
            onError?("Invalid URL")
            publishDisconnected(expected: false, reason: "Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())

        let task = urlSession?.webSocketTask(with: request)
        transportLock.withLock { webSocket = task }
        task?.resume()

        print("🔌 [Translate] WebSocket 任务已启动")
        receiveMessage()
    }

    func disconnect() {
        print("🔌 [Translate] 断开 WebSocket 连接")
        closeTransport(expected: true, reason: nil)
        lifecycle.reset()
        stopRecording()
        cancelPlaybackQueue()
        stopPlaybackEngine()
        releaseAudioSession()
        finishTimeoutWorkItem?.cancel()
        finishTimeoutWorkItem = nil
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func closeTransport(expected: Bool, reason: String?) {
        let transport = transportLock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            let value = (webSocket, urlSession)
            webSocket = nil
            urlSession = nil
            return value
        }
        transport.0?.cancel(with: .goingAway, reason: nil)
        transport.1?.invalidateAndCancel()
        publishDisconnected(expected: expected, reason: reason)
    }

    private func publishDisconnected(expected: Bool, reason: String?) {
        let shouldPublish = transportLock.withLock { () -> Bool in
            guard !hasPublishedDisconnect else { return false }
            hasPublishedDisconnect = true
            return true
        }
        guard shouldPublish else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onDisconnected?(expected, reason)
        }
    }

    private func failTransport(_ reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.failTransport(reason)
            }
            return
        }
        guard lifecycle.transition(
            from: [.connecting, .configuring, .ready, .recording, .finishing],
            to: .failed
        ) else { return }
        stopRecording()
        releaseAudioSession()
        finishTimeoutWorkItem?.cancel()
        finishTimeoutWorkItem = nil
        finishContinuation?.resume()
        finishContinuation = nil
        closeTransport(expected: false, reason: reason)
    }

    // MARK: - Configuration

    func updateSettings(
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage,
        voice: TranslateVoice,
        audioEnabled: Bool
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.voice = voice
        let normalizedAudioEnabled = audioEnabled && targetLanguage.supportsAudioOutput
        if self.audioOutputEnabled && !normalizedAudioEnabled {
            clearPlaybackQueue()
            stopPlaybackEngine()
            if !isRecording {
                releaseAudioSession()
            }
        }
        self.audioOutputEnabled = normalizedAudioEnabled

        // Deliberately do not send session.update here. Alibaba allows the
        // configuration only during session initialization. The view model
        // replaces the socket when settings change.
    }

    private func configureSession() {
        guard lifecycle.state == .configuring else {
            print("⚠️ [Translate] 当前状态不允许 session.update: \(lifecycle.state)")
            return
        }
        var session = Self.sessionOutputFields(
            audioEnabled: audioOutputEnabled,
            voice: voice
        )
        // LiveTranslate accepts raw PCM. The audio tap below sends 16-bit
        // little-endian samples at the declared sample rate; `pcm16`/`pcm24`
        // are not valid LiveTranslate format values.
        session["sample_rate"] = 16000
        session["input_audio_format"] = "pcm"
        session["output_audio_format"] = "pcm"
        session["input_audio_transcription"] = [
            "model": "qwen3-asr-flash-realtime",
            "language": sourceLanguage.rawValue
        ]
        session["translation"] = [
            "language": targetLanguage.rawValue
        ]
        session["turn_detection"] = [
            "type": "server_vad",
            "threshold": 0.5,
            "prefix_padding_ms": 300,
            "silence_duration_ms": 500,
            "create_response": true,
            // A new speech turn must not cancel generation for the
            // previous one; local playback is serialized separately.
            "interrupt_response": false
        ]

        let sessionConfig: [String: Any] = [
            "event_id": generateEventId(),
            "type": TranslateClientEvent.sessionUpdate.rawValue,
            "session": session
        ]

        sendEvent(sessionConfig)
        print("📤 [Translate] 配置会话: \(sourceLanguage.rawValue) → \(targetLanguage.rawValue), 音色: \(voice.rawValue)")
    }

    /// Gracefully seals the realtime session so the server can finish the last
    /// VAD turn. Completion waits for both session.finished and local audio
    /// playback, with a bounded timeout for network failures.
    func finishSession(timeout: TimeInterval = 8) async {
        stopRecording()
        guard lifecycle.transition(from: [.recording, .ready], to: .finishing) else { return }
        guard transportLock.withLock({ webSocket != nil }) else {
            failTransport("Socket 未连接")
            return
        }

        hasReceivedSessionFinished = false
        sendEvent([
            "event_id": generateEventId(),
            "type": TranslateClientEvent.sessionFinish.rawValue
        ])

        await withCheckedContinuation { continuation in
            finishContinuation = continuation
            finishTimeoutWorkItem?.cancel()
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.lifecycle.transition(from: [.finishing], to: .failed) {
                    // The server never acknowledged finish. The transport and
                    // queue are no longer trustworthy, so recover within a
                    // bounded time instead of leaving the mic disabled.
                    self.closeTransport(expected: false, reason: "Session finish timeout")
                    self.hasReceivedSessionFinished = true
                    self.clearPlaybackQueue()
                    self.completeFinishIfReady(force: true)
                } else if self.lifecycle.state == .finished {
                    // Normally keep strict, complete playback. A lost player
                    // completion callback must still not wedge the app forever.
                    self.schedulePlaybackDrainTimeout(after: 22)
                }
            }
            finishTimeoutWorkItem = timeoutWorkItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWorkItem
            )
            completeFinishIfReady()
        }
    }

    private func schedulePlaybackDrainTimeout(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.finishContinuation != nil else { return }
            print("⚠️ [Translate] 播放队列收尾超时，释放 Session")
            self.clearPlaybackQueue()
            self.completeFinishIfReady(force: true)
        }
        finishTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - Audio Recording

    @discardableResult
    func startRecording(usePhoneMic: Bool = false) -> Bool {
        guard !isRecording, lifecycle.state == .ready else {
            print("⚠️ [Translate] 当前 Session 尚未就绪，无法录音: \(lifecycle.state)")
            return false
        }

        do {
            print("🎤 [Translate] 开始录音, 使用\(usePhoneMic ? "iPhone" : "蓝牙")麦克风")
            self.usePhoneMic = usePhoneMic

            if let engine = audioEngine, engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }

            guard let engine = audioEngine else {
                print("❌ [Translate] 音频引擎未初始化")
                return false
            }

            let audioSession = AVAudioSession.sharedInstance()
            let configuration = AudioSessionPolicy.liveTranslate(usePhoneMic: usePhoneMic)
            try audioSession.setCategory(
                configuration.category,
                mode: configuration.mode,
                options: configuration.options
            )
            try audioSession.setActive(true)
            ownsAudioSession = true

            let preferredInputType: AVAudioSession.Port = usePhoneMic ? .builtInMic : .bluetoothHFP
            guard let preferredInput = audioSession.availableInputs?.first(where: {
                $0.portType == preferredInputType
            }) else {
                throw LiveTranslateAudioSessionError.inputUnavailable(usePhoneMic: usePhoneMic)
            }
            preferredInputUID = preferredInput.uid
            try audioSession.setPreferredInput(preferredInput)
            try allowSystemPreferredOutput(on: audioSession)
            print("🎙️ [Translate] 使用\(usePhoneMic ? "iPhone" : "蓝牙")麦克风")

            logAudioRoute(audioSession, reason: "recording_started")

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            print("🎵 [Translate] 输入格式: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channels")
            print("🎵 [Translate] 目标格式: \(targetSampleRate) Hz (将自动重采样)")

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
                self?.processAudioBuffer(buffer)
            }

            engine.prepare()
            try engine.start()
            // Starting the input engine may renegotiate the route. Clear any
            // stale speaker override without coupling output to input choice.
            try allowSystemPreferredOutput(on: audioSession)

            guard lifecycle.transition(from: [.ready], to: .recording) else {
                engine.stop()
                inputNode.removeTap(onBus: 0)
                releaseAudioSession()
                return false
            }
            isRecording = true
            print("✅ [Translate] 录音已启动")
            return true

        } catch {
            releaseAudioSession()
            print("❌ [Translate] 启动录音失败: \(error.localizedDescription)")
            onError?("Failed to start recording: \(error.localizedDescription)")
            return false
        }
    }

    /// Allows the requested input route without forcing translated audio to
    /// the phone speaker. Phone-mic mode can still play over A2DP; glasses-mic
    /// mode uses the bidirectional HFP profile when available.
    static func audioSessionOptions(usePhoneMic: Bool) -> AVAudioSession.CategoryOptions {
        AudioSessionPolicy.liveTranslate(usePhoneMic: usePhoneMic).options
    }

    static func audioSessionConfiguration(usePhoneMic: Bool) -> AudioSessionConfiguration {
        AudioSessionPolicy.liveTranslate(usePhoneMic: usePhoneMic)
    }

    /// Reassert the duplex category immediately before real output starts.
    /// This repairs cases where another feature left the global session in
    /// SoloAmbient/Default, while retaining the input selected for this
    /// translation session.  It intentionally never switches to `.playback`
    /// or stops the recording engine.
    private func ensureDuplexAudioSessionForPlayback() -> Bool {
        guard audioOutputEnabled else { return false }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            let configuration = AudioSessionPolicy.liveTranslate(usePhoneMic: usePhoneMic)
            try audioSession.setCategory(
                configuration.category,
                mode: configuration.mode,
                options: configuration.options
            )
            try audioSession.setActive(true)

            let preferredInput = audioSession.availableInputs?.first {
                $0.uid == preferredInputUID
            } ?? audioSession.availableInputs?.first {
                usePhoneMic ? $0.portType == .builtInMic : $0.portType == .bluetoothHFP
            }
            if let preferredInput {
                preferredInputUID = preferredInput.uid
                try audioSession.setPreferredInput(preferredInput)
            }
            try allowSystemPreferredOutput(on: audioSession)
            ownsAudioSession = true
            logAudioRoute(audioSession, reason: "playback_activated")
            return true
        } catch {
            print("⚠️ [Translate] 激活播放音频会话失败: \(error.localizedDescription)")
            return false
        }
    }

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        do {
            try AVAudioSession.sharedInstance().setPreferredInput(nil)
        } catch {
            print("⚠️ [Translate] 重置音频输入失败: \(error.localizedDescription)")
        }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            print("⚠️ [Translate] 释放音频会话失败: \(error.localizedDescription)")
        }
        ownsAudioSession = false
        preferredInputUID = nil
    }

    private func observeAudioRouteChanges() {
        let session = AVAudioSession.sharedInstance()
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            // AVAudioSession posts route changes off the main thread.  Keep
            // all state and engine interaction on the service's main queue.
            DispatchQueue.main.async { [weak self] in
                self?.handleAudioRouteChange(notification)
            }
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard ownsAudioSession else { return }
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)
            .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0.uintValue) }
        let reasonText = reason.map { String(describing: $0) } ?? "unknown"
        let session = AVAudioSession.sharedInstance()
        logAudioRoute(session, reason: "route_changed_\(reasonText)")

        guard isRecording || isPlaybackEngineRunning else { return }
        do {
            try session.setActive(true)
            try allowSystemPreferredOutput(on: session)
            logAudioRoute(session, reason: "route_reactivated")
        } catch {
            print("⚠️ [Translate] 路由变化后恢复音频会话失败: \(error.localizedDescription)")
        }
    }

    /// Route diagnostics intentionally contain device types only.  Never log
    /// transcript, audio, API key, or other payload data here.
    private func logAudioRoute(_ session: AVAudioSession, reason: String) {
        let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("🔊 [Translate] 音频路由 reason=\(reason) category=\(session.category.rawValue) mode=\(session.mode.rawValue) input=\(inputs.isEmpty ? "none" : inputs) output=\(outputs.isEmpty ? "none" : outputs)")
    }

    /// Remove overrides left by another feature. Bluetooth is allowed by the
    /// category options; when no compatible Bluetooth output is active,
    /// `.defaultToSpeaker` prevents fallback to the receiver.
    private func allowSystemPreferredOutput(on session: AVAudioSession) throws {
        try session.overrideOutputAudioPort(.none)
    }

    func stopRecording() {
        guard isRecording else { return }

        print("🛑 [Translate] 停止录音")
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        isRecording = false
        hasSentImageForSpeechTurn = false
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.floatChannelData != nil else { return }

        let inputSampleRate = buffer.format.sampleRate

        // 如果采样率不是 16kHz，需要重采样
        if inputSampleRate != targetSampleRate {
            guard let resampledBuffer = resampleBuffer(buffer) else {
                return
            }
            sendBufferAsPCM16(resampledBuffer)
        } else {
            sendBufferAsPCM16(buffer)
        }
    }

    private func resampleBuffer(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputFormat = inputBuffer.format
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1) else {
            return nil
        }

        // 创建或更新 converter
        if audioConverter == nil || audioConverter?.inputFormat != inputFormat {
            audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }

        guard let converter = audioConverter else {
            print("❌ [Translate] 无法创建音频转换器")
            return nil
        }

        // 计算输出帧数
        let ratio = targetSampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        var hasProvidedInput = false
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if hasProvidedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("❌ [Translate] 重采样失败: \(error.localizedDescription)")
            return nil
        }

        return outputBuffer
    }

    private func sendBufferAsPCM16(_ buffer: AVAudioPCMBuffer) {
        guard let floatChannelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channel = floatChannelData.pointee

        // Float32 → PCM16
        var int16Data = [Int16](repeating: 0, count: frameLength)
        for i in 0..<frameLength {
            let sample = channel[i]
            let clampedSample = max(-1.0, min(1.0, sample))
            int16Data[i] = Int16(clampedSample * 32767.0)
        }

        let data = Data(bytes: int16Data, count: frameLength * MemoryLayout<Int16>.size)
        let base64Audio = data.base64EncodedString()

        sendAudioAppend(base64Audio)
    }

    // MARK: - Image Sending

    func sendImageFrame(_ image: UIImage) {
        guard !hasSentImageForSpeechTurn else {
            return
        }
        hasSentImageForSpeechTurn = true

        // The caller invokes this once after speech_started. Do not use a
        // repeating timer or a global 500 ms throttle: each VAD turn should
        // get its own latest frame, including short consecutive turns.
        guard webSocket != nil else {
            hasSentImageForSpeechTurn = false
            return
        }

        guard let imageData = image.jpegData(compressionQuality: 0.6) else {
            hasSentImageForSpeechTurn = false
            print("❌ [Translate] 无法压缩图片")
            return
        }

        // 限制图片大小 500KB
        guard imageData.count <= 500 * 1024 else {
            hasSentImageForSpeechTurn = false
            print("⚠️ [Translate] 图片过大，跳过发送")
            return
        }

        let base64Image = imageData.base64EncodedString()
        print("📸 [Translate] 发送图片: \(imageData.count) bytes")

        let event: [String: Any] = [
            "event_id": generateEventId(),
            "type": TranslateClientEvent.inputImageBufferAppend.rawValue,
            "image": base64Image
        ]
        sendEvent(event)
    }

    // MARK: - Send Events

    private func sendEvent(_ event: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ [Translate] 无法序列化事件")
            return
        }

        guard let socket = transportLock.withLock({ webSocket }) else {
            print("⚠️ [Translate] 忽略发送，Socket 未连接")
            return
        }
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        socket.send(message) { [weak self, weak socket] error in
            if let error = error {
                print("❌ [Translate] 发送事件失败: \(error.localizedDescription)")
                guard let self, let socket,
                      self.transportLock.withLock({ self.webSocket === socket }) else { return }
                self.onError?("Send error: \(error.localizedDescription)")
                self.failTransport(error.localizedDescription)
            }
        }
    }

    private var audioSendCount = 0

    private func sendAudioAppend(_ base64Audio: String) {
        guard lifecycle.state == .recording else { return }
        audioSendCount += 1
        if audioSendCount == 1 || audioSendCount % 50 == 0 {
            print("🎵 [Translate] 发送音频块 #\(audioSendCount), 大小: \(base64Audio.count) bytes")
        }

        let event: [String: Any] = [
            "event_id": generateEventId(),
            "type": TranslateClientEvent.inputAudioBufferAppend.rawValue,
            "audio": base64Audio
        ]
        sendEvent(event)
    }

    // MARK: - Receive Messages

    private func receiveMessage() {
        guard let socket = transportLock.withLock({ webSocket }) else { return }
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket,
                  self.transportLock.withLock({ self.webSocket === socket }) else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage()

            case .failure(let error):
                print("❌ [Translate] 接收消息失败: \(error.localizedDescription)")
                self.onError?("Receive error: \(error.localizedDescription)")
                self.failTransport(error.localizedDescription)
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
            // Never echo a malformed payload: realtime packets can contain
            // audio/base64 or transcript text.
            print("⚠️ [Translate] 收到无法解析的消息")
            return
        }

        logServerEvent(type: type, json: json)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            switch type {
            case TranslateServerEvent.sessionCreated.rawValue:
                print("✅ [Translate] 会话已创建，等待配置确认")

            case TranslateServerEvent.sessionUpdated.rawValue:
                guard self.lifecycle.transition(from: [.configuring], to: .ready) else { return }
                print("✅ [Translate] 会话配置已确认")
                self.onConnected?()

            case TranslateServerEvent.inputAudioBufferSpeechStarted.rawValue:
                self.hasSentImageForSpeechTurn = false
                self.onSpeechStarted?(json["item_id"] as? String)

            case TranslateServerEvent.inputAudioBufferSpeechStopped.rawValue:
                self.onSpeechStopped?(json["item_id"] as? String)

            case TranslateServerEvent.responseCreated.rawValue:
                let responseID = (json["response"] as? [String: Any])?["id"] as? String
                    ?? json["response_id"] as? String
                if let responseID {
                    if self.audioOutputEnabled {
                        self.audioQueue.register(responseID: responseID)
                    }
                    self.onResponseStarted?(responseID)
                }

            case TranslateServerEvent.responseOutputItemAdded.rawValue,
                 TranslateServerEvent.responseOutputItemDone.rawValue:
                let responseID = (json["response_id"] as? String)
                    ?? ((json["response"] as? [String: Any])?["id"] as? String)
                guard let responseID,
                      let item = json["item"] as? [String: Any],
                      let responseItemID = item["id"] as? String else { return }
                self.onResponseItem?(responseID, responseItemID)

            case TranslateServerEvent.conversationItemCreated.rawValue:
                guard let sourceItemID = json["previous_item_id"] as? String,
                      let item = json["item"] as? [String: Any],
                      let responseItemID = item["id"] as? String,
                      item["role"] as? String == "assistant" else { return }
                self.onTurnLink?(sourceItemID, responseItemID)

            case TranslateServerEvent.sourceTranscriptText.rawValue:
                guard let itemID = json["item_id"] as? String else { return }
                self.onSourceTranscript?(TranslateSourceTranscriptEvent(
                    itemID: itemID,
                    confirmedText: json["text"] as? String ?? "",
                    pendingText: json["stash"] as? String ?? "",
                    isFinal: false
                ))

            case TranslateServerEvent.sourceTranscriptCompleted.rawValue:
                guard let itemID = json["item_id"] as? String else { return }
                self.onSourceTranscript?(TranslateSourceTranscriptEvent(
                    itemID: itemID,
                    confirmedText: json["transcript"] as? String ?? "",
                    pendingText: "",
                    isFinal: true
                ))

            case TranslateServerEvent.sourceTranscriptFailed.rawValue:
                let message = (json["error"] as? [String: Any])?["message"] as? String
                    ?? "Source transcription failed"
                self.onError?(message)

            case TranslateServerEvent.responseAudioTranscriptText.rawValue:
                guard let responseID = json["response_id"] as? String else { return }
                self.onTranslation?(TranslateTextEvent(
                    responseID: responseID,
                    itemID: json["item_id"] as? String,
                    confirmedText: json["text"] as? String ?? "",
                    pendingText: json["stash"] as? String ?? "",
                    isFinal: false
                ))

            case TranslateServerEvent.responseAudioTranscriptDone.rawValue:
                guard let responseID = json["response_id"] as? String else { return }
                self.onTranslation?(TranslateTextEvent(
                    responseID: responseID,
                    itemID: json["item_id"] as? String,
                    confirmedText: json["transcript"] as? String ?? "",
                    pendingText: "",
                    isFinal: true
                ))

            case TranslateServerEvent.responseTextText.rawValue:
                guard let responseID = json["response_id"] as? String else { return }
                self.onTranslation?(TranslateTextEvent(
                    responseID: responseID,
                    itemID: json["item_id"] as? String,
                    confirmedText: json["text"] as? String ?? "",
                    pendingText: json["stash"] as? String ?? "",
                    isFinal: false
                ))

            case TranslateServerEvent.responseTextDone.rawValue:
                guard let responseID = json["response_id"] as? String else { return }
                self.onTranslation?(TranslateTextEvent(
                    responseID: responseID,
                    itemID: json["item_id"] as? String,
                    confirmedText: (json["text"] as? String) ?? (json["transcript"] as? String) ?? "",
                    pendingText: "",
                    isFinal: true
                ))

            case TranslateServerEvent.responseAudioDelta.rawValue:
                if let responseID = json["response_id"] as? String,
                   let base64Audio = json["delta"] as? String,
                   let audioData = Data(base64Encoded: base64Audio) {
                    self.appendAudioChunk(audioData, responseID: responseID)
                }

            case TranslateServerEvent.responseAudioDone.rawValue:
                if let responseID = json["response_id"] as? String {
                    self.markAudioResponseFinished(responseID)
                }

            case TranslateServerEvent.responseDone.rawValue:
                let responseID = (json["response"] as? [String: Any])?["id"] as? String
                    ?? json["response_id"] as? String
                if let responseID { self.onResponseFinished?(responseID) }

            case TranslateServerEvent.sessionFinished.rawValue:
                guard self.lifecycle.transition(from: [.finishing], to: .finished) else { return }
                self.hasReceivedSessionFinished = true
                self.onSessionFinished?()
                // A finished Alibaba session is terminal. Close its socket
                // immediately; already buffered translated audio may continue
                // to drain locally before finishSession returns.
                self.closeTransport(expected: true, reason: "session.finished")
                self.completeFinishIfReady()

            case TranslateServerEvent.error.rawValue:
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    print("❌ [Translate] 服务器错误: \(message)")
                    self.onError?(message)
                    self.failTransport(message)
                }

            default:
                break
            }
        }
    }

    // MARK: - Audio Playback

    private func appendAudioChunk(_ audioData: Data, responseID: String) {
        guard audioOutputEnabled else {
            return
        }
        audioQueue.append(audioData, responseID: responseID)
        drainPlaybackQueue()
    }

    private func markAudioResponseFinished(_ responseID: String) {
        // A late audio.done can arrive after the user has switched to
        // text-only output. Do not recreate an empty queue entry, otherwise
        // session finalization would wait forever for playback that is
        // intentionally disabled.
        guard audioOutputEnabled else { return }
        if audioQueue.markServerFinished(responseID) {
            finishPlaybackResponse(responseID)
        }
        drainPlaybackQueue()
    }

    private func drainPlaybackQueue() {
        guard audioOutputEnabled else {
            publishPlaybackState()
            completeFinishIfReady()
            return
        }
        guard let responseID = audioQueue.activateNextIfReady() else {
            publishPlaybackState()
            completeFinishIfReady()
            return
        }

        publishPlaybackState()

        // A server may legitimately finish a response without audio bytes.
        if audioQueue.completeActiveIfDrained(responseID) {
            finishPlaybackResponse(responseID)
            drainPlaybackQueue()
            return
        }

        guard let audioData = audioQueue.takePendingAudio(responseID) else {
            completeFinishIfReady()
            return
        }

        if !isPlaybackEngineRunning {
            guard ensureDuplexAudioSessionForPlayback(), startPlaybackEngine() else {
                discardPlaybackResponse(responseID)
                return
            }
        }

        guard let playerNode = playerNode,
              let playbackFormat = playbackFormat else {
            discardPlaybackResponse(responseID)
            return
        }

        guard let pcmBuffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            discardPlaybackResponse(responseID)
            return
        }

        playerNode.scheduleBuffer(pcmBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                self?.completePlaybackBuffer(responseID)
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func completePlaybackBuffer(_ responseID: String) {
        if audioQueue.markBufferPlayed(responseID) {
            finishPlaybackResponse(responseID)
        }
        publishPlaybackState()
        drainPlaybackQueue()
    }

    private func finishPlaybackResponse(_ responseID: String) {
        onPlaybackCompleted?(responseID)
        publishPlaybackState()
        completeFinishIfReady()
    }

    private func discardPlaybackResponse(_ responseID: String) {
        guard audioQueue.discardActive(responseID) else { return }
        onPlaybackCompleted?(responseID)
        publishPlaybackState()
        drainPlaybackQueue()
    }

    private func cancelPlaybackQueue() {
        clearPlaybackQueue()
        completeFinishIfReady(force: true)
    }

    private func clearPlaybackQueue() {
        playerNode?.stop()
        playerNode?.reset()
        audioQueue.reset()
        publishPlaybackState()
    }

    private func publishPlaybackState() {
        let state: TranslationPlaybackState = audioQueue.activeResponseID.map {
            .playing(responseID: $0)
        } ?? .idle
        onPlaybackStateChanged?(state, audioQueue.pendingCount)
    }

    private func completeFinishIfReady(force: Bool = false) {
        guard force || (hasReceivedSessionFinished && audioQueue.isEmpty) else {
            return
        }
        finishTimeoutWorkItem?.cancel()
        finishTimeoutWorkItem = nil
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = data.count / 2
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        // PCM16 → Float32
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            let floatData = channelData[0]
            for i in 0..<frameCount {
                floatData[i] = Float(int16Pointer[i]) / 32768.0
            }
        }

        return buffer
    }

    // MARK: - Helpers

    /// Logs only event metadata needed to diagnose turn association.  Never
    /// include packet bodies, transcripts, audio, or authorization material.
    private func logServerEvent(type: String, json: [String: Any]) {
        var metadata = ["type=\(type)"]
        if let eventID = json["event_id"] as? String {
            metadata.append("event_id=\(eventID)")
        }
        let nestedResponseID = (json["response"] as? [String: Any])?["id"] as? String
        if let responseID = (json["response_id"] as? String) ?? nestedResponseID {
            metadata.append("response_id=\(responseID)")
        }
        if let itemID = json["item_id"] as? String {
            metadata.append("item_id=\(itemID)")
        } else if let itemID = (json["item"] as? [String: Any])?["id"] as? String {
            metadata.append("item_id=\(itemID)")
        }
        if let previousItemID = json["previous_item_id"] as? String {
            metadata.append("previous_item_id=\(previousItemID)")
        }
        if let status = (json["response"] as? [String: Any])?["status"] as? String {
            metadata.append("status=\(status)")
        }
        let entry = metadata.joined(separator: " ")
        diagnosticEventLog.append(entry)
        if diagnosticEventLog.count > diagnosticEventLogCapacity {
            diagnosticEventLog.removeFirst(diagnosticEventLog.count - diagnosticEventLogCapacity)
        }
        print("📥 [Translate] \(entry)")
    }

    private func generateEventId() -> String {
        eventIdCounter += 1
        return "translate_\(eventIdCounter)_\(UUID().uuidString.prefix(8))"
    }
}

private enum LiveTranslateAudioSessionError: LocalizedError {
    case inputUnavailable(usePhoneMic: Bool)

    var errorDescription: String? {
        switch self {
        case .inputUnavailable(true):
            return "livetranslate.error.phoneMicUnavailable".localized
        case .inputUnavailable(false):
            return "livetranslate.error.glassesMicUnavailable".localized
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension LiveTranslateService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ [Translate] WebSocket 连接已建立")
        DispatchQueue.main.async { [weak self, weak webSocketTask] in
            guard let self, let webSocketTask,
                  self.transportLock.withLock({ self.webSocket === webSocketTask }),
                  self.lifecycle.transition(from: [.connecting], to: .configuring) else { return }
            self.configureSession()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        print("🔌 [Translate] WebSocket 已断开, closeCode: \(closeCode.rawValue), reason: \(reasonString)")
        let isCurrent = transportLock.withLock { webSocket === webSocketTask }
        guard isCurrent else { return }
        let wasExpected = lifecycle.state == .finished || lifecycle.state == .disconnected
        if wasExpected {
            closeTransport(expected: true, reason: reasonString)
        } else {
            failTransport(reasonString)
        }
    }
}
