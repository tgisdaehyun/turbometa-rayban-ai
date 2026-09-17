import SwiftUI
import MeetingCore

struct SettingsView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var meta: MetaConnection
    @Environment(\.dismiss) private var dismiss
    @AppStorage("transcriptionPace") private var transcriptionPace = "slow"
    @AppStorage("hostSyncEnabled") private var hostSyncEnabled = false
    @AppStorage("hostURL") private var hostURL = "https://100.126.27.18:8766"
    @State private var hostToken = ""
    @ObservedObject private var hostSync = HostSync.shared
    @AppStorage("viewMode") private var viewMode = "korean"
    @AppStorage("translationFontSize") private var fontSize = 32.0
    @AppStorage("keepScreenAwake") private var keepAwake = true
    @AppStorage("preferGlasses") private var preferGlasses = true
    @AppStorage("geminiModel") private var model = GeminiModels.defaultModel
    @AppStorage("readTranslations") private var readTranslations = false
    @AppStorage("speechRate") private var speechRate = 0.5
    @AppStorage("metaStreamingEnabled") private var metaStreamingEnabled = false
    @AppStorage("preferredInputUID") private var microphoneID = ""
    @State private var microphones: [AudioCapture.Microphone] = []
    @State private var models: [String] = []
    @State private var checking = false
    @State private var checkResult = ""
    @State private var microphoneResult = ""
    @State private var key = ""
    @State private var saved = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("표시 방식", selection: $viewMode) {
                        Text("한국어 크게").tag("korean")
                        Text("원문 + 번역").tag("bilingual")
                    }.pickerStyle(.segmented).accessibilityIdentifier("displayMode")
                    HStack { Text("한국어 글자 크기"); Spacer(); Text("\(Int(fontSize))").monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: $fontSize, in: 24...44, step: 2).accessibilityLabel("한국어 글자 크기")
                    Text("신호는 100밀리초마다 전송됩니다.").font(.system(size: CGFloat(fontSize))).padding(.vertical, 12)
                    Toggle("녹음 중 화면 켜 두기", isOn: $keepAwake)
                } header: { Text("화면") } footer: { Text("한국어 크게 보기에서도 중국어 원문은 저장됩니다. 내보내기에는 원문과 번역이 모두 포함됩니다.") }
                Section {
                    Toggle("Tailscale 원음 자동 백업", isOn: $hostSyncEnabled)
                        .onChange(of: hostSyncEnabled) { _, _ in hostSync.retry() }
                    TextField("호스트 주소", text: $hostURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("호스트 연결 키", text: $hostToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("연결 키 저장 · 백업 재시도") {
                        do {
                            guard HostDestination.validate(hostURL) != nil else { throw NSError(domain: "Host", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tailscale 주소를 확인해 주세요."]) }
                            if !hostToken.isEmpty { try Keychain.saveHostToken(hostToken); hostToken = "" }
                            hostSync.retry()
                        } catch { store.error = error.localizedDescription }
                    }
                    Button("호스트에서 한국어 번역 사용") { Task { await hostSync.configureTranslation() } }
                    Text("이 버튼을 누르면 앱의 Gemini 키를 지정된 호스트에 암호화 연결로 저장합니다. 사후 번역에는 텍스트만 Google로 전송합니다.").font(.caption).foregroundStyle(.secondary)
                    Text(hostSync.status).font(.caption)
                } header: { Text("호스트 백업") } footer: {
                    Text("Tailscale 연결 중 원음을 약 1분씩 묶어 전송합니다. 끊기면 보관 후 재시도하며 폰 원본은 삭제하지 않습니다. 앱을 강제 종료한 경우 다시 열어 주세요.")
                }
                Section("안경 · 마이크") {
                    Text(meta.status).font(.footnote)
                    Text(meta.permissionStatus).font(.footnote)
                    Text(meta.deviceStatus).font(.footnote)
                    DisclosureGroup("Meta 연결 진단") {
                        Text(meta.diagnostics.isEmpty ? "기록 없음" : meta.diagnostics).font(.caption.monospaced()).textSelection(.enabled)
                        ShareLink(item: meta.diagnostics) { Label("진단 공유", systemImage: "square.and.arrow.up") }
                    }
                    if meta.streamStarting { Button("연결 대기 취소") { meta.stopStreaming() } }
                    Button(meta.connecting ? "Meta 앱 승인 대기 중" : "Meta 앱 연결 승인") { Task { await meta.connect() } }.disabled(meta.connecting || store.activeID != nil)
                    if let error = meta.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    Toggle("회의 중 Meta 스트리밍 연결", isOn: $metaStreamingEnabled).disabled(store.activeID != nil || meta.streamStarting)
                    Text(meta.streamStatus).font(.footnote)
                    Button(meta.streamActive ? "Meta 스트리밍 중지" : "Meta 스트리밍 시작 · 권한 요청") {
                        Task { if meta.streamActive { meta.stopStreaming() } else { await meta.startStreaming() } }
                    }.disabled(!meta.registered || meta.streamStarting)
                    Text("Meta SDK 스트림은 카메라 권한을 요구하며 카메라가 켜질 수 있습니다. 영상은 표시·저장·전송하지 않고, 회의 음성은 Bluetooth 마이크로 받습니다. 장시간 회의에서는 이 옵션을 끄고 안경 마이크만 사용할 수도 있습니다.").font(.footnote).foregroundStyle(.secondary)
                    Toggle("Meta 안경 마이크 우선", isOn: $preferGlasses).disabled(store.activeID != nil)
                    Button("Bluetooth 마이크 확인") {
                        Task {
                            do { microphones = try await AudioCapture.microphones(); microphoneResult = microphones.isEmpty ? "Bluetooth 마이크가 없습니다. 안경을 착용하고 연결 상태를 확인해 주세요." : "마이크를 선택해 주세요." }
                            catch { microphoneResult = error.localizedDescription }
                        }
                    }.disabled(store.activeID != nil || store.starting)
                    if !microphones.isEmpty {
                        Picker("안경 마이크", selection: $microphoneID) {
                            Text("이름으로 자동 선택").tag("")
                            ForEach(microphones) { microphone in Text(microphone.name).tag(microphone.id) }
                        }.disabled(store.activeID != nil)
                    }
                    if !microphoneResult.isEmpty { Text(microphoneResult).font(.footnote) }
                    Text("Meta 앱에서 개발자 모드를 켜고 연결을 승인해 주세요. 마이크 사용은 iOS에서 별도로 허용합니다. 안경 입력이 없으면 iPhone 마이크로 자동 전환하며 실제 입력을 회의 화면에 표시합니다.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Picker("음성 처리 속도", selection: $transcriptionPace) {
                        ForEach(TranscriptionPace.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.segmented).disabled(store.activeID != nil || store.starting)
                } header: { Text("음성 처리 속도") } footer: { Text("빨리는 짧게 나누어 바로 처리하고, 느리게는 더 긴 문장을 모아 처리합니다. 새 회의를 시작할 때 적용됩니다.") }
                Section("번역 읽어주기") {
                    Toggle("Bluetooth 안경으로 한국어 읽기", isOn: $readTranslations).disabled(store.activeID != nil)
                    HStack { Text("읽기 속도"); Slider(value: $speechRate, in: 0.35...0.6, step: 0.05) }
                    Text("회의 중 새 한국어 번역이 나오면 Bluetooth 오디오로 읽습니다. 음성은 iPhone의 한국어 음성을 사용합니다. 번역이 도착하면 읽기 시작하며, 오래 밀린 번역은 읽지 않습니다. 에코 제거는 실제 안경에서 확인해야 합니다.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Gemini API") {
                    SecureField("API 키 변경 (선택)", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("apiKey")
                    Button(saved ? "키 저장됨" : "키 저장") { store.saveSettings(key: key); saved = store.hasKey }
                    Text(store.hasKey ? "API 키 준비됨 · 내장 키 또는 저장된 키 사용" : "API 키가 없습니다").font(.footnote)
                    TextField("모델 이름", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(store.activeID != nil || store.processing || checking)
                    Button(checking ? "확인 중…" : "이 키의 모델 목록 불러오기") {
                        Task {
                            checking = true; defer { checking = false }
                            do { models = try await GeminiModels.list(key: Keychain.read()); checkResult = "목록 조회 완료. 사용 한도와 음성 지원은 연결 테스트로 확인하세요." }
                            catch { checkResult = error.localizedDescription }
                        }
                    }.disabled(checking || store.processing)
                    if !models.isEmpty {
                        Picker("모델 선택", selection: $model) {
                            if !models.contains(model) { Text(model).tag(model) }
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }.disabled(store.activeID != nil || store.processing || checking)
                    }
                    Button("음성 API 연결 테스트") {
                        Task {
                            checking = true; defer { checking = false }
                            do {
                                guard let fixture = Bundle.main.url(forResource: "mandarin", withExtension: "wav") else { throw GeminiFailure("연결 테스트 음성을 찾을 수 없습니다.") }
                                let audio = try Data(contentsOf: fixture)
                                _ = try await GeminiClient().transcribe(audio: audio, duration: 4.93, model: model, key: Keychain.read(), glossary: "")
                                checkResult = "연결 성공 · \(model) 음성 요청과 응답 형식 확인 완료"
                            } catch { checkResult = error.localizedDescription }
                        }
                    }.disabled(checking || store.processing)
                    if !checkResult.isEmpty { Text(checkResult).font(.footnote).textSelection(.enabled) }
                    Text("연결 테스트는 앱에 포함된 짧은 합성 중국어 음성을 Google로 보냅니다. 음성 인식 품질은 실제 회의에서 확인해야 합니다. 녹음한 음성은 선택한 Gemini 모델로 전송됩니다.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("녹음과 보관") {
                    Text("선택한 속도에 따라 음성을 모아 전사합니다. 표시까지 녹음 시간과 API 처리 시간이 필요합니다. 연결이 끊기면 음성을 보관하고 ‘다시 전사’로 이어갑니다.")
                    Text("화면을 잠가도 녹음하도록 구성했습니다. 통화나 오디오 장치 전환으로 생기는 공백은 회의 상태 기록에 남습니다.")
                    Text("음성 WAV와 회의 JSON은 파일 앱 → 나의 iPhone → MetaMeet에서 찾을 수 있습니다. 회의를 삭제하기 전까지 보관합니다.")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden).background(.black)
            .navigationTitle("설정").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            .onAppear { key = Keychain.storedKey() }
        }.preferredColorScheme(.dark).tint(.white)
    }
}
