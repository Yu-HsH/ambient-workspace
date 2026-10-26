# rc.2 설치 도우미 검토 기록 — 2026-10-26

## 기준과 현재 구조

작업 브랜치는 `feat/rc2-orca-desktop`, 기준 커밋은 `9f684032781bc06b47375331729f34923c92e019`입니다. 기존 Orca 미커밋 변경을 유지했습니다. `main`과 `v1.0.0-rc.1` 태그, 기존 DEV/운영 설치, 실제 설정·키, 실제 Native 등록은 변경하지 않았습니다. 커밋·push·Release 게시도 수행하지 않았습니다.

기존 설치는 `Desktop_Companion` 옆에 `Browser_Extension`을 두는 Portable 구조입니다. 첫 실행의 `Start.bat` → `Launch-AmbientDesktop.ps1` → `Start-AmbientDesktop.ps1` 순서에서 ACL을 먼저 검사한 뒤, 설정이 없을 때만 기본값을 복사하고 키가 없을 때만 제품의 기존 키 생성 경로를 사용합니다. 보안 실패 때는 설정/키/오류 로그도 쓰지 않습니다.

`File-Security.ps1`은 Desktop 모든 하위 파일의 개인 데이터 읽기/변경 권한, 소유자/정규 ACL/재분석 지점, 상위 경로의 삭제·권한 변경 권한, 형제 Chrome 확장의 변경 권한을 확인합니다. `Test-FileSecurity.ps1`은 같은 검사를 읽기 전용으로 호출합니다. `C:\SSAFY`에서 다른 사용자 그룹의 권한이 상속된 두 개발 폴더가 실패한 것은 이 경계에 따른 결과입니다. 새 도우미는 이 정책을 변경하거나 예외 처리하지 않습니다.

설정·백업·키는 계속 `settings.json`, `settings.json.bak`, `bridge-pairing.txt`입니다. Chrome 고정 ID는 `ncbcjbbidoaallpikijfbjdmijjljhoe`이며 확장 경로/Native host 경로 변경과 Chrome 저장소 유지 여부를 각각 확인해야 합니다. `Setup-Chrome.bat`은 기존 등록 GUI를 열며 Install/Repair/Recover의 기존 journal 기반 복구를 유지합니다.

## 구현 파일과 책임

| 파일 | 역할 |
|---|---|
| `Install.bat` | 한국어 콘솔 설치 마법사 진입점 |
| `Installer/Install-AmbientWorkspace.ps1` | ZIP 스냅샷/해시 검증, 신규 보호 폴더, 승인한 데이터 복사, 실행/ACL 검사, Native 상태·승인·인증 |
| `Installer/product-files.json` | 제품/문서만 포함하는 검토 패키지 allowlist |
| `tools/New-InstallPackage.ps1` | 내부 manifest와 ZIP/독립 도우미·각 해시를 생성하는 로컬 검토 도구 |
| `tests/test-installer.ps1` | 실제 NTFS·합성 개인 파일·시험용 Native 이름을 사용한 17개 시나리오 |
| `tests/test-native-registration.ps1` | 기존 Native 등록/복구 회귀 13개 시나리오를 공개 개발 트리에 포함 |
| `tools/Test-Installer.ps1` | 새 전용 시험 루트 생성 후 설치·Native·Orca 회귀 실행 |
| `tools/Test-Orca.ps1` | 기존 파서 검사에 Installer 폴더 추가; Orca 검증 경로 유지 |
| `docs/SAFE_INSTALL_GUIDE.md` | 설치/이전/등록/실패 복구와 출처 신뢰 제한 |
| README·CHANGELOG·Orca 문서 | 미배포 기능 안내와 사용자의 실제 Orca 표시 확인 보고 반영 |

기존 제품의 `File-Security.ps1`, `Test-FileSecurity.ps1`, `Start.bat`, `Setup-Chrome.bat`, Native 등록·Host 및 Browser 코드는 변경하지 않았습니다. 별도 SDK·패키지·외부 API 의존성도 추가하지 않았습니다.

## 안전한 생성·이전·등록

도우미는 검증된 메모리 ZIP에 담긴 원래 보안 검사만 로드합니다. 자기 파일의 변경 권한/상위 경로와 ZIP 내 도우미 해시까지 확인합니다. 새 폴더의 상속 차단 ACL을 `CreateDirectoryW`의 보안 기술자로 생성 순간에 지정하며, 이미 존재하는 경로에는 이 API가 실패합니다. 현재 사용자·SYSTEM·Administrators 이외의 주체를 추가하지 않습니다. 기존 폴더 ACL을 수정하는 코드 경로는 없습니다.

업데이트는 새 버전 폴더를 만들고 명시적인 `-ApproveMigration` 또는 마법사의 `복사` 승인 후 세 개인 파일만 바이트 그대로 복사합니다. 이전 위치의 권한은 검사/경고만 합니다. 이전 데이터가 이미 노출됐을 위험은 남습니다. 같은 Desktop mutex를 설치 전체 동안 소유하며, 실행 중이면 종료를 요청하고 프로세스를 강제 종료하지 않습니다. 보호된 새 폴더에서 복사 후 해시·독립 ACL 검사·실제 시작 전 필수 파일/Native 경로 길이/쓰기/WPF 검사까지 통과해야 완료 표시를 기록합니다.

Native 상태 조회는 읽기 전용이며 경로뿐 아니라 Host manifest의 실행 대상·허용 ID도 확인합니다. 등록은 사용자 승인 후 기존 GUI에서 최종 선택합니다. 실제 Host 인증은 별도 키 읽기 승인 뒤 표준 입출력과 기존 개인 메일박스로 검사합니다. 키 원문·인증 패킷을 명령행/로그/파일 큐에 저장하지 않고 Chrome 프로필 lease를 만들지 않습니다. Chrome 프로필의 실제 연결은 별도 단계로 남깁니다.

## 시험 결과

Windows PowerShell 5.1, WPF, 로컬 NTFS에서 수행했으며 시험 프로세스의 관리자 승격 상태는 `False`였습니다. 시험 루트는 `%USERPROFILE%\AmbientInstallerLab-Final-20261026-b6c2` 아래 새 하위 폴더들입니다. 기존 사용자 데이터 대신 기본값에서 만든 합성 설정·백업·64자리 합성 키를 사용했습니다. 레지스트리 시험은 매번 새 `org.ambientworkspace.lab_<GUID>` 이름만 생성하고 제거했습니다. 실제 제품 등록은 대상으로 사용하지 않았습니다.

| 요청 항목 | 결과 | 근거와 한계 |
|---|---|---|
| 1. 개인 NTFS 신규 설치 | PASS | 새 앱 관리 폴더·버전 폴더에 설치 완료 |
| 2. 상속 ACL이 불안전한 원본 | PASS | 시험 폴더에만 Authenticated Users 수정 상속을 부여. 그 위치의 도우미 실행은 거부하고, 독립 해시가 맞는 ZIP 데이터만 신뢰된 도우미에서 읽음 |
| 3. 신규 개인 폴더 ACL | PASS | 원자적 생성·보호 상속·실제 `Test-FileSecurity.ps1` PASS. 기존 경로와 ACL은 재사용/교체 거부 |
| 4. 최초 설치 | PASS | 기존 데이터 입력 없음. 도우미는 설정/키를 미리 생성하지 않음 |
| 5. 보존 업그레이드 | PASS | 승인 전 읽기 차단, 승인 후 설정/백업/키 원본·복사본 해시 동일, Orca 1.0 유지 |
| 6. 중단/복사 실패/공간 부족 | PASS(주입) | 취소 예외·실제 부분 복사 뒤 오류·여유 공간 0 반환을 주입. 이전 파일 보존, 실패 폴더 완료 표시 없음. 실제 디스크 고갈/강제 전원 중단은 미수행 |
| 7. Native 충돌/복구 | PASS | 독립 시험 레지스트리에서 충돌 거부·승인한 Repair·컴파일 실패/쓰기 거부 rollback·중단 journal 복구 13/13 |
| 8. 파일 변조/해시 | PASS | ZIP 기대 해시 불일치, 활성 writer, manifest 불일치, 복사 후 변조, 경로 탈출 거부 |
| 9. 이동과 재등록 | PASS | 시험 설치만 이동 후 `reregisterRequired`; 명시적 Repair 후 일치. 원본 합성 개인 파일 유지 |
| 10. 파일/백업/설정 보존 | PASS | 원본/복사본 해시 및 기존 폴더 SDDL 보존. 이전 개인 파일은 복사 동안 쓰기/삭제 공유 거부 |
| 11. Chrome 고정 ID | PASS | 공개 key에서 ID 재계산, manifest key 일치; 변조한 ID/key 패키지 거부 |
| 12. Orca/기존 Desktop 회귀 | PASS | 기존 설정·트레이·WPF 두 회귀 스크립트 통과. PS 5.1 33개 파일 파서·XAML·JSON 검사 통과 |
| Host 실제 인증 | PASS(합성) | 실제 컴파일 Host → 개인 메일박스 → 격리된 실제 제어 채널 왕복. 잘못된 토큰 거부, 응답 없는 Desktop을 성공 처리하지 않음 |
| 등록 경로와 Host 실행 대상 불일치 | PASS | 레지스트리 경로가 같아도 Host manifest 실행 대상이 다르면 재등록 필요 |
| 실제 Chrome/YouTube E2E | 미수행 | 사용자의 Chrome 프로필·저장소·Native 등록을 변경하지 않음 |
| 실제 사용자 Orca 표시 | 사용자 보고 | 2026-10-26 사용자가 확인했다고 보고. 이번 합성 설치 시험의 화면 검증 결과와 합산하지 않음 |
| 실제 두 계정 공격·악의적 경합/전원 중단 | 미수행 | 전용 시험 ACL·writer·원자적 기존 경로 거부만 검증 |

최종 설치 시험은 **17/17**, 별도 Native 등록·복구는 **13/13**, 기존 설정/WPF 회귀는 **2/2 스크립트 PASS**입니다. 서로 다른 범위이므로 과거 rc.1의 자동 52/52에 더하지 않습니다. 초기 개발 중 발견한 반환값 혼합과 시험 스코프 문제를 수정한 뒤의 통과 결과이며, 실패한 초기 시험 폴더도 개인 시험 루트에 남아 있습니다.

## 남은 위험과 사용자 검증

- 서명 없는 PowerShell 도우미는 실행 전에 이미 변조됐다면 자기 검사로 신뢰를 복원할 수 없습니다. 공식 출처와 별도 SHA-256 검증이 전제이며 같은 폴더에 있는 출처 불명 해시 파일을 자동 신뢰하지 않습니다. Authenticode/서명된 배포 메타데이터 도입은 후속 검토가 필요합니다.
- 현재 공개 rc.1 ZIP에는 새 내부 manifest가 없어 직접 설치할 수 없습니다. 새 형식의 rc.2 패키지와 도우미/해시를 배포 검토해야 합니다. 로컬 검토 ZIP은 공식 Release 인증을 뜻하지 않습니다.
- 기본 LocalAppData도 부모 ACL에 따라 차단될 수 있습니다. 다른 개인 경로 선택이 필요하며 부모/시스템 권한은 자동 수정하지 않습니다. 이번 UX는 콘솔 마법사입니다.
- 프로세스 중단 방지는 기존 `Local` Desktop mutex와 원본 파일 공유 잠금을 사용합니다. 동일 사용자의 여러 Windows 로그인 세션 전체를 포괄하는 실행 탐지는 검증하지 않았습니다.
- 실패한 새 폴더와 이전 위치에는 개인 파일 사본이 남을 수 있습니다. 자동 삭제/키 교체/보안 삭제를 하지 않습니다. 완료 표시 없는 폴더를 실행하지 않습니다.
- 등록 GUI의 사람 승인과 실제 Chrome 프로필 연결·원본 영상 재생·Orca RGB/영상 조합은 최종 사용자 수락이 필요합니다. 같은 사용자 악성코드, 공용 계정, 정책으로 차단된 환경의 안전성을 보장하지 않습니다.

실제 사용자는 공식 해시와 검증한 도우미로 **신규 설치 → 완료 폴더 Start.bat → Chrome 확장 경로/ID 확인 → 등록 위치 확인 → 승인한 등록 → Host 인증 → Chrome 팝업 인증 → Orca RGB/영상/왕복 확인** 순서로 검사합니다. 업그레이드는 원본을 보존한 별도 설치에서 데이터 복사를 승인하고 전후 개인 파일 해시/설정/키/Native 복구를 확인합니다. 상세 명령과 복구 절차는 [설치 안내](SAFE_INSTALL_GUIDE.md)를 따릅니다.
