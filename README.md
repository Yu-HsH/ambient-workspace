# Ambient Workspace

**YouTube 영상의 색과 흐릿한 영상을 Chrome 작업 화면과 Windows 앱 주변의 배경·조명으로 연결하는 무료 오픈소스 앱입니다.**

## [⬇ Windows 설치 ZIP 바로 다운로드](https://github.com/Yu-HsH/ambient-workspace/releases/download/v1.0.0-rc.2-review.1/AmbientWorkspace-1.0.0-rc.2-review.1-windows.zip)

**위 버튼을 누르면 설치 ZIP 파일을 바로 받습니다.** 다른 README나 파일 목록에서 다시 찾을 필요가 없습니다.

받을 파일: **`AmbientWorkspace-1.0.0-rc.2-review.1-windows.zip`** · 무료 · [MIT 오픈소스](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/LICENSE) · **공개 테스트용 Pre-release (정식판 아님)**

## 설치는 이렇게 진행하세요

1. **설치 시작** — 다운로드한 ZIP을 오른쪽 클릭 → **모두 압축 풀기** → 풀린 폴더의 **`Install.bat`**을 두 번 클릭합니다. 원본 ZIP도 보관하세요. [이 버전의 설치 확인값(SHA-256)](https://github.com/Yu-HsH/ambient-workspace/releases/tag/v1.0.0-rc.2-review.1)에서 64자리 값을 복사해 넣고 **확인 후 설치**를 누릅니다.
2. **Chrome 확장 설치** — **Chrome 확장 관리 열기** → **개발자 모드** → **압축해제된 확장 프로그램을 로드합니다**. **폴더 위치 복사**로 안내된 `Browser_Extension` 폴더를 선택합니다.
3. **Windows 연결 (선택)** — Windows 앱까지 쓰면 **Desktop 실행 → 연결 등록 열기**. 등록 창에서 직접 승인한 뒤 Chrome 팝업의 **연결 설정 → Windows 연결**을 누릅니다. 최초 인증 안내가 나올 때만 기존 페어링 코드를 넣습니다.
4. **설치 완료** — 지원 웹 탭을 새로고침해 그라데이션을 확인하세요. 영상 배경은 YouTube 로딩 후 **YouTube 연결**로 직접 시작합니다. Windows 출력은 **Windows로 전송**도 확인하세요.

**Chrome만 쓰려면 설치 첫 화면에서 `Chrome만 사용`을 선택하세요.** Desktop 설치·실행·연결 등록·페어링 없이 웹 효과를 사용할 수 있습니다.

[그림으로 따라 하는 설치](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/GETTING_STARTED.md) · [설치가 안 될 때](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/TROUBLESHOOTING.md) · [버전 설명·SHA-256](https://github.com/Yu-HsH/ambient-workspace/releases/tag/v1.0.0-rc.2-review.1)

지원 환경: **Windows 10/11 데스크톱의 본인 전용 계정, 개인 로컬 NTFS 폴더, Windows PowerShell 5.1/WPF, Google Chrome**. 관리자 권한·Node.js·Python·추가 SDK 설치는 필요하지 않습니다. Chrome 최소 선언 버전은 116이며 모든 버전에서 시험했다는 의미는 아닙니다.

현재 설치 프로그램은 **미서명 검토판**입니다. Windows나 조직 정책으로 차단되면 보안 설정을 끄거나 관리자 실행으로 우회하지 마세요. 실제 Chrome 추가·Windows 출력·다운로드 후 실행은 사용자 실기 검증이 진행 중이며, 모든 PC의 설치 성공을 보장하지 않습니다.

**`Source code (zip)`은 설치 파일이 아닙니다.** 위의 **Windows 설치 ZIP 바로 다운로드**를 사용하세요. 해시 비교는 파일 일치 확인이며 배포자 전자서명을 대신하지 않습니다.

> 🎬 **제품 데모 위치** — 웹 그라데이션 → YouTube 영상 배경 → Windows 주변 조명을 보여주는 짧은 영상/GIF를 추가할 예정입니다. 아래는 합성 예시 경로로 렌더한 실제 설치 화면입니다.

![설치 시작 화면 · 합성 예시 경로](https://raw.githubusercontent.com/Yu-HsH/ambient-workspace/v1.0.0-rc.2-review.1/docs/images/setup-1.png)

## Chrome만 쓸까요, Windows 앱도 연결할까요?

| 원하는 사용법 | 선택과 다음 행동 |
|---|---|
| **Chrome만 사용** | 마법사에서 **Chrome만 사용**. 확장·문서만 설치합니다. 웹 그라데이션·YouTube 조명·웹 영상 배경과 **Chrome 효과 일시정지/재개**를 씁니다. |
| **Windows 앱도 사용** | 기본 선택을 유지합니다. Chrome 확장 추가 후 Desktop 실행·연결 등록·최초 인증을 진행합니다. **Windows 효과 일시정지/재개**는 별도입니다. |

웹 대상은 ChatGPT·Claude·Gemini·Notion입니다. Chrome Web Store에는 아직 게시하지 않았으므로 확장 추가는 사용자가 직접 승인합니다. YouTube 캡처도 직접 시작하며 원본 영상·소리는 그대로 재생됩니다. Pause는 공유 종료가 아니므로 캡처를 끝내려면 **취소·해제**를 누르세요.

## 기존 사용자 업데이트

기존 Desktop을 트레이의 **Desktop 앱 종료**로 종료한 뒤, 새 ZIP의 마법사에서 **기존 Desktop에서 업데이트 · 설정과 키 보존**을 선택하세요. 기존 폴더 선택과 별도 승인 후 설정·백업·페어링 키 세 파일만 새 개인 폴더에 복사합니다. 기존 폴더를 덮어쓰거나 키를 초기화하지 않습니다.

Chrome에서 새 확장 경로를 확인하고 새 Desktop 위치로 **이 폴더로 재등록**한 뒤 **Windows 연결**을 누르세요. 확장 삭제·프로필 초기화는 필요하지 않습니다. [업데이트·중단 후 이어 하기](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/GETTING_STARTED.md#기존-사용자-업데이트)를 참고하세요.

## 더 알아보기

- 사용자: [시작 안내](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/GETTING_STARTED.md), [문제 해결](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/TROUBLESHOOTING.md), [알려진 제한](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/KNOWN_ISSUES.md), [개인정보](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/PRIVACY.md), [FAQ](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/FAQ.md)
- 고급 설치: [설치 보안·자동화](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/SAFE_INSTALL_GUIDE.md), [Native 등록·복구·이전](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/NATIVE_MESSAGING_GUIDE.md)
- 개발·검증: [설치 경험 분석·신뢰 경계·시험](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/INSTALL_EXPERIENCE_RC2.md), [Windows 연결·Chrome Pause](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/RC2_CONNECTION_PAUSE.md), [Orca](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/ORCA_SUPPORT_RC2.md), [변경 기록](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/CHANGELOG.md)
- 이전 수동 설치판: [rc.1 ZIP 직접 다운로드](https://github.com/Yu-HsH/ambient-workspace/releases/download/v1.0.0-rc.1/AmbientWorkspace-1.0.0-rc.1-windows.zip), [rc.1 설치 안내](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/WINDOWS_PORTABLE_GUIDE.md). rc.1에는 새 설치 마법사가 없습니다.
- 기술·권리 고지: [이전 README 전체 보존본](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/REFERENCE_RC1.md), [LICENSE](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/LICENSE), [COPYRIGHT](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/COPYRIGHT.md), [THIRD_PARTY_NOTICES](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/THIRD_PARTY_NOTICES.md), [upstream MIT 전문](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/licenses/youtube-ambilight-MIT.txt), [아이콘 출처](https://github.com/Yu-HsH/ambient-workspace/blob/v1.0.0-rc.2-review.1/docs/ICON_PROVENANCE.md)

한국어 안내가 기준입니다. 영문판은 추후 `README.en.md`, `docs/en/GETTING_STARTED.md`에 같은 단계·버튼 대응표를 유지해 추가할 수 있습니다.
