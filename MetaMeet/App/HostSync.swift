import Foundation
import UIKit
import CryptoKit
import Security
import MeetingCore

@MainActor
final class HostSync: NSObject, ObservableObject, URLSessionTaskDelegate {
    static let shared = HostSync()
    nonisolated static let sessionID = "com.rsnav.metameet.host-upload.v1"
    @Published private(set) var status = "자동 백업 꺼짐"
    @Published private(set) var connectionStatus = "호스트 연결 확인 전"
    @Published private(set) var checkingConnection = false
    @Published private(set) var acknowledged: [UUID: Int] = [:]
    @Published private(set) var completed: Set<UUID> = []
    var source: (() -> (URL, [Meeting]))?
    var backgroundCompletion: (() -> Void)?
    private var timer: Timer?
    private var ready = false
    private var busy = false
    private var failures = 0
    private var retryAfter = Date.distantPast
    private var blocked = false
    private let directory: URL
    private var receipts: [String: Receipt] = [:]
    private var job: Job?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false; config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true; config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    private struct Receipt: Codable {
        var metadata: TransferMeeting?
        var audio: [Int: String] = [:]
    }
    private struct Job: Codable {
        var endpoint: String
        var digest: String
        var envelope: TransferEnvelope
    }
    private override init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HostUpload", isDirectory: true)
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: directory.appendingPathComponent("receipts.json")) {
                receipts = try JSONDecoder().decode([String: Receipt].self, from: data)
            }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("job.json")) {
                job = try JSONDecoder().decode(Job.self, from: data)
            }
        } catch { status = "백업 기록 확인 필요 · 원음은 폰에 보관됨" }
    }
    func configurePrivateBuild() {
        guard !UserDefaults.standard.bool(forKey: "hostPrivateBuildConfigured"),
              let url = Bundle.main.url(forResource: "EmbeddedHostConfig", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode([String: String].self, from: data),
              let address = config["url"], HostDestination.validate(address) != nil,
              let token = config["token"], token.count >= 32 else { return }
        do {
            try Keychain.saveHostToken(token)
            UserDefaults.standard.set(address, forKey: "hostURL")
            UserDefaults.standard.set(true, forKey: "hostSyncEnabled")
            UserDefaults.standard.set("slow", forKey: "transcriptionPace")
            UserDefaults.standard.set(true, forKey: "hostPrivateBuildConfigured")
        } catch { status = "호스트 연결 키 저장 실패" }
    }
    func checkConnection() async {
        guard !checkingConnection else { return }
        guard let base = endpoint, !Keychain.readHostToken().isEmpty else {
            connectionStatus = "호스트 주소와 연결 키를 먼저 저장해 주세요"; return
        }
        checkingConnection = true; connectionStatus = "호스트 연결 확인 중"
        defer { checkingConnection = false }
        var request = URLRequest(url: base.appendingPathComponent("v1/health"))
        request.timeoutInterval = 15
        request.setValue("Bearer " + Keychain.readHostToken(), forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let client = URLSession(configuration: config, delegate: HostTLSDelegate(), delegateQueue: nil)
        defer { client.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await client.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            connectionStatus = code == 200 ? "호스트 연결·인증 확인 완료" : Self.responseMessage(code)
        } catch { connectionStatus = Self.connectionError(error) }
    }
    nonisolated private static func responseMessage(_ code: Int) -> String {
        if code == 401 { return "호스트 연결 키가 맞지 않습니다 (HTTP 401)" }
        return "호스트 응답 확인 필요 (HTTP \(code))"
    }
    nonisolated private static func connectionError(_ error: Error) -> String {
        let e = error as NSError
        let reason: String
        if e.domain == NSURLErrorDomain {
            switch e.code {
            case -1206 ... -1200: reason = "호스트 인증서 연결 실패"
            case -1009: reason = "네트워크 연결 또는 앱의 네트워크 권한 확인 필요"
            case -1001: reason = "호스트 응답 시간 초과"
            case -1004, -1003: reason = "호스트 주소 또는 Tailscale 연결 확인 필요"
            case -999: reason = "전송이 취소됨 · 다시 시도해 주세요"
            default: reason = "호스트 연결 실패"
            }
        } else { reason = "호스트 연결 실패" }
        return "\(reason) (\(e.domain) \(e.code))"
    }
    func configureTranslation() async {
        guard let base = endpoint, !Keychain.readHostToken().isEmpty, !Keychain.read().isEmpty else {
            status = "호스트 연결 키와 Gemini 키를 먼저 저장해 주세요"; return
        }
        var request = URLRequest(url: base.appendingPathComponent("v1/translation-key"))
        request.httpMethod = "PUT"; request.timeoutInterval = 30
        request.setValue("Bearer " + Keychain.readHostToken(), forHTTPHeaderField: "Authorization")
        request.httpBody = Data(Keychain.read().utf8)
        let client = URLSession(configuration: .ephemeral, delegate: HostTLSDelegate(), delegateQueue: nil)
        defer { client.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await client.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { status = Self.responseMessage(code); connectionStatus = status; return }
            status = "호스트 한국어 번역 설정 완료"
        } catch { status = Self.connectionError(error); connectionStatus = status }
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pump() }
        }
        session.getAllTasks { tasks in
            Task { @MainActor in
                self.busy = !tasks.isEmpty; self.ready = true
                self.pump()
            }
        }
    }
    func retry() { blocked = false; retryAfter = .distantPast; failures = 0; pump() }
    func refresh() { pump() }
    private var endpoint: URL? { HostDestination.validate(UserDefaults.standard.string(forKey: "hostURL") ?? "https://100.126.27.18:8766") }
    private func receiptKey(_ endpoint: String, _ id: UUID) -> String { endpoint + "|" + id.uuidString }
    private func save<T: Encodable>(_ value: T, _ name: String) throws {
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func pump() {
        guard ready else { return }
        guard UserDefaults.standard.bool(forKey: "hostSyncEnabled") else { status = "자동 백업 꺼짐"; return }
        guard let endpoint, !Keychain.readHostToken().isEmpty else { status = "백업 주소·연결 키 설정 필요"; return }
        guard let (root, meetings) = source?() else { return }
        let address = endpoint.absoluteString
        acknowledged = [:]; completed = []
        for meeting in meetings {
            let snapshot = TransferMeeting(meeting)
            let receipt = receipts[receiptKey(address, meeting.id)] ?? Receipt()
            let count = snapshot.chunks.filter { receipt.audio[$0.id] != nil }.count
            acknowledged[meeting.id] = count
            if count == snapshot.chunks.count, receipt.metadata == snapshot { completed.insert(meeting.id) }
        }
        guard !busy, !blocked, Date() >= retryAfter else { return }
        do {
            if let existing = job {
                guard existing.endpoint == address else { status = "기존 백업 전송을 완료한 뒤 주소를 바꿔 주세요"; return }
                try send(existing); return
            }
            for meeting in meetings {
                let snapshot = TransferMeeting(meeting)
                guard !snapshot.chunks.isEmpty else { continue }
                let receipt = receipts[receiptKey(address, meeting.id)] ?? Receipt()
                var audio: [TransferAudio] = []; var seconds = 0.0
                let missing = snapshot.chunks.filter { receipt.audio[$0.id] == nil }
                if snapshot.ended == nil, missing.reduce(0, { $0 + $1.duration }) < 60 { continue }
                for chunk in missing {
                    if audio.count >= 60 || seconds >= 60 { break }
                    let data = try Data(contentsOf: root.appendingPathComponent(meeting.id.uuidString).appendingPathComponent(chunk.filename))
                    guard data.count == 44 + Int((chunk.duration * Double(WAV.bytesPerSecond)).rounded()), data.prefix(44) == WAV.header(byteCount: data.count - 44) else {
                        throw NSError(domain: "HostSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "녹음 파일 확인 필요"])
                    }
                    audio.append(TransferAudio(id: chunk.id, sha256: Self.digest(data), audio: data)); seconds += chunk.duration
                }
                guard !audio.isEmpty || receipt.metadata != snapshot else { continue }
                let envelope = TransferEnvelope(revision: Date().timeIntervalSince1970, meeting: snapshot, audio: audio)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let body = try encoder.encode(envelope)
                guard body.count <= 12 * 1024 * 1024 else { throw NSError(domain: "HostSync", code: 2) }
                let next = Job(endpoint: address, digest: Self.digest(body), envelope: envelope)
                try body.write(to: directory.appendingPathComponent("body.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try save(next, "job.json"); job = next
                try send(next); return
            }
            status = completed.isEmpty ? "전송할 녹음 대기 · 녹음 중에는 약 1분씩 전송" : "호스트 수신 확인됨 · 녹음 중에는 약 1분씩 전송"
        } catch { status = "백업 준비 실패 · 원음 보관 중"; retryAfter = Date().addingTimeInterval(30) }
    }
    private func send(_ job: Job) throws {
        guard let base = HostDestination.validate(job.endpoint) else { throw NSError(domain: "HostSync", code: 4) }
        let bodyURL = directory.appendingPathComponent("body.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(job.envelope)
        guard Self.digest(body) == job.digest else { throw NSError(domain: "HostSync", code: 3) }
        try body.write(to: bodyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var request = URLRequest(url: base.appendingPathComponent("v1/batches/" + job.digest))
        request.httpMethod = "PUT"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + Keychain.readHostToken(), forHTTPHeaderField: "Authorization")
        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = job.digest; busy = true; status = "호스트로 원음 백업 중"; task.resume()
    }
    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let response = task.response as? HTTPURLResponse
        let code = response?.statusCode
        let digest = response?.value(forHTTPHeaderField: "X-Content-SHA256")
        let taskDigest = task.taskDescription
        let failure = error.map { Self.connectionError($0) }
        Task { @MainActor in self.finished(taskDigest: taskDigest, code: code, digest: digest, failure: failure) }
    }
    private func finished(taskDigest: String?, code: Int?, digest: String?, failure: String?) {
        guard let job, taskDigest == job.digest else { busy = false; return }
        busy = false
        guard failure == nil, code == 200, digest == job.digest else {
            failures += 1; retryAfter = Date().addingTimeInterval(min(300, pow(2, Double(min(failures, 8))) * 5))
            blocked = [400, 401, 403, 409, 413].contains(code ?? 0)
            let detail = failure ?? Self.responseMessage(code ?? 0)
            connectionStatus = detail
            status = detail + (blocked ? " · 설정 확인 후 재시도" : " · 원음 보관 중, 자동 재시도")
            return
        }
        do {
            let key = receiptKey(job.endpoint, job.envelope.meeting.id)
            var receipt = receipts[key] ?? Receipt()
            for audio in job.envelope.audio { receipt.audio[audio.id] = audio.sha256 }
            receipt.metadata = job.envelope.meeting; receipts[key] = receipt
            try save(receipts, "receipts.json")
            try FileManager.default.removeItem(at: directory.appendingPathComponent("job.json"))
            self.job = nil; failures = 0; retryAfter = .distantPast
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("body.json"))
            pump()
        } catch { blocked = true; status = "백업 확인 저장 실패 · 재시도 필요" }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in let callback = self.backgroundCompletion; self.backgroundCompletion = nil; callback?() }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        HostTLSDelegate.validate(challenge, completionHandler: completionHandler)
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        HostTLSDelegate.validate(challenge, completionHandler: completionHandler)
    }
}

@MainActor
final class HostUploadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == HostSync.sessionID else { completionHandler(); return }
        HostSync.shared.backgroundCompletion = completionHandler
        HostSync.shared.start()
    }
}

final class HostTLSDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        Self.validate(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        Self.validate(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    static func validate(_ challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The host-only ATS exception permits this custom anchor, never unchecked trust.
        // HTTPS is mandatory in HostDestination. Validate hostname and validity as well.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let url = Bundle.main.url(forResource: "HostCertificate", withExtension: "der"),
              let bytes = try? Data(contentsOf: url), let certificate = SecCertificateCreateWithData(nil, bytes as CFData) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString))
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
