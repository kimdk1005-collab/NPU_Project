# 문서 인덱스 — 최신 정본 기준

> 갱신: 2026-08-30 · 기준: A/B/C 통합 소스 + v04 데모 후보

`docs/`에는 같은 목적의 최신 정본 하나만 둔다. `_v1.x`, `(1)` 같은 사본은 만들지 않고
과거 내용은 Git 이력에서 확인한다.

## 우선순위

| 순위 | 정본 | 현재 버전 | 용도 |
|---:|---|---:|---|
| 1 | `TEAM_COMMON_AI_INTEGRATION_SPEC.md` | v1.5-A1 | 팀 최상위 공통 규격 |
| 2 | `TEAM_ROLE_PLAN.md` | v1.6 | 역할과 진행 계획 |
| 3 | `NPU_DEVELOPMENT_PLAN.md` | v1.4 | Gate와 개발 계획 |
| 4 | `interface_contract.md` | v0.5 | RTL·AXI 인터페이스 계약 |
| 5 | `PROJECT_STATUS.md` | 2026-08-30 | 현재 구현·검증·블로커 |

## 현재 통합 문서

| 파일 | 내용 |
|---|---|
| `A_NPU_HANDOFF.md` | A NPU/AXI/SoC/PS 계약과 제한 |
| `../handoff/B_MODEL_HANDOFF.md` | v04 데모 Model/Golden과 범위 |
| `../handoff/C_EVENT_CONTROL_HANDOFF.md` | C Event/Control/Servo/Laser 계약 |
| `integration_manifest.md` | 역할별 Version Lock, 측정, 산출물 체크섬 |
| `A_INTEGRATION_VERIFICATION.md` | 공유 저장소 재현 명령과 실제 결과 |
| `LIVE_RUNTIME_GUIDE.md` | PC Camera→UART→NPU Live 운용 |
| `change_log.md` | 공유 규격·통합 이력 |

## 전달·승인 문서

- `B_TO_A_DELIVERY_SPEC.md`, `C_TO_A_DELIVERY_SPEC.md`
- `C_TO_A_REPLY_001.md`~`C_TO_A_REPLY_005.md`
- `D3_FREEZE_REQUEST_A_001.md`, `D3_FREEZE_REQUEST_A_002.md`
- `D3_B_to_A_CNN_Convolution_Freeze_Request.md`
- `D3_FREEZE_APPROVAL_A_TO_B_001.md`
- `C_TO_A_APPROVAL_D3_A002_rev2.md`
- `CHANGE_REQUEST_C_001_servo_command_format.md`
- `CHANGE_REQUEST_C_002_event_window_and_input_source.md`

번호가 붙은 요청·회신은 서로 다른 의사결정 기록이므로 중복 정본으로 보지 않는다.

## C 작업·안전 기록

`D1_CHECKLIST_C.md`~`D5_CHECKLIST_C.md`, `D5_FINAL_DRIVE_TEST.md`,
`KY008_PREARRIVAL_CHECKLIST_C.md`, `C_COMPONENT_MANUAL_TEST.md`는 C의 자동시험과 실물
검증 근거다. A 통합이 이 기록을 덮어쓰지 않는다.

## 파일 관리 규칙

1. 공유 Interface 변경은 Change Request 승인 후 정본과 `change_log.md`에 반영한다.
2. 생성 가능한 Bitstream/XSA/ELF/로그/프로젝트는 Git에 올리지 않는다.
3. 측정하지 않은 성능·보드·안전 결과를 PASS로 표시하지 않는다.
4. v04 데모 후보는 항상 `DEMO_ONLY`와 필수 Color Mask 조건을 함께 표기한다.
