import AVFoundation
import SwiftUI
import UIKit

struct AudioNoteRecordsView: View {
    @Binding var isSelectionMode: Bool
    @Binding var selectedIDs: Set<UUID>
    @ObservedObject private var library = AudioNoteLibrary.shared
    @State private var selectedNote: AudioNote?
    @State private var notePendingDeletion: AudioNote?
    @State private var showsDeleteConfirmation = false

    var body: some View {
        Group {
            if library.notes.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "waveform.badge.mic").font(.system(size: 58)).foregroundStyle(.secondary)
                    Text("audioNote.records.empty".localized).font(.title3.bold())
                    Text("audioNote.records.emptyDetail".localized).foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        RecordListScrollMarker(category: .audioNote)

                        ForEach(library.notes) { note in
                            HStack(spacing: AppSpacing.sm) {
                                if isSelectionMode {
                                    RecordSelectionIndicator(isSelected: selectedIDs.contains(note.id))
                                }

                                AudioNoteRow(note: note)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSelectionMode {
                                    toggleSelection(for: note.id)
                                } else {
                                    selectedNote = note
                                }
                            }
                            .contextMenu {
                                if !isSelectionMode {
                                    Button(role: .destructive) {
                                        notePendingDeletion = note
                                        showsDeleteConfirmation = true
                                    } label: {
                                        Label("common.delete".localized, systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.bottom, RecordsLayout.bottomContentPadding)
                }
                .refreshable { library.reload() }
            }
        }
        .recordsListTopSpacing()

        .background(Color.black.ignoresSafeArea())
//        .ignoresSafeArea(edges: .bottom)
        .onAppear { library.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .recordsBatchDeleteRequested)) { notification in
            guard let request = notification.object as? RecordBatchDeleteRequest,
                  request.category == .audioNote else { return }
            request.ids.forEach { library.delete($0) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordsSelectAllRequested)) { notification in
            guard let request = notification.object as? RecordSelectAllRequest,
                  request.category == .audioNote else { return }
            selectedIDs.formUnion(library.notes.map(\.id))
        }
        .confirmationDialog(
            "records.delete.title".localized,
            isPresented: $showsDeleteConfirmation
        ) {
            Button("records.delete.confirm".localized, role: .destructive) {
                guard let notePendingDeletion else { return }
                library.delete(notePendingDeletion.id)
                self.notePendingDeletion = nil
            }
            Button("common.cancel".localized, role: .cancel) {
                notePendingDeletion = nil
            }
        } message: {
            Text("records.delete.message".localized)
        }
        .sheet(item: $selectedNote) { note in
            AudioNoteDetailView(noteID: note.id) {
                selectedNote = nil
            }
        }
    }

    private func toggleSelection(for id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

private struct AudioNoteRow: View {
    let note: AudioNote

    var body: some View {
        UnifiedRecordCard(
            icon: "waveform.badge.mic",
            tint: .red,
            title: note.title,
            summary: note.transcript.isEmpty ? "audioNote.records.noTranscript".localized : note.transcript,
            metadata: metadata,
            badge: RecordCardBadge(
                text: "audioNote.status.\(note.status.rawValue)".localized,
                color: statusColor
            )
        )
    }

    private var metadata: [RecordCardMetadata] {
        var values = [
            RecordCardMetadata(
                icon: "clock",
                text: note.createdAt.formatted(date: .abbreviated, time: .shortened)
            ),
            RecordCardMetadata(icon: "timer", text: formatDuration(note.duration))
        ]
        if note.speakerCount > 0 {
            values.append(RecordCardMetadata(icon: "person.2", text: "\(note.speakerCount)"))
        }
        return values
    }

    private var statusColor: Color {
        switch note.status {
        case .failed: return .red
        case .completed: return .green
        case .uploading, .transcribing, .organizing: return .orange
        case .recording: return .red
        case .saved: return AppColors.textSecondary
        }
    }
}

struct AudioNoteDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = AudioNoteLibrary.shared
    let noteID: UUID
    let onDelete: (() -> Void)?
    @StateObject private var player = AudioNotePlayer()
    @State private var draftTitle = ""
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var speakerBeingRenamed: Int?
    @State private var speakerNameDraft = ""
    @State private var confirmsDeletion = false

    init(noteID: UUID, onDelete: (() -> Void)? = nil) {
        self.noteID = noteID
        self.onDelete = onDelete
    }

    private var note: AudioNote? { library.note(id: noteID) }

    var body: some View {
        NavigationStack {
            Group {
                if let note {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 16) {
                                titleEditor(note)
                                playback(note)
                                processing(note)
                                LazyVStack(spacing: 12) {
                                    ForEach(note.segments) { segment in
                                        segmentCard(note, segment: segment)
                                            .id(segment.id)
                                    }
                                }
                            }
                            .padding()
                        }
                        .onChange(of: player.currentTime) { _, value in
                            guard let active = note.segments.first(where: {
                                Double($0.beginTimeMs) / 1000 <= value && value <= Double($0.endTimeMs) / 1000
                            }) else { return }
                            withAnimation { proxy.scrollTo(active.id, anchor: .center) }
                        }
                    }
                } else {
                    ContentUnavailableView("audioNote.records.missing".localized, systemImage: "waveform.slash")
                }
            }
            .navigationTitle("audioNote.detail.title".localized)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                if let note {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("audioNote.export.audio".localized) { shareAudio(note) }
                            Button("audioNote.export.text".localized) { shareText(note, srt: false) }
                            Button("audioNote.export.srt".localized) { shareText(note, srt: true) }
                        } label: { Image(systemName: "square.and.arrow.up") }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        confirmsDeletion = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .tint(.red)
                }
            }
            .onAppear {
                guard let note else { return }
                draftTitle = note.title
                player.load(url: library.audioURL(for: note))
            }
            .onDisappear { player.stop() }
            .sheet(isPresented: $showShare) { AudioNoteShareSheet(items: shareItems) }
            .confirmationDialog(
                "records.delete.title".localized,
                isPresented: $confirmsDeletion
            ) {
                Button("records.delete.confirm".localized, role: .destructive) {
                    player.stop()
                    library.delete(noteID)
                    onDelete?()
                    dismiss()
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("records.delete.message".localized)
            }
            .alert("audioNote.playback.errorTitle".localized, isPresented: Binding(
                get: { player.errorMessage != nil },
                set: { if !$0 { player.errorMessage = nil } }
            )) {
                Button("common.ok".localized, role: .cancel) {}
            } message: {
                Text(player.errorMessage ?? "")
            }
            .alert("audioNote.renameSpeaker".localized, isPresented: Binding(
                get: { speakerBeingRenamed != nil },
                set: { if !$0 { speakerBeingRenamed = nil } }
            )) {
                TextField("audioNote.speakerName".localized, text: $speakerNameDraft)
                Button("common.done".localized) {
                    if let speaker = speakerBeingRenamed {
                        library.updateSpeakerName(noteID, speakerID: speaker, name: speakerNameDraft)
                    }
                    speakerBeingRenamed = nil
                }
                Button("common.cancel".localized, role: .cancel) { speakerBeingRenamed = nil }
            }
        }
    }

    private func titleEditor(_ note: AudioNote) -> some View {
        TextField("audioNote.title.placeholder".localized, text: $draftTitle)
            .font(.title2.bold())
            .textFieldStyle(.roundedBorder)
            .onSubmit { library.updateTitle(note.id, title: draftTitle) }
            .onChange(of: draftTitle) { _, value in library.updateTitle(note.id, title: value) }
    }

    private func playback(_ note: AudioNote) -> some View {
        VStack(spacing: 10) {
            Slider(value: Binding(get: { player.currentTime }, set: player.seek), in: 0...max(note.duration, 0.1))
            HStack {
                Text(formatDuration(player.currentTime))
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 46))
                }
                Spacer()
                Menu("\(String(format: "%.1f", player.rate))×") {
                    ForEach([0.5, 1, 1.5, 2], id: \.self) { rate in
                        Button("\(String(format: "%.1f", rate))×") { player.setRate(Float(rate)) }
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding().background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func processing(_ note: AudioNote) -> some View {
        if note.status.isProcessing || note.status == .failed || note.status == .saved {
            HStack {
                if note.status.isProcessing { ProgressView() }
                VStack(alignment: .leading) {
                    Text("audioNote.status.\(note.status.rawValue)".localized).font(.headline)
                    if let error = note.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Spacer()
                if note.status == .failed || note.status == .saved {
                    Button("audioNote.retry".localized) { library.retry(note.id) }
                }
            }
            .padding().background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func segmentCard(_ note: AudioNote, segment: AudioTranscriptSegment) -> some View {
        let active = player.currentTime >= Double(segment.beginTimeMs) / 1000 && player.currentTime <= Double(segment.endTimeMs) / 1000
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let speaker = segment.speakerID {
                    Button {
                        speakerNameDraft = note.speakerNames[String(speaker)] ?? String(format: "audioNote.speaker".localized, speaker + 1)
                        speakerBeingRenamed = speaker
                    } label: {
                        Label(
                            note.speakerNames[String(speaker)] ?? String(format: "audioNote.speaker".localized, speaker + 1),
                            systemImage: "pencil"
                        )
                        .font(.caption.bold())
                    }
                }
                Spacer()
                Text(formatTimestamp(segment.beginTimeMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            TextEditor(text: Binding(
                get: { segment.editedText },
                set: { library.updateSegment(note.id, segmentID: segment.id, text: $0) }
            ))
            .frame(minHeight: 54)
            .scrollContentBackground(.hidden)
        }
        .padding()
        .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .onTapGesture { player.seek(Double(segment.beginTimeMs) / 1000) }
    }

    private func shareAudio(_ note: AudioNote) {
        shareItems = [library.audioURL(for: note)]
        showShare = true
    }

    private func shareText(_ note: AudioNote, srt: Bool) {
        let value = srt ? SRTExporter.export(note.segments) : note.transcript
        let ext = srt ? "srt" : "txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(note.title).\(ext)")
        try? value.write(to: url, atomically: true, encoding: .utf8)
        shareItems = [url]
        showShare = true
    }
}

@MainActor
private final class AudioNotePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var rate: Float = 1
    @Published var errorMessage: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.delegate = self
            guard player.prepareToPlay() else {
                throw AudioNotePlaybackError.cannotPrepare
            }
            self.player = player
            print("🔊 [AudioNote] loaded playback file duration=\(player.duration), url=\(url.path)")
        } catch {
            player = nil
            errorMessage = error.localizedDescription
            print("❌ [AudioNote] playback load failed: \(error)")
        }
    }
    func toggle() { isPlaying ? pause() : play() }
    func play() {
        guard let player else {
            errorMessage = AudioNotePlaybackError.fileUnavailable.localizedDescription
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            player.rate = rate
            guard player.play() else { throw AudioNotePlaybackError.cannotStart }
            isPlaying = true
            print("🔊 [AudioNote] playback started route=\(session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" })")
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.currentTime = self?.player?.currentTime ?? 0 }
            }
        } catch {
            isPlaying = false
            errorMessage = error.localizedDescription
            print("❌ [AudioNote] playback start failed: \(error)")
        }
    }
    func pause() { player?.pause(); isPlaying = false; timer?.invalidate() }
    func stop() {
        player?.stop()
        timer?.invalidate()
        isPlaying = false
        deactivateSession()
    }
    func seek(_ time: TimeInterval) { player?.currentTime = time; currentTime = time }
    func setRate(_ value: Float) { rate = value; player?.rate = value }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.timer?.invalidate()
            self?.deactivateSession()
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private enum AudioNotePlaybackError: LocalizedError {
    case fileUnavailable
    case cannotPrepare
    case cannotStart

    var errorDescription: String? {
        switch self {
        case .fileUnavailable: return "audioNote.playback.fileUnavailable".localized
        case .cannotPrepare: return "audioNote.playback.cannotPrepare".localized
        case .cannotStart: return "audioNote.playback.cannotStart".localized
        }
    }
}
enum SRTExporter {
    static func export(_ segments: [AudioTranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(srtTime(segment.beginTimeMs)) --> \(srtTime(segment.endTimeMs))\n\(segment.editedText)"
        }.joined(separator: "\n\n")
    }
    private static func srtTime(_ milliseconds: Int) -> String {
        let ms = max(0, milliseconds)
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1_000) % 60, ms % 1_000)
    }
}

private func formatTimestamp(_ milliseconds: Int) -> String {
    let seconds = max(0, milliseconds / 1000)
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

private struct AudioNoteShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
