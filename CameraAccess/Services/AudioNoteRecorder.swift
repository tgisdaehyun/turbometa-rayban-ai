import AVFoundation
import Foundation

@MainActor
final class AudioNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let maximumDuration: TimeInterval = 2 * 60 * 60

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var meterSamples: [Float] = Array(repeating: 0.04, count: 42)
    @Published private(set) var activeInput: AudioNoteInput?
    @Published private(set) var activeInputName: String?
    @Published private(set) var isGlassesInputAvailable = false
    @Published private(set) var isPreparingInput = false

    var onRouteLost: (() -> Void)?
    var onMaximumDuration: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var accumulatedElapsed: TimeInterval = 0
    private var recordingStartedAt: TimeInterval?
    private var didReachMaximumDuration = false
    private var preparationGeneration = 0

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
                Task { @MainActor in self?.handleRouteChange(note) }
            }
        refreshRouteState()
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    /// Activates an input-capable audio session when the recording page opens.
    /// Bluetooth HFP inputs are commonly registered only after activation, so
    /// querying `availableInputs` during cold launch reports a false negative.
    func prepare(input: AudioNoteInput) async {
        guard !isRecording else { return }
        preparationGeneration += 1
        let generation = preparationGeneration
        isPreparingInput = true
        defer {
            if preparationGeneration == generation {
                isPreparingInput = false
            }
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try activateRecordingSession(session)

            let desiredPort: AVAudioSession.Port = input == .glasses ? .bluetoothHFP : .builtInMic
            for attempt in 0..<15 {
                guard preparationGeneration == generation, !Task.isCancelled else { return }
                refreshRouteState()
                if let preferred = session.availableInputs?.first(where: { $0.portType == desiredPort }) {
                    try session.setPreferredInput(preferred)
                    refreshRouteState(fallbackName: preferred.portName)
                    print("🎙️ [AudioNote] prepared input=\(input.rawValue), attempt=\(attempt + 1), name=\(preferred.portName)")
                    return
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            refreshRouteState()
            print("⚠️ [AudioNote] input preparation timed out: \(desiredPort.rawValue)")
        } catch is CancellationError {
            // The page disappeared or a newer input selection superseded this request.
        } catch {
            refreshRouteState()
            print("⚠️ [AudioNote] input preparation failed: \(error.localizedDescription)")
        }
    }

    func releasePreparation() {
        preparationGeneration += 1
        isPreparingInput = false
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredInput(nil)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        activeInputName = nil
    }

    func start(at url: URL, input: AudioNoteInput) throws {
        let session = AVAudioSession.sharedInstance()
        let baseOptions: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        // This is a one-way recorder: it does not need a playback path while
        // recording. Using voiceChat here enables call-style voice processing
        // and echo cancellation, which can suppress a far-end speaker's voice
        // picked up from the glasses. Measurement mode keeps the HFP input
        // available while avoiding the duplex voice-chat processing path.
        try activateRecordingSession(session)

        let desiredPort: AVAudioSession.Port = input == .glasses ? .bluetoothHFP : .builtInMic
        let availableInputs = session.availableInputs?.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ") ?? "none"
        print("🎙️ [AudioNote] start requested input=\(input.rawValue), available=[\(availableInputs)]")
        guard var preferred = session.availableInputs?.first(where: { $0.portType == desiredPort }) else {
            print("❌ [AudioNote] requested input unavailable: \(desiredPort.rawValue)")
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioNoteRecorderError.inputUnavailable(input)
        }

        // iOS 26.2+ lets compatible Bluetooth microphones expose a dedicated
        // far-field capture path. Prefer it for Audio Notes because this
        // feature records the surrounding conversation rather than only the
        // wearer's near-field voice. Unsupported accessories continue using
        // ordinary HFP without failing the recording.
        if input == .glasses, #available(iOS 26.2, *) {
            let capability = preferred.bluetoothMicrophoneExtension?.farFieldCapture
            let isSupported = capability?.isSupported == true
            print("🎙️ [AudioNote] farField supported=\(isSupported)")
            if isSupported {
                try session.setActive(false)
                try session.setCategory(
                    .record,
                    mode: .measurement,
                    options: [baseOptions, .farFieldInput]
                )
                try session.setActive(true)
                preferred = session.availableInputs?.first(where: { $0.uid == preferred.uid })
                    ?? session.availableInputs?.first(where: { $0.portType == desiredPort })
                    ?? preferred
            }
        }
        try session.setPreferredInput(preferred)
        refreshRouteState(fallbackName: preferred.portName)

        // AAC encoding must use a rate supported by the active input route.
        // Built-in microphones normally run at 48 kHz while Bluetooth HFP runs
        // at 16/24 kHz. DashScope accepts M4A at any sample rate and resamples it.
        let recordingSampleRate = session.sampleRate > 0 ? session.sampleRate : 48_000
        let recordingBitRate = recordingSampleRate <= 24_000 ? 32_000 : 64_000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: recordingSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: recordingBitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        self.recorder = recorder
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        let prepared = recorder.prepareToRecord()
        print("🎙️ [AudioNote] route=\(session.currentRoute.inputs.map(\.portName)), sampleRate=\(session.sampleRate), file=\(url.path), prepared=\(prepared)")
        guard prepared else {
            self.recorder = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            print("❌ [AudioNote] prepareToRecord failed")
            throw AudioNoteRecorderError.cannotStart
        }
        let started = recorder.record()
        print("🎙️ [AudioNote] record started=\(started), isRecording=\(recorder.isRecording)")
        if input == .glasses, #available(iOS 26.2, *) {
            let enabled = session.currentRoute.inputs.first?
                .bluetoothMicrophoneExtension?.farFieldCapture.isEnabled == true
            print("🎙️ [AudioNote] farField enabled=\(enabled)")
        }
        guard started else {
            self.recorder = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            print("❌ [AudioNote] AVAudioRecorder.record failed")
            throw AudioNoteRecorderError.cannotStart
        }
        activeInput = input
        elapsed = 0
        level = 0
        meterSamples = Array(repeating: 0.04, count: 42)
        accumulatedElapsed = 0
        recordingStartedAt = ProcessInfo.processInfo.systemUptime
        didReachMaximumDuration = false
        isRecording = true
        isPaused = false
        startTimer()
    }

    private func activateRecordingSession(_ session: AVAudioSession) throws {
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setPreferredSampleRate(16_000)
        try session.setActive(true)
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        updateElapsedClock()
        accumulatedElapsed = elapsed
        recordingStartedAt = nil
        recorder?.pause()
        isPaused = true
    }

    func resume() {
        guard recorder?.record() == true else { return }
        recordingStartedAt = ProcessInfo.processInfo.systemUptime
        isPaused = false
    }

    @discardableResult
    func stop() -> TimeInterval {
        updateElapsedClock()
        let duration = elapsed
        // Mark the session stopped before AVAudioRecorder dispatches its delegate
        // callback so a user-initiated stop cannot be mistaken for the time limit.
        isRecording = false
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isPaused = false
        recordingStartedAt = nil
        accumulatedElapsed = duration
        activeInput = nil
        activeInputName = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredInput(nil)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.updateElapsedClock()
                self.updateMeter(recorder)
                if self.elapsed >= Self.maximumDuration, !self.didReachMaximumDuration {
                    self.didReachMaximumDuration = true
                    self.onMaximumDuration?()
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateElapsedClock(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isRecording || recordingStartedAt != nil else { return }
        if let recordingStartedAt, !isPaused {
            elapsed = min(Self.maximumDuration, accumulatedElapsed + max(0, now - recordingStartedAt))
        } else {
            elapsed = min(Self.maximumDuration, accumulatedElapsed)
        }
    }

    private func updateMeter(_ recorder: AVAudioRecorder) {
        let nextLevel: Float
        if isPaused {
            nextLevel = max(0.025, level * 0.72)
        } else {
            recorder.updateMeters()
            let average = recorder.averagePower(forChannel: 0)
            let peak = recorder.peakPower(forChannel: 0)
            // Convert the logarithmic dB values into a visually useful 0...1
            // range. Peak adds responsiveness while smoothing avoids jitter.
            let averageLinear = pow(max(0, min(1, (average + 60) / 60)), 0.72)
            let peakLinear = pow(max(0, min(1, (peak + 60) / 60)), 0.72)
            let measured = max(0.025, min(1, averageLinear * 0.72 + peakLinear * 0.28))
            nextLevel = level * 0.58 + measured * 0.42
        }
        level = nextLevel
        meterSamples.append(nextLevel)
        if meterSamples.count > 42 {
            meterSamples.removeFirst(meterSamples.count - 42)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard isRecording else { return }
        pause()
    }

    private func handleRouteChange(_ notification: Notification) {
        refreshRouteState()
        guard isRecording, activeInput == .glasses else { return }
        if !isGlassesInputAvailable {
            pause()
            onRouteLost?()
        }
    }

    private func refreshRouteState(fallbackName: String? = nil) {
        let session = AVAudioSession.sharedInstance()
        isGlassesInputAvailable = session.availableInputs?.contains { $0.portType == .bluetoothHFP } == true
        if isRecording || fallbackName != nil {
            activeInputName = session.currentRoute.inputs.first?.portName ?? fallbackName
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.isRecording else { return }
            self.onMaximumDuration?()
        }
    }
}

enum AudioNoteRecorderError: LocalizedError {
    case inputUnavailable(AudioNoteInput)
    case cannotStart

    var errorDescription: String? {
        switch self {
        case .inputUnavailable(.glasses): return "audioNote.error.glassesUnavailable".localized
        case .inputUnavailable(.iPhone): return "audioNote.error.phoneMicUnavailable".localized
        case .cannotStart: return "audioNote.error.cannotStart".localized
        }
    }
}
