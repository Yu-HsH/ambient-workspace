# Ambient Workspace 1.0.0-rc.1

YouTube 영상의 색과 흐릿한 영상을 웹 작업 공간과 Windows 조명에 연결하는 무료 수동 설치형 앱입니다. 원본 영상과 오디오는 그대로 재생되며, 웹 배경은 Demo 또는 명시적으로 연결한 영상의 Live 모드로 사용할 수 있습니다.

**공개 테스트용 Release Candidate입니다. 정식 1.0.0이 아닙니다.** 지원 범위는 **본인 전용 Windows 계정과 ACL 검사를 통과한 로컬 NTFS 설치**입니다. 실제 두 Windows 계정 접근 실험은 수행하지 않았습니다. 공용 계정·공유 폴더·조직 정책 환경의 안전성을 보장하지 않습니다. [Known Issues](docs/KNOWN_ISSUES.md)와 [개인정보 안내](docs/PRIVACY.md)를 먼저 확인하세요.

## 설치

1. 신뢰한 전체 RC ZIP을 새 개인 로컬 NTFS 폴더에 압축 해제합니다. ZIP 안에서 실행하지 않습니다. `Desktop_Companion`과 `Browser_Extension`을 함께 유지합니다.
2. 압축해제 루트에서 아래 읽기 전용 ACL 검사로 `PASS`를 확인합니다. 기존 사용자는 첫 실행 전에 [설정·키 보존 절차](docs/NATIVE_MESSAGING_GUIDE.md)를 마치고 다시 검사합니다. 기존 파일을 초기화하거나 덮어쓰지 않습니다.
3. `Desktop_Companion/Start.bat`을 실행합니다. Windows PowerShell 5.1/WPF를 사용하며 관리자 권한·Node.js·Python 설치는 실행에 필요하지 않습니다.
4. Chrome의 개발자 모드에서 압축해제된 `Browser_Extension`을 로드합니다. 고정 ID는 `ncbcjbbidoaallpikijfbjdmijjljhoe`입니다. 사용할 YouTube/작업 탭을 새로고침합니다.
5. Desktop 설정 → 연결 → **Chrome 연결 등록** 또는 `Setup-Chrome.bat`에서 현재 사용자 등록을 합니다. 트레이에서 페어링 코드를 복사해 팝업에 저장하고 실제 상태 조회로 연결을 확인합니다. 코드는 공유하지 않습니다.
6. 팝업에서 YouTube 캡처를 명시적으로 시작합니다. Windows RGB/JPEG 출력에는 Windows 전송·영상 전송을 켭니다. 기본 2FPS로 시작하며 5/10FPS는 실험 기능입니다.

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Desktop_Companion\Test-FileSecurity.ps1
```

[Windows 설치·업데이트·제거 안내](docs/WINDOWS_PORTABLE_GUIDE.md), [Native 등록·보존·복구](docs/NATIVE_MESSAGING_GUIDE.md), [FAQ](docs/FAQ.md)를 따르세요. SECURITY 오류를 관리자 실행·공유 권한 추가·보안 기능 해제로 우회하지 않습니다. Chrome Web Store·자동 업데이트·Windows 자동 시작 등록을 사용하지 않습니다.

## 조작과 제한

트레이 두 번 클릭으로 설정을 열고 우클릭 → **Desktop 앱 종료**로 종료합니다. 설정창 닫기는 앱 종료가 아닙니다. Chrome 캡처는 팝업에서 별도로 연결 중지합니다.

통합 Pause/Resume는 Desktop·웹 배경·YouTube 조명·프레임 처리/인코딩/송신에 적용하며 개별 OFF는 유지합니다. Pause는 캡처 트랙 종료와 다릅니다. 전역 단축키는 선택 기능이며 기본 비활성입니다.

2026-10-23 Native RC 사용자 검증에서 시작/종료10/10, Chrome/Desktop 재시작 후 설정·페어링 유지, 30분 이상 후 팝업 상태조회·Pause/Resume, ChatGPT/Codex/Windows 영상, 개별OFF/통합pause를 수락했습니다. 기존 자동 회귀는52/52 PASS입니다. 새 다운로드·다른 환경의 검증과 합산하지 않습니다.

과거 간헐 시작 실패와 장시간 반복 뒤 팝업 복귀 실패의 원인/영구 해결은 미확정입니다. 기본2FPS는 상한이며 실제 화면 표시율 보장이 아닙니다. 실험5/10FPS 달성도 보장하지 않습니다. SA-01 이동 이벤트 전 비원자적 경합·이미 전송한 데이터 회수 불가 등 [잔여 위험](docs/KNOWN_ISSUES.md)을 유지합니다.

## 소스와 라이선스

이 저장소는 RC 제품 소스·새 아이콘·사용자 문서만 포함합니다. 개발용 검증 harness·내부 감사·사용자 데이터·생성 실행 파일은 포함하지 않습니다. 배포 ZIP은 여기의 제품 파일과 BUILD-INFO를 담으며 사용자별 host 실행 파일은 설치 시 Windows 기본 .NET 컴파일러로 생성합니다.

자체 코드·새 SVG/PNG 아이콘은 [MIT](LICENSE), `Copyright (c) 2026 Hwang Seonghyeon`입니다. [COPYRIGHT](COPYRIGHT.md)의 범위와 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md), [Wessel Kroos의 MIT 전문](licenses/youtube-ambilight-MIT.txt)을 함께 보존합니다. 확장만 따로 재배포할 때도 해당 고지가 필요합니다. [새 아이콘 출처](docs/ICON_PROVENANCE.md)를 확인하세요. YouTube·Chrome·지원 앱의 공식 제품이나 보증을 뜻하지 않습니다.
