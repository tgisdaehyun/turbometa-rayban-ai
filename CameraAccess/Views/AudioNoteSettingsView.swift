import SwiftUI

struct AudioNoteSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = AudioNoteLibrary.shared
    @State private var input = AudioNotePreferences.defaultInput
    @State private var diarization = AudioNotePreferences.diarizationEnabled
    @State private var language = AudioNotePreferences.languageHint
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("audioNote.settings.defaultInput".localized, selection: $input) {
                        Text("audioNote.input.glasses".localized).tag(AudioNoteInput.glasses)
                        Text("audioNote.input.phone".localized).tag(AudioNoteInput.iPhone)
                    }
                    Toggle("audioNote.diarization".localized, isOn: $diarization)
                    Picker("audioNote.language".localized, selection: $language) {
                        Text("audioNote.language.auto".localized).tag("auto")
                        Text("中文").tag("zh")
                        Text("English").tag("en")
                        Text("日本語").tag("ja")
                        Text("한국어").tag("ko")
                    }
                } header: {
                    Text("audioNote.settings.recording".localized)
                } footer: {
                    Text("audioNote.settings.footer".localized)
                }

                Section("audioNote.settings.storage".localized) {
                    LabeledContent("audioNote.settings.count".localized, value: "\(library.notes.count)")
                    LabeledContent("audioNote.settings.size".localized, value: ByteCountFormatter.string(fromByteCount: library.storageSize(), countStyle: .file))
                    Button("audioNote.settings.clear".localized, role: .destructive) { confirmClear = true }
                }
            }
            .navigationTitle("audioNote.settings.title".localized)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done".localized) { dismiss() } } }
            .onChange(of: input) { _, value in AudioNotePreferences.defaultInput = value }
            .onChange(of: diarization) { _, value in AudioNotePreferences.diarizationEnabled = value }
            .onChange(of: language) { _, value in AudioNotePreferences.languageHint = value }
            .confirmationDialog("audioNote.settings.clearConfirm".localized, isPresented: $confirmClear) {
                Button("audioNote.settings.clear".localized, role: .destructive) { library.clearAll() }
                Button("common.cancel".localized, role: .cancel) {}
            }
        }
    }
}
