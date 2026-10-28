# 설치 경험 개편 — 분석·신뢰 경계·검토 기록

> 현재 다운로드: [rc.2 공개 검토판](https://github.com/Yu-HsH/ambient-workspace/releases/tag/v1.0.0-rc.2-review.1). 아래 미커밋·미배포 및 로컬 전용 표시는 각 기록을 작성했던 시점의 상태입니다. 실제 Windows/Chrome 사용자 수락은 별도이며 과거 자동 검증과 합산하지 않습니다.

2026-10-28 / `feat/rc2-connection-pause` / **로컬 개발 검토, 미배포**.
기준 커밋 `3d4c018e9a4182f2b3d6c13781f95e8a84378735`의 Orca·안전 설치를 유지하고 작업 시작 당시 미커밋 Windows 연결·Chrome Pause 위에 설치 UX를 추가합니다. 커밋·push·merge·tag·GitHub Release·기존 설치 수정은 하지 않습니다.

## 현재 구조에서 확인한 내용

[공개 rc.1 Release](https://github.com/Yu-HsH/ambient-workspace/releases/tag/v1.0.0-rc.1)는 수동 포터블 설치입니다. 본문은 Windows ZIP·SHA-256·manifest를 안내하며, 사용자에게 해시 명령·ACL 명령·Desktop 실행·Chrome 수동 추가·Native 등록·코드 인증을 요구합니다. 새 마법사가 있다고 안내하면 안 됩니다. Release의 Assets 동적 목록은 웹 열람에서 로딩 오류가 있었으므로 본문에 명시된 파일명·해시와 로컬 문서를 근거로 분석했습니다. 호스팅된 ZIP을 새로 내려받아 실행한 것은 아닙니다.

로컬 rc.2 설치 엔진은 이미 **검증된 ZIP 메모리 스냅샷 → 개인 버전 폴더 → 승인한 개인 파일 복사 → 최종 해시/ACL → 완료 표시** 구조입니다. 기존 `Install.bat`은 콘솔 질문을 열고, 패키지 도구는 별도 PS1 도우미를 함께 생성했습니다. 콘솔에는 ZIP 경로·해시·출처 확인 단어·설치 위치·이전 선택·등록 선택·별도 인증 선택의 7개 응답란이 있습니다. 업데이트하면 기존 폴더·이전 승인 두 입력이 더 필요합니다. Enter 응답도 입력 1회로 센 수입니다.

Windows 연결은 기존 rc.2 `windows-connection.js`가 Host 응답·Desktop 존재·기존 키 인증을 구분하고 새 Native 포트를 엽니다. 팝업의 Chrome Pause는 Desktop과 독립입니다. 이 로직은 새 설치 마법사에 복제하지 않았습니다.

## 실제 사용자 행동과 단계 수

다음은 **신규 Desktop+Chrome 설치 → 웹 그라데이션 확인**의 목적별 행동 목록입니다. 마우스 클릭 횟수·소요 시간 실측이 아닙니다. 한 폴더를 선택하는 내부 탐색 클릭은 하나로 묶고, 복사와 붙여넣기는 별도 행동으로 셉니다. 이미 확장을 추가했거나 기존 키가 유효한 업데이트에는 일부가 생략됩니다.

| 번호 | 공개 rc.1 안내 | 새 rc.2 마법사 |
|---|---|---|
| 1 | Windows ZIP 다운로드 | Windows 설치 ZIP 다운로드 |
| 2 | `.sha256` 다운로드 | ZIP 전체 압축 해제 |
| 3 | manifest 다운로드·확인 | `Install.bat` 실행 |
| 4 | PowerShell에서 ZIP 해시 명령 실행 | 별도 게시 SHA-256 복사 |
| 5 | 게시 해시와 대조 | 마법사에 SHA-256 입력 |
| 6 | 개인 위치에 ZIP 전체 압축 해제 | 출처 확인란 승인 |
| 7 | PowerShell에서 ACL 명령 실행 | **확인 후 설치** |
| 8 | ACL PASS 확인 | **Chrome 확장 관리 열기** |
| 9 | Desktop `Start.bat` 실행 | Chrome 개발자 모드 ON |
| 10 | Chrome 확장 관리 열기 | **폴더 위치 복사** |
| 11 | 개발자 모드 ON | Chrome 로드 버튼 → 복사한 확장 폴더 선택 |
| 12 | 확장 로드 버튼 → 폴더 선택 | 확장 표시 직접 확인·다음 |
| 13 | Desktop 등록 창 열기 | **Desktop 실행** |
| 14 | 확장 공개 ID 복사 | **연결 등록 열기** |
| 15 | 등록 창에 ID 붙여넣기 | 자동 채운 ID 확인·**처음 등록** |
| 16 | **처음 등록** 승인 | 팝업 **Windows 연결** |
| 17 | Desktop 페어링 코드 복사 | Desktop 기존 페어링 코드 복사 |
| 18 | 팝업 코드 붙여넣기 | 팝업 코드 붙여넣기 |
| 19 | **코드 저장 · 연결 검사** | **코드 저장 · 연결 검사** |
| 20 | 웹 탭 새로고침·효과 확인 | 웹 탭 새로고침·그라데이션 확인 |

이 정의에서는 **20 → 20행동**입니다. 새 마법사의 확인 버튼과 독립 해시 입력이 있어 전체 세부 행동 수가 줄었다고 주장하지 않습니다. 개선의 핵심은 **배포 안내 파일 3개 → 일반 사용자 다운로드 ZIP 1개**, **PowerShell 명령 입력 2개 → 0개**, 확장 ID 수동 전사 제거, 기본 경로·ACL 자동 검사, 단계별 다음 행동 제공입니다. 새 흐름에서 수동 값 입력은 **게시 해시·최초 페어링 코드 2개**이고 Chrome 폴더 주소 붙여넣기를 사용하면 1개가 추가됩니다. rc.1의 필수 명령 2개·ID·코드 4개 입력과 구분합니다. 상위 설치 안내는 rc.1 Quick Start 5단계 → 새 4단계입니다.

새 Chrome-only는 위 13~19를 생략한 **13행동**, 해시 값 입력 1개(폴더 주소 붙여넣기 선택 시 +1), Native 승인·페어링 0개입니다. YouTube 영상으로 시작하면 양쪽 모두 **YouTube 연결·공유 대상 승인**을 별도로 추가합니다. Windows 영상 출력 옵션 선택은 설치 성공 판정에 포함하지 않습니다.

| 분류 | 해당 작업 | 처리 |
|---|---|---|
| 사용자 직접 승인 필요 | 다운로드 출처·독립 게시 해시 확인, Chrome 개발자 모드·확장 추가, 현재 사용자 Native 등록/재등록, 최초 코드 입력, YouTube 캡처 | 대신 승인하거나 보안 정책을 우회하지 않음 |
| 안전한 자동 처리 | ZIP 위치 후보, 환경·디스크·경로·ACL·무결성 확인, 새 전용 폴더, 고정 공개 ID 채우기, 승인한 3개 개인 파일의 바이트 보존 복사 | 기존 파일·ACL·키·프로필은 수정하지 않음 |
| 불필요한 복잡성 | 독립 도우미 별도 다운로드, 일반 사용자 PowerShell 명령, ID 복사/전사, 문서마다 다른 진입점 | ZIP 내부 진입점·기존 UI·복사 버튼으로 통합 |
| 업데이트 전용 | 기존 Desktop 정상 종료, 이전 폴더 지정·개인 파일 복사 승인, 확장 새 경로 확인, Native 재등록, 옛 ID 이전 | 신규 설치에는 노출 최소화; 데이터 복사 별도 승인 |

## 단일 ZIP의 신뢰 경계

**원본 ZIP은 그대로 보관**하고 풀린 `Install.bat`으로 시작합니다. 설치 GUI는 도우미 내부에 포함되어 인접 XAML/제품 코드를 검증 전에 가져오지 않습니다. 원본 ZIP 파일명은 manifest의 제한된 파일명 힌트나 추출 폴더명으로만 찾고, 해시는 자동 채우지 않습니다. 못 찾으면 파일 선택을 요구합니다.

신뢰 단계는 다릅니다.

1. **배포 출처**: 사용자가 공식 저장소·정확한 버전의 Release를 확인합니다. 처음 실행되는 BAT·PS1도 이 신뢰에 의존합니다.
2. **독립 게시 ZIP SHA-256**: Release 본문 또는 별도 검토 기록에서 읽어 입력합니다. ZIP 변조·다른 버전·전송 오류를 감지합니다. ZIP 내부/동봉 해시만 자동으로 읽어 승인하지 않습니다. 같은 GitHub 계정이 침해되면 ZIP과 Release 본문 해시를 함께 바꿀 수 있으므로 별도 암호학적 신뢰 채널과 동등하지 않습니다.
3. **내부 manifest·제품 allowlist·고정 ID**: 검증된 ZIP의 파일 집합·각 크기/해시·허용 경로·제품 공개 ID를 확인합니다. 배포자 서명 검증이 아닙니다.
4. **설치 ACL**: 새 폴더 생성 시에만 사용자·SYSTEM·Administrators 권한을 설정하고 상위 경로와 설치 파일을 검사합니다. 기존 ACL을 고치지 않습니다. 복사한 바이트를 검증하고 완료 표시를 마지막에 씁니다.
5. **향후 코드 서명**: 서명된 네이티브 부트스트랩/설치 프로그램과 Authenticode 검증·게시자 키 관리가 필요합니다. 서명되지 않은 BAT/PS1이 먼저 실행되고 검사 자체를 바꾸는 공격은 자기 해시 검사로 막을 수 없습니다. 내부 manifest에 서명 필드를 넣는 것만으로 해결되지 않습니다.

사용자용 `Install.bat`과 새 마법사의 후속 프로세스는 `ExecutionPolicy Bypass`로 실행 제한을 낮추지 않습니다. 보안 차단에는 정지·출처 확인·승인된 설치 경로를 안내합니다. 기존 포터블 `Start.bat`·`Setup-Chrome.bat`과 과거 고급 시험 명령의 동작은 보존했으며, 새 마법사는 이 BAT들을 통한 차단 우회를 안내하거나 호출하지 않습니다. 제품 전체의 서명/부트스트랩 정리는 출시 전 별도 과제입니다.

이 때문에 기본 `Restricted` 또는 다운로드 MOTW를 적용하는 `RemoteSigned` PC에서 **현재 미서명 진입점이 시작되지 않을 수 있습니다**. 목표 UX가 모든 신규 Windows에서 달성됐거나 출시 가능하다고 판정하지 않습니다. [Microsoft 정책 설명](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1), [Chrome 사용자 수동 추가](https://developer.chrome.com/docs/extensions/get-started/tutorial/hello-world#load-unpacked)를 참고합니다.

## 패키지 구성과 설치 범위

```text
AmbientWorkspace-rc2-onboarding-LOCAL-REVIEW-20261028-….zip
├─ Install.bat                         설치 시작
├─ Installer/Install-AmbientWorkspace.ps1  자체 포함 WPF + 안전 설치 엔진
├─ Installer/product-files.json        명시적 제품 파일 목록
├─ INSTALL-MANIFEST.json               내부 파일 집합/해시 (서명 아님)
├─ Browser_Extension/                  고정 ID Chrome 확장
├─ Desktop_Companion/                  기존 Windows 제품
├─ README.md, docs/, docs/images/      한국어 안내·합성 경로 UI 이미지
└─ LICENSE, COPYRIGHT.md, THIRD_PARTY_NOTICES.md, licenses/
```

검토 도구는 ZIP 외부에 `.sha256`과 `.review.json`을 기록합니다. 사용자는 ZIP만 받고 게시된 해시를 복사합니다. 독립 PS1 출력은 고급 검토용 `-IncludeStandaloneHelper` 선택사항입니다. 로컬 패키지는 항상 `reviewOnly=true`, 공개 배포·서명·GitHub 승인 증거가 아닙니다.

Desktop+Chrome은 전체 검증 제품을 새 버전 폴더에 설치합니다. Chrome-only는 전체 ZIP의 무결성·allowlist·도우미 검증 후 메모리에서 **Desktop/Installer/Install.bat을 제외**하고 확장·문서·권리 고지만 설치합니다. 설치 manifest는 선택한 집합을 기록하고 완료 표시에는 원본 ZIP SHA-256과 모드를 기록합니다. Desktop mutex·개인 파일 이전·Native 등록·키 읽기·Desktop 시작을 하지 않습니다.

개인 설정·키·프로필·로그·프레임·생성 Native EXE·Git·시험 자료는 패키지에 넣지 않습니다. 경로 탈출·ADS·예약명·중복·symlink/reparse·ZIP 크기 한도와 제품 allowlist 검사를 유지합니다. 버전별 새 폴더이며 기존 설치를 덮어쓰지 않습니다. 새 의존성·SDK·외부 API는 추가하지 않고 Windows/.NET/WPF와 Node 내장 시험만 사용합니다.

## 자동 검증과 실제 사용자 확인의 경계

자동 시험은 **합성 개인 파일과 새 개인 NTFS 시험 폴더**, 무작위 Native 시험 이름만 사용합니다. 운영 기본 host 등록·실제 Chrome 프로필·기존 정상 rc.2 설치·기존 키는 변경하지 않습니다. 최종 결과와 검토 ZIP 해시는 로컬 검토 보고서에서 별도 기록합니다.

```powershell
# 개발자용: Windows PowerShell 5.1에서 합성 설치·Native·WPF·Orca 회귀
powershell.exe -NoProfile -NonInteractive -STA -File .\tools\Test-Installer.ps1

# Chrome API 합성 회귀 (실제 Chrome E2E 아님)
node --test tests/test-windows-connection.mjs tests/test-chrome-pause.mjs tests/test-popup.mjs

# 제품 allowlist만 포함한 새 로컬 검토 ZIP. 기존 출력은 덮어쓰지 않음.
powershell.exe -NoProfile -NonInteractive -STA -File .\tools\New-InstallPackage.ps1 `
  -OutputPath .\artifacts\AmbientWorkspace-rc2-onboarding-LOCAL-REVIEW.zip
```

개발 작업 저장소는 현재 제품 ACL 검사를 통과하지 않습니다. 일반 사용자 실행 위치가 아니며, 시험은 새 개인 사용자 시험 폴더를 사용합니다. 실행 정책을 바꾸는 명령은 시험의 선행 조건으로 제공하지 않습니다.

실제 Windows 확인은 다음 순서로 **사용자가 승인한 별도 시험 계정/Chrome 프로필**에서 수행해야 합니다. 기본 운영 등록을 바꾸지 않으려면 별도 Windows 시험 계정을 사용하세요.

- 완전 신규: 브라우저로 실제 다운로드한 ZIP의 MOTW·SmartScreen·실행 정책을 유지한 채 전체 압축 해제, 진입점 실행 여부와 차단 안내, 게시 해시 검증.
- Chrome-only: Desktop/등록 없이 확장 폴더 선택, 그라데이션·YouTube 캡처·Chrome Pause/Resume·브라우저 재시작 후 설정 보존.
- Desktop+Chrome: 트레이 실행, 등록 창에서 직접 승인, 팝업 Windows 연결의 실제 인증, 최초 코드, YouTube 탭 직접 승인, Windows RGB·영상 출력.
- 업데이트: 합성 또는 별도로 보존한 설정·키 사본으로 이전 승인, 원본/사본 동일성, 새 확장 경로·기존 저장소·새 Native 포트·기존 키 재사용 확인.
- 오류·중단: 불완전 압축 해제, 잘못된 폴더, Desktop 이미 실행, 잘못된 해시·키, 등록만 완료/미실행, Windows 송신 OFF, 설치 전 취소·설치 후 닫기·오류 후 재시도.
- 환경: 깨끗한 Windows 10/11·기본 PowerShell 5.1, 두 계정 접근 경계, 고DPI/키보드/화면 읽기, 긴 경로·부족 공간·파일 잠금. 자동 합성 시험으로 이 전체 실기 결과를 대체하지 않음.

## 출시 전에 필요한 작업

2026-10-28 최종 자동 회귀: **설치 18/18, 실제 WPF 이벤트·BAT 진입점 8/8, Native 등록·복구 13/13, Chrome 연결·Pause 합성 15/15**, 기존 설정·Desktop/Orca/WPF **2/2 스크립트**, PowerShell 5.1 파서 **34개 파일**, XAML·기본 JSON·확장 JavaScript 10개 구문·주요 문서 7개의 상대 링크/이미지·제품 allowlist 84개 경로·`git diff --check` 통과. 시험 환경은 Windows 커널 `10.0.26200.0`, Windows PowerShell `5.1.26100.9711`, Node `24.18.0`입니다. 최종 시험은 새 개인 합성 루트에서 실행했으며 운영 Native 등록은 시험하지 않았습니다.

새 시험 작성 중 제품 allowlist JSON의 배열 처리 오류 1건은 설치 엔진에서 수정했고, WPF 시험 의존성 누락 1건은 시험에서 보완했습니다. 문서 이미지의 초기 빈 렌더와 스타일 상속 문제도 고친 뒤 네 화면을 직접 확인했습니다. 최종 미해결 자동 시험 실패는 없습니다. 실제 Chrome 추가·Desktop 화면 출력·기본 운영 등록·인터넷 다운로드/MOTW·SmartScreen·기본 Restricted 환경의 설치는 이번 자동 통과에 포함하지 않습니다.

기존 Windows 연결·Pause 기능의 소스·시험 13개 파일은 작업 시작 시 보존한 사본과 바이트 단위로 동일함을 확인했습니다. 팝업과 Desktop 트레이의 버전 표시·등록 UI 안내 등 이번에 필요한 화면 변경은 별도입니다. 기존 제품 공개 key는 그대로입니다. 이전 자동 검증·사용자 수락을 이번 실제 설치 성공으로 합산하지 않습니다.

실제 다운로드·설치 E2E 수락, 서명된 설치 프로그램과 스크립트 신뢰 체계, 정식 제품 데모/Chrome 화면 캡처, 지원 Windows/Chrome 버전 매트릭스, 신규/업데이트의 새 경로 로드 검증, 장시간 캡처·Orca 회귀가 필요합니다. Chrome Web Store 게시를 준비하면 개발자 모드·폴더 선택과 확장 ID 이전 UX도 줄일 수 있습니다. 게시 전에는 정책 우회나 자동 확장 설치를 추가하지 않습니다.

미래 Release 본문 초안은 [다운로드 설명 초안](RELEASE_DOWNLOAD_RC2_DRAFT.md)이며 실제 Release를 생성하거나 수정한 것은 아닙니다. 기존 설치 도우미/Orca/연결 검증 기록은 당시 결과로 보존하고 이번 새 시험 결과와 합산하지 않습니다.
