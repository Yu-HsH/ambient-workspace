# 변경 기록

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
