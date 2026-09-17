import Foundation
import SwiftUI
import UIKit
import MeetingCore

@MainActor
final class MeetingStore: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selectedID: UUID?
    @Published var activeID: UUID?
    @Published var starting = false
    @Published var paused = false
    @Published var inputName = "시작하면 마이크를 연결합니다"
    @Published var bluetooth = false
    @Published var level: Float = 0
    @Published var error: String?
    @Published var processing = false
    @Published var hasKey = !Keychain.read().isEmpty
    @Published var isPreview = false
    let speaker = TranslationSpeaker()
    private var capture: AudioCapture?
    private var workers: [Int: Task<Void, Never>] = [:]
    private var spokenCursors: [UUID: Int] = [:]
    @Published private(set) var lastAPISeconds: Double?
    private var queuePaused = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    let root: URL
    var selected: Meeting? { meetings.first { $0.id == selectedID } }
    var active: Meeting? { meetings.first { $0.id == activeID } }
    var canStart: Bool { activeID == nil && !starting }

    init(preview: Bool = false) {
        UserDefaults.standard.set(GeminiModels.migrated(UserDefaults.standard.string(forKey: "geminiModel")), forKey: "geminiModel")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("MetaMeet", isDirectory: true)
        isPreview = preview
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { self.error = "회의 저장 공간을 준비하지 못했습니다: \(error.localizedDescription)" }
        if preview {
            var meeting = Meeting(title: "중국 기술팀 회의 · 미리보기")
            var chunk = AudioChunk(id: 0, filename: "preview.wav", start: 0, duration: 15, state: .complete)
            chunk.utterances = [Utterance(start: 1, end: 5, speaker: "화자 A", original: "我们先确认一下 CAN 报文的周期。", korean: "먼저 CAN 메시지의 전송 주기를 확인하겠습니다."), Utterance(start: 7, end: 12, speaker: "화자 B", original: "这个信号每一百毫秒发送一次。", korean: "이 신호는 100밀리초마다 한 번 전송됩니다.")]
            meeting.chunks = [chunk]; meeting.ended = Date(); meetings = [meeting]; selectedID = meeting.id
            inputName = "Ray-Ban Meta · 미리보기"; bluetooth = true
        } else {
            load()
            HostSync.shared.source = { [weak self] in (self?.root ?? documents, self?.meetings ?? []) }
            HostSync.shared.configurePrivateBuild()
            HostSync.shared.start()
        }
    }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func load() {
        do {
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                let manifest = url.appendingPathComponent("meeting.json")
                guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
                do {
                    var meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: manifest))
                    // Do not trust filenames or IDs from imported/modified manifests as filesystem paths.
                    guard url.lastPathComponent == meeting.id.uuidString,
                          meeting.chunks.allSatisfy({ $0.filename == String(format: "%06d.wav", $0.id) && $0.id >= 0 }) else { throw TranscriptError.invalidResponse }
                    var recovered = false
                    for index in meeting.chunks.indices where meeting.chunks[index].state == .recording || meeting.chunks[index].state == .processing {
                        do {
                            meeting.chunks[index].duration = try WAV.repair(url.appendingPathComponent(meeting.chunks[index].filename))
                            meeting.chunks[index].state = .queued; meeting.chunks[index].error = nil
                        } catch { meeting.chunks[index].state = .failed; meeting.chunks[index].error = "녹음 파일을 복구하지 못했습니다." }
                        recovered = true
                    }
                    // Recover an audio file created just before the manifest callback could commit.
                    let known = Set(meeting.chunks.map(\.filename))
                    for audio in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) where audio.pathExtension == "wav" && !known.contains(audio.lastPathComponent) {
                        guard let id = Int(audio.deletingPathExtension().lastPathComponent), id >= 0, audio.lastPathComponent == String(format: "%06d.wav", id) else { continue }
                        let duration = try WAV.repair(audio)
                        meeting.chunks.append(AudioChunk(id: id, filename: audio.lastPathComponent, start: meeting.duration, duration: duration, state: .queued)); recovered = true
                    }
                    meeting.chunks.sort { $0.id < $1.id }
                    if meeting.ended == nil { meeting.ended = Date(); recovered = true }
                    if recovered { meeting.events.append("앱 종료 후 저장된 음성을 복구했습니다. 미전사 구간은 ‘다시 전사’를 눌러 처리할 수 있습니다."); try write(meeting) }
                    meetings.append(meeting)
                } catch { self.error = "일부 회의 파일을 열지 못했습니다. 원본 파일은 그대로 보관했습니다." }
            }
            meetings.sort { $0.created > $1.created }; selectedID = meetings.first?.id
        } catch { self.error = "저장된 회의를 읽지 못했습니다: \(error.localizedDescription)" }
    }
    private func write(_ meeting: Meeting) throws {
        let data = try JSONEncoder().encode(meeting)
        try data.write(to: folder(meeting.id).appendingPathComponent("meeting.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func edit(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[i])
        do { try write(meetings[i]) }
        catch {
            self.error = "회의 기록 저장 실패: \(error.localizedDescription)"
            // Stop capture on persistence failure; never imply that unsaved recording is safe.
            if activeID == id { capture?.stop(); activeID = nil; paused = false }
        }
    }
    func event(_ id: UUID, _ text: String) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        edit(id) { $0.events.append("\(Meeting.timestamp(Date().timeIntervalSince(meeting.created))) · \(text)") }
    }
    func saveSettings(key: String) {
        do { try Keychain.save(key); hasKey = !Keychain.read().isEmpty }
        catch { self.error = error.localizedDescription }
    }
    func start() async {
        guard canStart, !isPreview else { return }
        guard hasKey else { error = "설정에서 Gemini API 키를 먼저 저장해 주세요."; return }
        starting = true; defer { starting = false }
        guard await AudioCapture.permission() else { error = "iPhone 설정에서 MetaMeet의 마이크 사용을 허용해 주세요."; return }
        let formatter = DateFormatter(); formatter.dateFormat = "M월 d일 HH:mm 회의"
        let meeting = Meeting(title: formatter.string(from: Date()))
        do {
            try FileManager.default.createDirectory(at: folder(meeting.id), withIntermediateDirectories: true)
            try write(meeting)
        } catch { self.error = "녹음을 저장할 수 없습니다: \(error.localizedDescription)"; return }
        spokenCursors[meeting.id] = 0
        meetings.insert(meeting, at: 0); selectedID = meeting.id; activeID = meeting.id; paused = false
        let recorder = AudioCapture(); capture = recorder
        recorder.onOpened = { [weak self] chunk in self?.edit(meeting.id) { $0.chunks.append(chunk) } }
        recorder.onClosed = { [weak self] id, duration in
            guard let self else { return }
            self.edit(meeting.id) { value in
                guard let i = value.chunks.firstIndex(where: { $0.id == id }) else { return }
                value.chunks[i].duration = duration; value.chunks[i].state = duration > 0.05 ? .queued : .complete
            }
            self.runQueue()
        }
        recorder.onRoute = { [weak self] name, bluetooth in
            self?.inputName = name; self?.bluetooth = bluetooth
            self?.event(meeting.id, "마이크: \(name)\(bluetooth ? " (Bluetooth)" : " (iPhone)")")
        }
        recorder.onLevel = { [weak self] level in self?.level = level }
        recorder.onEvent = { [weak self] message in self?.event(meeting.id, message) }
        recorder.onPaused = { [weak self] paused in
            if paused && self?.paused == false { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            self?.paused = paused
        }
        recorder.onFailure = { [weak self] message in self?.error = message; self?.event(meeting.id, message); self?.stop() }
        do { try recorder.start(directory: folder(meeting.id), preferGlasses: UserDefaults.standard.object(forKey: "preferGlasses") as? Bool ?? true) }
        catch { self.error = error.localizedDescription; stop() }
    }
    func stop() {
        guard let id = activeID else { return }
        speaker.stop(); capture?.stop(); activeID = nil; paused = false; level = 0
        edit(id) { $0.ended = Date() }
        // Closed chunk callbacks arrive on main after stop; they also wake the durable queue.
        runQueue()
    }
    func resume() { capture?.resume() }
    func retry(_ id: UUID) {
        guard !isPreview else { return }
        queuePaused = false
        edit(id) { meeting in
            for i in meeting.chunks.indices where meeting.chunks[i].state == .failed { meeting.chunks[i].state = .queued; meeting.chunks[i].error = nil }
        }
        runQueue()
    }
    func rename(_ id: UUID, title: String) { edit(id) { $0.title = String(title.prefix(120)) } }
    func delete(_ id: UUID) {
        guard activeID != id, !processing, !isPreview else { return }
        do {
            try FileManager.default.removeItem(at: folder(id)); meetings.removeAll { $0.id == id }
            if selectedID == id { selectedID = meetings.first?.id }
        } catch { self.error = "회의를 삭제하지 못했습니다." }
    }
    private func runQueue() {
        guard !isPreview, !queuePaused else { return }
        for slot in 0..<2 where workers[slot] == nil { startWorker(slot) }
    }
    private func startWorker(_ slot: Int) {
        workers[slot] = Task { [weak self] in
            guard let self else { return }
            self.processing = true
            if self.backgroundTask == .invalid { self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish transcription") { [weak self] in
                Task { @MainActor in self?.workers.values.forEach { $0.cancel() } }
            }
            }
            defer {
                self.workers.removeValue(forKey: slot)
                self.processing = !self.workers.isEmpty
                if self.workers.isEmpty && self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid }
            }
            while !Task.isCancelled && !self.queuePaused {
                guard let meeting = self.meetings.first(where: { $0.chunks.contains { $0.state == .queued } }),
                      let chunk = meeting.chunks.first(where: { $0.state == .queued }) else { break }
                let key = Keychain.read()
                if key.isEmpty { self.error = "미전사 녹음이 있습니다. API 키를 저장한 뒤 다시 전사를 눌러 주세요."; break }
                self.updateChunk(meeting.id, chunk.id) { $0.state = .processing; $0.error = nil }
                let apiStarted = Date()
                do {
                    let audio = try Data(contentsOf: self.folder(meeting.id).appendingPathComponent(chunk.filename))
                    var result: [Utterance] = []
                    for attempt in 0..<3 {
                        do {
                            result = try await GeminiClient().transcribe(audio: audio, duration: chunk.duration, model: UserDefaults.standard.string(forKey: "geminiModel") ?? GeminiModels.defaultModel, key: key, glossary: "")
                            break
                        } catch let failure as GeminiFailure where failure.retryable && attempt < 2 {
                            try await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000)
                        }
                    }
                    try Task.checkCancellation()
                    let beforeFiltering = result.count
                    result.removeAll { AudioSanity.isPlaybackEcho(original: $0.original, spoken: self.speaker.recentSpeech) }
                    if result.count < beforeFiltering { self.event(meeting.id, "읽어준 한국어가 다시 입력된 것으로 보이는 문장을 제외했습니다. 원음은 보관돼 있습니다.") }
                    self.lastAPISeconds = Date().timeIntervalSince(apiStarted)
                    self.updateChunk(meeting.id, chunk.id) { $0.utterances = result; $0.state = .complete; $0.error = nil }
                    self.drainSpeech(meeting.id)
                } catch is CancellationError {
                    self.updateChunk(meeting.id, chunk.id) { $0.state = .queued; $0.error = "앱을 다시 열어 전사를 이어갈 수 있습니다." }; break
                } catch {
                    self.updateChunk(meeting.id, chunk.id) { $0.state = .failed; $0.error = error.localizedDescription }
                    // Pause network work after a failure; keep capturing locally without repeating failed API calls.
                    self.queuePaused = true; self.error = error.localizedDescription; break
                }
            }
        }
    }
    private func drainSpeech(_ id: UUID) {
        guard let meeting = meetings.first(where: { $0.id == id }), activeID == id else { return }
        var cursor = spokenCursors[id] ?? 0
        while let chunk = meeting.chunks.first(where: { $0.id == cursor }) {
            guard chunk.state == .complete || chunk.state == .failed else { break }
            if chunk.state == .complete && Date().timeIntervalSince(meeting.created) - (chunk.start + chunk.duration) < 30 {
                for utterance in chunk.utterances { speaker.enqueue(utterance.korean) }
            }
            cursor += 1
        }
        spokenCursors[id] = cursor
    }
    private func updateChunk(_ meeting: UUID, _ chunk: Int, _ update: (inout AudioChunk) -> Void) {
        edit(meeting) { value in
            guard let i = value.chunks.firstIndex(where: { $0.id == chunk }) else { return }; update(&value.chunks[i])
        }
    }
    func foreground() { capture?.foreground(); HostSync.shared.refresh(); if activeID != nil { runQueue() } }
}
