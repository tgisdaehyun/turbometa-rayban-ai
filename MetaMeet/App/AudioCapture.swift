import AVFoundation
import UIKit
import MeetingCore

/// AVAudioSession control stays on the main thread; conversion and disk I/O are serialized off the audio callback.
final class AudioCapture {
    var onOpened: ((AudioChunk) -> Void)?
    var onClosed: ((Int, Double) -> Void)?
    var onRoute: ((String, Bool) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onEvent: ((String) -> Void)?
    var onPaused: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private let io = DispatchQueue(label: "com.rsnav.metameet.audio", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    private var recording = false
    private var suspended = false
    private var preferGlasses = true
    private var directory: URL!
    private var began = Date()
    // The following writer state is only accessed on io, including through io.sync.
    private var file: FileHandle?
    private var currentURL: URL?
    private var byteCount = 0
    private var chunkID = 0
    private var nextOffset = 0.0
    private var failed = false
    private var levelCount = 0
    private let chunkBytes = 15 * WAV.bytesPerSecond

    static func permission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
    struct Microphone: Identifiable { let id: String; let name: String }
    static func microphones() async throws -> [Microphone] {
        guard await permission() else { throw NSError(domain: "MetaMeet.Audio", code: 5, userInfo: [NSLocalizedDescriptionKey: "iPhone 설정에서 마이크 권한을 허용해 주세요."]) }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: UserDefaults.standard.bool(forKey: "readTranslations") ? .voiceChat : .default, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
        defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        return (session.availableInputs ?? []).filter { $0.portType == .bluetoothHFP }.map { Microphone(id: $0.uid, name: $0.portName) }
    }
    func start(directory: URL, preferGlasses: Bool) throws {
        precondition(Thread.isMainThread)
        guard !recording else { return }
        self.directory = directory; self.preferGlasses = preferGlasses; began = Date()
        io.sync { chunkID = 0; nextOffset = 0; failed = false; byteCount = 0 }
        recording = true
        observe()
        do { try configureAndStart() }
        catch { stop(); throw error }
    }
    func stop() {
        precondition(Thread.isMainThread)
        recording = false; suspended = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        stopEngine()
        io.sync { finishChunk() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func resume() {
        guard recording else { return }
        do { try configureAndStart(); suspended = false; onPaused?(false); onEvent?("녹음을 다시 시작했습니다.") }
        catch { suspended = true; onPaused?(true); onEvent?("마이크를 다시 열지 못했습니다. 재개 버튼을 눌러 주세요.") }
    }
    private func stopEngine() {
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil
    }
    private func configureAndStart() throws {
        stopEngine()
        io.sync { finishChunk(); nextOffset = Date().timeIntervalSince(began) }
        let session = AVAudioSession.sharedInstance()
        // Meta registration and iOS HFP routing are separate. Confirm the actual microphone before writing audio.
        try session.setCategory(.playAndRecord, mode: UserDefaults.standard.bool(forKey: "readTranslations") ? .voiceChat : .default, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setPreferredSampleRate(16000)
        try session.setActive(true)
        let inputs = session.availableInputs ?? []
        let named = inputs.first { input in
            let name = input.portName.lowercased()
            return input.portType == .bluetoothHFP && ["ray-ban", "rayban", "meta", "oakley"].contains { name.contains($0) }
        }
        let chosenUID = UserDefaults.standard.string(forKey: "preferredInputUID") ?? ""
        let explicit = inputs.first { $0.uid == chosenUID && $0.portType == .bluetoothHFP }
        let phone = inputs.first(where: { $0.portType == .builtInMic })
        var preferred = preferGlasses ? (explicit ?? named ?? phone) : phone
        guard preferred != nil else { throw NSError(domain: "MetaMeet.Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "사용 가능한 마이크가 없습니다."]) }
        do { try session.setPreferredInput(preferred) }
        catch { preferred = phone; try session.setPreferredInput(phone) }
        if preferGlasses && preferred?.portType != .bluetoothHFP { onEvent?("안경 마이크를 사용할 수 없어 iPhone 마이크로 녹음합니다.") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if UserDefaults.standard.bool(forKey: "readTranslations") {
            do { try input.setVoiceProcessingEnabled(true) }
            catch { onEvent?("에코 제거를 켜지 못했습니다. 읽어준 번역이 마이크에 다시 들어갈 수 있습니다.") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "MetaMeet.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "마이크 형식을 사용할 수 없습니다. Bluetooth 연결을 확인해 주세요."])
        }
        converter.primeMethod = .none
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let owned = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            owned.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
            for i in 0..<source.count {
                if let src = source[i].mData, let dst = destination[i].mData { memcpy(dst, src, Int(source[i].mDataByteSize)) }
            }
            self.io.async { [weak self] in self?.consume(owned, converter: converter, target: target) }
        }
        self.engine = engine
        engine.prepare(); try engine.start()
        // Report the actual current route, not the preferred route or merely a Bluetooth connection.
        let actual = session.currentRoute.inputs.first
        if preferGlasses && actual?.portType != .bluetoothHFP { onEvent?("실제 입력: iPhone 마이크 (안경 폴백)") }
        onRoute?(actual?.portName ?? "마이크 확인 중", actual?.portType == .bluetoothHFP)
    }
    private func consume(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat) {
        guard !failed else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return buffer
        }
        if status == .error { fail(error?.localizedDescription ?? "오디오 변환 실패"); return }
        guard output.frameLength > 0, let pointer = output.int16ChannelData?[0] else { return }
        let count = Int(output.frameLength)
        levelCount += 1
        if levelCount % 4 == 0 {
            var sum = 0.0
            for i in 0..<count { let v = Double(pointer[i]) / 32768; sum += v * v }
            let level = Float(min(1, sqrt(sum / Double(count)) * 5))
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }
        let data = Data(bytes: pointer, count: count * 2)
        do {
            var offset = 0
            while offset < data.count {
                if file == nil { try openChunk() }
                let length = min(chunkBytes - byteCount, data.count - offset)
                try file?.write(contentsOf: data.subdata(in: offset..<(offset + length)))
                byteCount += length; offset += length
                if byteCount >= chunkBytes { finishChunk(); if failed { return } }
            }
        } catch { fail("녹음 저장 실패: \(error.localizedDescription)") }
    }
    private func openChunk() throws {
        let filename = String(format: "%06d.wav", chunkID)
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.createFile(atPath: url.path, contents: WAV.header(byteCount: 0), attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw NSError(domain: "MetaMeet.Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "녹음 파일을 만들지 못했습니다. 저장 공간을 확인해 주세요."])
        }
        file = try FileHandle(forUpdating: url); try file?.seekToEnd(); currentURL = url; byteCount = 0
        let chunk = AudioChunk(id: chunkID, filename: filename, start: nextOffset)
        let callback = onOpened
        DispatchQueue.main.async { callback?(chunk) }
    }
    private func finishChunk() {
        guard let handle = file else { return }
        let id = chunkID, duration = Double(byteCount) / Double(WAV.bytesPerSecond)
        do {
            try handle.seek(toOffset: 0); try handle.write(contentsOf: WAV.header(byteCount: byteCount)); try handle.synchronize(); try handle.close()
            file = nil; currentURL = nil; nextOffset += duration; chunkID += 1; byteCount = 0
            let callback = onClosed
            DispatchQueue.main.async { callback?(id, duration) }
        } catch { try? handle.close(); file = nil; fail("녹음 마무리 실패: \(error.localizedDescription)") }
    }
    private func fail(_ message: String) {
        guard !failed else { return }; failed = true
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
    }
    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, self.recording, !self.suspended,
                  let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            // Ignore override/routeConfigurationChange: setPreferredInput itself emits them.
            self.onEvent?("오디오 연결 변경: 입력을 다시 선택합니다. 전환 중 짧은 녹음 공백이 생길 수 있습니다.")
            self.resume()
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, self.recording,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self.suspended = true; self.stopEngine(); self.io.sync { self.finishChunk() }
                self.onPaused?(true); self.onEvent?("통화 또는 다른 앱으로 녹음이 중단됐습니다. 이 구간은 녹음되지 않습니다.")
            } else {
                let options = AVAudioSession.InterruptionOptions(rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                if options.contains(.shouldResume) { self.resume() }
                else { self.onEvent?("오디오 중단이 끝났습니다. 재개 버튼을 눌러 주세요.") }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.recording else { return }; self.onEvent?("오디오 서비스가 재시작되어 마이크를 다시 연결합니다."); self.resume()
        })
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
