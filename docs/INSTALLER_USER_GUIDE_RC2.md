# rc.2 설치 도우미 — 실제 사용자 검증 순서

이 문서는 **로컬 검토 패키지용**입니다. rc.2 공개 Release는 아직 만들지 않았습니다. 기존 rc.1 다운로드를 이 도우미에 넣지 마세요. 설치 시험 17/17, Native 시험 13/13은 앞선 합성 시험 결과이며 아래 실제 사용자 시험의 통과를 뜻하지 않습니다. 결과는 [별도 수락 기록](INSTALLER_USER_ACCEPTANCE_RC2.md)에 적습니다. 기존 [Orca 실사용 보고](ORCA_SUPPORT_RC2.md)는 별도로 유지합니다.

이번 준비 작업에서는 운영 등록·Chrome 프로필·사용자 설정·키·기존 ACL을 변경하지 않았습니다. 아래 명령은 **사용자가 이후 직접 실행할 절차**입니다. Native 변경과 Chrome 조작은 해당 단계에서 따로 결정합니다.

## 1. 시작과 출처 확인

관리자 권한 없이 시작 메뉴에서 **Windows PowerShell**을 엽니다. PowerShell 7의 `pwsh` 대신 Windows 기본 5.1을 사용합니다. 같은 창을 끝까지 유지하세요. 다음 실행은 일반 대화형 콘솔에서 합니다.

```powershell
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw '시작 메뉴에서 Windows PowerShell 5.1을 열어 다시 실행하세요.'
}
$ReviewDir = Read-Host '검토 파일이 있는 폴더의 전체 경로'
$ExpectedZip = Read-Host '이번 검토 완료 응답에 적힌 ZIP SHA-256'
$ExpectedHelper = Read-Host '이번 검토 완료 응답에 적힌 독립 도우미 SHA-256'
$PackageName = 'AmbientWorkspace-1.0.0-rc.2-user-review-20261026.zip'
$Zip = Join-Path $ReviewDir $PackageName
$HelperSource = $Zip + '.installer.ps1'
if ($ExpectedZip -notmatch '^[a-fA-F0-9]{64}$' -or $ExpectedHelper -notmatch '^[a-fA-F0-9]{64}$') {
    throw '검토 완료 응답의 64자리 해시를 사용하세요.'
}
if ((Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash -ine $ExpectedZip) { throw 'ZIP 해시 불일치: 중지' }
if ((Get-FileHash -LiteralPath $HelperSource -Algorithm SHA256).Hash -ine $ExpectedHelper) { throw '도우미 해시 불일치: 중지' }
Get-AuthenticodeSignature -LiteralPath $HelperSource | Select-Object Status
'PASS: ZIP과 독립 도우미 해시 일치'
```

예상 출력은 `NotSigned`와 `PASS: ZIP과 독립 도우미 해시 일치`입니다. `NotSigned`는 이번 도우미에 게시자 전자서명이 없다는 뜻입니다. 해시 일치는 **검토한 바이트와 같다**는 뜻이며 게시자 인증은 아닙니다. 도우미와 ZIP 옆 `.sha256`을 함께 바꿀 수 있는 출처라면 그 파일만으로 신뢰하지 마세요. 이번에는 이 대화의 기대 해시와 로컬 검토 결과를 별도 대조 기준으로 씁니다. 실제 배포 때에는 신뢰한 배포 채널에서 ZIP·독립 도우미·각 기대 해시를 확보해야 하며, 현재 rc.2 다운로드 주소는 없습니다.

## 2. 도우미를 실행할 새 개인 폴더

작업 저장소, 공유 폴더, 압축 해제한 제품의 `Install.bat`에서 먼저 실행하지 않습니다. ZIP은 압축을 풀지 않아도 됩니다. 도우미만 새 개인 폴더에 복사하고 다시 해시를 확인합니다. 이번 PC에서 사용자 폴더와 그 상위 경로를 읽기 전용 검사한 결과는 로컬 검토 보고서에 기록합니다. 다른 PC는 검사 결과가 달라질 수 있으며, 도우미의 실제 ACL 검사를 생략하지 않습니다.

```powershell
$Inbox = Join-Path $env:USERPROFILE 'AmbientWorkspace-Review-Inbox-20261026'
if (Test-Path -LiteralPath $Inbox) { throw '이미 있는 폴더를 재사용하지 마세요. 새 이름을 선택하세요.' }
New-Item -ItemType Directory -Path $Inbox | Out-Null
$Helper = Join-Path $Inbox 'Install-AmbientWorkspace.ps1'
Copy-Item -LiteralPath $HelperSource -Destination $Helper
if ((Get-FileHash -LiteralPath $Helper -Algorithm SHA256).Hash -ine $ExpectedHelper) { throw '복사한 도우미 해시 불일치' }
Get-Acl -LiteralPath $Inbox | Format-List Owner,AccessToString
'PASS: 개인 폴더로 도우미 복사 및 해시 재확인'
```

새 폴더 생성은 부모 권한을 상속할 뿐 기존 ACL을 고치지 않습니다. 개인 폴더는 본인·SYSTEM·Administrators 외 계정의 수정/삭제 권한이 없어야 합니다. 알 수 없는 수정 권한이 보이면 실행을 멈추세요. 본인 전용 폴더도 같은 계정 악성코드와 관리자까지 막지는 못합니다. 이후 도우미가 자신의 경로와 상위 경로를 다시 검사하며, 통과하지 못하면 `INSTALL_HELPER_LOCATION`으로 중지합니다. 서명 없는 코드가 이미 변조됐다면 실행 후 자기 검사로 안전해지지 않으므로 **실행 전 해시 확인**이 필요합니다.

`-ExecutionPolicy Bypass`는 아래 실행 프로세스의 옵션입니다. 시스템 실행 정책을 변경하는 `Set-ExecutionPolicy`나 파일 일괄 `Unblock-File`은 사용하지 않습니다. 조직 정책·보안 경고로 실행이 차단되면 중지하고 원인을 확인하세요. 관리자 실행으로 우회하지 않습니다.

## 3. 원래 Native 등록을 먼저 읽기 전용 보관

아래 함수는 HKCU의 32/64비트 보기만 읽습니다. 등록 값과 형식, 권한 문자열을 보관하며 키·설정 파일 내용은 읽지 않습니다. 이름에 `NATIVE-BLOCKED-review`가 있어도 현재 실제 등록 위치일 수 있으므로 이름만 보고 삭제하거나 새 경로를 추측하지 마세요.

```powershell
function Read-ReviewNativeRegistration {
    $subkey = 'Software\Google\Chrome\NativeMessagingHosts\org.ambientworkspace.bridge'
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $view)
        $key = $null
        try {
            $key = $base.OpenSubKey($subkey, $false)
            [pscustomobject]@{
                View = $view.ToString()
                Exists = ($null -ne $key)
                Value = $(if ($key) { $key.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null })
                Kind = $(if ($key) { $key.GetValueKind('').ToString() } else { $null })
                Names = $(if ($key) { @($key.GetValueNames()) } else { @() })
                Sddl = $(if ($key) { $key.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All) } else { $null })
            }
        } finally { if ($key) { $key.Dispose() }; $base.Dispose() }
    }
}
$BeforeNative = @(Read-ReviewNativeRegistration)
$BeforeNative | Format-Table View,Exists,Kind,Value -AutoSize -Wrap
$Snapshot = Join-Path $Inbox 'native-registration-before.json'
if (Test-Path -LiteralPath $Snapshot) { throw '기존 스냅샷을 덮어쓰지 마세요.' }
$BeforeNative | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Snapshot -Encoding UTF8
```

신규 사용자는 두 보기 모두 `Exists=False`를 기대합니다. 기존 사용자는 두 보기 모두 `Exists=True`, `Kind=String`, 동일한 원래 `native-host.json` 경로를 기대합니다. 한쪽만 존재하거나 경로가 다르거나 여분의 값·읽기 거부가 있으면 Native 변경을 보류합니다. 아래 업그레이드와 복원 예시는 **두 보기에 동일한 기존 String 값이 있고 기본값 외의 값이 없는 경우**에 한정합니다.

## 4. 최초 설치 또는 기존 사용자 복사 설치

기존 Desktop이 실행 중이면 트레이 우클릭 → **Desktop 앱 종료**로 종료합니다. 설정창의 닫기만으로는 종료되지 않습니다. 같은 PC에서 두 Desktop을 동시에 실행하지 않습니다.

### 신규 설치

```powershell
$NewRoot = Join-Path $env:USERPROFILE 'AmbientWorkspace-Rc2-FirstInstall-20261026'
$Zip
$ExpectedZip
$NewRoot
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File $Helper -Interactive
if ($LASTEXITCODE -ne 0) { throw '설치가 완료되지 않았습니다. 아래 오류 안내를 확인하세요.' }
```

| 콘솔 질문/표시 | 직접 입력 또는 예상 결과 |
|---|---|
| 다운로드한 공식 ZIP의 전체 경로 | 위 `$Zip`의 실제 전체 경로. 이번 것은 로컬 검토용이며 공식 배포물은 아님 |
| 공식 Release에서 별도로 확인한 ZIP SHA-256 | `$ExpectedZip`의 64자리 값 |
| 출처와 해시를 확인했습니까? | 검토 출처와 해시를 확인했다면 `설치` |
| 설치 위치 | 이번 검토는 `C:\Users\SSAFY\AmbientWorkspace-Rc2-FirstInstall-20261026` 같은 **새** 관리 폴더. 본인 PC는 사용자 폴더 이름에 맞춤 |
| 기존 설정·백업·페어링 키를 복사하려면 | 신규는 **Enter** |
| 파일 무결성 확인 중… | 이어서 `개발 검토용 패키지입니다. 공개 배포물로 승인된 것이 아닙니다.` |
| 안전한 설치 위치 확인 중… | `개인 전용 설치 폴더 준비 완료`, `PASS: local file ACL preflight...`, `파일 무결성 검사 통과 · 설치 완료` |
| Windows 실행 / Chrome 확장 위치 | `1.0.0-rc.2-review-<8자리>` 완료 폴더 아래 실제 두 경로 |
| 등록 안내창을 열려면 등록 입력 | **Enter**: 이번에는 등록을 미룸 |
| 현재 설치의 키를 읽어 … 인증 입력 | **Enter**: 최초 Desktop 실행 전이므로 미룸 |

기본 LocalAppData를 Enter로 선택했다가 `INSTALL_ACL_*`로 거부될 수 있습니다. 기존 경로의 ACL을 고치지 말고 마법사를 다시 실행해 **사용자 폴더 바로 아래 새 관리 폴더**를 입력하세요. 경로 입력란에 `$env:USERPROFILE` 문자열을 쓰면 확장되지 않습니다. PowerShell에서 아래처럼 실제 값을 출력해 복사합니다.

```powershell
$NewRoot = Join-Path $env:USERPROFILE 'AmbientWorkspace-Rc2-FirstInstall-20261026'
$Zip
$ExpectedZip
$NewRoot
```

기존 rc.1 사용자가 신규 시나리오도 확인한다면 여기서는 설치·첫 Desktop 실행까지만 확인하고 종료하세요. 새 시험 키를 기존 Chrome 팝업에 저장하지 마세요. 이후 아래 복사 설치를 별도 폴더에 준비해 E2E를 진행하면 기존 페어링을 유지할 수 있습니다.

### 기존 rc.1 사용자 업그레이드

같은 PowerShell 창에서 다음으로 원래 경로를 결정합니다. 경로를 추측하거나 개발 저장소를 기존 설치로 지정하지 않습니다.

```powershell
if ($BeforeNative.Count -ne 2 -or @($BeforeNative | Where-Object { -not $_.Exists -or $_.Kind -cne 'String' -or @($_.Names).Count -ne 1 -or @($_.Names)[0] -cne '' }).Count) {
    throw '기존 등록 형태가 예상과 다릅니다. Native 변경을 보류하세요.'
}
if ($BeforeNative[0].Value -cne $BeforeNative[1].Value) { throw '두 레지스트리 보기의 경로가 다릅니다.' }
$OldManifest = [string]$BeforeNative[0].Value
$OldDesktop = Split-Path $OldManifest
$OldRoot = Split-Path $OldDesktop
$NewRoot = Join-Path $env:USERPROFILE 'AmbientWorkspace-Rc2-Upgrade-20261026'
$OldDesktop
$NewRoot
```

개인 파일을 읽는 다음 명령은 **사용자가 보존 비교를 승인한 경우에만** 실행합니다. 해시만 메모리에 보관하며 원문을 출력하지 않습니다. 원래 Desktop은 먼저 종료하세요. 원본 폴더는 계속 보관하고 덮어쓰지 않습니다.

```powershell
if ((Read-Host '원본 설정·백업·페어링을 읽어 보존 비교하려면 비교 입력') -cne '비교') { throw '비교 미승인' }
$PersonalBefore = @{}
foreach ($name in @('settings.json','settings.json.bak','bridge-pairing.txt')) {
    $path = Join-Path $OldDesktop $name
    $PersonalBefore[$name] = $(if (Test-Path -LiteralPath $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null })
}
if (-not $PersonalBefore['settings.json'] -or -not $PersonalBefore['bridge-pairing.txt']) { throw '필수 기존 데이터가 없습니다. 초기화하지 말고 경로를 확인하세요.' }
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File $Helper -Interactive
if ($LASTEXITCODE -ne 0) { throw '복사 설치가 완료되지 않았습니다.' }
```

위 신규 질문표에서 설치 위치는 `$NewRoot`의 실제 값, 데이터 선택은 **`이전`**, 원래 위치는 `$OldRoot`의 실제 값, 세 파일 읽기·복사 승인은 **`복사`**로 입력합니다. 이후 등록과 인증 질문은 모두 **Enter**로 넘깁니다. `복사` 전에 취소하면 이전 데이터 복사는 진행하지 않습니다. 원래 ACL 경고는 남기고 승인한 데이터만 복사할 수 있으며, 원래 위치의 권한을 수정하지 않습니다.

## 5. 완료 폴더·제품 파일·ACL과 첫 실행

완료 경로는 임의의 8자리가 붙으므로 고정 이름을 가정하지 않습니다. 아래는 방금 선택한 `$NewRoot`에서 이번 해시의 **유일한** 완료 폴더를 찾습니다. 여러 개라면 자동으로 최신 폴더를 선택하지 않고 중지합니다.

```powershell
$Ready = @(Get-ChildItem -LiteralPath $NewRoot -Directory | Where-Object {
    $marker = Join-Path $_.FullName 'INSTALL-COMPLETE.json'
    if (Test-Path -LiteralPath $marker) {
        (Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json).zipSha256 -ieq $ExpectedZip
    }
})
if ($Ready.Count -ne 1) { throw '해당 ZIP의 완료 폴더가 유일하지 않습니다. 콘솔 완료 경로를 확인하세요.' }
$InstalledRoot = $Ready[0].FullName
$Desktop = Join-Path $InstalledRoot 'Desktop_Companion'
$Extension = Join-Path $InstalledRoot 'Browser_Extension'
$manifest = Get-Content -LiteralPath (Join-Path $InstalledRoot 'INSTALL-MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($item in $manifest.files) {
    $path = Join-Path $InstalledRoot $item.path
    if ((Get-Item -LiteralPath $path).Length -ne $item.bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $item.sha256) {
        throw ('복사한 제품 파일 불일치: ' + $item.path)
    }
}
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Desktop 'Test-FileSecurity.ps1')
if ($LASTEXITCODE -ne 0) { throw 'ACL 불통과: 실행하지 마세요.' }
$InstalledRoot
'PASS: 완료 표시·제품 파일·ACL 확인'
```

복사 설치는 **첫 실행 전에** 다음 비교를 추가합니다. 모든 줄의 `OriginalUnchanged`, `CopyMatches`가 `True`여야 합니다. 신규 설치는 이 비교를 건너뜁니다.

```powershell
foreach ($name in @('settings.json','settings.json.bak','bridge-pairing.txt')) {
    $original = Join-Path $OldDesktop $name
    $copy = Join-Path $Desktop $name
    $oldHash = $(if (Test-Path -LiteralPath $original) { (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash } else { $null })
    $newHash = $(if (Test-Path -LiteralPath $copy) { (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash } else { $null })
    if ($oldHash -cne $PersonalBefore[$name] -or $newHash -cne $PersonalBefore[$name]) { throw ('개인 파일 보존 불일치: ' + $name) }
    [pscustomobject]@{File=$name;OriginalUnchanged=$true;CopyMatches=$true}
}
```

이제 완료 폴더에서 실행합니다.

```powershell
Start-Process -FilePath (Join-Path $Desktop 'Start.bat') -WorkingDirectory $Desktop -WindowStyle Hidden
```

예상 화면: 관리자 UAC 요청 없이 트레이 아이콘이 생깁니다. 숨겨진 아이콘 **∧**도 확인하세요. 아이콘 두 번 클릭 → 설정창, **고급·진단**에서 Orca 대상과 배율을 확인합니다. 시작만으로 효과가 반드시 보이지는 않습니다. 대상 앱 활성 상태와 RGB/영상 ON 여부, YouTube 연결이 별도 조건입니다. 신규는 이 새 폴더에 설정·페어링이 최초 생성되고, 업그레이드는 복사한 키를 유지합니다. 첫 실행 직후 설정을 저장하기 전 위 보존 비교를 다시 실행하세요. 실제 설정 변경 후에는 새 복사본의 `settings.json`과 `.bak` 변경이 정상이며, 원래 세 파일은 계속 동일해야 합니다.

## 6. Chrome 확장과 Native 등록: 서로 다른 승인

**여기부터는 사용자가 실제 검증을 결정했을 때만 진행합니다. 이번 준비 작업에서는 실행하지 않았습니다.** rc.1 복구 경로와 아래 8번을 먼저 확인하고, Chrome에서 진행 중인 작업을 저장하세요.

| 단계 | 화면과 승인 | 바뀌는 범위 |
|---|---|---|
| Chrome 확장 로드 | `chrome://extensions` → 개발자 모드 → 압축해제된 확장 프로그램 로드 → `$Extension`의 실제 경로 | 선택한 Chrome 프로필의 확장 로드 위치. **Native 등록 아님** |
| Native 등록 창 열기 | 아래 `-Gui` 명령. 폴더 표시와 고정 ID 확인 | 창을 여는 것만으로 등록하지 않음 |
| Native 등록 최종 승인 | 신규는 **처음 등록**, 기존은 **이 폴더로 재등록** 클릭 | HKCU 32/64 보기와 새 Desktop의 Host 파일·journal. Chrome 확장 로드 위치를 바꾸지 않음 |
| 팝업 연결 | 기존 키 유지 확인 후 **코드 저장 · 연결 검사** | Chrome에 코드 저장 및 실제 Desktop 인증. 등록 성공과 별도 |
| YouTube 연결 | **YouTube 연결**과 Chrome의 탭 공유 선택/허용 | 선택한 영상 탭 캡처. 앞 단계와 별도 |

기존 고정 ID 확장을 쓰는 사용자는 **rc.1 폴더·확장 삭제·설정 초기화 없이** 새 경로 로드를 선택합니다. Chrome이 같은 ID 때문에 거부하거나 기존 설정을 유지하지 못하면 멈추고 기록하세요. 확장을 삭제해 재설치하는 방법으로 우회하지 않습니다. 이미 로드된 rc.1 확장으로 Desktop 연결을 확인할 수는 있지만, 그것만으로 rc.2 확장 경로 검증을 통과 처리하지 않습니다. 원래 확장 경로를 미리 기록해 복구 때 다시 로드할 수 있게 합니다. 새 로드 경로와 설정 보존 동작은 실제 Chrome에서 확인할 항목입니다.

새 확장 ID는 `ncbcjbbidoaallpikijfbjdmijjljhoe`여야 합니다. 다른 ID라면 이전 ID 마이그레이션을 이번 시험과 섞지 말고 중지합니다. 등록 직전 `$BeforeNative`와 현재 값이 같은지도 확인합니다.

```powershell
$PreRegistration = @(Read-ReviewNativeRegistration)
if (($PreRegistration | ConvertTo-Json -Depth 4 -Compress) -cne ($BeforeNative | ConvertTo-Json -Depth 4 -Compress)) { throw '보관 뒤 등록 정보가 달라졌습니다. 변경을 보류하세요.' }
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $Desktop 'Register-NativeHost.ps1') -Gui
```

예상 창 제목은 **Ambient Workspace · Chrome 연결 등록**입니다. **현재 Desktop 폴더**가 `$Desktop`인지 확인하고 ID를 붙여 넣으세요. 기존 경로가 있는데 **처음 등록**을 누르면 `NATIVE_REGISTRATION_CONFLICT`로 원래 등록을 보존합니다. 새 위치 사용을 결정했을 때만 **이 폴더로 재등록**을 누릅니다. 성공 문구는 **현재 사용자 등록을 저장했습니다. Chrome 팝업에서 페어링 코드와 실제 Desktop 연결을 확인하세요.**입니다.

```powershell
$AfterNative = @(Read-ReviewNativeRegistration)
$AfterNative | Format-Table View,Exists,Kind,Value -Wrap
$ExpectedNative = Join-Path $Desktop 'native-host.json'
if (@($AfterNative | Where-Object { -not $_.Exists -or $_.Kind -cne 'String' -or $_.Value -ine $ExpectedNative }).Count) { throw '새 Native 등록 경로 불일치' }
```

Desktop 설정 → 연결에서 기존 페어링 유지 여부를 확인합니다. 기존 Chrome 코드로 연결되면 다시 저장하지 않아도 됩니다. 신규만 Desktop **페어링 코드 복사** → 팝업 **연결 설정 → Windows 연결 → 코드 저장 · 연결 검사**를 진행합니다. 키를 터미널·명령행·기록표에 붙이지 마세요. 팝업의 실제 Desktop 상태 조회가 성공해야 합니다. 필요 시 도우미의 추가 Host 인증은 별도 키 읽기 승인을 받아 실행할 수 있지만, Chrome 팝업 검증을 대신하지 않습니다.

## 7. YouTube·Orca·재실행 확인

1. YouTube 영상 로딩 후 확장 **YouTube 연결**을 누릅니다. 공유 선택창이 나오면 해당 YouTube 탭만 선택합니다. 원본 영상과 소리가 계속 재생되는지 확인합니다.
2. **Windows로 전송**을 켭니다. 흐릿한 영상 시험 때는 **흐릿한 영상도 전송**을 켭니다. Desktop 전체 ON과 통합 Pause 해제를 확인합니다.
3. Orca를 활성화하고 `RGB ON / 영상 OFF`, `RGB OFF / 영상 ON`, `둘 다 ON`, `둘 다 OFF`를 각각 눈으로 확인합니다. 기존 설정이 OFF이면 설치가 자동으로 켜지 않으므로 사용자가 검증용 복사본에서 바꿉니다.
4. 효과를 켠 세 조합에서 각각 Orca → 메모장 → Orca를 3회 반복합니다. 미지원 앱에서는 잔상이 없어지고 돌아오면 복귀해야 합니다. VS Code 등 지원 앱 왕복과 Orca 이동·크기 변경·최소화·복귀도 확인합니다.
5. Pause/Resume가 개별 OFF를 유지하는지 확인합니다. 트레이 → **Desktop 앱 종료** 후 **같은 완료 폴더**에서 Start.bat을 다시 실행합니다. 키·설정 유지와 팝업 연결을 재확인합니다.
6. Chrome 재시작 후 저장된 페어링·Native 연결을 확인합니다. 끝난 캡처는 **YouTube 연결을 다시 명시적으로 승인**해야 합니다. 키 재발급으로 해결하지 않습니다.

화면을 직접 보지 못한 항목은 `미수행`으로 둡니다. 과거 Orca 표시 확인을 이번 설치 시험 PASS로 옮기지 않습니다.

## 8. 실패 보존과 rc.1 등록 복원 준비

설치 실패는 `.pending-...` 또는 완료 표시 없는 새 폴더를 남길 수 있습니다. 개인 파일 사본이 들어갈 수 있으므로 공유하거나 Git에 추가하지 말고 실행도 하지 마세요. 원본은 덮어쓰거나 자동 삭제하지 않습니다. 공간·잠금·경로 원인을 해결한 다음 새 시도를 합니다. 실제 디스크를 가득 채우거나 운영 파일을 잠가 실패를 재현하지 않습니다. 복사 실패·중단·공간 부족 보존은 앞선 합성 시험의 결과를 참고하고 실제 중단은 관찰된 경우에만 별도 기록합니다.

**등록 변경 전 실패:** Native 값이 `$BeforeNative`와 같은지만 읽어 확인합니다. rc.1 파일과 등록은 그대로 보존됩니다.

**등록 도중 실패:** Chrome의 작업을 저장하고 종료한 뒤 새 폴더 등록 GUI에서 **실패 이전으로 복구**를 선택합니다. 이는 `prepared/recoveryRequired` journal의 실패 복구입니다. **이미 성공한 재등록을 되돌리는 버튼은 아닙니다.** 복구가 필요한 journal이 없으면 `NATIVE_RECOVERY_NOT_PENDING`을 표시합니다.

**성공한 rc.2 시험 후 rc.1 경로로 복원:** 다음은 원래 두 보기에 같은 String 기본값이 있던 사용자만을 위한 절차입니다. Chrome과 rc.2 Desktop을 정상 종료하고 사용자 승인 후 **기본 등록 값만** 원래 경로로 되돌립니다. 원래 폴더의 Host/설정/키/ACL은 변경하지 않습니다. 실행 전까지는 복구 준비일 뿐입니다.

```powershell
# 같은 세션을 잃었다면 새 기준을 만들지 말고 보관한 원본 스냅샷을 읽습니다.
# $BeforeNative = Get-Content -LiteralPath $Snapshot -Raw -Encoding UTF8 | ConvertFrom-Json
if ($BeforeNative.Count -ne 2 -or @($BeforeNative | Where-Object { -not $_.Exists -or $_.Kind -cne 'String' -or @($_.Names).Count -ne 1 -or @($_.Names)[0] -cne '' }).Count) { throw '이 복원 예시의 대상이 아닙니다.' }
if ($BeforeNative[0].Value -cne $BeforeNative[1].Value) { throw '원래 두 등록 값이 다릅니다.' }
$OldManifest = [string]$BeforeNative[0].Value
if (-not (Test-Path -LiteralPath $OldManifest -PathType Leaf)) { throw '원래 Native manifest가 없습니다. 복원을 보류하세요.' }
$CurrentNative = @(Read-ReviewNativeRegistration)
if (@($CurrentNative | Where-Object { -not $_.Exists -or $_.Kind -cne 'String' -or @($_.Names).Count -ne 1 -or @($_.Names)[0] -cne '' -or ($_.Value -ine $ExpectedNative -and $_.Value -cne $OldManifest) }).Count) { throw '예상 밖의 등록입니다. 덮어쓰지 마세요.' }
if ((Read-Host 'Chrome과 rc.2 Desktop을 종료했고 원래 등록 경로로 되돌리려면 rc1복원 입력') -cne 'rc1복원') { throw '복원 미승인' }
$RegKey = 'HKCU\Software\Google\Chrome\NativeMessagingHosts\org.ambientworkspace.bridge'
& "$env:SystemRoot\System32\reg.exe" add $RegKey /ve /t REG_SZ /d $OldManifest /f /reg:32
if ($LASTEXITCODE -ne 0) { throw '32비트 보기 복원 실패. 중지하고 두 보기를 다시 확인하세요.' }
& "$env:SystemRoot\System32\reg.exe" add $RegKey /ve /t REG_SZ /d $OldManifest /f /reg:64
if ($LASTEXITCODE -ne 0) { throw '64비트 보기 복원 실패. 중지하고 두 보기를 다시 확인하세요.' }
$Restored = @(Read-ReviewNativeRegistration)
if (($Restored | ConvertTo-Json -Depth 4 -Compress) -cne ($BeforeNative | ConvertTo-Json -Depth 4 -Compress)) { throw '원래 등록 값/형식/ACL과 다릅니다. 실행을 보류하세요.' }
'PASS: rc.1 등록 값·형식·권한 복원 확인 (Desktop 실행은 별도)'
```

이 두 쓰기는 하나의 트랜잭션이 아닙니다. 중간 실패하면 Chrome/Desktop을 열지 말고 두 보기를 읽어 확인한 후 원인을 해결하세요. 등록에 새로운 충돌이 생겼거나 권한이 거부되면 관리자 권한·ACL 변경으로 우회하지 않습니다. 신규 사용자에게 원래 없던 등록을 지우는 명령은 이 업그레이드 복원 예시에 포함하지 않습니다.

Chrome 확장 경로를 바꿨다면 기록한 **원래 rc.1 Browser_Extension 경로**를 다시 로드합니다. 같은 고정 ID·기존 설정 유지가 확인되지 않으면 삭제/초기화하지 말고 기록하세요. 원래 Desktop의 읽기 전용 ACL 검사를 통과할 때만 다시 실행합니다.

```powershell
$OldDesktop = Split-Path $OldManifest
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Desktop 'Test-FileSecurity.ps1') -Directory $OldDesktop
if ($LASTEXITCODE -ne 0) { throw '등록 값은 복원했지만 rc.1 실행 경로는 ACL 불통과입니다. 기존 ACL을 고치거나 실행을 강행하지 마세요.' }
Start-Process -FilePath (Join-Path $OldDesktop 'Start.bat') -WorkingDirectory $OldDesktop -WindowStyle Hidden
```

원래 폴더와 그 상위 경로가 현 시점의 권한 검사를 통과할지는 별도 조건입니다. 등록 경로를 되돌리는 것으로 ACL 문제를 해결하지는 못합니다. 설정 저장 시험을 했다면 새 복사본의 정상 변경과 원래 파일의 보존을 구분해 기록합니다.

## 9. 오류를 만났을 때

| 표시 | 해결과 중지 기준 |
|---|---|
| `INSTALL_HELPER_LOCATION` | 해시를 확인한 도우미를 사용자 폴더 바로 아래 다른 새 개인 위치에 복사. 그 상위 권한도 거부되면 중지 |
| `INSTALL_ACL_*`, `INSTALL_FOLDER_ACCESS` | 기존 ACL을 고치지 않고 다른 새 개인 위치 선택. 이번 PC는 기본 LocalAppData 대신 사용자 폴더 바로 아래 권장 |
| `INSTALL_PARENT_MISSING` | 존재하는 사용자 폴더 바로 아래 새 이름 사용. 이미 설치한 제품 폴더를 부모로 지정하지 않음 |
| `INSTALL_DESTINATION_*`, `INSTALL_FOLDER_EXISTS` | 기존 제품과 겹치지 않는 새 관리 폴더 선택 |
| `INSTALL_DESKTOP_RUNNING` | 트레이의 Desktop 앱 종료 후 재시도. 강제 종료하지 않음 |
| `INSTALL_*HASH*` | 중지. 검토 출처와 ZIP/독립 도우미의 기대 해시를 각각 재확인 |
| `INSTALL_DISK_FULL`, 복사 실패 | 불완전 폴더 실행 금지. 원본 보존 확인 후 충분한 공간의 새 위치로 재시도 |
| `NATIVE_REGISTRATION_CONFLICT` | 원래 등록 보존 상태. 사용자 결정 뒤에만 이 폴더로 재등록 |
| `NATIVE_FILE_SECURITY`, `NATIVE_REGISTRY_SECURITY` | 실행/등록 보류. 관리자 실행·시스템 ACL 수정·키 재발급으로 해결하지 않음 |
| 연결은 저장됐지만 실제 상태 조회 실패 | Desktop 실행 위치·등록 경로·고정 ID 확인. 팝업/YouTube/Host 각 단계를 따로 기록 |
