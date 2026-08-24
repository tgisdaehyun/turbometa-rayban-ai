import SwiftUI

struct AudioNoteView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = AudioNoteViewModel()
    @ObservedObject private var library = AudioNoteLibrary.shared
    @State private var confirmClose = false
    @State private var selectedNote: AudioNote?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                header
                statusPanel
                Spacer()
                AudioNoteMeter(recorder: viewModel.recorder)
                timer
                Spacer()
                controls
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .preferredColorScheme(.dark)
        .alert("audioNote.error.title".localized, isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog("audioNote.fallback.title".localized, isPresented: $viewModel.showPhoneFallback) {
            Button("audioNote.fallback.usePhone".localized) {
                Task { await viewModel.usePhoneAndStart() }
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text("audioNote.fallback.message".localized)
        }
        .confirmationDialog("audioNote.close.title".localized, isPresented: $confirmClose) {
            Button("audioNote.stopAndClose".localized, role: .destructive) {
                viewModel.stop()
                dismiss()
            }
            Button("common.cancel".localized, role: .cancel) {}
        }
        .sheet(item: $selectedNote) { note in
            AudioNoteDetailView(noteID: note.id)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("audioNote.title".localized)
                    .font(.title.bold())
                Text("audioNote.consent".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                viewModel.recorder.isRecording ? (confirmClose = true) : dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title)
            }
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.top, 12)
    }

    private var statusPanel: some View {
        VStack(spacing: 14) {
            HStack {
                Label(
                    viewModel.selectedInput == .glasses ? "audioNote.input.glasses".localized : "audioNote.input.phone".localized,
                    systemImage: viewModel.selectedInput == .glasses ? "eyeglasses" : "iphone"
                )
                Spacer()
                if !viewModel.recorder.isRecording {
                    Picker("", selection: $viewModel.selectedInput) {
                        Text("audioNote.input.glasses".localized).tag(AudioNoteInput.glasses)
                        Text("audioNote.input.phone".localized).tag(AudioNoteInput.iPhone)
                    }
                    .pickerStyle(.menu)
                }
            }
            if viewModel.selectedInput == .glasses {
                HStack(spacing: 8) {
                    Circle()
                        .fill(viewModel.recorder.isGlassesInputAvailable ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(viewModel.recorder.isGlassesInputAvailable
                         ? "audioNote.glasses.connected".localized
                         : "audioNote.glasses.unavailable".localized)
                        .font(.caption)
                    Spacer()
                }
            }
            if let inputName = viewModel.recorder.activeInputName {
                HStack {
                    Text("audioNote.actualInput".localized).foregroundStyle(.secondary)
                    Spacer()
                    Text(inputName).lineLimit(1)
                }
                .font(.caption)
            }
            Divider().overlay(.white.opacity(0.15))
            Toggle("audioNote.diarization".localized, isOn: $viewModel.diarizationEnabled)
                .disabled(viewModel.recorder.isRecording)
            if !viewModel.recorder.isRecording {
                Picker("audioNote.language".localized, selection: $viewModel.languageHint) {
                    Text("audioNote.language.auto".localized).tag("auto")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                }
            }
            if let note = currentNote, !viewModel.recorder.isRecording {
                Divider().overlay(.white.opacity(0.15))
                HStack {
                    ProgressView().opacity(note.status.isProcessing ? 1 : 0)
                    Text(statusText(note.status)).font(.subheadline)
                    Spacer()
                    Button("audioNote.viewRecord".localized) { selectedNote = note }
                }
            }
        }
        .padding(18)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
    }

    private var currentNote: AudioNote? {
        guard let id = viewModel.currentNoteID else { return nil }
        return library.note(id: id)
    }

    private var timer: some View {
        AudioNoteTimer(recorder: viewModel.recorder)
    }

    private var controls: some View {
        HStack(spacing: 46) {
            if viewModel.recorder.isRecording {
                Button(action: viewModel.pauseOrResume) {
                    Image(systemName: viewModel.recorder.isPaused ? "play.fill" : "pause.fill")
                        .font(.title2).frame(width: 58, height: 58)
                        .background(.white.opacity(0.14), in: Circle())
                }
                Button(action: viewModel.stop) {
                    Image(systemName: "stop.fill")
                        .font(.title).frame(width: 90, height: 90)
                        .background(Color.red, in: Circle())
                }
            } else {
                Button { Task { await viewModel.start() } } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 36)).frame(width: 100, height: 100)
                        .background(Color.red, in: Circle())
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func statusText(_ status: AudioNoteStatus) -> String {
        "audioNote.status.\(status.rawValue)".localized
    }
}

private struct AudioNoteTimer: View {
    @ObservedObject var recorder: AudioNoteRecorder

    var body: some View {
        HStack(spacing: 12) {
            timeMetric(
                title: "audioNote.elapsed".localized,
                value: formatDuration(recorder.elapsed),
                color: .white
            )
            timeMetric(
                title: "audioNote.remainingTitle".localized,
                value: formatDuration(AudioNoteRecorder.maximumDuration - recorder.elapsed),
                color: .secondary
            )
        }
    }

    private func timeMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 27, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct AudioNoteMeter: View {
    @ObservedObject var recorder: AudioNoteRecorder

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(recorder.meterSamples.enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(waveformColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(4, 72 * CGFloat(sample)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .padding(.horizontal, 4)
        .accessibilityLabel("audioNote.waveform".localized)
        .animation(.linear(duration: 0.05), value: recorder.meterSamples)
    }

    private var waveformColor: Color {
        guard recorder.isRecording else { return .gray.opacity(0.55) }
        return recorder.isPaused ? .orange.opacity(0.75) : .red
    }
}

func formatDuration(_ duration: TimeInterval) -> String {
    let value = max(0, Int(duration))
    return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
}
