/*
 * Live Translate Settings View
 * 实时翻译设置界面
 */

import SwiftUI

struct LiveTranslateSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: LiveTranslateViewModel
    @State private var showClearHistoryConfirmation = false

    var body: some View {
        NavigationView {
            List {
                // 源语言
                Section {
                    ForEach(TranslateLanguage.sourceLanguages) { language in
                        Button {
                            viewModel.sourceLanguage = language
                        } label: {
                            HStack {
                                Text(language.flag)
                                    .font(.title2)
                                Text(language.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if viewModel.sourceLanguage == language {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("livetranslate.settings.sourceLanguage".localized)
                }

                // 目标语言
                Section {
                    ForEach(TranslateLanguage.targetLanguages) { language in
                        Button {
                            viewModel.targetLanguage = language
                        } label: {
                            HStack {
                                Text(language.flag)
                                    .font(.title2)
                                Text(language.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if viewModel.targetLanguage == language {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("livetranslate.settings.targetLanguage".localized)
                } footer: {
                    Text("livetranslate.settings.targetLanguage.footer".localized)
                }

                // 音色选择
                Section {
                    ForEach(TranslateVoice.allCases) { voice in
                        Button {
                            viewModel.selectedVoice = voice
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(voice.displayName)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if viewModel.selectedVoice == voice {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                    }
                                }
                                Text(voice.description)
                                    .font(AppTypography.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .disabled(!voice.supports(language: viewModel.targetLanguage))
                        .opacity(voice.supports(language: viewModel.targetLanguage) ? 1.0 : 0.5)
                    }
                } header: {
                    Text("livetranslate.settings.voice".localized)
                } footer: {
                    Text("livetranslate.settings.voice.footer".localized)
                }

                // 麦克风选择
                Section {
                    Toggle(isOn: $viewModel.usePhoneMic) {
                        HStack {
                            Image(systemName: viewModel.usePhoneMic ? "iphone" : "airpodsmax")
                                .foregroundColor(.purple)
                            Text("livetranslate.settings.usePhoneMic".localized)
                        }
                    }
                } header: {
                    Text("livetranslate.settings.microphone".localized)
                } footer: {
                    Text("livetranslate.settings.microphone.footer".localized)
                }

                // 输出选项
                Section {
                    Toggle(isOn: $viewModel.audioOutputEnabled) {
                        HStack {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundColor(.blue)
                            Text("livetranslate.settings.audioOutput".localized)
                        }
                    }
                    .disabled(!viewModel.targetLanguage.supportsAudioOutput)
                    .opacity(viewModel.targetLanguage.supportsAudioOutput ? 1.0 : 0.5)

                    Toggle(isOn: $viewModel.imageEnhanceEnabled) {
                        HStack {
                            Image(systemName: "eye.fill")
                                .foregroundColor(.green)
                            Text("livetranslate.settings.imageEnhance".localized)
                        }
                    }
                } header: {
                    Text("livetranslate.settings.output".localized)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("livetranslate.settings.audioOutput.footer".localized)
                        Text("livetranslate.settings.imageEnhance.footer".localized)
                    }
                }

                // 历史记录
                if viewModel.historyRecordCount > 0 {
                    Section {
                        Button(role: .destructive) {
                            showClearHistoryConfirmation = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("livetranslate.settings.clearHistory".localized)
                            }
                        }
                    } header: {
                        Text("livetranslate.settings.history".localized)
                    } footer: {
                        Text(String(format: "livetranslate.settings.historyCount".localized, viewModel.historyRecordCount))
                    }
                }
            }
            .navigationTitle("livetranslate.settings.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done".localized) {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "livetranslate.settings.clearHistory.confirm.title".localized,
                isPresented: $showClearHistoryConfirmation,
                titleVisibility: .visible
            ) {
                Button("livetranslate.settings.clearHistory".localized, role: .destructive) {
                    viewModel.clearHistory()
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("livetranslate.settings.clearHistory.confirm.message".localized)
            }
        }
    }
}

#Preview {
    LiveTranslateSettingsView(viewModel: LiveTranslateViewModel())
}
