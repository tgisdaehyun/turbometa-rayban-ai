import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("viewMode") private var viewMode = "korean"
    @AppStorage("translationFontSize") private var fontSize = 32.0
    @AppStorage("keepScreenAwake") private var keepAwake = true
    @AppStorage("preferGlasses") private var preferGlasses = true
    @AppStorage("geminiModel") private var model = "gemini-2.5-flash"
    @AppStorage("glossary") private var glossary = "CAN, CAN FD, ECU, i.MX95, i.MX8MP, R818, LVDS, HDMI, MCU"
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
                Section("마이크") {
                    Toggle("Meta 안경 마이크 우선", isOn: $preferGlasses).disabled(store.activeID != nil)
                    Text("Meta AI 앱에서 안경을 iPhone과 페어링해 주세요. Bluetooth 마이크를 선택하며, 사용할 수 없으면 iPhone 마이크로 녹음합니다. 실제 입력 장치는 회의 화면에 표시됩니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Gemini API") {
                    SecureField("API 키", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("apiKey")
                    Button(saved ? "키 저장됨" : "키 저장") { store.saveSettings(key: key); saved = store.hasKey }
                    TextField("모델 이름", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(store.activeID != nil || store.processing)
                    Text("키는 이 iPhone의 키체인에 저장합니다. 녹음한 음성을 Google Gemini로 전송해 중국어 전사와 한국어 번역을 만듭니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    TextEditor(text: $glossary).frame(minHeight: 90).autocorrectionDisabled()
                } header: { Text("기술 용어") } footer: { Text("부품 번호, 프로젝트 이름, CAN ID 등을 쉼표로 적으면 인식에 참고합니다. 최대 4,000자까지 사용합니다.") }
                Section("녹음과 보관") {
                    Text("약 15초 단위로 전사하므로 표시까지 녹음 시간과 API 처리 시간이 필요합니다. 연결이 끊기면 음성을 보관하고 ‘다시 전사’로 이어갑니다.")
                    Text("화면을 잠가도 녹음하도록 구성했습니다. 통화나 오디오 장치 전환으로 생기는 공백은 회의 상태 기록에 남습니다.")
                    Text("음성 WAV와 회의 JSON은 파일 앱 → 나의 iPhone → MetaMeet에서 찾을 수 있습니다. 회의를 삭제하기 전까지 보관합니다.")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden).background(.black)
            .navigationTitle("설정").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            .onAppear { key = Keychain.read() }
        }.preferredColorScheme(.dark).tint(.white)
    }
}
