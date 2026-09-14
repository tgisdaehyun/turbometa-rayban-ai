import SwiftUI
import MWDATCore
import MWDATCamera

@MainActor
final class MetaConnection: ObservableObject {
    @Published private(set) var registered = false
    @Published private(set) var connecting = false
    @Published private(set) var status = "Meta 앱 연결 필요"
    @Published var error: String?
    @Published private(set) var streamStatus = "스트리밍 꺼짐"
    @Published private(set) var streamActive = false
    @Published private(set) var streamStarting = false
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
            update(Wearables.shared.registrationState)
            watcher = Task { [weak self] in
                for await state in Wearables.shared.registrationStateStream() {
                    guard !Task.isCancelled else { break }
                    self?.update(state)
                }
            }
        } catch { self.error = "Meta 연결 초기화 실패: \(error.localizedDescription)"; status = "Meta 초기화 실패" }
    }
    private func update(_ state: RegistrationState) {
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
        streamStarting = true; defer { streamStarting = false }
        do {
            // DAT 0.8 exposes camera permission, not a microphone permission. Audio remains iOS HFP.
            var permission = try await wearables.checkPermissionStatus(.camera)
            if permission != .granted { permission = try await wearables.requestPermission(.camera) }
            guard permission == .granted else { throw NSError(domain: "MetaMeet.Meta", code: 1, userInfo: [NSLocalizedDescriptionKey: "Meta 스트리밍 권한이 허용되지 않았습니다."]) }
            let session = try wearables.createSession(deviceSelector: AutoDeviceSelector(wearables: wearables))
            self.session = session
            try session.start()
            for _ in 0..<150 {
                if session.state == .started { break }
                if session.state == .stopped { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard session.state == .started else { throw NSError(domain: "MetaMeet.Meta", code: 2, userInfo: [NSLocalizedDescriptionKey: "안경 세션 연결 시간이 초과됐습니다. 안경 착용과 Meta 앱 권한을 확인해 주세요."]) }
            guard let stream = try session.addStream(config: StreamConfiguration(videoCodec: .h264, resolution: .low, frameRate: 24)) else { throw NSError(domain: "MetaMeet.Meta", code: 3, userInfo: [NSLocalizedDescriptionKey: "안경 스트림을 열지 못했습니다."]) }
            self.stream = stream
            streamTokens = [stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    self?.streamStatus = "Meta 스트림: \(String(describing: state))"
                    self?.streamActive = state != .stopped && state != .stopping
                }
            }, stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.error = "Meta 스트림: \(error.description)"; self?.stopStreaming() }
            }]
            // Video frames are neither decoded, displayed, recorded nor sent to Gemini.
            stream.start(); streamActive = true; streamStatus = "Meta 스트림 연결 중"
        } catch { stopStreaming(); self.error = "Meta 스트리밍 실패: \(error.localizedDescription)" }
    }
    func stopStreaming() {
        streamTokens.forEach { $0.cancel() }; streamTokens.removeAll()
        stream?.stop(); stream = nil; session?.stop(); session = nil
        streamActive = false; streamStatus = "스트리밍 꺼짐"
    }
    deinit { watcher?.cancel() }

}
