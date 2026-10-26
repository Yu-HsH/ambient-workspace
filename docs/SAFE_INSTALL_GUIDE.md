# rc.2 개발용 안전한 설치 도우미

실제 사용자 검증은 [단계별 실행 명령·예상 화면·등록 복원 안내](INSTALLER_USER_GUIDE_RC2.md)를 따르고 [별도 수락 기록](INSTALLER_USER_ACCEPTANCE_RC2.md)에 기록합니다. 패키지별 실제 경로와 기대 해시는 로컬 검토 보고서에 제공합니다. 기존 Orca 확인과 새 설치 도우미 수락 결과는 합산하지 않습니다.

이 기능은 미커밋 개발 변경입니다. 현재 공개 `v1.0.0-rc.1` 배포 ZIP은 새 `INSTALL-MANIFEST.json`이 없으므로 이 도우미의 입력으로 지원하지 않습니다. rc.2 배포 검토 시 새 형식으로 패키징해야 하며, 이번 작업은 공개 Release나 기존 운영 설치를 갱신하지 않습니다.

## 처음 사용하기

1. 공식 Release의 **원본 Windows ZIP**, ZIP SHA-256, 독립 실행형 `Install-AmbientWorkspace.ps1`을 신뢰 가능한 경로에서 확인합니다. 도우미 자체의 SHA-256도 별도로 확인해야 합니다. ZIP과 함께 받은 출처 불명의 해시만으로 출처를 신뢰하지 않습니다.
2. 검증한 도우미를 다른 Windows 계정이 수정할 수 없는 개인 위치에서 Windows PowerShell 5.1로 실행합니다. `Install.bat`은 콘솔 안내를 여는 편의 진입점입니다. 도우미가 바뀐 상태에서 실행된 공격을 자기 해시 검사만으로 되돌릴 수 없으므로, 서명 없는 도우미의 사전 출처 확인은 필수입니다.
3. ZIP 경로와 공식 출처에서 별도로 확인한 SHA-256을 입력하고 출처 확인을 승인합니다. 원본 ZIP을 직접 읽으며 압축 해제 폴더의 PS1/BAT는 실행하지 않습니다.
4. 기본 `%LOCALAPPDATA%\AmbientWorkspace`를 제안합니다. 실제 부모 권한 검사에 실패하면 기존 권한을 고치지 않고 `%USERPROFILE%\AmbientWorkspace` 등 다른 새 개인 경로를 입력합니다. 사용자가 수동 ACL 명령을 실행할 필요는 없습니다.
5. 신규 설치 또는 기존 데이터 복사를 선택합니다. 데이터 복사는 별도 승인 뒤에만 수행합니다. Desktop이 실행 중이면 트레이에서 종료한 뒤 다시 시도합니다.
6. 완료된 새 버전 폴더의 `Desktop_Companion\Start.bat`과 `Browser_Extension` 위치를 확인합니다. 새 폴더는 설치마다 다른 이름이며 기존 설치를 덮어쓰지 않습니다.

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Installer\Install-AmbientWorkspace.ps1 -Interactive
```

자동화 호출은 출처 확인을 명시해야 합니다. 아래 해시는 예시 자리표시자이며 실제 공식 ZIP 해시를 사용해야 합니다.

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Installer\Install-AmbientWorkspace.ps1 `
  -PackagePath 'C:\Users\사용자\Downloads\AmbientWorkspace.zip' `
  -ExpectedSha256 '공식_Release에서_별도로_확인한_64자리_SHA256' `
  -DestinationRoot "$env:LOCALAPPDATA\AmbientWorkspace" -SourceVerified
```

## 보안 경계와 파일 검증

ZIP 출처/해시 확인과 설치 후 ACL 검사는 별개입니다. 도우미는 네트워크에서 최신 해시를 자동으로 신뢰하거나 ZIP 옆 `.sha256`을 자동 승인하지 않습니다. `-SourceVerified`는 호출자가 공식 출처와 해시를 확인했다는 승인이고 전자서명 검증을 뜻하지 않습니다.

ZIP을 쓰기·삭제 공유 없이 열고 크기를 제한한 메모리 스냅샷을 만듭니다. 그 바이트의 전체 ZIP 해시가 기대값과 일치한 뒤에만 ZIP을 해석합니다. 내부 manifest의 각 파일 크기·SHA-256과 실제 ZIP 멤버 목록을 일치시킵니다. 경로 탈출, 절대 경로/ADS, 예약 이름, 대소문자 중복, 심볼릭 링크/재분석 지점, 허용하지 않은 개인·실행 중 파일, 과도한 파일 수/크기를 거부합니다. 기존 확장의 공개 key와 고정 ID `ncbcjbbidoaallpikijfbjdmijjljhoe`도 검증합니다.

현재 입력 한도는 ZIP/전체 압축 해제 바이트 각 32MiB, 항목 256개, 개별 제품 파일 5MiB, 이전 개인 파일 각 1MiB입니다. 초과한 파일은 잘라서 복사하지 않고 설치를 거부합니다.

검증한 ZIP에 담긴 기존 `File-Security.ps1`만 메모리에서 로드합니다. 압축 해제 폴더 옆 파일을 로드하지 않습니다. 도우미 자신의 파일/상위 경로가 다른 계정에 의해 수정 가능하면 설치를 차단합니다. 이미 변조된 도우미가 검사 전에 실행되는 위험까지 이 검사로 제거할 수 없다는 제한은 남습니다.

이후 설치는 검증된 메모리 바이트만 사용하므로 원본 ZIP/압축 해제 폴더의 이후 변경을 설치 바이트로 다시 가져오지 않습니다. 복사 후 각 파일과 manifest를 재검증하고, 기존 `Assert-AmbientInstallSecurity` 및 별도 프로세스의 `Test-FileSecurity.ps1` PASS를 확인합니다. 완료 직전 다시 검증하며 `INSTALL-COMPLETE.json`이 있어야 도우미의 Native 후속 기능을 사용할 수 있습니다.

새 앱 전용 폴더를 생성하는 순간에만 상속을 차단하고 현재 사용자·SYSTEM·Administrators에 상속 가능한 FullControl을 부여합니다. 일반 Users/Authenticated Users 권한은 넣지 않습니다. 현재 사용자는 업데이트와 쓰기·삭제에 필요하고 SYSTEM/Administrators는 기존 정책의 신뢰 주체입니다. 이는 실행 계정 분리나 같은 계정 악성코드 방어를 제공하지 않습니다. 기존 폴더·DEV·시스템의 소유자나 ACL을 변경하지 않으며, 상위 폴더 검사도 생략하지 않습니다. NTFS 고정 로컬 볼륨만 새 설치 대상으로 지원합니다.

[Windows ACL 상속 보호](https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.objectsecurity.setaccessruleprotection?view=netframework-4.8.1), [파일 공유 모드](https://learn.microsoft.com/en-us/dotnet/api/system.io.fileshare?view=netframework-4.8.1)의 플랫폼 동작을 사용합니다. 파일 해시는 공개 출처·서명·설치 후 접근 제어를 대신하지 않습니다.

## 기존 사용자 업데이트와 실패 복구

기존 설치 루트 또는 `Desktop_Companion`을 지정한 뒤 세 파일을 읽고 복사하도록 별도 승인합니다. 승인 전에는 개인 파일 내용이나 키를 읽지 않습니다. 복사 대상은 `settings.json`, 존재하는 `settings.json.bak`, `bridge-pairing.txt`뿐입니다. 이전 설치의 스크립트·EXE·Native 등록 파일·로그·프레임은 가져오지 않습니다.

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Installer\Install-AmbientWorkspace.ps1 `
  -PackagePath '공식_ZIP_전체경로' -ExpectedSha256 '공식_64자리_SHA256' `
  -DestinationRoot "$env:USERPROFILE\AmbientWorkspace" -SourceVerified `
  -ExistingInstall '기존_설치_루트' -ApproveMigration
```

같은 Desktop 인스턴스 mutex를 설치 전체 동안 소유해 중간 실행을 막습니다. 이미 실행 중이면 설치를 시작하지 않고 종료를 요청합니다. 프로세스를 강제 종료하지 않습니다. 승인한 개인 파일은 변경/삭제 공유 없이 열어 원본 바이트를 보관하고 설정 형식·키 형식을 메모리에서 검사합니다. 복사 후 원본과 복사본의 해시를 비교하며 정규화한 설정을 파일에 덮어쓰지 않습니다. Orca 이전은 다음 제품 실행의 기존 호환 경로로 적용됩니다.

설치 중 취소·공간 부족·복사/검증 실패는 새 `.pending-...` 또는 완료 표시가 없는 새 버전 폴더만 남길 수 있습니다. 승인한 개인 파일 사본이 포함될 수 있으므로 이 폴더도 공유하거나 Git에 추가하지 마세요. 도우미는 자동으로 폴더를 재귀 삭제하지 않습니다. 해당 불완전 폴더를 실행하지 말고 공간/잠금/경로 문제를 해결한 뒤 새 시도로 설치하세요. 원본 설치와 기존 Native 등록은 설치 단계에서 변경하지 않아 그대로 복구 기준으로 남습니다. 이미 다른 위치로 재등록한 뒤의 복구는 아래 등록 안내를 따릅니다.

기존 위치에 남은 설정·키는 자동으로 안전해지거나 삭제되지 않습니다. 과거에 다른 계정이 읽을 수 있었던 키를 복사한다고 기존 노출이 회수되지 않습니다. 이 도우미는 키 재발급·자동 재페어링을 하지 않습니다. 오래된 개인 파일의 별도 보관/제거는 사용자가 결정합니다.

## Chrome Native 등록과 실제 인증

설치 완료 뒤 HKCU 두 레지스트리 보기를 읽어 기존 등록 위치와 `installRequired / reregisterRequired / registered`를 표시합니다. 상태 조회는 등록을 바꾸지 않습니다. 사용자가 `등록`을 승인하면 기존 `Register-NativeHost.ps1 -Gui`를 호출하고, 사용자가 그 창에서 **처음 등록 / 이 폴더로 재등록**을 선택합니다. 기존 절차의 충돌 거부·등록 journal·실패 이전으로 복구 기능을 그대로 사용합니다.

[Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)은 등록 경로와 허용 확장 ID를 사용하므로 설치 위치 변경 뒤에는 재등록이 필요합니다. 확장 자체는 고정 공개 key를 유지하지만 Chrome은 새 확장 경로를 사용해야 합니다. Chrome 프로필/확장 저장소를 도우미가 편집하지 않으며 옛 확장을 자동 제거하지 않습니다. 예전 key 없는 ID를 사용했다면 [기존 Native 이전 안내](NATIVE_MESSAGING_GUIDE.md)를 따릅니다.

등록 성공은 인증 성공이 아닙니다. Desktop을 먼저 실행한 뒤 `인증`을 별도 승인하면 현재 설치의 키를 메모리에서 읽고 검증된 Host EXE를 통해 실제 `control.hello` 왕복을 검사합니다. 키를 명령행·파일 명령 큐·로그에 쓰지 않고 profileId도 보내지 않아 Chrome 프로필 lease를 생성/갱신하지 않습니다. 성공은 Host ↔ 실행 중인 Desktop의 인증만 뜻합니다. Chrome 팝업의 **코드 저장 · 연결 검사**와 YouTube RGB/영상 출력은 별도 사용자 검증입니다.

등록/인증 실패 시 앱 설치 파일과 개인 파일은 보존합니다. 기존 등록 GUI의 **실패 이전으로 복구**로 해당 journal의 등록/Host 파일만 복구하고 필요하면 보존한 이전 폴더에서 등록 위치를 되돌립니다. Chrome 보안 정책·레지스트리 ACL 차단을 관리자 실행이나 보안 해제로 우회하지 않습니다.

## 개발 검토 패키지와 시험

아래 도구는 allowlist의 제품 파일만 담은 **로컬 검토용** ZIP과 내부 manifest/`.sha256`을 생성합니다. 공개 출처를 보증하지 않으며 기존 rc.1 ZIP/태그/Release를 변경하지 않습니다. 테스트에서만 이 생성 해시를 기대값으로 사용합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\New-InstallPackage.ps1 `
  -OutputPath .\artifacts\AmbientWorkspace-rc2-review.zip
```

실제 시험 결과와 미수행 항목은 [설치 도우미 검증 기록](INSTALLER_VALIDATION_RC2.md)에 기록합니다. 개발 작업 폴더 자체는 ACL 검사 실패 위치일 수 있으므로 도우미의 실사용 진입점으로 취급하지 않습니다. 운영 설정·키·현재 검증용 설치는 테스트 입력으로 사용하지 않습니다.

개발 회귀를 한 번에 실행하려면 아래 명령을 사용합니다. 사용자 폴더 아래 **새로운** 전용 시험 루트만 만들며, 합성 데이터와 무작위 Native 시험 이름을 사용합니다. 기존 경로를 지정하면 덮어쓰지 않고 거부합니다. 시험 파일은 검토를 위해 남깁니다.

```powershell
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File .\tools\Test-Installer.ps1
```
