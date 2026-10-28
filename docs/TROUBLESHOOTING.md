# 문제 해결

새 rc.2 설치 마법사 기준입니다. 공개 rc.1은 [기존 설치 안내](WINDOWS_PORTABLE_GUIDE.md)와 [알려진 문제](KNOWN_ISSUES.md)를 함께 보세요. **사용자 행동 안내**와 **원인 코드**는 분리합니다. 원문 예외에는 경로·키가 들어갈 수 있어 화면에 그대로 표시하지 않습니다.

| 보이는 문제 | 먼저 할 일 | 원인 코드·고급 확인 |
|---|---|---|
| Windows가 설치 파일이나 스크립트 실행을 차단함 | 창을 닫고 공식 Release의 버전·SHA-256과 파일 출처를 확인합니다. 조직 PC는 관리자에게 승인된 설치 방식을 문의합니다. SmartScreen·백신·실행 정책을 끄거나 관리자 실행·차단 해제 명령으로 해결하지 않습니다. | 스크립트 실행 전 차단은 앱 오류 코드가 없을 수 있습니다. 미서명 한계이며 서명된 배포 경로가 필요합니다. |
| `Install.bat`만 실행되고 마법사가 안 열림 | ZIP을 오른쪽 클릭 → **모두 압축 풀기**. 원본 ZIP과 전체 폴더를 보관하고 풀린 폴더의 `Install.bat`을 실행합니다. | `INSTALL_EXTRACT_ALL` |
| 원본 ZIP 위치가 비어 있음 | **ZIP 선택**으로 다운로드한 원본 Windows ZIP을 선택합니다. `Source code (zip)`이나 내부 파일을 선택하지 않습니다. | `INSTALL_PACKAGE_MISSING`, `INSTALL_MANIFEST_REQUIRED` |
| 해시가 다르거나 입력이 안 됨 | 공식 Release 본문에서 같은 버전의 64자리 해시를 복사합니다. 파일이 다르면 실행을 중단하고 공식 출처에서 다시 받습니다. 동봉 해시로 자동 승인하지 않습니다. | `INSTALL_EXPECTED_HASH_REQUIRED`, `INSTALL_ZIP_HASH`, `INSTALL_FILE_HASH`, `INSTALL_HELPER_HASH` |
| 설치 폴더 권한·환경 검사 실패 | **설치 위치 · 고급**에서 개인 로컬 NTFS의 새 앱 관리 폴더를 선택합니다. 기본 위치가 막혔다면 사용자 폴더 바로 아래의 새 위치를 사용합니다. 기존 ACL·공유 권한은 고치지 않습니다. | `INSTALL_ACL_*`, `INSTALL_HELPER_LOCATION`, `INSTALL_NTFS_REQUIRED`, `INSTALL_FOLDER_ACCESS` |
| 이미 다른 Desktop 버전 실행 중 | 숨겨진 트레이 아이콘 **∧** → 기존 Ambient Workspace 우클릭 → **Desktop 앱 종료**. 강제 종료하지 않고 설치 또는 Desktop 실행을 다시 시도합니다. | `INSTALL_DESKTOP_RUNNING`, `ALREADY_RUNNING` |
| Chrome이 manifest를 찾을 수 없다고 함 | **폴더 위치 복사**로 표시된 **`Browser_Extension` 자체**를 선택합니다. 바로 안에 `manifest.json`이 있어야 합니다. 상위 폴더·`source`·ZIP 안은 잘못된 위치입니다. | Chrome 확장 관리 화면의 오류. 앱이 확장 추가 성공을 자동 판정하지 않습니다. |
| Host 등록은 됐는데 Windows 연결 안 됨 | 등록한 **같은 폴더**의 `Desktop_Companion\Start.bat` 실행 → 트레이 확인 → 팝업 **Windows 연결**. 설치 완료·등록 완료만으로 Desktop 실행을 가정하지 않습니다. | `desktopNotRunning`, `bridgeUnavailable` |
| 새 위치로 재등록해도 이전 버전에 연결됨 | 팝업 **연결 설정 → Windows 연결**을 눌러 기존 포트를 닫고 현재 등록에서 새 연결을 엽니다. 계속 실패하면 `chrome://extensions`에서 확장을 새로고침하고 작업 탭도 새로고침합니다. | `nativeUnavailable`, `hostStartFailed`, 기존 Native 포트. 키·설정 초기화 없음. |
| 최초 코드 필요 / 기존 키 인증 실패 | 현재 실행 중인 설치의 Desktop 설정 → **연결 → 페어링 코드 복사**. 최초 인증 안내에만 붙여넣고 **코드 저장 · 연결 검사**. 틀린 코드는 기존 저장 키를 덮어쓰지 않습니다. 다른 설치가 실행 중인지 먼저 확인합니다. | `pairingRequired`, `pairingRejected`. 키 재발급·인증 우회 금지. |
| YouTube 연결됨, Windows 출력은 안 나옴 | Windows 연결의 실제 인증 → **Windows로 전송** ON → 필요하면 **흐릿한 영상도 전송** ON → Desktop의 RGB·영상 사용 및 대상 앱 활성 상태를 확인합니다. Chrome·Windows 각각의 일시정지도 확인합니다. | 캡처 성공은 Windows 출력 성공이 아닙니다. Chrome 송신 상태와 Desktop 트레이 표시 상태를 각각 확인합니다. |
| Chrome-only인데 Windows 오류가 보임 | 웹 배경·YouTube 조명은 Desktop 없이 사용할 수 있습니다. Windows로 전송은 끈 채 웹 기능을 확인합니다. Windows 연결·페어링을 완료할 필요가 없습니다. | Chrome 효과 일시정지/재개는 Windows 연결과 독립입니다. |
| 업데이트 승인·개인 파일 복사 실패 | 기존 Desktop을 종료하고 기존 폴더를 정확히 선택합니다. 설정·키가 모두 있는지 본인 PC에서 확인합니다. 원본을 삭제·초기화하지 않습니다. | `INSTALL_MIGRATION_APPROVAL_REQUIRED`, `INSTALL_MIGRATION_INCOMPLETE`, `INSTALL_MIGRATION_KEY_INVALID` |
| 복사 도중 중단 / 공간 부족 | 불완전한 새 폴더는 실행하지 않습니다. 공간·잠금을 해결한 뒤 새 시도로 설치합니다. 원본은 보존되며 남은 개인 사본 폴더를 공유하지 않습니다. | `INSTALL_DISK_FULL`, `INSTALL_COPIED_HASH`, `INSTALL_IO_OR_POLICY` |

Windows 기본 실행 정책은 환경에 따라 스크립트 실행이나 인터넷에서 받은 미서명 스크립트를 막습니다. 새 설치 진입점은 실행 정책을 낮추지 않습니다. 코드 서명은 배포자 확인을 개선하지만 `Restricted`처럼 모든 스크립트를 막는 정책에서는 서명만으로 충분하지 않을 수 있습니다. 승인된 서명 설치 프로그램 설계와 실제 다운로드 시험이 필요합니다. [Microsoft 실행 정책 설명](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1)

연결 등록을 복구하려면 [Native 등록·복구 안내](NATIVE_MESSAGING_GUIDE.md)를 따릅니다. 문의에는 **버전, 원인 코드, 발생 시각, 신규/업데이트 여부, 바로 전 누른 버튼**만 먼저 제공합니다. 키·전체 설정·Chrome 프로필·원문 로그·캡처 영상은 첨부하지 않습니다.
