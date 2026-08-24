import AVFoundation
import Foundation
import UIKit

@MainActor
final class AudioNoteLibrary: ObservableObject {
    static let shared = AudioNoteLibrary()

    @Published private(set) var notes: [AudioNote] = []

    private let storage: AudioNoteStorage
    private let transcriptionService: AudioNoteTranscriptionService
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        storage: AudioNoteStorage = .shared,
        transcriptionService: AudioNoteTranscriptionService = AudioNoteTranscriptionService()
    ) {
        self.storage = storage
        self.transcriptionService = transcriptionService
        reload()
        for note in notes where note.status.isProcessing || note.status == .saved {
            process(note.id)
        }
        for var note in notes where note.status == .recording {
            note.status = .failed
            note.errorMessage = "audioNote.error.interrupted".localized
            save(note)
        }
    }

    func reload() {
        notes = storage.loadAll()
    }

    func note(id: UUID) -> AudioNote? {
        notes.first { $0.id == id }
    }

    func save(_ note: AudioNote) {
        notes = storage.upsert(note)
    }

    func delete(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        notes = storage.delete(id: id)
    }

    func clearAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        storage.deleteAll()
        reload()
    }

    func retry(_ id: UUID) {
        guard var note = storage.note(id: id) else { return }
        note.status = .saved
        note.taskID = nil
        note.remoteURL = nil
        note.errorMessage = nil
        save(note)
        process(id)
    }

    func process(_ id: UUID) {
        guard tasks[id] == nil, let initial = storage.note(id: id) else { return }
        let endpoint = APIProviderManager.shared.alibabaEndpoint
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            let backgroundID = UIApplication.shared.beginBackgroundTask(withName: "AudioNoteTranscription")
            defer {
                if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
            }
            do {
                let result = try await self.transcriptionService.transcribe(
                    audioURL: self.storage.audioURL(for: initial),
                    endpoint: endpoint,
                    diarization: initial.diarizationEnabled,
                    languageHints: initial.languageHints,
                    existingTaskID: initial.taskID,
                    existingRemoteURL: initial.remoteURL
                ) { [weak self] status, taskID, remoteURL in
                    guard let self, var note = self.storage.note(id: id) else { return }
                    note.status = status
                    note.taskID = taskID ?? note.taskID
                    note.remoteURL = remoteURL ?? note.remoteURL
                    note.updatedAt = Date()
                    self.save(note)
                }
                guard var note = self.storage.note(id: id) else { return }
                note.status = .completed
                note.taskID = result.taskID
                note.segments = result.segments
                note.errorMessage = nil
                note.updatedAt = Date()
                self.save(note)
            } catch is CancellationError {
                // Deletion intentionally cancels work.
            } catch {
                guard var note = self.storage.note(id: id) else { return }
                note.status = .failed
                note.errorMessage = error.localizedDescription
                note.updatedAt = Date()
                self.save(note)
            }
            self.tasks[id] = nil
        }
    }

    func updateTitle(_ id: UUID, title: String) {
        guard var note = storage.note(id: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        note.title = trimmed
        note.updatedAt = Date()
        save(note)
    }

    func updateSegment(_ noteID: UUID, segmentID: UUID, text: String) {
        guard var note = storage.note(id: noteID),
              let index = note.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        note.segments[index].editedText = text
        note.updatedAt = Date()
        save(note)
    }

    func updateSpeakerName(_ noteID: UUID, speakerID: Int, name: String) {
        guard var note = storage.note(id: noteID) else { return }
        note.speakerNames[String(speakerID)] = name
        note.updatedAt = Date()
        save(note)
    }

    func audioURL(for note: AudioNote) -> URL { storage.audioURL(for: note) }
    func storageSize() -> Int64 { storage.storageSize() }
}

@MainActor
final class AudioNoteViewModel: ObservableObject {
    @Published var selectedInput = AudioNotePreferences.defaultInput
    @Published var diarizationEnabled = AudioNotePreferences.diarizationEnabled
    @Published var languageHint = AudioNotePreferences.languageHint
    @Published var errorMessage: String?
    @Published var showPhoneFallback = false
    @Published private(set) var currentNoteID: UUID?

    let recorder: AudioNoteRecorder
    private let storage: AudioNoteStorage
    private let library: AudioNoteLibrary

    convenience init() {
        self.init(
            recorder: AudioNoteRecorder(),
            storage: .shared,
            library: .shared
        )
    }

    init(
        recorder: AudioNoteRecorder,
        storage: AudioNoteStorage,
        library: AudioNoteLibrary
    ) {
        self.recorder = recorder
        self.storage = storage
        self.library = library
        recorder.onRouteLost = { [weak self] in
            self?.errorMessage = "audioNote.error.glassesDisconnected".localized
            self?.showPhoneFallback = true
        }
        recorder.onMaximumDuration = { [weak self] in self?.stop() }
    }

    func start() async {
        let granted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: granted = true
        case .denied: granted = false
        case .undetermined:
            granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: granted = false
        }
        guard granted else {
            errorMessage = "audioNote.error.permission".localized
            return
        }

        do {
            let id = UUID()
            let directory = try storage.directory(for: id)
            let audioURL = directory.appendingPathComponent("audio.m4a")
            try recorder.start(at: audioURL, input: selectedInput)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let languageHints = languageHint == "auto" ? [] : [languageHint]
            let note = AudioNote(
                id: id,
                title: String(format: "audioNote.defaultTitle".localized, formatter.string(from: Date())),
                createdAt: Date(),
                updatedAt: Date(),
                duration: 0,
                audioRelativePath: "\(id.uuidString)/audio.m4a",
                input: selectedInput,
                languageHints: languageHints,
                diarizationEnabled: diarizationEnabled,
                status: .recording,
                taskID: nil,
                remoteURL: nil,
                segments: [],
                speakerNames: [:],
                errorMessage: nil
            )
            currentNoteID = id
            library.save(note)
            AudioNotePreferences.defaultInput = selectedInput
            AudioNotePreferences.diarizationEnabled = diarizationEnabled
            AudioNotePreferences.languageHint = languageHint
        } catch AudioNoteRecorderError.inputUnavailable(.glasses) {
            showPhoneFallback = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func usePhoneAndStart() async {
        if recorder.isRecording { stop() }
        selectedInput = .iPhone
        showPhoneFallback = false
        await start()
    }

    func pauseOrResume() {
        recorder.isPaused ? recorder.resume() : recorder.pause()
    }

    func stop() {
        let duration = recorder.stop()
        guard let id = currentNoteID, var note = storage.note(id: id) else { return }
        note.duration = duration
        note.status = .saved
        note.updatedAt = Date()
        library.save(note)
        library.process(id)
    }
}
