# Ambient Workspace 1.0.0-rc.1

YouTube 영상의 색과 흐릿한 영상을 작업 공간의 배경과 조명으로 연결하는 무료 앱입니다. Chrome에서는 웹 작업 화면과 YouTube 플레이어 주변에, Windows에서는 Desktop Companion이 대상 앱 주변에 효과를 표시합니다. 원본 영상과 오디오는 그대로 재생됩니다.

YouTube를 연결하지 않아도 그라데이션 배경(Demo)을 사용할 수 있고, 직접 연결하면 영상 기반 배경(Live)으로 바꿀 수 있습니다. 색상 조명과 흐릿한 영상은 각각 선택하며, 통합 Pause/Resume로 효과를 함께 멈추고 재개합니다.

**공개 테스트용 Release Candidate(RC)이며 정식 1.0.0이 아닙니다.** 수동 설치형이며, 지원 범위는 **본인 전용 Windows 계정과 ACL 검사를 통과한 로컬 NTFS 설치**입니다. 설치 전에 [개인정보 안내](docs/PRIVACY.md), [알려진 문제](docs/KNOWN_ISSUES.md)와 아래 지원 환경을 확인하세요.

## 1. 프로젝트 소개와 핵심 기능

작업 화면에 YouTube 영상의 분위기를 더하고 싶을 때 사용합니다. 웹 배경·YouTube 주변 조명·Windows 출력을 개별적으로 선택할 수 있습니다.

- **웹 작업 배경:** ChatGPT·Claude·Gemini·Notion의 배경에 그라데이션, 영상 테두리 또는 반사광을 표시합니다.
- **YouTube 주변 조명:** 연결한 플레이어의 영상 색을 주변으로 확산합니다.
- **Windows 출력:** 대상 앱 주변에 RGB 조명과 선택적 흐릿한 영상을 표시합니다.
- **통합 제어:** 개별 ON/OFF를 보존하며 효과와 프레임 처리를 일시정지·재개합니다.

## 2. Chrome + Windows Desktop 동작 방식

| 구성 요소 | 하는 일 |
|---|---|
| Chrome 확장 (`Browser_Extension`) | 사용자가 연결한 YouTube 탭의 영상을 받아 웹 배경·플레이어 조명을 표시하고, 선택한 색상·영상을 Windows에 전송합니다. |
| Native Messaging host | Chrome과 로컬 Desktop을 연결합니다. 최초 사용자별 등록이 필요하며, 폴더를 옮기거나 업데이트하면 재등록합니다. |
| Desktop Companion (`Desktop_Companion`) | Windows 트레이에서 실행되며 대상 앱 주변 출력·설정·페어링·선택적 전역 단축키를 관리합니다. |

연결 흐름은 **YouTube 탭 → Chrome 확장 → Native Messaging → Desktop Companion**입니다. 웹 배경과 YouTube 조명은 확장에서, Windows 표시는 Desktop에서 제어합니다. Demo 배경은 YouTube 캡처 없이 사용할 수 있습니다.

## 3. 주요 기능

| 기능 | 사용 방법과 범위 |
|---|---|
| Demo / Live 배경 | 미연결 그라데이션 또는 직접 연결한 영상의 테두리·반사광을 선택합니다. 사이트별 ON/OFF와 밝기·흐림·중앙 보호 등을 조절합니다. |
| Windows RGB / 영상 | 확장의 **Windows로 전송**과 **흐릿한 영상도 전송**, Desktop의 RGB·영상 사용을 함께 확인합니다. |
| 통합 Pause/Resume | Desktop·웹 배경·YouTube 조명·프레임 처리/인코딩/송신을 멈추고 재개합니다. 개별 OFF는 유지하며, 캡처 연결과 원본 재생은 유지합니다. |
| 트레이와 단축키 | 트레이 두 번 클릭으로 설정을 엽니다. Windows 전역 단축키는 기본 비활성이며 설정에서 선택적으로 켭니다. |
| 설정 보존과 이전 | 재실행 때 설정·페어링을 유지합니다. 기존 설치에서 옮길 때는 첫 실행 전에 설정·키를 보존하고, 예전 확장 ID는 별도 이전 절차를 따릅니다. |

## 4. 설치 및 Native Messaging 등록

### 준비와 기존 사용자 안내

신뢰한 전체 Windows RC ZIP을 개인 로컬 NTFS 폴더에 압축 해제하세요. ZIP 안에서 실행하지 말고 `Desktop_Companion`과 `Browser_Extension`을 함께 유지합니다. 다운로드 경로와 파일 확인은 아래 다운로드 안내와 [Release Notes](docs/RELEASE_NOTES_v1.0.0-rc.1.md)를 참고하세요.

**기존 사용자는 새 폴더를 처음 실행하기 전에** [설정·키 보존 및 예전 확장 ID 이전 절차](docs/NATIVE_MESSAGING_GUIDE.md)를 먼저 진행합니다. 원본과 비공개 백업을 보존하며 기존 파일을 초기화하거나 임의로 덮어쓰지 않습니다.

### 처음 설치하기

1. 압축 해제한 루트 폴더에서 아래 읽기 전용 ACL(파일 접근 권한) 검사를 실행해 `PASS`를 확인합니다. 실패하면 [Windows 설치 안내의 원인 코드](docs/WINDOWS_PORTABLE_GUIDE.md)를 따릅니다.

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Desktop_Companion\Test-FileSecurity.ps1
```

2. `Desktop_Companion/Start.bat`을 실행합니다. 트레이 아이콘을 두 번 클릭하면 설정이 열립니다. 숨겨진 아이콘 **∧**도 확인하세요.
3. Chrome에서 아래 주소를 열고 **개발자 모드 → 압축해제된 확장 프로그램을 로드합니다**로 `Browser_Extension`을 선택합니다. 사용할 YouTube·작업 탭을 새로고침합니다.

```text
chrome://extensions
```

4. Desktop 설정 → **연결 → Chrome 연결 등록**, 또는 `Desktop_Companion/Setup-Chrome.bat`을 엽니다. 확장 팝업의 **연결 설정 → Windows 연결 → 등록용 ID 복사**로 ID를 복사해 등록 창에 붙이고 **처음 등록**을 누릅니다. 고정 ID는 `ncbcjbbidoaallpikijfbjdmijjljhoe`입니다. 다른 위치가 이미 등록돼 있으면 [등록·복구 안내](docs/NATIVE_MESSAGING_GUIDE.md)를 먼저 확인합니다.
5. Desktop에서 **페어링 코드 복사**를 누르고 확장 팝업의 Windows 연결에 붙여넣은 뒤 **코드 저장 · 연결 검사**를 누릅니다. 코드는 공유하지 않습니다.
6. 실제 Desktop 상태 조회가 되는지 확인합니다. **등록 완료·코드 저장·실제 인증·YouTube 캡처는 서로 다른 확인 단계**입니다. 코드 저장만으로 전체 연결이 끝난 것은 아닙니다.

Windows PowerShell 5.1/WPF와 Windows 기본 .NET 컴파일러를 사용합니다. 실행에 관리자 권한·Node.js·Python·추가 SDK 설치는 필요하지 않습니다. Chrome Web Store·자동 업데이트·Windows 자동 시작 등록을 사용하지 않습니다. 자세한 업데이트·이동·제거 방법은 [Windows 설치 안내](docs/WINDOWS_PORTABLE_GUIDE.md)를 따르세요.

## 5. YouTube 연결과 일반 사용법

1. YouTube 탭에서 영상과 페이지 로딩을 마친 뒤 확장 팝업의 **YouTube 연결**을 누릅니다. 공유 선택창이 나오면 해당 YouTube 탭을 선택합니다.
2. 지원하는 작업 탭을 선택해 웹 배경을 확인합니다. 팝업에서 영상 테두리·반사광·사이트별 ON/OFF를 조절합니다. 캡처 없이 사용하려면 **연결 해제 후 웹 그라데이션 사용**을 선택합니다.
3. Windows 출력은 **Windows로 전송**을 켭니다. 영상도 필요하면 **흐릿한 영상도 전송**과 Desktop의 영상 사용을 켜고, 대상 앱이 활성 상태인지 확인합니다.
4. **통합 효과 일시정지/재개**로 효과를 제어합니다. Pause는 화면 공유 종료가 아닙니다. 캡처까지 끝내려면 상단 **취소·해제**를 누릅니다.
5. Desktop을 종료하려면 트레이 우클릭 → **Desktop 앱 종료**를 선택합니다. 설정창 닫기는 앱 종료가 아니며, Chrome 캡처는 별도로 중지합니다.

Chrome을 재시작하면 종료된 캡처는 다시 명시적으로 연결해야 합니다. 설정·페어링은 유지하며, 폴더 이동·업데이트 뒤에는 Native host를 새 위치로 재등록합니다.

## 6. 보안·개인정보·지원 환경

| 항목 | 범위와 제한 |
|---|---|
| Windows | 본인 전용 계정·ACL 검사 PASS 로컬 NTFS 설치만 지원합니다. 실제 두 Windows 계정 접근 실험은 미수행이며, 공용 계정·공유 폴더·조직 정책 환경의 안전성을 보장하지 않습니다. |
| Chrome | manifest의 최소 선언 버전은 116입니다. 이 선언이 모든 116 이상 버전의 동작 검증을 뜻하지 않습니다. 다른 Chromium 브라우저·macOS·Linux의 Desktop 동작은 이번 RC 지원 범위에 포함하지 않습니다. |
| 웹·Desktop 대상 | 웹은 ChatGPT·Claude·Gemini·Notion, Desktop 기본 대상은 VS Code·Codex·ChatGPT·Claude·Cursor 등입니다. 실제 대상 목록은 Desktop 설정의 고급·진단에서 확인합니다. 사이트 개편·고DPI·절전/복귀·다중 모니터 등은 포괄 검증하지 않았습니다. |
| 캡처와 로컬 처리 | 명시적으로 연결한 YouTube 탭의 영상만 요청하며 전체 화면·다른 창·오디오 캡처는 요청하지 않습니다. Native Messaging을 사용하고 localhost HTTP 송신/리스너/자동 fallback은 없습니다. |
| 개인 파일 | 설정·페어링 키·프레임·로그·이전 백업은 로컬에 남을 수 있습니다. 암호화·보안 삭제·동일 사용자 악성코드 방어를 제공하지 않습니다. 키·전체 설정·프로필·캡처 영상·원문 로그는 공유하지 마세요. |

SECURITY 오류를 관리자 실행·공유 권한 추가·보안 기능 해제로 우회하지 않습니다. [개인정보 안내](docs/PRIVACY.md)와 [Known Issues](docs/KNOWN_ISSUES.md)에서 데이터 보관·클립보드·이동 경합 등 잔여 위험을 확인하세요.

## 7. 알려진 문제와 해결 방법

| 증상 | 먼저 확인할 내용 |
|---|---|
| Chrome 재시작 뒤 웹 배경만 나오고 Windows 전송이 시작되지 않음 | 팝업의 **Windows 전송이 시작되지 않았어요** 안내를 확인합니다. Desktop 트레이·전송 ON·개별 영상 ON·통합 pause를 확인한 뒤 **취소·해제 → YouTube 연결**을 누릅니다. 기다리거나 팝업을 다시 여는 것만으로 자동 복구되지 않습니다. 키·설정은 유지합니다. |
| YouTube 연결 시작이 끝나지 않음 | 영상·페이지 로딩을 마치고 팝업에서 상태를 읽은 뒤 명시적으로 재연결합니다. 이동·레이아웃 변경 중에는 연결이 취소될 수 있습니다. 설정 초기화·재페어링으로 우회하지 않습니다. |
| 조명이 보이지 않음 | 대상 앱 활성 상태·트레이 실행·개별 RGB/영상·통합 pause를 확인합니다. 페어링 성공과 캡처 연결은 별도로 확인합니다. |
| 영상이 느리거나 끊김 | Windows 영상 기본 2FPS와 실험 5/10FPS는 처리 상한이며 실측 표시율 보장이 아닙니다. 웹 영상 FPS 설정과도 구분하세요. |
| 실행 또는 등록이 차단됨 | [Windows 원인 코드](docs/WINDOWS_PORTABLE_GUIDE.md)와 [Native 등록·복구](docs/NATIVE_MESSAGING_GUIDE.md)를 따릅니다. 기존 설정·키·로그를 보존합니다. |

간헐 시작 실패·장시간 반복 후 팝업 복귀 실패와 Native 지연의 영구 해결은 미확정입니다. 과거 실패 기록과 후속 통과를 구분합니다. 2026-10-23의 사용자 수락(시작/종료 10/10, 재시작 후 설정·페어링 유지, 30분 이상 뒤 상태 조회·Pause/Resume 등)과 기존 자동 회귀 52/52는 [Release Notes](docs/RELEASE_NOTES_v1.0.0-rc.1.md)에 기록돼 있습니다. 이번 문서 정리나 새 다운로드·다른 환경의 검증으로 합산하지 않습니다.

상세 제한과 복구 방법은 [Known Issues](docs/KNOWN_ISSUES.md), [FAQ](docs/FAQ.md)를 확인하세요. 문의에는 오류 코드·시각·시작/재시작 여부와 짧은 안내 문구부터 제공합니다.

## 8. 다운로드 및 Release 안내

공식 저장소는 [Yu-HsH/ambient-workspace](https://github.com/Yu-HsH/ambient-workspace)이며, 다운로드 게시 위치는 [GitHub Releases](https://github.com/Yu-HsH/ambient-workspace/releases)입니다. **현재 RC는 로컬 게시 준비 단계로, push·태그·Release 게시는 아직 하지 않았습니다.** Release가 없다면 배포 ZIP도 아직 게시되지 않은 상태입니다.

게시 후에는 해당 RC의 Assets에서 전체 `AmbientWorkspace-1.0.0-rc.1-windows.zip`과 SHA-256 확인 파일을 받으세요. GitHub의 자동 **Source code (zip)**은 별도의 소스 스냅샷입니다. 설치 안내는 배포용 Windows ZIP을 기준으로 합니다.

파일 확인은 다운로드 폴더에서 다음 명령으로 수행하고, 결과를 같은 Release의 SHA-256과 비교합니다. 해시 일치는 배포자 전자서명 검증을 대신하지 않습니다.

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\AmbientWorkspace-1.0.0-rc.1-windows.zip
```

배포 ZIP에는 저장소의 제품 파일·사용자 문서·권리 고지와 `BUILD-INFO.json`을 포함합니다. Git 관리 파일과 이력은 포함하지 않습니다. 사용자별 host 실행 파일은 설치 시 Windows 기본 .NET 컴파일러로 생성합니다. 버전별 변경 내용은 [CHANGELOG](CHANGELOG.md), 이번 RC의 검증 범위는 [Release Notes](docs/RELEASE_NOTES_v1.0.0-rc.1.md)를 확인하세요.

## 9. 라이선스와 제3자 고지

자체 코드·새 SVG/PNG 아이콘은 [MIT License](LICENSE), `Copyright (c) 2026 Hwang Seonghyeon`입니다. 사용·수정·재배포 시 저작권·허락·면책 고지를 보존하세요.

[COPYRIGHT](COPYRIGHT.md)의 범위와 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md), [Wessel Kroos의 MIT 전문](licenses/youtube-ambilight-MIT.txt)을 함께 보존합니다. 확장만 따로 재배포할 때도 해당 고지가 필요합니다. [현행 아이콘 출처](docs/ICON_PROVENANCE.md)를 확인하세요. 공개 소스와 ZIP에는 출처 미확인 옛 이미지·스크린샷·개인 데이터·내부 감사 자료를 포함하지 않습니다. YouTube·Chrome·지원 앱의 공식 제품이나 보증을 뜻하지 않습니다.
