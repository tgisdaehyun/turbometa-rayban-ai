# MetaMeet

iPhone + Meta 안경으로 중국 기술팀 회의를 녹음하고, Gemini로 중국어 원문과 한국어 번역을 순서대로 표시하는 SwiftUI 앱입니다. iOS 17 이상이 필요합니다.

검은 배경과 흰 글씨를 사용합니다. 기본 화면은 **한국어 크게 보기**이며 설정에서 **원문 + 번역**으로 바꿀 수 있습니다. 글자 크기는 24–44pt로 조절합니다. 표시 방식과 관계없이 원문과 번역을 모두 저장하고 내보냅니다.

## 사용

1. 빌드한 `MetaMeet.ipa`를 Sideloadly 등으로 본인 Apple ID로 서명하여 설치합니다. CI 산출물은 서명되지 않았습니다.
2. Meta 앱에서 안경을 iPhone에 페어링합니다. 앱 설정에 본인 Gemini API 키를 저장합니다. 기본 모델은 `gemini-2.5-flash`이며 변경할 수 있습니다.
3. **회의 시작**을 누르고 최초 마이크 권한을 허용합니다. 화면에 실제 입력 장치 이름이 표시되는지 확인합니다.
4. 약 15초 분량의 녹음이 쌓이면 전사합니다. 첫 표시까지 약 15초 + Gemini 처리 시간이 필요합니다. 초단위 동시통역 방식은 아닙니다.
5. **회의 종료** 후 남은 구간을 처리합니다. 공유 버튼으로 원문/번역 Markdown 회의록을 내보냅니다. 지난 회의는 시계 버튼에서 엽니다.

안경 마이크는 iOS Bluetooth HFP를 사용합니다. 안경 이름을 우선 선택하고, 다른 HFP 마이크 또는 iPhone 마이크로 대체될 수 있으므로 화면의 실제 장치를 확인하세요. 카메라와 Meta DAT 스트리밍 권한은 사용하지 않습니다. 설정에서 안경 우선 선택을 끌 수 있습니다.

## 보관 및 장애 복구

- 16 kHz 모노 PCM16 WAV를 15초 단위로 로컬에 저장합니다. 약 1.9 MB/분, 115 MB/시간입니다.
- 파일 앱 → 나의 iPhone → MetaMeet → MetaMeet → 회의 UUID 폴더에 WAV와 `meeting.json`이 있습니다.
- API 키는 이 기기의 Keychain에만 저장합니다. Google Gemini HTTPS 요청 헤더로 전송하며 URL이나 로그에 기록하지 않습니다.
- 녹음 음성과 기술 용어 설정은 사용자가 지정한 Gemini 모델로 전송됩니다. Google의 API 데이터 취급 조건과 요금은 사용하는 계정/서비스 설정을 따릅니다. 별도 자체 서버나 분석 SDK는 없습니다.
- 네트워크/한도 오류 시 유한 재시도 후 전사 큐를 멈춥니다. 녹음은 계속 로컬에 보관합니다. 문제 해결 후 **다시 전사**를 누릅니다.
- 앱 재실행 시 중단된 WAV 헤더와 큐 상태를 복구합니다. 과거 녹음은 사용자가 다시 전사를 눌러 처리합니다.
- 화면 잠금 녹음을 위한 background audio가 설정되어 있습니다. 통화, Bluetooth 전환, iOS 강제 종료 등의 공백은 복원할 수 없으며 상태 기록을 남깁니다. 실제 iPhone/안경에서 잠금·전환 시험이 필요합니다.
- 화자 식별은 각 15초 구간 안에서만 유효합니다. 시간과 전사/번역은 AI 추정이므로 부품 번호, 수치 등은 원문 음성과 확인하세요.
- 지난 회의의 삭제 기능은 음성과 회의록을 함께 삭제합니다.

## 빌드와 검증

macOS + Xcode + XcodeGen:

```sh
swift test --package-path MetaMeet/Core
cd MetaMeet
xcodegen generate
xcodebuild -project MetaMeet.xcodeproj -scheme MetaMeet -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

`.github/workflows/build-metameet.yml`은 전사 파싱, 범위 검증, WAV 복구, 내보내기, Gemini 요청/응답 테스트를 실행하고 시뮬레이터 화면 및 unsigned IPA를 아티팩트로 보관합니다. `--preview` 실행은 합성 회의록을 표시하며 실제 마이크나 API를 사용하지 않습니다.

실제 Gemini API, 안경 HFP 입력, 장시간 녹음, 화면 잠금은 사용자 기기와 API 키가 있어야 검증할 수 있습니다.

## 참고한 프로젝트

기존 TurboMeta를 변경하지 않고 별도 앱/타깃으로 추가했습니다.

- [TurboMeta](https://github.com/tgisdaehyun/turbometa-rayban-ai): Gemini 연결 및 iOS 오디오 구성 참고.
- 같은 저장소의 `metarec` 브랜치: 안경 HFP 선택, 오디오 route-change 재진입 회피, 녹음 수명 관리 참고.
- 같은 저장소의 `visionclaw` 브랜치: iPhone/Meta 음성 처리 구성 참고.
- [Gemini 음성 이해](https://ai.google.dev/gemini-api/docs/audio), [구조화 출력](https://ai.google.dev/gemini-api/docs/structured-output).

앱은 자체 SwiftUI 화면과 AVAudioEngine 녹음기, REST 전사 클라이언트로 구현했습니다. 기존 앱의 스트리밍/카메라 의존성은 포함하지 않습니다.
