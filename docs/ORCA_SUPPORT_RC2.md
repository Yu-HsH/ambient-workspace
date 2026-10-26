# rc.2 개발 — Orca Desktop 지원과 검증

상태: **로컬 개발 변경, 미배포**. 기준은 공개 저장소의 `main` 커밋 `9f68403`이며 개발 브랜치는 `feat/rc2-orca-desktop`입니다. 기존 `v1.0.0-rc.1` 태그와 공개 배포물은 변경하지 않습니다. 제품 버전 문자열과 확장 manifest도 출시 준비 단계까지 rc.1로 유지합니다. 이 문서의 테스트를 과거 rc.1의 자동 52/52 또는 사용자 수락 결과와 합산하지 않습니다.

## 1. 추가한 동작과 보존 범위

사용자가 실제 Windows에서
확인한 정보는 ProcessName `orca`, MainWindowTitle `Orca`, 0이 아닌 MainWindowHandle입니다. 제목은 참고 정보이며 매칭 규칙으로 저장하지 않습니다.

Desktop 신규 설치의 `targets`에 `orca`, `appMultipliers.orca`에 `1.0`을 추가합니다. 기존 VS Code·Codex·ChatGPT·Claude·Cursor의 대상 이름과 배율은 그대로입니다. RGB와 흐릿한 영상은 기존 개별 ON/OFF, 통합 Pause/Resume, Desktop 전체 ON/OFF를 따릅니다. 기존 OFF 설정은 Orca 추가 후에도 유지하므로 필요 시 사용자가 직접 켜야 합니다.

기존 설정은 `ConvertTo-AmbientControlConfig`가 복사본에서 다음처럼 처리합니다.

1. `targetDefaultsVersion`이 없거나 0이면 기존 대상 목록 끝에 Orca가 없을 때만 추가합니다. 대소문자는 구분하지 않으며 다른 대상을 복구하거나 재추가하지 않습니다.
2. Orca 배율이 없을 때만 1.0을 추가합니다. 사용자가 이미 등록한 Orca의 이름 표기와 배율은 그대로입니다.
3. `targetDefaultsVersion=1`을 메모리에 기록합니다. 시작 시 `settings.json`, `.bak`, 페어링 파일에 쓰지 않습니다. 저장하지 않고 종료해도 다음 실행에서 같은 추가가 적용됩니다.
4. 다음 실제 설정 변경을 정상 저장하면 기존 원자적 저장 경로가 Orca와 이전 표시를 함께 저장합니다. 직전 설정은 기존 `.bak` 규칙으로 보존됩니다. 이미 `.bak`이 있으면 일반 저장 시 교체되므로 별도 보관할 이전 백업은 사전에 비공개 복사하세요.
5. 표시가 저장된 뒤 `targets`에서 Orca를 명시적으로 제거하면 다음 실행에서 다시 추가하지 않습니다. 이 버전의 UI에는 대상 삭제 기능이 없으므로 파일을 직접 편집할 때는 Desktop을 종료하고 `targetDefaultsVersion=1`을 유지하세요.

기존 `version`, 스키마 버전, 다른 앱 설정, 연결 설정, 키, 알 수 없는 사용자 필드를 초기화하지 않습니다. 잘못된 JSON/스키마/이전 표시는 오류로 남기며 기본값 파일로 덮어쓰지 않습니다. 키 생성·교체와 Native 등록 코드는 수정하지 않습니다.

## 2. 전경 창 기준

표시 경로는 기존 `Start-AmbientDesktop.ps1`을 유지합니다. [GetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getforegroundwindow)로 현재 창을 얻고 [GetWindowThreadProcessId](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowthreadprocessid)로 그 창의 PID를 조회합니다. 이 프로세스의 `ProcessName`을 소문자로 바꿔 대상 목록과 비교합니다.

프로세스가 실행 중이라는 이유만으로 표시하지 않습니다. 전경 HWND가 0이 아니고 최소화되지 않았으며, 해당 창의 DWM 영역 또는 `GetWindowRect` 영역이 너비 200px·높이 150px보다 커야 표시합니다. 보조 Orca 창도 실제 전경 HWND의 위치를 사용합니다. `MainWindowHandle` 하나를 고정하거나 창 제목 `Orca`만으로 다른 프로세스를 매칭하지 않습니다. `Get-Process orca`의 GUI 프로세스 확인과 실제 전경 자격 확인은 서로 다른 단계입니다.

미지원 앱으로 이동하면 오버레이를 숨기고 두 영상 레이어를 비웁니다. Orca로 돌아오면 선택한 RGB/영상 출력을 기존 경로로 다시 표시합니다. 다른 지원 앱으로 이동하면 해당 앱의 기존 배율을 적용합니다. 전경 확인 주기는 기본 설정에서 최대 450ms이며 영상 수신·유효 시간과 별개입니다.

## 3. 자동 검증 실행

저장소 루트에서 실행합니다. Node·Python·새 SDK 설치가 필요하지 않습니다.

```powershell
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File .\tools\Test-Orca.ps1
```

테스트는 저장소의 `artifacts` 아래 새 임시 폴더와 합성 설정/키/JPEG를 사용합니다. 실제 Desktop, Bridge, Chrome 캡처를 시작하지 않으며 운영 설정·페어링·포커스를 변경하지 않습니다. UI 테스트는 격리된 WPF 객체와 테스트 창을 사용하며, 합성 스크린샷은 Git에서 제외된 `artifacts/ui4`에 남습니다.

| 검증 | 확인하는 내용 |
|---|---|
| PowerShell 5.1 파서·XAML·JSON | 제품 및 추가 테스트/도구의 문법, 기본값 형식 |
| `test-control-state.ps1` + `orca-settings-cases.ps1` | 신규 설치, 기존 사용자 대상/배율/버전/OFF/사용자 필드 보존, 입력·파일 불변, 대소문자, 중복 이전 방지, 저장/재시작, 이전 설정 백업, 합성 키 해시 불변, Orca 명시적 제거 |
| `test-desktop-controls.ps1` + `orca-window-cases.ps1` | 실제 제품 전경 콜백·타깃 정규화, RGB/영상 4조합, 1.0 배율, 합성 JPEG 실제 디코딩, 각 표시 조합별 미지원 앱 왕복 3회, Code/Codex/ChatGPT/Claude/Cursor 전환, 다른 Orca HWND/영역, DWM fallback, 최소화/복귀, Pause/Resume |
| 기존 트레이·설정 회귀 | 저장 실패 복구, 개별 OFF 보존, 충돌 방지, 단축키 입력, WPF 설정창 생명주기 |

제품 전경 콜백의 OS 창 API와 프로세스 조회만 테스트 대역으로 교체합니다. 대상 매칭·배율·출력 제어·JPEG/WPF·저장은 제품 코드를 실행합니다. 따라서 자동 통과는 **실제 Orca 화면에서 보였다는 증거가 아닙니다**.

2026-10-25 개발 환경에서 두 회귀 스크립트와 문법 검사를 통과했습니다. 당시 실행 환경의 전경 PID 조회는 불가하여 실제 Orca 검증으로 세지 않습니다. **2026-10-26 사용자가 Orca의 실제 화면 표시 확인을 보고했습니다.** 이 사용자 보고를 자동 테스트와 구분하며, RGB/영상 각 조합·반복 왕복 등의 세부 수락 결과는 아래 절차로 별도 기록합니다.

## 4. 실제 사용자 검증 절차

먼저 기존 Desktop을 트레이에서 종료합니다. 기존 rc.1 폴더를 보존하고, [설정·키 보존 및 새 위치 재등록 절차](NATIVE_MESSAGING_GUIDE.md)에 따라 개인 NTFS 검증용 복사본을 준비하세요. 기존 운영 폴더에서 바로 테스트를 실행하거나 기본 설정으로 초기화하지 않습니다. 검증용 복사본에는 개발 브랜치의 제품 코드를 사용하고, **첫 실행 전** 기존 `settings.json`, 필요한 `.bak`, `bridge-pairing.txt`를 복사합니다. 새 위치를 쓰면 기존 안내대로 Chrome Native host를 그 위치로 재등록해야 합니다. 이 절차는 사용자의 기존 파일을 자동으로 옮기는 기능이 아닙니다.

신규 설치 확인은 다른 빈 개인 폴더와 별도 테스트 페어링으로 수행합니다. 기존 설치 보존 시험과 신규 설치 시험을 구분하세요. 두 Desktop을 동시에 실행하지 않습니다.

기존 설정·키를 복사한 검증용 루트에서 첫 실행 전 다음 값을 로컬 PowerShell 세션에 보관합니다. 키 원문이나 전체 설정을 출력하지 않습니다.

```powershell
$keyBefore = (Get-FileHash -LiteralPath .\Desktop_Companion\bridge-pairing.txt -Algorithm SHA256).Hash
$settingsBefore = Get-Content -LiteralPath .\Desktop_Companion\settings.json -Raw -Encoding UTF8 | ConvertFrom-Json
$settingsHashBefore = (Get-FileHash -LiteralPath .\Desktop_Companion\settings.json -Algorithm SHA256).Hash
$backupExistsBefore = Test-Path -LiteralPath .\Desktop_Companion\settings.json.bak
if ($backupExistsBefore) {
    $backupHashBefore = (Get-FileHash -LiteralPath .\Desktop_Companion\settings.json.bak -Algorithm SHA256).Hash
}
Get-Process -Name orca -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
    Select-Object ProcessName, MainWindowTitle, MainWindowHandle
```

1. ACL 검사 후 검증용 `Desktop_Companion/Start.bat`을 실행합니다. **아직 설정을 변경하지 않고** 설정 → 고급·진단에서 `orca`, `orca: 1배`를 확인합니다. 기존 Orca 배율이 있었다면 그 값을 기대합니다. 다른 앱의 배율도 실행 전 기록과 같아야 합니다.
2. 아래 비교로 시작만으로 기존 설정/백업/키를 덮어쓰지 않았는지 확인합니다. 재페어링은 요구하지 않아야 하며 기존 Chrome 페어링으로 상태 조회가 성공해야 합니다.

```powershell
((Get-FileHash .\Desktop_Companion\settings.json -Algorithm SHA256).Hash -eq $settingsHashBefore)
((Get-FileHash .\Desktop_Companion\bridge-pairing.txt -Algorithm SHA256).Hash -eq $keyBefore)
if ($backupExistsBefore) {
    ((Get-FileHash .\Desktop_Companion\settings.json.bak -Algorithm SHA256).Hash -eq $backupHashBefore)
}
```

3. YouTube 연결을 완료하고 확장 **Windows로 전송**을 켭니다. 통합 Pause를 해제하고 Desktop 전체를 켭니다. RGB ON / 영상 OFF로 Orca 테두리 RGB를 확인합니다. 이 시험의 ON/OFF 변경은 검증용 복사본에 저장됩니다.
4. **흐릿한 영상도 전송**과 Desktop 영상을 켜고 RGB OFF / 영상 ON, RGB ON / 영상 ON을 각각 확인합니다. 색이 바뀌는 영상으로 실제 움직임을 확인하고, RGB OFF / 영상 OFF에서는 표시가 사라져야 합니다. 원본 영상·오디오는 유지되어야 합니다.
5. 다음 관찰 도구를 30초 실행하고 그동안 Orca → 미지원 앱(예: 메모장) → Orca, Orca → VS Code/Codex/ChatGPT → Orca를 전환합니다. 도구는 제목/키/영상/설정 전체를 출력하거나 파일을 저장하지 않습니다. 실행 당시 설정을 읽으므로 설정 변경 뒤에는 도구를 다시 실행합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Watch-DesktopForeground.ps1 -Seconds 30
```

Orca에서는 `process=orca`, 0이 아닌 `hwnd`, `supported=True`, `eligible=True`, `outputAllowed=True`와 실제 창 영역을 기대합니다. 미지원 앱은 `supported=False`, `eligible=False`가 되어야 합니다. `lookup unavailable`이면 조회를 확인하지 못한 것이므로 통과로 기록하지 않습니다. 이 출력은 대상/창 자격만 보여 주며 실제 RGB·영상 표시는 눈으로 별도 확인합니다. `MainWindowTitle`이 Orca인 다른 앱은 매칭하지 않습니다.

6. RGB만·영상만·둘 다 조합에서 각각 미지원 앱 왕복을 3회 이상 반복합니다. 미지원 앱에서는 잔상이 사라지고 Orca로 돌아오면 선택한 효과가 복귀해야 합니다. 다른 지원 앱에서는 그 앱의 기존 배율을 유지해야 합니다. 트레이의 테두리/밝기 진단은 끝난 상태로 검사합니다. 10초 진단은 임시로 대상 제한을 넓힐 수 있습니다.
7. Orca 이동·크기 변경·최소화·복귀와 다른 Orca 창으로 전환을 확인합니다. 실제 전경 창 영역을 따라야 합니다. 통합 Pause/Resume에서도 개별 OFF가 유지되어야 합니다.
8. 일반 설정 하나를 변경하고 저장한 뒤 Desktop을 종료·재실행합니다. Orca 지원·일반 설정·페어링 유지와 아래 결과를 확인합니다. 테스트에서 바꾼 출력/세기 설정은 사용자가 원하는 값으로 되돌립니다.

```powershell
$settingsAfter = Get-Content -LiteralPath .\Desktop_Companion\settings.json -Raw -Encoding UTF8 | ConvertFrom-Json
($settingsAfter.targetDefaultsVersion -eq 1)
($settingsAfter.targets -contains 'orca')
($settingsAfter.appMultipliers.orca -eq 1.0) # 기존 Orca 배율이 없던 설치 기준
((Get-FileHash .\Desktop_Companion\bridge-pairing.txt -Algorithm SHA256).Hash -eq $keyBefore)
foreach ($name in @('code','code - insiders','codex','chatgpt','claude','cursor')) {
    '{0}: unchanged={1}' -f $name, ($settingsBefore.appMultipliers.$name -eq $settingsAfter.appMultipliers.$name)
}
```

기록 양식: Windows/Orca 버전, 신규/기존 설치, Orca 전경 자격, RGB만/영상만/둘 다/OFF, 미지원 앱 왕복, 지원 앱 왕복, 최소화·다른 창, Pause/Resume, 재실행, 키 보존을 각각 `PASS / FAIL / 미수행`으로 적습니다. 키·전체 설정·창 제목·캡처 원본은 공유하지 않습니다.

## 5. 남은 범위

사용자가 실제 Orca 표시 확인을 보고했으며 각 출력 조합과 반복 전환의 세부 수락은 추가 기록이 필요합니다. 고DPI·다중 모니터·절전 복귀 등의 기존 RC 제한과 [Known Issues](KNOWN_ISSUES.md)는 유지합니다. 키 재발급, 설정 초기화, 자동 앱 탐색/등록, 브라우저 변경, 공개 배포 ZIP 게시, GitHub push 또는 Release는 수행하지 않습니다. 로컬 검토 ZIP은 [설치 도우미](SAFE_INSTALL_GUIDE.md)의 개발 도구로만 생성합니다. 앱 직접 등록 기능은 [별도 설계안](WINDOWS_APP_REGISTRATION_DESIGN.md)에만 정리합니다.
