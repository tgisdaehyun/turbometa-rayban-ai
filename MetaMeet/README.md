# MetaMeet

iPhone + Meta 안경으로 중국 기술팀 회의를 녹음하고, Gemini로 중국어 원문과 한국어 번역을 순서대로 표시하는 SwiftUI 앱입니다. iOS 17 이상이 필요합니다.

검은 배경과 흰 글씨를 사용합니다. 기본 화면은 **한국어 크게 보기**이며 설정에서 **원문 + 번역**으로 바꿀 수 있습니다. 글자 크기는 24–44pt로 조절합니다. 표시 방식과 관계없이 원문과 번역을 모두 저장하고 내보냅니다.

## 사용

1. 빌드한 `MetaMeet.ipa`를 Sideloadly 등으로 본인 Apple ID로 서명하여 설치합니다. CI 산출물은 서명되지 않았습니다.
2. Meta 앱에서 안경을 iPhone에 페어링합니다. 앱 설정에 본인 Gemini API 키를 저장합니다. 기본 모델은 `gemini-3.6-flash`이며 변경할 수 있습니다.
3. **회의 시작**을 누르고 최초 마이크 권한을 허용합니다. 화면에 실제 입력 장치 이름이 표시되는지 확인합니다.
4. 약 2초 분량의 녹음이 쌓이면 전사합니다. 첫 표시까지 약 2초 + Gemini 처리 시간이 필요합니다. 초단위 동시통역 방식은 아닙니다.
5. **회의 종료** 후 남은 구간을 처리합니다. 공유 버튼으로 원문/번역 Markdown 회의록을 내보냅니다. 지난 회의는 시계 버튼에서 엽니다.

안경 마이크는 iOS Bluetooth HFP를 사용합니다. 안경 이름을 우선 선택하고, 다른 HFP 마이크 또는 iPhone 마이크로 대체될 수 있으므로 화면의 실제 장치를 확인하세요. Meta DAT 0.8.0의 연결 승인을 지원합니다. 선택적 Meta 스트리밍은 카메라 권한을 요청하지만 영상은 보관하거나 전송하지 않습니다. SDK에는 오디오 전용 스트림이 없어 실제 오디오는 iOS Bluetooth HFP로 받습니다. 설정에서 안경 우선 선택을 끌 수 있습니다.

## 보관 및 장애 복구

- 16 kHz 모노 PCM16 WAV를 2초 단위로 로컬에 저장합니다. 약 1.9 MB/분, 115 MB/시간입니다.
- 파일 앱 → 나의 iPhone → MetaMeet → MetaMeet → 회의 UUID 폴더에 WAV와 `meeting.json`이 있습니다.
- 개인용 IPA에는 사용자 요청으로 로컬 패키징 시 API 키가 내장됩니다. 변경한 키는 이 기기의 Keychain에 저장합니다. Google Gemini HTTPS 요청 헤더로 전송하며 URL이나 로그에 기록하지 않습니다.
- 녹음 음성과 기술 용어 설정은 사용자가 지정한 Gemini 모델로 전송됩니다. Google의 API 데이터 취급 조건과 요금은 사용하는 계정/서비스 설정을 따릅니다. 자체 서버는 없습니다. Meta SDK의 분석/크래시 수집은 설정에서 끕니다.
- 네트워크/한도 오류 시 유한 재시도 후 전사 큐를 멈춥니다. 녹음은 계속 로컬에 보관합니다. 문제 해결 후 **다시 전사**를 누릅니다.
- 앱 재실행 시 중단된 WAV 헤더와 큐 상태를 복구합니다. 과거 녹음은 사용자가 다시 전사를 눌러 처리합니다.
- 화면 잠금 녹음을 위한 background audio가 설정되어 있습니다. 통화, Bluetooth 전환, iOS 강제 종료 등의 공백은 복원할 수 없으며 상태 기록을 남깁니다. 실제 iPhone/안경에서 잠금·전환 시험이 필요합니다.
- 화자 식별은 각 2초 구간 안에서만 유효합니다. 시간과 전사/번역은 AI 추정이므로 부품 번호, 수치 등은 원문 음성과 확인하세요.
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

앱은 자체 SwiftUI 화면과 AVAudioEngine 녹음기, REST 전사 클라이언트로 구현했습니다. Meta 앱 등록과 선택적 스트리밍에 MWDATCore/MWDATCamera 0.8.0을 사용합니다.

## 1.1 변경

- 기존 2.5 Flash 설정을 3.6 Flash로 마이그레이션하고 키별 모델 조회, 음성 연결 테스트, 서버 오류 상세를 추가했습니다. 모델 목록에 있어도 실제 호출은 거부될 수 있습니다.
- Meta 앱 연결 승인 및 복귀 URL 처리, 선택적 스트리밍/권한 요청, Bluetooth 입력 목록과 수동 선택을 지원합니다.
- 안경 마이크를 사용할 수 없으면 iPhone 마이크로 폴백합니다. 실제 입력을 표시하고 회의 기록에 남깁니다.
- 스트리밍은 카메라를 활성화할 수 있습니다. 영상은 소비하지 않으며 오디오는 HFP로 별도 수집합니다. 장시간 회의에는 선택적으로 끌 수 있습니다.
- iOS에는 별도 백그라운드 실행 승인창이 없습니다. audio / bluetooth-peripheral / external-accessory 선언과 iOS 마이크 권한을 사용합니다.
- 개발용 MetaAppID 0을 사용하므로 Meta 앱의 안경 개발자 모드를 켜야 합니다.
- 빌드 전 빈 `EmbeddedGeminiKey.txt` 파일을 만듭니다. 개인 키는 로컬에서 IPA에 넣으며 소스 관리와 CI에는 전송하지 않습니다. 개인 키가 내장된 IPA는 타인에게 배포하지 마세요.
- 실제 API 테스트는 환경 변수로 키를 제공할 때만 실행됩니다. CI에서는 이 테스트를 건너뛰고 별도로 로컬에서 실제 REST 요청을 검증합니다.

- 설정의 번역 읽어주기를 켜면 새 한국어 번역을 Bluetooth 출력으로 읽습니다. 기본값은 꺼짐이며 새 회의부터 적용합니다. 읽기 대기열은 최신 3개로 제한하고 회의 종료 시 중지합니다. 음성 처리의 에코 제거를 켜며 실제 안경에서 재입력/에코를 확인해야 합니다.

## 1.1.1 기기 선택 수정

AutoDeviceSelector를 세션 생성과 동시에 만들던 순서를 수정했습니다. 선택기를 앱 수명 동안 유지하며, 카메라 권한 승인 후 SDK의 activeDevice가 준비될 때까지 최대 20초 기다린 뒤 SpecificDeviceSelector로 세션을 생성합니다. 선택 직후 기기가 사라져 noEligibleDevice가 발생한 경우에만 제한 시간 안에서 재시도합니다. 기기 없음/권한/세션 시작 오류를 구분해 표시하고 설정에서 기기 수·연결·호환성 및 진단 기록을 공유할 수 있습니다. 안경 발견이 지연되거나 실패하는 실제 원인은 실기 진단으로 확인해야 합니다.

## 빠른 전사

음성 저장/전사 단위를 2초로 줄였습니다. 3.6 Flash는 MINIMAL 추론을 사용하며 API 요청은 최대 2개만 동시에 처리합니다. 결과 화면은 시간순으로 정렬하고 읽어주기는 앞 구간이 끝난 뒤 순서대로 처리합니다. 실제 표시 지연은 구간 수집 시간과 API 처리·대기 시간의 합이며 2초 고정 응답을 보장하지 않습니다. 문장 중간에서 나뉘어 번역 문맥이 약해질 수 있고 API 요청 수가 늘어납니다.

무음/매우 낮은 신호의 PCM은 API로 보내지 않습니다. 원본 WAV는 유지합니다. 읽어주기가 실제 시작된 한국어와 거의 일치하는 한국어 재입력은 전사 표시에서 제외하고 회의 상태 기록에 남깁니다. 이는 보수적인 신호/문자열 필터이며 소음에서 발생하는 모든 환각을 판별하거나 번역 정확성을 보장하지 않습니다. 화면 캡처나 영상 프레임을 Gemini에 보내는 경로는 없습니다.
