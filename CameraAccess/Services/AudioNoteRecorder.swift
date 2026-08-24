import AVFoundation
import Foundation

@MainActor
final class AudioNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let maximumDuration: TimeInterval = 2 * 60 * 60

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var activeInput: AudioNoteInput?
    @Published private(set) var activeInputName: String?
    @Published private(set) var isGlassesInputAvailable = false

    var onRouteLost: (() -> Void)?
    var onMaximumDuration: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?

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

    func start(at url: URL, input: AudioNoteInput) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setPreferredSampleRate(16_000)
        try session.setActive(true)

        let desiredPort: AVAudioSession.Port = input == .glasses ? .bluetoothHFP : .builtInMic
        let availableInputs = session.availableInputs?.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ") ?? "none"
        print("🎙️ [AudioNote] start requested input=\(input.rawValue), available=[\(availableInputs)]")
        guard let preferred = session.availableInputs?.first(where: { $0.portType == desiredPort }) else {
            print("❌ [AudioNote] requested input unavailable: \(desiredPort.rawValue)")
            throw AudioNoteRecorderError.inputUnavailable(input)
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
        guard started else {
            self.recorder = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            print("❌ [AudioNote] AVAudioRecorder.record failed")
            throw AudioNoteRecorderError.cannotStart
        }
        activeInput = input
        elapsed = 0
        level = 0
        isRecording = true
        isPaused = false
        startTimer()
    }

    func pause() {
        recorder?.pause()
        isPaused = true
    }

    func resume() {
        guard recorder?.record() == true else { return }
        isPaused = false
    }

    @discardableResult
    func stop() -> TimeInterval {
        let duration = elapsed
        // Mark the session stopped before AVAudioRecorder dispatches its delegate
        // callback so a user-initiated stop cannot be mistaken for the time limit.
        isRecording = false
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isPaused = false
        activeInput = nil
        activeInputName = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredInput(nil)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
                recorder.updateMeters()
                self.level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 55) / 55))
                if self.elapsed >= Self.maximumDuration - 0.2 {
                    self.onMaximumDuration?()
                }
            }
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
