# C → A 회신 003 — Phase 3 C Stub 통합 계약

> 회신일: 2026-08-24
> 안전 확장: 2026-08-25 — KY-008 실제 광원 사전 준비 / 수동 재무장 상태 추가
> 대상: `C_TO_A_DELIVERY_SPEC.md` Phase 3 §11 / `interface_contract.md` v0.5
> C 산출물: `rtl/control/c_event_control_top.v`, `tb/control/tb_c_event_control_top.v`

## 결론

1. A Phase 3 stub 포트와 C 실제 Event/Control RTL을 연결한 래퍼를 구현했다.
2. `npu_done`을 C `target_update`로 직접 연결했다.
3. A의 RW Servo Command Register는 **Manual Override**로 채택한다.
4. C 자동 추적 위치는 `0x58/0x5C` 신규 RO 상태 Register로 PS에 공개할 것을 요청한다.
5. `SAFE_LIMIT/SAFE_LIMIT2`, `LASER_CAL`, `INPUT_STAT` bit 배치를 C가 확정했다.
6. A stub에 빠진 실제 Event Source 포트와 `tensor_start`를 추가해야 한다.
7. 실제 광원은 Power-on/E-stop/max-on 뒤 Laser Arm LOW→HIGH 수동 재무장을 요구한다.

공통 명세의 PT#2 좌표식, 4-Servo, SAFE_LIMIT2, LED 우선 정책은 변경하지 않았다.
2026-08-22 Dataset/Label 운영 정정도 C 인터페이스 변경이 없으므로 RTL 영향이 없다.

## D3 FREEZE A-002 항목 회신

| 항목 | C 회신 |
|---|---|
| Base `0x4000_0000`, 4 KB | **수용** |
| `CTRL.INPUT_SRC` 0=PS / 1=C | **수용** |
| PT#2 좌표 변환 | **수용·구현 완료** |
| `SAFE_LIMIT2` 필수 | **수용·구현 완료** |
| `PAN/TILT/PAN2/TILT2_CMD` | RW 유지, **Manual Override 명령**으로 사용 |
| `TRACK_ERR_X/Y` | C 하드웨어 Tracking에서는 미사용. RO 상태 Register로 교체 권장 |
| `EVENT_CFG/INPUT_STAT` | 아래 bit 배치로 확정 요청 |

## Register bit 배치

### `0x08 EVENT_CFG`

```text
bit0 EVENT_ENABLE
bit1 POLARITY_INVERT
31:2 예약 0
```

### `0x28 LASER_CTRL`

```text
bit0 SERVO_ENABLE
bit1 SW_LASER_ARM       // 실제 Arm = 이 bit AND laser_arm_hw
bit2 SW_ESTOP           // 실제 E-stop = 이 bit OR emergency_stop_hw
bit3 MANUAL_OVERRIDE
bit4 MANUAL_AIM_READY   // 수동 조준 확인 전에는 0
bit8 RUNTIME_LIMIT_EN
bit9 RUNTIME_CAL_EN
그 외 예약 0
```

### Servo / Limit / Calibration

```text
PAN_CMD / TILT_CMD / PAN2_CMD / TILT2_CMD
  [7:0] unsigned Servo pos, Manual Override에서만 사용

SAFE_LIMIT / SAFE_LIMIT2
  [7:0] PAN_MIN      [15:8] PAN_MAX
  [23:16] TILT_MIN   [31:24] TILT_MAX

LASER_CAL
  [15:0]  PAN signed offset
  [31:16] TILT signed offset
  단위 = Servo pos step
```

잘못된 Runtime Limit은 적용하지 않고 정적 32~224 범위로 fallback하며 fault를 세운다.
Limit 갱신 중에는 Laser Arm을 해제한다.

### `0x0C INPUT_STAT`

```text
bit0 ACC_READY
bit1 TENSOR_READY       // sticky: tensor_start에서 1, NPU BUSY에서 0
bit2 OVERRUN
bit3 EVENT_ENABLE
bit4 NPU_BUSY
bit5 TARGET_VALID
bit6 LASER_LOCK
bit7 LASER_TIMEOUT
19:8  WIN_EVT_COUNT     // 12-bit saturation
31:20 WIN_DROP_COUNT    // 12-bit saturation
```

### 신규 RO 제안

```text
0x58 SERVO_POS_STAT = {TILT2, PAN2, TILT1, PAN1}
0x5C CONTROL_STAT:
  [0] LASER_EN        [1] LASER_LOCK       [2] TARGET_FRESH
  [3] LASER_TIMEOUT   [4] AIM_READY        [5] MANUAL_OVERRIDE
  [6] LIMIT_ACTIVE    [7] LIMIT_FAULT      [8] SERVO_ENABLE
  [9] HW_ARM          [10] SW_ARM          [11] EMERGENCY_STOP
  [12] TENSOR_READY   [13] ACC_READY       [14] OVERRUN
  [15] TARGET_VALID   [16] LASER_REARM_REQUIRED
  [31:17] 0
```

`LASER_REARM_REQUIRED=1`이면 Lock 조건이 다시 만족되어도 출력은 유지 OFF다. PS는
Laser Arm을 0으로 내린 뒤 상태가 0으로 clear된 것을 확인하고 다시 Arm해야 한다.

## START 연결 권장안

원 공통 명세 §7.3과 C 회신 001의 Direct Handshake를 유지하는 안을 권장한다.

```verilog
npu_start = input_src ? c_tensor_start : axi_start_pulse;
```

```text
INPUT_SRC=0: PS가 AXI로 Tensor 적재 후 CTRL.START
INPUT_SRC=1: C가 Tensor 8192 byte 전송 후 tensor_start 자동 발생
```

이렇게 하면 두 경로가 동시에 START를 발생시키지 않는다. `TENSOR_READY`는 PS 진단용으로
남는다. A가 PS-managed 방식을 선택한다면 `c_tensor_start`를 NPU에 연결하지 않고
PS가 `TENSOR_READY`를 폴링해야 한다. 두 방식 동시 사용은 금지한다.

## A stub에 추가할 실제 Event Source 포트

```verilog
input wire                   src_valid;
input wire [SRC_COORD_W-1:0] src_x;
input wire [SRC_COORD_W-1:0] src_y;
input wire                   src_pol;
input wire                   src_window_end;
```

현재 Phase 3 문서의 stub만으로는 Event Adapter에 입력이 들어오지 않아 실물 경로가
성립하지 않는다. 실제 Event Camera 또는 Webcam 변환 경로가 이 5개를 구동해야 한다.

## 외부 핀

C가 실물 검증한 배치를 유지한다.

| 신호 | Pmod | Pin |
|---|---|---|
| PAN1 | JD1 | T14 |
| TILT1 | JD2 | T15 |
| PAN2 | JD3 | P14 |
| TILT2 | JD4 | R14 |
| Laser LED | JD7 | U14 |

A stub 문서의 임시 Pmod JC 배치 대신 위 JD 배치를 통합 XDC에 반영 요청한다.

## 검증

`tb_c_event_control_top` 27/27 PASS:

```text
8192 byte CHW Tensor 전송
Positive/Negative count / Polarity Invert
tensor_start / Sticky TENSOR_READY
NPU done -> target_update
4-Servo Manual Override
Runtime SAFE_LIMIT clamp / invalid fallback
Hardware E-stop Fail-Closed
E-stop release 자동 재점등 금지 / CONTROL_STAT[16] 재무장 상태
```

KY-008 전용 TB를 포함해 자동판정 TB 12개를 재실행했으며 로그 기준
**287 PASS, errors=0**이다.

Zybo Z7-20 (`xc7z020clg400-1`) 100 MHz 기준 C 래퍼 단독 OOC implementation은
LUT 829, Register 582, BRAM Tile 4, DSP 6을 사용했고 DRC 0 Error,
WNS +1.138 ns / WHS +0.147 ns를 만족했다. A 전체 시스템 통합 후에는 타이밍을 다시 측정한다.

## A 회신 요청

1. `INPUT_SRC` 기반 START MUX 권장안 승인 여부
2. 실제 Event Source 5포트를 `top_system`에 추가할 수 있는지
3. `0x58 SERVO_POS_STAT`, `0x5C CONTROL_STAT` 추가 승인 여부
4. `TRACK_ERR_X/Y`를 유지할지 RO Status로 교체할지
5. JD1~JD4 + JD7 통합 XDC 반영 여부
6. A Phase 3 실제 RTL/PS 소프트웨어 브랜치 전달 또는 integration merge 시점
