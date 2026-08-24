# 이벤트 카메라 기반 FPGA NPU 팬틸트 추적 시스템

Event Input → 64×64×2 Event Tensor → Tiny CNN → INT8 → Integer Golden → Dense INT8 FPGA NPU → 8×8 Heatmap → Argmax → Camera PT#1 Tracking → Laser PT#2 Follower → LED/Laser Interlock

- 플랫폼: Digilent Zybo Z7-20 (`xc7z020clg400-1`)
- 툴체인: Vivado 2024.2 / Vitis / xsim
- 기간: 15일 / 3인

## 문서 우선순위 (SPEC §1)

```text
1순위  docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md
2순위  docs/TEAM_ROLE_PLAN.md
3순위  docs/NPU_DEVELOPMENT_PLAN.md
4순위  docs/interface_contract.md (인터페이스 세부 계약)
5순위  개인 메모 (docs/D1_CHECKLIST_C.md 등)
```

문서가 서로 다르면 **위쪽이 이긴다.** 규격을 바꿀 때는 SPEC §22 CHANGE REQUEST를 먼저 쓴다.

| 파일 | 내용 |
|---|---|
| [docs/00_DOCUMENT_INDEX.md](docs/00_DOCUMENT_INDEX.md) | 최신 정본 목록과 문서 관리 규칙 |
| [docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md](docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md) | **최상위 공통 명세** (현재 v1.5) |
| [docs/interface_contract.md](docs/interface_contract.md) | A/B/C RTL·AXI Interface Contract (현재 v0.4) |
| [docs/NPU_DEVELOPMENT_PLAN.md](docs/NPU_DEVELOPMENT_PLAN.md) | 전체 개발 계획 (현재 v1.4) |
| [docs/TEAM_ROLE_PLAN.md](docs/TEAM_ROLE_PLAN.md) | A/B/C 역할과 일정 (현재 v1.6) |
| [docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md) | 팀 공유용 최신 진행상황, 블로커, 다음 액션 |
| [docs/D3_CHECKLIST_C.md](docs/D3_CHECKLIST_C.md) | C Day 3 완료 기준과 검증 결과 |
| [docs/D4_CHECKLIST_C.md](docs/D4_CHECKLIST_C.md) | C Day 4 완료 기준과 검증 결과 |
| [docs/D5_CHECKLIST_C.md](docs/D5_CHECKLIST_C.md) | C Day 5 — 2-Head 4축 제어와 LED Interlock 검증 |
| [docs/D5_FINAL_DRIVE_TEST.md](docs/D5_FINAL_DRIVE_TEST.md) | Camera/Laser 4축 + JD7 RED 실물 구동 절차 |
| [docs/C_TO_A_REPLY_002.md](docs/C_TO_A_REPLY_002.md) | PT#2 좌표식 승인, 통합 포트와 JD 핀 제안 |
| [docs/C_TO_A_REPLY_003.md](docs/C_TO_A_REPLY_003.md) | A Phase 3 Event/Control 통합 계약과 검증 결과 |
| [handoff/C_EVENT_CONTROL_HANDOFF.md](handoff/C_EVENT_CONTROL_HANDOFF.md) | C Handoff — Event / Tracking / Servo / Laser |
| [docs/CHANGE_REQUEST_C_001_servo_command_format.md](docs/CHANGE_REQUEST_C_001_servo_command_format.md) | CR C-001 Servo Command Format (승인 대기) |
| [docs/CHANGE_REQUEST_C_002_event_window_and_input_source.md](docs/CHANGE_REQUEST_C_002_event_window_and_input_source.md) | CR C-002 Event Window + 입력원 Fallback (승인 대기) |

## 역할 (SPEC §4)

| | 담당 | 영역 |
|---|---|---|
| A | | NPU RTL / SoC / Architecture / 최종 통합 |
| B | | CNN / Quantization / Integer Golden / 검증 |
| **C** | 김도근 | **Event 입력 / Tracking / Pan-Tilt / Laser** |

## 디렉토리 (SPEC §5 파일 소유권)

```
ai/                B 소유 — dataset / train / quantize / integer_golden
weights/           B 소유
test_vectors/      B 소유
golden_outputs/    B 소유
results/model/     B 소유

rtl/npu/           A 소유
rtl/integration/   A 소유 — npu_axi.v, top_system.v
tb/npu/            A 소유

rtl/event/         C 소유 — event_adapter.v, event_accumulator.v
rtl/control/       C 소유 — tracking/laser-head/interlock/dual-head/servo RTL
tb/event/          C 소유
tb/control/        C 소유

constraints/       공유 — 단독 수정 금지
handoff/           각자 Handoff 문서
docs/              문서
sim/               시뮬레이션 러너 및 C 로컬 자극
```

## 사용법

### Event 자극 생성 (C 로컬 개발용)

이벤트 카메라 없이 Event Adapter / Accumulator를 개발·검증하기 위한 가상 이벤트 스트림.

```bash
python3 tools/gen_event_vector.py
python3 tools/gen_event_vector.py --sensor 346x260 --traj linear --window-us 5000
```

출력은 `sim/event_vectors/` 에 생성된다 — `events.csv` / `labels.csv` / `tensor_wNNN.hex`.

> **팀 공식 Test Vector가 아니다.** `test_vectors/`와 `golden_outputs/`는 SPEC §5.2에 따라 B 소유다.

### 웹캠 능력 실측 (SPEC §34 Fallback 판단 근거)

웹캠의 최대 fps가 Event Window 길이의 물리적 하한을 정한다. CR C-002의 근거다.

```bash
python3 tools/probe_webcam.py            # 기본 /dev/video0
```

표준 라이브러리만 쓴다 (OpenCV / v4l2-ctl 불필요). 캡처하지 않고 조회만 한다.

### 시뮬레이션

명령행 (xsim 직접 실행):

```bash
./sim/run_xsim.sh tb_event_adapter     # 판정 TB — 23/23 PASS 확인용
./sim/run_xsim.sh tb_event_accumulator # 판정 TB — 15/15 PASS 확인용
./sim/run_xsim.sh tb_event_pipeline    # 판정 TB — 15/15 PASS 확인용
./sim/run_xsim.sh tb_servo_pwm         # 판정 TB — 6/6 PASS 확인용
./sim/run_xsim.sh tb_board_io           # 판정 TB — 19/19 PASS 확인용
./sim/run_xsim.sh tb_tracking_controller # 판정 TB — 30/30 PASS 확인용
./sim/run_xsim.sh tb_laser_head_controller # 판정 TB — 23/23 PASS 확인용
./sim/run_xsim.sh tb_laser_interlock    # 판정 TB — 28/28 PASS 확인용
./sim/run_xsim.sh tb_dual_head_control  # 판정 TB — 30/30 PASS 확인용
./sim/run_xsim.sh tb_dual_head_board_io # 판정 TB — 최종 4축+RED 32/32 PASS
./sim/run_xsim.sh tb_servo_pwm_sweep   # pos 0~255 스윕, 파형 관찰용
```

Vivado GUI로 파형을 보려면:

```bash
vivado -mode batch -source sim/create_vivado_project.tcl
vivado vivado_proj/npu_c_sim.xpr
# 시뮬레이션 실행 후 Tcl Console 에서:
#   source sim/wave_servo_pwm.tcl
```

`vivado_proj/`는 스크립트로 재생성되므로 `.gitignore` 대상이다.
`rtl/`을 **참조**만 하므로 GUI에서 편집해도 원본이 그대로 바뀐다.

### 레이저 PT#2 Servo 단독 브링업

카메라 PT#1의 JD1/JD2 연결을 바꾸지 않고 레이저 PAN/TILT Servo를 JD3/JD4에서
먼저 검증하는 순수 PL Bitstream이다.

```bash
./sim/run_xsim.sh tb_board_io
vivado -mode batch -source sim/create_laser_bringup_project.tcl
```

생성 Bitstream은
`vivado_laser_bringup/c_laser_servo_bringup.runs/impl_1/laser_board_io.bit`이다.

```text
Laser PAN  signal = JD3 / P14
Laser TILT signal = JD4 / R14
sw[0] enable  sw[1] sweep  sw[2] range  sw[3] 0=PAN/1=TILT
btn[0] pos-   btn[1] pos+  btn[2] neutral  btn[3] reset
```

처음에는 `sw=0000`으로 Program하고 `led[0]` heartbeat를 확인한 뒤 Servo를
활성화한다. Servo 전원은 외부 5~6 V를 사용하고 Zybo와 GND만 공통 연결한다.
실제 레이저 광원은 이 브링업 Top에 연결하지 않는다.

### 최종 4축 Servo + RED 구동 테스트

```bash
./sim/run_xsim.sh tb_dual_head_board_io
vivado -mode batch -source sim/create_dual_head_drive_test_project.tcl
vivado vivado_dual_head_bringup/c_dual_head_drive_test.xpr
```

Bitstream:
`vivado_dual_head_bringup/c_dual_head_drive_test.runs/impl_1/dual_head_board_io.bit`

Camera Servo는 JD1/JD2, Laser Servo는 JD3/JD4, 저항 내장 RGB LED 모듈의
`R`은 JD7, `-`는 JD11 GND에 연결한다. 세부 조작과 판정은
[docs/D5_FINAL_DRIVE_TEST.md](docs/D5_FINAL_DRIVE_TEST.md)를 따른다.

이 보드 테스트 Top은 카메라/NPU 대신 Switch와 Button으로 가상 Target 좌표를
만든다. 실제 영상 기반 중앙 판정은 A의 NPU `target_*` 신호를 연결한 뒤 검증한다.

## Git (SPEC §24, §25)

```text
main / integration / feature/a-npu / feature/b-model / feature/c-event-control
```

Commit 형식: `[C][CTRL] Add servo dead-zone logic`

팀 협업과 업데이트 절차는 [CONTRIBUTING.md](CONTRIBUTING.md)를 따른다.

## C 진행 상태

| 모듈 | 상태 | 검증 |
|---|---|---|
| `rtl/control/servo_pwm.v` | 구현 완료 (D1) | `tb_servo_pwm` 6/6 PASS |
| `rtl/control/board_io.v` | 구현 완료 (D1, 브링업 전용) | 19/19 PASS + 2축 실물 검증 완료 |
| `rtl/control/laser_board_io.v` | PT#2 단독 실물 브링업 완료 | JD3/JD4 Servo 방향·범위 정상, WNS +0.396 ns / WHS +0.165 ns |
| `rtl/control/dual_head_board_io.v` | 최종 4축+RED 실물 검증 완료 | 32/32 PASS + 실물 전 항목 PASS, WNS +1.068 ns / WHS +0.179 ns |
| `rtl/event/event_adapter.v` | 구현 완료 (D2) | `tb_event_adapter` 23/23 PASS |
| `rtl/event/event_accumulator.v` | 구현 완료 (D3) | `tb_event_accumulator` 15/15 PASS, 8192 B 전수 비교 |
| Adapter→Accumulator 통합 경로 | 검증 완료 (D4) | `tb_event_pipeline` 15/15 PASS, 2 Window × 8192 B 전수 비교 |
| `rtl/control/tracking_controller.v` | 구현 완료 (D4) | `tb_tracking_controller` 30/30 PASS |
| `rtl/control/laser_head_controller.v` | 구현 완료 (D5) | `tb_laser_head_controller` 23/23 PASS |
| `rtl/control/laser_interlock.v` | LED 우선 구현 완료 (D5) | `tb_laser_interlock` 28/28 PASS |
| `rtl/control/dual_head_control.v` | 4 Servo + LED 경로 구현 완료 (D5) | `tb_dual_head_control` 30/30 PASS |
