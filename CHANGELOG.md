# 변경 기록

## rc.2 설치 경험 개편 (미커밋·미배포)

- Windows ZIP 내부 `Install.bat` → 자체 포함 WPF 네 단계 안내. 원본 ZIP 후보·기본 설치 위치, 독립 게시 SHA-256·명시적 출처 승인, 기존 안전 설치 엔진 재사용.
- Chrome-only는 확장·문서만 설치하며 Desktop 파일·Native 등록·키 읽기 생략. Chrome 수동 추가·폴더 위치 복사, 기존 Windows 등록 UI·팝업 인증 재사용.
- 고정 공개 확장 ID 자동 채움, 사용자용 안내와 원인 코드 분리, 실제 설치·실행 위치 표시. 실행 정책을 낮추지 않으며 미서명 다운로드 차단 한계를 명시.
- 신규/업데이트/취소/재시도 WPF 시험과 제품 allowlist 회귀 추가. README·화면별 설치·문제 해결·Release 다운로드 초안 정리, 기존 기술·보안·권리 설명 전체 보존.
- 로컬 확장 표시와 Desktop 트레이만 rc.2 개발 검토 버전으로 표시. 공개 rc.1 태그·Release·ZIP은 변경하지 않음. [분석·신뢰 경계·실기 확인](docs/INSTALL_EXPERIENCE_RC2.md).

## rc.2 후속 개발 중 — Windows 연결·Chrome 일시정지 (미커밋·미배포)

- 팝업 Windows 연결에서 새 Native 포트·Desktop 실행·저장된 인증을 순서대로 확인. 최초 인증/거부일 때만 코드 입력 안내, 실패별 고급 진단 유지.
- 이전 설치에 남은 Native 포트를 새로 여는 연결 경로와 읽기 전용 1회 재시도. 쓰기·미디어 재전송 금지, 등록은 기존 Windows 승인 UI에서만 수행.
- Chrome 웹·YouTube·공유 캡처 처리의 영구 일시정지 상태를 Desktop 제어와 분리. 재연결·워커 재시작·탭 이동 후 명시적 정지 유지.
- Windows 트레이의 별도 Chrome 제어 진단, Node 내장 자동 시험과 기존 보안·설치·WPF 회귀. [검토 범위·실사용 확인](docs/RC2_CONNECTION_PAUSE.md).

## rc.2 개발 중 — Orca Desktop 지원 (미배포)

- PowerShell 5.1 안전한 설치 도우미: 출처 승인과 기대 ZIP 해시, 불변 스냅샷/내부 manifest/복사 후 파일 검증, 새 폴더의 원자적 생성과 보호 ACL, 기존 보안 검사 및 실행 전 검사 유지.
- 기존 설치를 덮어쓰지 않는 별도 버전 설치, 명시적으로 승인한 설정·백업·키의 바이트 보존, 실행 중 Desktop 차단, 실패한 새 폴더 보존.
- 승인한 Native 등록 GUI 호출과 별도 Host 인증 검사. Chrome 프로필/저장소·운영 Native 등록을 자동 변경하지 않음. 검토용 패키징/합성 설치·복구 시험과 [사용 안내](docs/SAFE_INSTALL_GUIDE.md) 추가.

- 신규 Desktop 기본 대상에 `orca`, 기본 앱 배율 1.0 추가.
- 기존 설정을 읽을 때 Orca만 보충하는 일회성 기본 대상 이전 추가. 다른 대상·배율·OFF·일시정지·사용자 필드는 보존하며 로드 시 파일은 쓰지 않음.
- `targetDefaultsVersion=1`은 다음 일반 설정 저장 시 함께 저장. 기존 Orca 배율과 대소문자를 보존하고 이후 명시적으로 제거한 대상은 다시 추가하지 않음.
- 기존 전경 HWND → PID → ProcessName 및 창 영역 경로로 RGB·영상 모두 적용. 설정/페어링·Native 등록·브라우저 전송 코드는 유지.
- 격리된 설정·WPF 회귀 테스트, 읽기 전용 전경 관찰 도구, 실제 사용자 검증 절차와 대상 앱 직접 등록 설계안 추가.
- rc.1 태그·공개 Release·배포 ZIP·버전 메타데이터는 그대로 유지. [검증 범위와 미확인 사항](docs/ORCA_SUPPORT_RC2.md)을 구분함.

## 1.0.0-rc.1 — 공개 테스트 버전

- Windows Portable 실행·트레이 종료·중복 실행 방지, 설정/페어링 보존, 선택적 전역 단축키.
- Desktop·웹 배경·YouTube 조명·캡처 처리의 통합 Pause/Resume와 개별 OFF 보존.
- 비허용 source 이동 차단·늦은 프레임 폐기, trusted 저장소와 privileged sender 검증.
- 개인 설치의 파일/상위 경로/HKCU ACL 사전 검사. 불안전 위치는 차단하며 기존 권한·키를 자동 변경하지 않음.
- Chrome Native Messaging: 사용자별 최초 등록·이동 후 재등록·복구·제거, 고정 확장 ID, 기존 설정의 사용자 주도 복사본 이전. HTTP 송신/리스너/fallback 제거.
- JPEG 인코딩을 내장 Worker로 분리. 기존 크기/화질·FPS 상한·단일 pending·기한·pause/source epoch 유지.
- 새 도형 아이콘과 MIT 라이선스, 별도 upstream MIT 고지.
- Native 준비 확인 실패로 웹만 연결된 세션은 팝업을 다시 열어도 Windows 송신 중단과 연결 해제·재연결 안내를 표시. Native 지연/공유 요청 취소 자체는 RC 잔여 위험으로 유지.
- 2026-10-23 사용자 수락과 기존 자동52/52를 기록. 개인 Windows 계정·ACL PASS 로컬 NTFS로 지원 제한. 실제 두 계정 실험은 미수행이며 이번 RC 필수 조건에서 제외.

간헐 시작/팝업 실패 원인은 미확정이며 기본2FPS·실험5/10FPS·SA-01 비원자적 경합 등의 [Known Issues](docs/KNOWN_ISSUES.md)를 유지합니다. [Release Notes](docs/RELEASE_NOTES_v1.0.0-rc.1.md)를 확인하세요.
