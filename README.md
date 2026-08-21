# 이벤트 카메라 기반 FPGA NPU 팬틸트 추적 시스템

Event Input → 64×64×2 Event Tensor → Tiny CNN → INT8 → Integer Golden → Dense INT8 FPGA NPU → 8×8 Heatmap → Argmax → Tracking Controller → Pan/Tilt Servo

- 플랫폼: Digilent Zybo Z7-20 (`xc7z020clg400-1`)
- 툴체인: Vivado 2024.2 / Vitis / xsim
- 기간: 15일 / 3인

## 문서 우선순위 (SPEC §1)

```text
1순위  docs/NPU_EVENT_CAMERA_TEAM_COMMON_AI_INTEGRATION_SPEC_v1.2.md
2순위  docs/TEAM_ROLE_PLAN_v1.3.md
3순위  docs/DEVELOPMENT_PLAN_v1.1.md
4순위  개인 메모 (docs/D1_CHECKLIST_C.md 등)
```

문서가 서로 다르면 **위쪽이 이긴다.** 규격을 바꿀 때는 SPEC §22 CHANGE REQUEST를 먼저 쓴다.

| 파일 | 내용 |
|---|---|
| [docs/NPU_EVENT_CAMERA_TEAM_COMMON_AI_INTEGRATION_SPEC_v1.2.md](docs/NPU_EVENT_CAMERA_TEAM_COMMON_AI_INTEGRATION_SPEC_v1.2.md) | **최상위 공통 명세** (A 작성) |
| [docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md) | 팀 공유용 최신 진행상황, 블로커, 다음 액션 |
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
rtl/control/       C 소유 — tracking_controller.v, servo_pwm.v, laser_interlock.v
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
./sim/run_xsim.sh tb_servo_pwm         # 판정 TB — 6/6 PASS 확인용
./sim/run_xsim.sh tb_board_io           # 판정 TB — 13/13 PASS 확인용
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
| `rtl/control/board_io.v` | 구현 완료 (D1, 브링업 전용) | 13/13 PASS + 2축 실물 검증 완료 |
| `rtl/event/event_adapter.v` | 구현 완료 (D2) | `tb_event_adapter` 23/23 PASS |
| `rtl/event/event_accumulator.v` | 구현 완료 (D3 선행) | `tb_event_accumulator` 15/15 PASS |
| `rtl/control/tracking_controller.v` | D4 | |
| `rtl/control/laser_interlock.v` | D6 | |
