# 문서 인덱스 — 최신 정본 기준

> 갱신: 2026-08-25
> 기준 상태: C Day 06 / A Phase 3 연동 래퍼 + KY-008 사전 안전 준비 완료

`docs/`에는 각 규격의 **최신 정본 한 개만** 둔다. 이전 버전은 Git 이력에서
확인하며 `_v1.x`, `_v0.x`, `(1)` 같은 사본은 저장소에 추가하지 않는다.

## 문서 우선순위

| 순위 | 정본 | 현재 버전 | 용도 |
|---:|---|---:|---|
| 1 | `TEAM_COMMON_AI_INTEGRATION_SPEC.md` | v1.5 | 팀 최상위 공통 규격 |
| 2 | `TEAM_ROLE_PLAN.md` | v1.6 | A/B/C 역할과 진행 계획 |
| 3 | `NPU_DEVELOPMENT_PLAN.md` | v1.4 | 전체 개발 계획과 Gate |
| 4 | `interface_contract.md` | v0.5 | A/B/C RTL·AXI 인터페이스 세부 계약 |
| 5 | `PROJECT_STATUS.md` | Day 06 | 현재 구현·검증·블로커 |

문서 내용이 충돌하면 상위 문서를 따르고, 공유 인터페이스 변경은 Change Request와
팀 승인 후 정본 및 `change_log.md`에 반영한다.

## 전달 및 인계 문서

| 파일 | 방향 | 내용 |
|---|---|---|
| `A_NPU_HANDOFF.md` | A → 팀 | NPU/SoC 포트, 타이밍, Known Limitation |
| `B_TO_A_DELIVERY_SPEC.md` | A → B | B 산출물 전달 형식 |
| `C_TO_A_DELIVERY_SPEC.md` | A → C | C RTL 전달 형식과 Phase 3 포트 계약 |
| `C_TO_A_REPLY_003.md` | C → A | Phase 3 통합 설정·상태·START·Laser 재무장 계약 |
| `../handoff/C_EVENT_CONTROL_HANDOFF.md` | C → 팀 | Event/Control RTL 상세 인계 |

`C_TO_A_REPLY_001~003`처럼 번호가 붙은 회신은 서로 다른 의사결정 시점의 기록이며
구버전 사본이 아니므로 유지한다.

## 승인 및 변경 기록

| 파일 | 상태/용도 |
|---|---|
| `D3_FREEZE_REQUEST_A_001.md` | A → B/C Freeze 요청 #001 |
| `D3_FREEZE_REQUEST_A_002.md` | A → B/C Freeze 요청 #002 rev.2 |
| `D3_B_to_A_CNN_Convolution_Freeze_Request.md` | B → A Conv 경계 규칙 요청 |
| `D3_FREEZE_APPROVAL_A_TO_B_001.md` | 위 요청에 대한 A 승인 |
| `CHANGE_REQUEST_C_001_servo_command_format.md` | Servo Command Format 변경 요청 |
| `CHANGE_REQUEST_C_002_event_window_and_input_source.md` | Event Window/Input Source 변경 요청 |
| `change_log.md` | 공유 규격 변경 이력 |

## 작업 기록

`D1_CHECKLIST_C.md`부터 `D5_CHECKLIST_C.md`, `D5_FINAL_DRIVE_TEST.md`까지는
당시 수행 내용과 실물 검증 근거를 보존하는 작업 이력이다. 현재 상태 판단에는
항상 `PROJECT_STATUS.md`와 최신 Handoff를 우선한다.

`KY008_PREARRIVAL_CHECKLIST_C.md`는 KY-008 도착 전 준비 상태와 도착 후
dummy load·실제 광원 승인 순서를 기록한 현재 작업 체크리스트다.

## 파일 관리 규칙

1. 정본 파일명에는 버전을 넣지 않고 문서 헤더에 버전을 기록한다.
2. 새 버전 승인 시 기존 정본 내용을 갱신하고 `change_log.md`를 함께 수정한다.
3. 배포용 버전 사본은 GitHub Release 등 저장소 밖에서 생성한다.
4. 다운로드 중 생긴 `(1)` 파일은 커밋하지 않는다.
5. 삭제된 구버전이 필요하면 Git 이력에서 복원한다.
