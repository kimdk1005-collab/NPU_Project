# 이벤트 카메라 기반 FPGA NPU 팬틸트 추적 시스템

이 저장소는 A·B·C 세 역할이 함께 사용하는 단일 통합 저장소다.

```text
Event Input
  → 64×64×2 Event Tensor
  → Tiny CNN / INT8 Golden
  → Dense INT8 FPGA NPU
  → 8×8 Heatmap / Argmax
  → Camera PT#1 Tracking
  → Laser PT#2 Follower / Safety Interlock
```

- 보드: Digilent Zybo Z7-20 (`xc7z020clg400-1`)
- 기준 툴체인: Vivado 2024.2 / Vitis / xsim
- 팀 구성: A=NPU·SoC, B=Model·Golden, C=Event·Control

## 처음 시작할 때

```bash
git clone https://github.com/kimdk1005-collab/NPU_Project.git
cd NPU_Project
git fetch origin --prune
git switch integration
```

1. [문서 인덱스](docs/00_DOCUMENT_INDEX.md)에서 최신 정본을 확인한다.
2. [프로젝트 진행상황](docs/PROJECT_STATUS.md)에서 완료 항목과 블로커를 확인한다.
3. [통합 Manifest](docs/integration_manifest.md)에서 역할별 버전과 산출물 조합을 확인한다.
4. 자신의 역할 폴더 `README.md`를 읽고 기능 브랜치를 만든다.
5. 작업·단위 검증·Handoff를 끝낸 뒤 `integration` 대상으로 PR을 연다.

브랜치 생성과 PR 규칙은 [CONTRIBUTING.md](CONTRIBUTING.md)를 따른다.

## 역할과 작업 공간

| 역할 | 책임 | 주 작업 경로 | 주요 전달물 |
|---|---|---|---|
| A | NPU RTL, AXI/SoC, PS 소프트웨어, 최종 통합 | `rtl/npu/`, `rtl/integration/`, `tb/npu/`, `sw/` | NPU RTL·TB, AXI/Top, 보드 검증 기록, `docs/A_NPU_HANDOFF.md` |
| B | Dataset, CNN, INT8 Quantization, Integer Golden | `ai/`, `weights/`, `test_vectors/`, `golden_outputs/`, `results/model/` | Weight·Scale, 공식 Vector·Golden, 정확도 보고서, `handoff/B_MODEL_HANDOFF.md` |
| C | Event 입력, Tracking, Pan/Tilt, Laser 안전 | `rtl/event/`, `rtl/control/`, `tb/event/`, `tb/control/` | Event/Control RTL·TB, 실물 검증 기록, `handoff/C_EVENT_CONTROL_HANDOFF.md` |

역할별 폴더의 `README.md`에는 예상 파일, 입력·출력 계약과 검증 기준이 적혀 있다.
다른 역할의 경로를 대규모로 수정하지 않으며, 공유 인터페이스 변경은 Change Request와
관련 역할의 승인을 먼저 받는다.

## 공유 경로

| 경로 | 용도 | 규칙 |
|---|---|---|
| `docs/` | 공통 SPEC, 역할 계획, 계약, 상태, 변경 기록 | 문서 우선순위와 최신 정본 규칙 준수 |
| `handoff/` | 역할별 통합 인계 | 버전·포트·검증·제한사항 기록 |
| `constraints/` | 통합 보드 핀·타이밍 제약 | 단독 수정 금지 |
| `rtl/integration/top_system.v` | 전체 RTL 연결점 | A 소유, 인터페이스 변경은 팀 공유 |
| `sim/` | 공통 시뮬레이션 실행·Vivado 재현 스크립트 | 생성 프로젝트는 커밋하지 않음 |
| `tools/` | 재현·검증 보조 도구 | 입력과 출력 버전을 명시 |
| `results/` | 결과 위치와 보존 정책 안내 | 재생성 가능한 바이너리는 Git 제외 |

## 문서 우선순위

문서가 충돌하면 아래에서 위쪽 문서가 우선한다.

1. [팀 공통 통합 명세](docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md) — v1.5
2. [팀 역할 계획](docs/TEAM_ROLE_PLAN.md) — v1.6
3. [NPU 개발 계획](docs/NPU_DEVELOPMENT_PLAN.md) — v1.4
4. [인터페이스 계약](docs/interface_contract.md) — v0.5
5. [프로젝트 진행상황](docs/PROJECT_STATUS.md)과 역할별 작업 기록

공유 규격을 변경할 때는 `docs/CHANGE_REQUEST_*.md`를 먼저 작성하고, 승인 후 정본과
`docs/change_log.md`를 함께 갱신한다.

## 역할별 검증 진입점

### A — NPU·SoC

- RTL/TB: `rtl/npu/`, `rtl/integration/`, `tb/npu/`
- PS 소프트웨어: `sw/`
- 수치 판정 기준: B의 `test_vectors/`, `golden_outputs/`
- C 연결 계약: `docs/C_TO_A_REPLY_004.md`

A 산출물이 합류하면 해당 폴더 README와 `docs/A_NPU_HANDOFF.md`의 재현 명령을 따른다.

### B — Model·Golden

- 학습·양자화·Integer Golden: `ai/`
- 전달 형식: `docs/B_TO_A_DELIVERY_SPEC.md`
- 출력: `weights/`, `test_vectors/`, `golden_outputs/`, `results/model/`

공식 산출물에는 모델 버전, shape/dtype/order, 생성 명령, seed와 checksum을 기록한다.

### C — Event·Control

공통 실행기는 Testbench 이름을 인자로 받는다.

```bash
./sim/run_xsim.sh tb_event_pipeline
./sim/run_xsim.sh tb_c_event_control_top
./sim/run_xsim.sh tb_ky008_laser_board_io
```

전체 C 판정 목록과 보드 절차는 `rtl/event/README.md`, `rtl/control/README.md`와
[C Handoff](handoff/C_EVENT_CONTROL_HANDOFF.md)를 따른다.

## 통합 흐름

```text
feature/a-*   feature/b-*   feature/c-*
       \          |          /
        역할별 단위 Test PASS
                  ↓
             integration
                  ↓
   B Golden ↔ A NPU ↔ C Event/Control
                  ↓
          통합 Test / Timing PASS
                  ↓
                main
```

통합 전에는 [integration manifest](docs/integration_manifest.md)의 SPEC, Interface,
Model, Weight, Golden, A_NPU, C_EVENT, C_CONTROL 버전을 대조한다.

## 현재 상태

현재 구현·PASS 수·보드 검증과 남은 담당 작업은 [PROJECT_STATUS.md](docs/PROJECT_STATUS.md)를
단일 현황판으로 사용한다. 루트 README에는 역할별 세부 진행률을 중복 기록하지 않는다.

## 안전 및 저장소 관리

- 실제 레이저 연결은 [KY-008 체크리스트](docs/KY008_PREARRIVAL_CHECKLIST_C.md)의
  dummy load·Arm·E-stop·출력 등급 확인을 통과한 뒤 수행한다.
- Vivado/Vitis 생성 프로젝트, `.runs/`, `.cache/`, `.Xil/`, 로그, 파형,
  Bitstream/XSA/ELF는 커밋하지 않는다.
- 개인 토큰, 비밀번호, 장치 인증정보와 불필요한 대용량 Dataset을 올리지 않는다.
- `docs/`에는 최신 정본만 두고 과거 버전은 Git 이력에서 확인한다.
