# rc.2 Windows 연결·Chrome 일시정지 검토

> 현재 다운로드: [rc.2 공개 검토판](https://github.com/Yu-HsH/ambient-workspace/releases/tag/v1.0.0-rc.2-review.1). 아래 미커밋·미배포 및 로컬 전용 표시는 각 기록을 작성했던 시점의 상태입니다. 실제 Windows/Chrome 사용자 수락은 별도이며 과거 자동 검증과 합산하지 않습니다.

2026-10-26, 개발 브랜치 `feat/rc2-connection-pause`. 이 문서의 새 기능은 **미커밋·미배포 검토 대상**입니다.

## 1단계 보존 지점

`feat/rc2-orca-desktop`의 로컬 커밋은 `3d4c018e9a4182f2b3d6c13781f95e8a84378735`입니다.

```text
feat: add Orca support and safe rc2 installation flow
```

커밋 전 변경 소스·테스트·문서 24개를 검토하고 명시적으로 스테이징했습니다. 설치 17/17, Native 등록·복구 13/13, 설정/WPF 회귀 2개 스크립트, PS 5.1 파서 33개 파일, XAML·기본 JSON 검사가 통과했습니다. 비밀정보 패턴과 개인/생성 파일 경로 검사를 수행했고 검토 ZIP·설정·키·로그는 포함하지 않았습니다. 정상 제품 파일인 `settings.defaults.json`은 포함했습니다. [실사용 수락 기록](INSTALLER_USER_ACCEPTANCE_RC2.md)에는 사용자 보고와 미확인 항목을 구분했습니다.

## 2단계: Windows 연결

Chrome 팝업의 **연결 설정 → Windows 연결** 버튼으로 다음 순서를 확인합니다.

1. 기존 Native 포트를 닫고 현재 등록에서 새 Host를 실행합니다.
2. `native.status`로 Host 응답과 Desktop 수신기 존재를 확인합니다.
3. Chrome에 저장한 기존 코드로 인증합니다. 코드가 없거나 거부된 경우에만 코드 입력 영역을 펼칩니다.
4. 최초 코드 입력은 인증 성공 후에만 저장하고 Windows 송신을 켭니다. 이미 저장된 코드로 검사할 때는 기존 Windows 송신 ON/OFF를 유지합니다.
5. 고급 연결 진단에서는 Host·Desktop·인증 상태를 각각 확인할 수 있습니다. 별도 Host 확인은 인증 성공을 뜻하지 않습니다.

역할은 다음과 같습니다.

| 구성 요소 | 역할 |
|---|---|
| 설치 도우미 | 파일·해시·ACL 검사, 승인한 설정/키 복사, 등록 UI를 열기 위한 별도 동의 |
| Desktop 등록 UI / `Setup-Chrome.bat` | 사용자가 등록/재등록 버튼으로 승인한 현재 사용자 레지스트리 변경 |
| Chrome 확장 | 등록된 Host를 실행해 상태·기존 인증 확인, 실패별 다음 행동 안내 |

Chrome 확장은 Windows 레지스트리를 직접 수정하거나 Desktop을 자동 실행하지 않습니다. Native origin 허용 목록, 개인 폴더 ACL, 기존 토큰 인증, Desktop 프로필 lease·revision·TTL·저장 정책을 유지합니다. 연결 실패 시 키/설정 초기화, 인증 없는 우회, HTTP fallback을 추가하지 않았습니다.

### 경로 변경 뒤 확장 새로고침이 필요했던 원인

코드에서 확인한 원인은 `AW_NATIVE`가 열린 포트를 재사용하며, 그 Host 프로세스가 시작 당시 설치 폴더를 계속 사용하는 구조입니다. Chrome 공식 문서도 `connectNative()` 연결에 따라 Host 프로세스가 실행된다고 설명합니다. 따라서 레지스트리를 새 폴더로 바꿔도 기존 포트가 자동으로 새 프로세스가 된다고 가정할 수 없습니다. 이는 코드와 API 계약으로 설명 가능한 원인이며, 사용자 Chrome에서 해당 시점의 프로세스·경로를 추적한 실측 결과는 아닙니다. [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)

명시적인 Windows 연결은 새 포트로 검사합니다. 자동 조회의 `bridgeUnavailable`에는 `native.status`·`ping`·`control.hello`·`control.query`만 한 번 새 포트에서 재시도합니다. 제어 쓰기·프레임·색상·백업 명령은 재전송하지 않습니다. 진행 중이던 제어의 결과가 불명확하면 새 조회로 실제 상태를 확인합니다. 재등록된 Host가 정상이어도 Chrome 정책·실행 잠금 등으로 연결할 수 없다면 확장 새로고침 안내를 제공합니다.

| 실패 | 표시와 한계 |
|---|---|
| `hostNotRegistered` | Chrome이 Host 미등록 오류를 명시적으로 반환한 경우 |
| `hostForbidden` / `hostStartFailed` | 확장 ID 허용 또는 등록된 Host 시작 문제 |
| `desktopNotRunning` | Host 응답은 있지만 Desktop endpoint가 없음 |
| `pairingRequired` / `pairingRejected` | 최초 코드 필요 / 기존 코드 인증 거부 |
| `timeout` | 연결 응답 시간 초과 |
| `bridgeUnavailable` | Host에서 수신기 접근 실패. 미실행·경로·접근 문제를 단정하지 않음 |
| `nativeUnavailable` | Chrome이 구체적 근거를 제공하지 않은 연결 실패. 미등록으로 추정하지 않음 |

Chrome의 알려진 오류 문구를 고정 코드로 변환하며 원문 예외·개인 경로·키는 UI 응답에 포함하지 않습니다. Chrome 버전이나 언어에 따라 알 수 없는 문구는 일반 연결 실패로 남을 수 있습니다.

구현: `native-transport.js`, 새 `windows-connection.js`, `background.js`, `popup.html/js`, Desktop `Native-Setup.ps1/xaml`, 설치 도우미의 마지막 안내, `Installer/product-files.json`.

## 3단계: Desktop 독립형 Chrome Pause/Resume

기존 코드는 Desktop에서 확인한 `globalPaused`를 웹 체크포인트로 저장하고, 팝업 버튼도 유효한 Desktop lease가 있어야 활성화했습니다. 이제 기존 `aw_web_pause` 저장 구조와 웹·YouTube·offscreen 제어 메시지를 재사용하면서 Chrome을 별도 상태의 소유자로 바꿉니다. 서비스 워커가 종료될 수 있으므로 상태를 전역 변수만으로 보관하지 않습니다. [Chrome 서비스 워커 상태 저장](https://developer.chrome.com/docs/extensions/develop/migrate/to-service-workers)

| 조작 | 적용 범위 |
|---|---|
| **Chrome 효과 일시정지/재개** | 모든 지원 웹 배경·YouTube 조명 및 공유 샘플링/인코딩/송신. Desktop 설치·실행·인증과 무관 |
| **Windows 효과 일시정지/재개** | 기존 Desktop 제어 채널을 통한 Windows 로컬 효과. Chrome 체크포인트는 바꾸지 않음 |
| Windows 연결/재연결/트레이 조작 | Chrome의 명시적 일시정지를 해제하지 않음 |

Chrome 일시정지 시 공유 캡처의 프레임 처리가 멈추므로 Windows로 보내는 영상·색상도 멈춥니다. Desktop의 자체 기본 팔레트 조명은 Desktop 설정에 따라 남을 수 있습니다. Windows 효과까지 멈추려면 Windows 버튼 또는 트레이를 사용합니다. Windows만 정지하면 Chrome 효과와 Chrome 내부 처리는 계속됩니다. 개별 웹/YouTube/Windows ON/OFF와 원본 영상·오디오·캡처 승인 자체는 유지합니다.

Chrome 상태는 신뢰한 팝업만 변경하며 저장 성공 후 세대 번호를 갱신합니다. 중복 요청은 토글하지 않고, 오래된 팝업 revision은 거부합니다. 이전 버전의 정지 체크포인트는 정지 상태로 읽어 보존합니다. 연결 실패나 Desktop 조회는 이 값을 쓰지 않습니다. 재개 저장 실패 시 계속 정지하며, 체크포인트 형식이 손상되면 효과를 자동 재개하지 않습니다. 정지 저장 자체가 실패한 경우에는 기존 상태를 유지하고 오류를 표시합니다.

지원 웹 렌더러는 기존 경로로 타이머·진행 중 이미지 디코딩을 무효화하고 그라데이션 애니메이션을 정지합니다. YouTube는 기존 renderer 해제 경로를 재사용합니다. offscreen은 기존 처리 gate로 샘플링/WebP/JPEG/송신을 막고 진행 중 전송을 취소하며, 늦은 인코딩 결과를 세대 검사로 버립니다. 정지 중 제어 확인 주기는 약 1초로 낮추되 캡처 track은 유지합니다. 운영체제/Chrome의 캡처 자체가 완전히 종료되거나 GPU 사용량이 0이 된다는 뜻은 아닙니다.

Windows와 Chrome의 정지 상태가 다르면 새 Desktop은 `independent-chrome-pause` capability로 `independent` 진단 값을 받아 **Chrome 별도 제어**라고 표시합니다. 이 값에도 기존 origin·lease·revision·freshness 검사를 적용하며 Desktop 항목에는 허용하지 않습니다. rc.1 Desktop은 이 값을 지원하지 않으므로 기존 `waiting`으로 보고하여 전체 적용 완료로 잘못 표시하지 않습니다.

구현: `background.js`, `popup.html/js`, `offscreen.js`; `content.js`·`youtube.js`는 권한 설명 주석 변경만 있습니다. Desktop `Control-Channel.ps1`, `Start-AmbientDesktop.ps1`은 별도 제어 진단을 표시합니다.

## 자동 검증

추가 패키지·SDK·외부 API 의존성 없이 Node 내장 `node:test`와 VM, 기존 Windows PowerShell 5.1 시험을 사용합니다. `tests/browser-harness.mjs`는 실제 확장 스크립트를 실행하고 Chrome API·탭·저장소·Native 포트만 합성합니다. 실제 Chrome E2E 시험을 대체하지 않습니다.

```powershell
# 2단계: 연결·오류 분류·Native 재연결·재전송 금지 (5개 테스트)
node --test tests/test-windows-connection.mjs

# 3단계: Chrome 상태·재시작·캡처·탭·팝업 (10개 테스트)
node --test tests/test-chrome-pause.mjs tests/test-popup.mjs

# 기존 보안·설치·Native·Orca·설정/WPF 전체 회귀
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File .\tools\Test-Installer.ps1
```

브라우저 **15/15 통과**: Chrome-only, Desktop 미실행/연결 실패/인증 거부/정상 연결, 기존 키 재사용, 최초 인증, Native 새 포트 및 읽기 재시도, 쓰기/영상 재전송 금지, 발신자 제한, 다중 사이트·탭 이동, 팝업 재실행·워커 재시작, 상태 저장 실패·중복·오래된 요청, YouTube 대상 선택·Desktop 실패 시 웹 fallback, 손상 체크포인트, 정지 중 처리·전송 억제와 늦은 인코딩 결과 폐기.

추가 PS 검증은 별도 Chrome 진단 값과 기존 freshness 경계, 실제 제어 채널의 capability·보고 값·lease 거부를 다룹니다. 최종 Windows PowerShell 5.1 재실행은 설치 **17/17**, Native 등록·복구 **13/13**, 설정/WPF **2/2 스크립트**, PS 파서 **33개 파일**, XAML·기본 JSON 모두 통과했습니다. 실제 Host 컴파일·인증·개인 메일박스를 사용하되 새 시험 폴더와 합성 데이터·무작위 시험 등록만 사용했습니다. 확장 JavaScript 구문과 제품 패키지 allowlist도 통과했습니다. 새 테스트 초기 작성 중 발생한 합성 소스 확인 응답 오류 1건은 fixture를 고친 뒤 통과했으며 최종 미해결 실패는 없습니다.

### 변경 파일 구분

| 범위 | 파일 |
|---|---|
| 2단계 연결 | `Browser_Extension/source/native-transport.js`, `Browser_Extension/source/windows-connection.js`, `Desktop_Companion/Native-Setup.ps1`, `Desktop_Companion/Native-Setup.xaml`, `Installer/Install-AmbientWorkspace.ps1` |
| 3단계 정지·진단 | `Browser_Extension/source/offscreen.js`, `Desktop_Companion/Control-Channel.ps1`, `Desktop_Companion/Start-AmbientDesktop.ps1` |
| 공통 진입점·UI·패키징 | `Browser_Extension/source/background.js`, `Browser_Extension/source/popup.js`, `Browser_Extension/source/popup.html`, `Installer/product-files.json` |
| 주석 정합성 | `Browser_Extension/source/content.js`, `Browser_Extension/source/youtube.js` |
| 2단계 시험 | `tests/test-windows-connection.mjs` |
| 3단계 시험 | `tests/test-chrome-pause.mjs`, `tests/test-popup.mjs`, `tests/test-desktop-controls.ps1` |
| 공통 시험 | `tests/browser-harness.mjs`, `tests/test-installer.ps1` |
| 문서 | `README.md`, `CHANGELOG.md`, `docs/RC2_CONNECTION_PAUSE.md` |

## 실제 Windows/Chrome 검토 체크리스트

이 새 기능의 실제 Chrome 검증은 아직 미수행입니다. 이전 브랜치의 사용자 실기 통과와 합산하지 않습니다. 운영 등록을 자동으로 변경하지 않았으며, 아래 등록 변경은 사용자가 원하는 새 설치를 선택하고 직접 승인해야 합니다.

- Desktop을 설치하지 않은 Chrome 프로필: 웹 그라데이션 정지/재개, 여러 지원 탭, 새로고침·이동·팝업 재실행 뒤 유지.
- YouTube 연결 중 Chrome 정지: 웹·YouTube 조명 숨김, 원본 재생·소리 유지, 처리 카운터 정지, 재개 후 새 프레임 복원. 브라우저 재시작 후 캡처 공유는 다시 승인.
- Desktop 종료 상태: Chrome 정지/재개 가능, Windows 연결은 Host와 Desktop 미실행을 구분하며 키 입력을 불필요하게 요구하지 않음.
- 정상 Desktop: Windows 연결 → 기존 키 인증 재사용, Windows 송신 OFF 유지, 최초 인증만 입력 안내, 잘못된 코드가 기존 저장 키를 덮지 않음.
- 승인한 Native 경로 이동·재등록 뒤 확장 새로고침 없이 Windows 연결 버튼으로 회복. 실패 시 구체적 코드와 새로고침 안내 확인.
- Chrome 정지 후 Desktop 재시작·재연결·Windows 재개: Chrome 정지가 그대로 유지. Chrome만 재개하거나 Windows만 정지했을 때 범위가 안내와 일치.
- `chrome://extensions`의 서비스 워커 중지 후 지원 탭/팝업에서 깨우기: 정지 상태와 기존 페어링·개별 OFF가 유지. 제어 쓰기가 중복 실행되지 않음.
- Orca RGB/흐릿한 영상/둘 다/OFF, 웹 소스 선택, 최소화·탭 전환·장시간 사용. 흐릿한 영상 전체와 장시간 안정성은 여전히 별도 완전 검증 대상.

검토 후 후속 기능 커밋을 결정합니다. 이 작업에서 `main` 변경, push, merge, tag, Release, 운영 배포는 수행하지 않습니다.
