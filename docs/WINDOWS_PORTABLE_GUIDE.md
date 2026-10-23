# Windows에서 시작하기

이 안내는 `1.0.0-rc.1` 공개 테스트 RC의 설치·업데이트·제거 절차입니다. 정식1.0.0이 아닙니다. 2026-10-23 Native RC 사용자 수락과 기존 자동52/52를 기록했습니다. 실제 두 계정 실험은 미수행이며 이번 RC 필수 조건에서 제외했습니다. Chrome Web Store를 사용하지 않습니다.

**지원 제한:** 본인 전용 Windows 계정·ACL PASS 로컬 NTFS 설치만 지원합니다. 공용 계정·공유 폴더·조직 정책 환경의 안전성을 보장하지 않습니다. 사용자별 최초 연결 등록과 이동/업데이트 후 재등록이 필요합니다. [Native Messaging Guide](NATIVE_MESSAGING_GUIDE.md)를 따르세요. 간헐 실패의 원인/영구 해결은 미확정입니다.

## 1. 압축 풀고 Desktop 실행하기

배포 위치는 [공식 GitHub Releases](https://github.com/Yu-HsH/ambient-workspace/releases)입니다. 현재 RC는 로컬 게시 준비 단계이며 아직 push·태그·Release를 게시하지 않았습니다. 게시 후 Assets의 전체 `AmbientWorkspace-1.0.0-rc.1-windows.zip`을 사용합니다. GitHub의 자동 Source code ZIP과 구분하고 [README의 SHA-256 확인 방법](../README.md)을 따르세요.

1. 승인된 배포 경로에서 받은 ZIP **전체를 압축 해제**합니다. ZIP 안에서 바로 실행하지 마세요. 신뢰한 배포 경로의 SHA-256과 파일 동일성을 확인하세요. 해시 일치는 배포자 서명 검증이 아닙니다.
2. 본인만 사용하는 **로컬 NTFS 개인 폴더**를 선택하세요. 예시는 `%USERPROFILE%\AmbientWorkspace`입니다. 사용자 폴더 아래라는 이유만으로 안전하다고 가정하지 않습니다. 실제 파일·상속 권한 검사를 통과해야 합니다. `Desktop_Companion`과 `Browser_Extension`을 함께 보관하세요.
3. 아래 읽기 전용 ACL 검사의 `PASS`를 확인하고 `Desktop_Companion` 폴더의 **Start.bat**을 두 번 클릭합니다. 기존 사용자는 **첫 실행 전에** 5절의 설정/키 복사와 전후 ACL 검사까지 마칩니다. 관리자 실행이나 Node.js·Python 설치는 필요 없습니다. Windows PowerShell 5.1과 Windows의 WPF를 사용합니다.
4. 잠시 뒤 작업 표시줄 오른쪽에 Ambient Workspace 트레이 아이콘이 나타납니다. 안 보이면 숨겨진 아이콘 **∧**를 누르세요. 실행 중 알림은 Windows 알림 설정에 따라 보이지 않을 수 있습니다.

검은 창은 시작 순간 잠깐 보일 수 있으며 계속 열어둘 필요는 없습니다. 효과가 일시정지되었거나 지원 앱을 사용하지 않아 화면에 조명이 없어도 트레이 아이콘이 있으면 Desktop은 실행 중입니다. 트레이 아이콘을 두 번 클릭하면 설정이 열립니다. 기본 대상 앱은 VS Code·Codex·ChatGPT·Claude·Cursor 등이며 상세 목록은 설정의 고급·진단에서 확인합니다.

처음 실행하면 설정의 **연결** 탭이 열립니다. 창을 닫아도 Desktop은 계속 실행됩니다. 다음 실행부터는 저장한 설정을 불러오며 안내창을 자동으로 열지 않습니다.

공유/Public 폴더, 여러 사람이 쓰는 계정·공용 PC, 네트워크 드라이브, FAT/exFAT 이동식 드라이브에서는 개인 데이터 보호를 보장하지 않습니다. 연결 지점·심볼릭 링크와 권한을 확인할 수 없는 위치도 차단합니다. OneDrive 등 동기화 폴더는 다른 장치로 개인 파일이 복사될 수 있고 reparse point 때문에 검사에 실패할 수 있으므로 설치 위치로 권장하지 않습니다. 사용자 프로필이 공용 계정이면 이 검사로 같은 계정을 쓰는 사람을 구분할 수 없습니다.

실행 전 권한 검사는 현재 사용자·SYSTEM·Administrators·Windows TrustedInstaller 이외의 데이터 읽기/수정 Allow ACE, 제품·상위 경로의 위험한 수정/삭제 권한을 보수적으로 거부합니다. 복잡한 Deny 예외·알 수 없는 그룹도 자동으로 안전하다고 판단하지 않습니다. 설치 폴더 전체 ACL을 자동 변경하지 않습니다. **SECURITY 실패 시 설정·키·startup 로그를 새로 쓰지 않습니다.** 신뢰할 수 있는 배포본에서 다음 읽기 전용 검사를 실행할 수 있습니다.

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Desktop_Companion\Test-FileSecurity.ps1
```

PASS는 해당 시점의 ACL 사전 검사 통과입니다. 다른 실제 계정 로그인 시험이나 배포 파일의 전자서명 확인을 대신하지 않습니다. 앱 실행 중 권한을 공유 상태로 바꾸지 마세요. 이미 다른 계정이 변조할 수 있었던 제품의 검증기 자체도 신뢰하지 말고 신뢰 가능한 제품을 새로 압축 해제하세요.

## 2. Chrome 확장 수동 설치하기

Desktop 실행과 별도 단계이며 처음 한 번 수행합니다.

1. Chrome 주소창에 아래 주소를 입력합니다.

```text
chrome://extensions
```

2. **개발자 모드**를 켜고 **압축해제된 확장 프로그램을 로드합니다**를 선택합니다.
3. ZIP에서 나온 **Browser_Extension** 폴더를 선택합니다. `manifest.json`이 들어 있는 폴더입니다.
4. 확장을 도구 모음에 고정하면 다음부터 쉽게 열 수 있습니다. 사용할 YouTube 탭과 작업 탭을 새로고침하세요.

학교·회사에서 확장 수동 설치나 PowerShell 실행을 차단했다면 담당 관리자에게 문의하세요. 보안 경고·차단을 우회하거나 Defender를 끄지 마세요.

## 3. 현재 사용자 연결 등록과 페어링

1. Desktop 설정 → **연결** → **Chrome 연결 등록** 또는 **Setup-Chrome.bat**을 엽니다. 팝업의 등록용 고정 ID를 복사해 **처음 등록**합니다. 고정 ID는 `ncbcjbbidoaallpikijfbjdmijjljhoe`입니다. 기존 사용자는 [보존·이전 절차](NATIVE_MESSAGING_GUIDE.md)를 먼저 진행합니다.
2. Desktop **페어링 코드 복사**를 누릅니다. 코드는 다른 사람에게 공유하지 마세요.
3. Chrome 확장 팝업 → **Windows 연결**에 코드를 붙여넣고 **코드 저장 · 연결 검사**를 누릅니다.
4. **Windows로 전송**을 켭니다. 영상도 사용하려면 **흐릿한 영상도 전송**을 켭니다.
5. YouTube 재생 탭을 확장에서 연결하고 화면 공유 선택창이 나오면 해당 탭을 선택합니다.
6. 트레이와 확장 팝업에서 연결 상태를 확인합니다. **통합 효과 일시정지/재개** 후 실제 표시와 적용 결과도 확인하세요. 원본 영상과 소리는 계속 재생됩니다.

사용자별 등록·코드 저장·실제 연결·영상 캡처는 각각 확인합니다. 코드가 저장되었다는 표시만으로 인증 성공을 뜻하지 않습니다. 영상이 없으면 YouTube 캡처 연결·송신 선택·Desktop 영상 사용 상태를 함께 확인하세요.

## 4. 종료하고 다시 실행하기

트레이 아이콘을 오른쪽 클릭 → **Desktop 앱 종료**를 선택합니다. 설정창만 닫는 것은 종료가 아닙니다. Desktop이 자신의 Bridge·트레이·전역 단축키를 정리합니다. Chrome 확장의 캡처도 끝내려면 확장 팝업에서 연결을 중지하세요.

다음에는 같은 **Start.bat**을 실행하세요. 설정·단축키·페어링은 유지됩니다. 중복 실행하면 기존 트레이를 찾으라는 안내가 나오며 새 Desktop이나 Bridge를 계속 실행하지 않습니다. 다른 위치의 버전도 기존 Desktop을 먼저 종료해야 실행할 수 있습니다.

Windows 시작 시 자동 실행은 기본으로 등록하지 않습니다. 이 단계에서는 자동 실행 설정 기능도 추가하지 않았습니다.

## 5. 폴더 이동과 새 버전 압축 해제

| 작업 | 설정과 페어링 |
|---|---|
| Desktop을 종료하고 전체 폴더 이동 | `settings.json`, `settings.json.bak`, `bridge-pairing.txt`를 포함하면 유지됩니다. **이동 뒤 ACL을 다시 검사합니다.** 같은 볼륨 이동은 이전 공유 권한을 보존할 수 있어 SECURITY 차단을 해결하지 못할 수 있습니다. 기존 바로가기는 새 위치로 고치고 Native host도 재등록하세요. |
| 새 ZIP을 기존 폴더에 풀기 | 배포본에 개인 설정이 없다는 전제에서 유지됩니다. 실행 중 덮어쓰지 말고 먼저 개인 파일을 비공개 백업하세요. |
| 새 빈 폴더에 새 ZIP 풀기 | 별도 최초 실행입니다. 기존 폴더의 설정·코드는 자동 검색하거나 가져오지 않습니다. 기존 폴더는 그대로 남습니다. |
| 기존 설정으로 새 폴더 사용 | 신뢰 가능한 제품을 개인 폴더에 새로 풀고 종료 후 기존 `settings.json`, 필요 시 `settings.json.bak`, `bridge-pairing.txt`를 새 `Desktop_Companion`에 **복사**합니다. 복사 전후 권한을 검사하고 파일을 덮어쓰기 전 비공개 백업하세요. 키 값이 같으면 기존 Chrome 페어링을 유지합니다. 개인 파일은 GitHub에 올리지 마세요. |

Chrome은 확장 경로와 Native host 경로를 각각 기억합니다. 이동/업데이트 뒤 Chrome을 종료하고 **Setup-Chrome.bat → 이 폴더로 재등록**하세요. 새 배포 후보는 공개 key로 고정 ID를 유지합니다. 같은 Chrome 프로필·ID의 저장소 보존을 확인하고 기존 항목 제거 전 백업하세요. 예전 key 없는 ID는 자동 합쳐지지 않으므로 [복사본 이전 절차](NATIVE_MESSAGING_GUIDE.md)가 필요합니다. 확장 재로딩 후 캡처는 다시 연결해야 할 수 있습니다.

개인 파일 저장 위치는 계속 `Desktop_Companion`입니다. 설정/백업은 `settings.json`/`.bak`, 인증 비밀값은 `bridge-pairing.txt`, 상태와 영상은 `control-*.json`, `bridge-*.json`, `bridge-frame-*.jpg` 및 임시 파일, 진단은 `startup-log.txt`, `diagnostic-log.txt`/`.1`, `bridge-log.txt`입니다. Native host 생성 실행 파일/manifest/허용 origin, `native-bridge.json`, `native-mailbox`, `native-registration-backups`, `native-profile-backups`와 선택적 계측 파일도 Desktop 폴더에 있습니다. `migration-*` 준비 폴더는 Desktop_Companion 옆의 제품 루트에 따로 남습니다. 백업·준비 폴더에는 비밀값이 포함될 수 있으므로 공유하지 마세요. Chrome 쪽 페어링과 일반 설정은 본인 Chrome 프로필의 확장 저장소에 별도로 남습니다. LocalAppData로 자동 이전하거나 기존 키를 재발급하지 않습니다.

복사·업데이트 실패 시 원본을 보존한 상태에서 종료하고 복구하세요. 공유 위치의 원본을 남겨두면 그 안의 키·설정·옛 로그 노출도 남습니다. 앱은 사용자의 기존 파일을 자동 삭제하거나 키를 교체하지 않습니다. 과거 유출이 의심되면 먼저 안전한 설치를 준비한 뒤 명시적으로 페어링 교체를 결정해야 합니다. 새 개인 폴더 사용만으로 이미 복사된 비밀값을 회수할 수 없습니다.

## 6. 실행이 안 될 때

| 표시/증상 | 확인 방법 |
|---|---|
| `ALREADY_RUNNING` 또는 이미 실행 중 안내 | 숨겨진 아이콘 ∧에서 기존 Desktop을 찾으세요. 다른 폴더를 쓰려면 기존 트레이에서 종료합니다. |
| `FILES` | ZIP 전체를 새 폴더에 다시 압축 해제하세요. 개인 설정·페어링을 삭제하지 마세요. |
| `FOLDER` | 폴더 전체를 직접 쓸 수 있는 문서 등의 로컬 경로로 옮기세요. 관리자 실행으로 해결하지 않습니다. |
| `SECURITY` | `DATA_ACL`: 개인 데이터 읽기/수정 권한, `PRODUCT_ACL`: 제품·상위 경로 변조/삭제 권한, `OWNER`: 신뢰 범위 밖 소유자, `REPARSE`: 연결 지점, `LOCAL_VOLUME`: 지원하지 않는 위치, `ACL_UNKNOWN`/`ACL_UNAVAILABLE`: ACL을 확인할 수 없음입니다. 신뢰 가능한 제품을 새 개인 전용 NTFS 폴더에 풀고 설정·키만 복사한 뒤 검사하세요. 단순 이동·관리자 실행·Everyone/Users 권한 추가로 해결하지 마세요. 기존 설치/시스템 ACL을 일괄 변경하지 않습니다. 조직 정책이면 관리자에게 원인 코드를 문의하세요. |
| `SETTINGS` | `settings.json` 읽기 오류입니다. 파일을 보존하고 종료 상태에서 수정하거나 `settings.json.bak`을 비공개 백업 후 확인하세요. 자동 초기화하지 않습니다. |
| `RUNTIME` / `POLICY` | Start.bat을 사용하세요. Windows PowerShell 5.1/WPF 또는 조직 보안 정책을 확인합니다. 시스템 실행 정책을 영구 변경하지 마세요. |
| `BOOTSTRAP` | 실행 진입점이 없거나 로드 전에 차단되었습니다. 전체 압축 해제 여부를 확인하고 조직 차단이면 관리자에게 문의하세요. |
| `DESKTOP` | `Desktop_Companion/startup-log.txt`의 오류 코드·시각을 확인합니다. WPF 시작 후 오류는 `diagnostic-log.txt`도 확인하세요. |
| 트레이는 있지만 Chrome 연결 실패 | Desktop 연결·진단 메뉴와 `bridge-log.txt`를 확인합니다. Setup-Chrome.bat → 등록 확인에서 경로·ID를 확인하고 팝업의 실제 연결을 검사하세요. host/registry/파일 권한·조직의 Native Messaging 정책 오류는 [등록 복구 안내](NATIVE_MESSAGING_GUIDE.md)를 따릅니다. 다른 프로그램을 임의 종료하거나 보안 기능을 끄지 마세요. Bridge 종료 시 Desktop이 2~30초 간격으로 재시도합니다. |
| 오류 로그를 쓸 수 없다는 안내 | 오류창의 코드와 시각을 기록하고 쓰기 가능한 폴더인지 확인하세요. WPF 오류창도 열 수 없으면 별도 콘솔 안내가 표시됩니다. |

`startup-log.txt`는 **가장 최근 실패** 기록이며 정상 재실행 뒤에도 이전 기록이 남을 수 있습니다. 시각을 확인하세요. 오류를 문의할 때 코드·시각·안내 문구를 전달하세요. 페어링 파일, 설정 전체, 캡처 이미지, 개인 Chrome 프로필은 공유하지 마세요.

Desktop 진단 로그는 재실행해도 기존 내용을 지우지 않고 시작 문구를 덧붙입니다. `diagnostic-log.txt`가 약 1MiB에 도달하면 최근 내용을 `diagnostic-log.txt.1` 한 개에 보관하고 새 로그를 시작합니다. 다음 회전에서는 이 백업 한 개를 교체합니다. 이미 큰 로그가 있으면 처음 회전할 때 전체를 백업하므로 백업이 일시적으로 1MiB를 넘을 수 있습니다. 장기 보관이 필요하면 앱을 종료한 뒤 두 파일을 비공개 위치에 직접 백업하세요.

로그가 잠겨 있거나 회전에 실패하면 일부 진단 기록을 건너뛰며 Desktop 기능은 계속 동작합니다. 회전 작업은 설정·페어링·control 파일을 정리하지 않습니다. 이번 보완 과정에서 기존 사용자 로그를 실행하거나 초기화하지 않았습니다.

개발자가 자세한 시작 오류를 확인하려면 압축 해제한 루트 폴더에서 다음을 실행합니다. 이 명령의 실행 정책은 해당 프로세스에만 적용됩니다.

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Desktop_Companion\Start-AmbientDesktop.ps1
```
