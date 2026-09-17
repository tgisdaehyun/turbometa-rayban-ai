# 출장용 호스트 백업·사후 전사

이 버전은 원음 자동 백업, 녹음 복구, 호스트 사후 전사를 추가합니다. 실시간 요약 카드, 겹치는 문맥 창, 회의 용어집은 아직 구현하지 않았습니다.

## 데이터 흐름

- iPhone은 원본 16 kHz PCM WAV를 유지합니다. 신규 기본 전사 간격은 15초이며 기존 선택값은 유지합니다. 개인용 호스트 설정을 처음 적용할 때는 15초로 설정합니다.
- 앱은 종료된 파일을 약 60초씩 모아 **HTTPS + Tailscale**로 업로드합니다. 앱에 포함된 `HostCertificate.der`만 신뢰하며 호스트명·유효기간을 검증합니다. ATS 예외를 사용하지 않습니다. 인증서 변경 시 앱의 공개 인증서도 갱신해야 합니다.
- SHA-256으로 각 WAV와 전체 요청을 검사합니다. 호스트가 원자적 저장을 마친 후 동일 체크섬으로 응답해야 폰이 수신 완료로 기록합니다. 재전송은 중복 저장하지 않으며, 같은 번호의 다른 내용은 409로 거절합니다.
- 폰 원본은 자동 삭제하지 않습니다. 백업 끄기는 새 전송을 중지하며 이미 iOS에 넘긴 전송은 완료될 수 있습니다.
- 회의 종료 및 전체 파일 수신을 확인한 뒤 호스트가 Whisper large-v3로 자동 전사합니다. 녹음 공백은 무음으로 보존하고 결과에 표시합니다.
- 결과는 `<수신 폴더>/<회의 UUID>/processed/<음성 해시>/`의 `asr.json`, `paragraphs.json`, `review.json`, `원문과_한국어.md`에 저장합니다. `latest-result.json`에서 최신 결과 위치를 찾습니다.
- 숫자·단위·부정 표현과 낮은 인식 점수는 `review.json`에 모읍니다. 자동 전사를 확정된 계약·합의 기록으로 간주하지 마세요.
- 번역 키 미설정 시 원문을 먼저 만들고 `translation_key_required`로 대기합니다. 앱 설정의 **호스트에서 한국어 번역 사용**을 누르면 현재 앱의 Gemini 키를 지정 호스트에 HTTPS로 저장합니다. 원음은 로컬 Whisper에만 전달하며, 한국어 번역에는 문단 텍스트를 Gemini로 보냅니다. 이 경로는 실시간 앱의 원음→Gemini 전사와 별개입니다.
- 전사와 문단별 번역을 디스크에 체크포인트하여 재부팅·네트워크 오류 후 이어갑니다. 번역 오류는 5분 후 재시도합니다. 오류 본문·키·음성 내용은 서비스 로그에 남기지 않습니다.

## 호스트 설치

Python 3.10+, CUDA 사용 가능한 faster-whisper 환경과 large-v3 모델이 필요합니다. 이 호스트에서는 기존 `~/.local/share/metameet-transcription/` 환경을 사용합니다.

1. 개인 키/서버 인증서는 `~/.local/share/metameet-host/host.key`, `host.crt`에 준비합니다. 개인 키는 600 권한으로 두고 저장소에 올리지 않습니다.
2. 대응되는 공개 DER 인증서만 앱의 `HostCertificate.der`로 배포합니다.
3. `python3 MetaMeet/Host/install_host.py`로 사용자 서비스를 설치합니다. 호스트 IP와 모델 경로는 `config.json`에서 조정합니다.
4. `systemctl --user status metameet-receiver metameet-worker`로 상태를 확인합니다. 사용자 서비스이므로 부팅 시 사용자 세션 또는 lingering이 필요합니다. 현재 호스트는 자동 로그인 구성이 되어 있습니다.

수신기는 Tailscale IPv4에만 바인딩합니다. 기본 포트는 8766이며 인터넷 공개/Funnel은 설정하지 않습니다. 사용자 서비스가 시작될 때 Tailscale 주소가 아직 없으면 15초 후 재시도합니다.

## 개인용 iPhone 설치

CI에는 빈 `EmbeddedHostConfig.json`을 사용합니다. 공개 CI IPA에는 호스트 연결 키나 Gemini 키가 없습니다.

```sh
python3 MetaMeet/Host/package_personal.py MetaMeet.ipa MetaMeet-private.ipa \
  --config ~/.local/share/metameet-host/config.json
```

개인용 IPA는 연결 키를 포함하므로 공유하지 않습니다. 기존 설치와 동일한 Apple ID·앱 ID로 다시 서명하여 업데이트하고, 기존 앱을 삭제하지 마세요. 처음 실행하면 호스트 백업과 15초 전사를 설정합니다. Gemini 키는 기존 기기의 Keychain에서 사용합니다. **호스트에서 한국어 번역 사용**은 별도로 눌러야 합니다.

## 실제 기기 확인

iOS 빌드 성공과 별개로 다음은 출장 기기에서 확인해야 합니다.

- 중국어+영어 짧은 녹음 → 녹음 종료 → 호스트 수신 완료
- 잠금 화면, Wi-Fi/셀룰러 전환, Tailscale 끊김·복귀 후 미수신분 재전송
- 통화 중 입력 중단 → 통화 종료 후 복구 또는 명확한 중단 상태
- 안경 연결 해제·재연결 시 실제 마이크 표시
- 앱 강제 종료 후 재실행, 미완료 WAV 복구 및 업로드 재개

통화 중 점유된 마이크와 iOS 강제 종료 중의 음성은 복원할 수 없습니다. iOS는 백그라운드 전송 시점을 조정할 수 있고 강제 종료하면 재실행이 필요합니다. 자동 복구는 1/2/4/8/15초 간격으로 최대 5회 재시도하며 실패 후 수동 재개를 표시합니다. 6초간 PCM 입력이 오지 않으면 오디오 엔진을 다시 연결합니다. 녹음 중단 경고·진동은 화면과 앱 실행 상태에 영향을 받으며 잠금 화면 알림을 보장하지 않습니다.

## 검증

```sh
python3 -m unittest discover -s MetaMeet/Host/tests -v
swift test --package-path MetaMeet/Core
```

Python 테스트는 인증, 손상·잘못된 경로 거절, 원본 불변성, 응답 유실 후 재전송, 전체 수신 전 전사 방지, 녹음 공백 보존 및 번역 재개를 확인합니다. iOS 앱 및 Swift 테스트는 macOS 빌드로 검증해야 합니다.
