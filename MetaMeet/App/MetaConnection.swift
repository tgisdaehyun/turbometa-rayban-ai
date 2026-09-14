import SwiftUI
import MWDATCore
import MWDATCamera
import MeetingCore

@MainActor
final class MetaConnection: ObservableObject {
    @Published private(set) var registered = false
    @Published private(set) var connecting = false
    @Published private(set) var status = "Meta 앱 연결 필요"
    @Published var error: String?
    @Published private(set) var streamStatus = "스트리밍 꺼짐"
    @Published private(set) var streamActive = false
    @Published private(set) var streamStarting = false
    @Published private(set) var deviceStatus = "발견된 안경 없음"
    @Published private(set) var permissionStatus = "권한 미확인"
    @Published private(set) var diagnostics = ""
    private var selector: AutoDeviceSelector?
    private var deviceWatcher: Task<Void, Never>?
    private var selectorWatcher: Task<Void, Never>?
    private var generation = 0
    private var connectionStage = ""
    private var session: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var streamTokens: [any AnyListenerToken] = []
    private var wearables: (any WearablesInterface)?
    private var watcher: Task<Void, Never>?
    init(preview: Bool = false) {
        guard !preview else { registered = true; status = "연결 미리보기"; return }
        do {
            try Wearables.configure()
            wearables = Wearables.shared
            let selector = AutoDeviceSelector(wearables: Wearables.shared)
            self.selector = selector
            refreshDevices()
            deviceWatcher = Task { [weak self] in
                for await _ in Wearables.shared.devicesStream() {
                    guard !Task.isCancelled else { break }
                    self?.refreshDevices()
                }
            }
            selectorWatcher = Task { [weak self] in
                for await device in selector.activeDeviceStream() {
                    guard !Task.isCancelled else { break }
                    self?.log("선택기: \(device == nil ? "준비된 안경 없음" : "안경 선택됨")")
                    self?.refreshDevices()
                }
            }
            update(Wearables.shared.registrationState)
            watcher = Task { [weak self] in
                for await state in Wearables.shared.registrationStateStream() {
                    guard !Task.isCancelled else { break }
                    self?.update(state)
                }
            }
        } catch { self.error = "Meta 연결 초기화 실패: \(error.localizedDescription)"; status = "Meta 초기화 실패" }
    }
    private func log(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) · \(message)"
        diagnostics = (diagnostics.split(separator: "\n").map(String.init) + [line]).suffix(100).joined(separator: "\n")
    }
    func refreshDevices() {
        guard let wearables else { return }
        let rows = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }.map {
            "\($0.nameOrId()): \(String(describing: $0.linkState)), \(String(describing: $0.compatibility()))"
        }
        let summary = rows.isEmpty ? "SDK가 발견한 안경 0개" : rows.joined(separator: "\n")
        if deviceStatus != summary { deviceStatus = summary; log(summary) }
    }
    private func update(_ state: RegistrationState) {
        log("등록: \(state.description)")
        registered = state == .registered; connecting = state == .registering
        switch state {
        case .registered: status = "Meta 앱 연결 승인됨"
        case .registering: status = "Meta 앱에서 연결을 승인해 주세요"
        case .available: status = "Meta 앱 연결 필요"
        case .unavailable: status = "Meta 앱 설치·안경 연결을 확인해 주세요"
        @unknown default: status = "Meta 연결 상태 확인 필요"
        }
    }
    func connect() async {
        guard let wearables, !connecting else { return }
        connecting = true
        do { try await wearables.startRegistration(); update(wearables.registrationState) }
        catch { connecting = false; self.error = "Meta 연결 승인 요청 실패: \(error.localizedDescription)" }
    }
    func handle(_ url: URL) async {
        guard url.scheme == "metameet", let wearables else { return }
        do { _ = try await wearables.handleUrl(url); update(wearables.registrationState) }
        catch { connecting = false; self.error = "Meta 앱 복귀 처리 실패: \(error.localizedDescription)" }
    }
    func startStreaming() async {
        guard let wearables, registered, !streamActive, !streamStarting else { return }
        generation += 1
        let startGeneration = generation
        streamStarting = true; error = nil
        defer { if generation == startGeneration { streamStarting = false } }
        connectionStage = "카메라 권한 확인"
        do {
            var permission = try await initialPermission(wearables)
            permissionStatus = "카메라 권한: \(String(describing: permission))"
            log(permissionStatus)
            if permission != .granted {
                connectionStage = "Meta 앱 권한 요청"
                permission = try await wearables.requestPermission(.camera)
                permissionStatus = "카메라 권한: \(String(describing: permission))"; log(permissionStatus)
            }
            guard generation == startGeneration else { throw CancellationError() }
            guard permission == .granted else { throw NSError(domain: "MetaMeet.Meta", code: 1, userInfo: [NSLocalizedDescriptionKey: "Meta 스트리밍 권한이 허용되지 않았습니다."]) }
            connectionStage = "사용 가능한 안경 선택"
            streamStatus = "안경 연결 대기 중 · 최대 20초"
            let session: DeviceSession = try await ReadinessGate.run(attempts: 100, intervalNanoseconds: 200_000_000) {
                guard self.generation == startGeneration else { throw CancellationError() }
                self.refreshDevices()
                // AutoDeviceSelector initializes asynchronously. A registered app is not yet a ready device.
                guard let device = self.selector?.activeDevice, wearables.devices.contains(device) else { return nil }
                return try self.createReadySession(wearables, device: device)
            }
            self.session = session
            log("안경 선택 완료 · 세션 생성됨")
            connectionStage = "안경 세션 시작"
            try session.start()
            for _ in 0..<150 {
                guard generation == startGeneration else { throw CancellationError() }
                if session.state == .started { break }
                if session.state == .stopped { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard session.state == .started else { throw NSError(domain: "MetaMeet.Meta", code: 2, userInfo: [NSLocalizedDescriptionKey: "안경 세션 연결 시간이 초과됐습니다. 안경 착용과 Meta 앱 권한을 확인해 주세요."]) }
            connectionStage = "카메라 스트림 시작"
            guard let stream = try session.addStream(config: StreamConfiguration(videoCodec: .hvc1, resolution: .low, frameRate: 24)) else { throw NSError(domain: "MetaMeet.Meta", code: 3, userInfo: [NSLocalizedDescriptionKey: "안경 스트림을 열지 못했습니다."]) }
            self.stream = stream
            streamTokens = [stream.statePublisher.listen { [weak self] (state: StreamState) in
                Task { @MainActor in
                    guard self?.generation == startGeneration else { return }
                    self?.streamStatus = "Meta 스트림: \(String(describing: state))"
                    self?.streamActive = state != .stopped && state != .stopping
                }
            }, stream.errorPublisher.listen { [weak self] (error: StreamError) in
                Task { @MainActor in guard self?.generation == startGeneration else { return }; self?.error = "Meta 스트림: \(error.description)"; self?.stopStreaming() }
            }]
            // Video frames are neither decoded, displayed, recorded nor sent to Gemini.
            stream.start(); streamActive = true; streamStatus = "Meta 스트림 연결 중"
        } catch {
            guard generation == startGeneration else { return }
            let message: String
            if error is ReadinessFailure {
                message = "20초 동안 사용 가능한 안경을 찾지 못했습니다. 안경을 착용하고, 다른 안경 앱의 스트리밍을 종료한 뒤 다시 시도해 주세요. 아래 진단에서 SDK 기기 수와 연결 상태를 확인할 수 있습니다."
            } else { message = error.localizedDescription }
            log("\(connectionStage) 실패: \(message)")
            stopStreaming()
            self.error = "\(connectionStage): \(message)"
        }
    }
    private func initialPermission(_ wearables: any WearablesInterface) async throws -> PermissionStatus {
        do { return try await wearables.checkPermissionStatus(.camera) }
        catch {
            if let failure = error as? PermissionError, failure == .noDevice {
                log("권한 조회: noDevice · Meta 권한 요청부터 진행합니다")
                return .denied
            }
            throw error
        }
    }
    private func createReadySession(_ wearables: any WearablesInterface, device: DeviceIdentifier) throws -> DeviceSession? {
        do { return try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: device)) }
        catch {
            if let failure = error as? DeviceSessionError, failure == .noEligibleDevice { return nil }
            throw error
        }
    }
    func stopStreaming() {
        generation += 1; streamStarting = false
        let tokens = streamTokens; streamTokens.removeAll()
        Task { for token in tokens { await token.cancel() } }
        stream?.stop(); stream = nil; session?.stop(); session = nil
        streamActive = false; streamStatus = "스트리밍 꺼짐"
    }
    deinit { watcher?.cancel(); deviceWatcher?.cancel(); selectorWatcher?.cancel() }

}
