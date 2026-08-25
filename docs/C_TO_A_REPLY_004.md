# C → A 회신 004 — A Phase 4 문서 수신 및 실제 C 모듈 교체 계약

> 회신일: 2026-08-25
> 대상: A Phase 4 `integration_manifest.md`, `C_TO_A_DELIVERY_SPEC.md` §11
> C 버전: `C_EVENT=c_event_v04`, `C_CONTROL=c_control_v07`, `INTERFACE=ifc_v0.5`
> 상태: **C RTL 전달 완료 / A 실제 NPU·AXI 통합 대기**

## 1. 결론

1. A 제공 기록의 A-only Zybo Z7-20 기능 판정 16/16 PASS를 Phase 4 완료로 반영한다.
2. A의 `c_module_stub.v` 기본 AXI/NPU/PWM 포트는 C 실제 모듈과 호환된다.
3. 실제 통합에는 stub에 없던 Event Source, 물리 안전, START, RO 상태 포트가 추가로 필요하다.
4. 기존 C 승인과 구현 상태는 유지한다. 새 배포본의 “C 미착수/승인 대기” 표기는 적용하지 않는다.
5. A-only 산출물은 현재 C 체크아웃에 없으므로 전체 A/C implementation은 통합 브랜치에서 수행한다.

## 2. 실제 교체 모듈

```text
자리표시자  rtl/integration/c_module_stub.v       A 소유
실제 모듈  rtl/control/c_event_control_top.v      C 소유
Handoff    handoff/C_EVENT_CONTROL_HANDOFF.md §11
```

A는 stub 내부에 C 코드를 복사하지 않고, stub 인스턴스를 `c_event_control_top`으로
교체하거나 동일 포트의 A 소유 wrapper에서 인스턴스한다.
`c_event_control_top`은 A stub의 named parameter `.PWM_W(20)`도 호환 입력으로 받는다.
실제 Servo 주기는 `CLK_HZ/PWM_HZ` 기반 C 구현을 사용한다.

### 2.1 그대로 연결되는 기본 포트

```text
clk / rstn
event_cfg / pan_cmd / tilt_cmd / laser_ctrl / safe_limit
track_err_x / track_err_y
pan2_cmd / tilt2_cmd / safe_limit2 / laser_cal
npu_busy / npu_done / target_valid / target_x / target_y / target_score
evt_we / evt_addr / evt_data / input_stat
servo_pwm[3:0] / laser_en
```

`servo_pwm = {TILT2, PAN2, TILT1, PAN1}`이며 bit0이 PAN1이다.

### 2.2 A stub에 추가해야 하는 포트

```verilog
// Event Source -> C
input  wire                   src_valid;
input  wire [SRC_COORD_W-1:0] src_x;
input  wire [SRC_COORD_W-1:0] src_y;
input  wire                   src_pol;
input  wire                   src_window_end;

// 물리 Fail-Closed 입력 -> C
input  wire                   laser_arm_hw;
input  wire                   emergency_stop_hw;

// C -> A
output wire                   tensor_start;
output wire [31:0]            servo_pos_stat;
output wire [31:0]            control_stat;
```

물리 입력을 상수 1/0으로 묶어 실제 광원을 우회하지 않는다. 광원 미장착 통합 시험에서는
`laser_arm_hw=0`으로 묶어 `laser_en`이 항상 OFF가 되게 한다.

## 3. START 단일 소유권

C 권장안은 Direct 방식이다.

```text
npu_start = INPUT_SRC ? tensor_start : axi_start_pulse
```

- `INPUT_SRC=0`: PS/AXI 입력 버퍼 적재 후 `CTRL.START`
- `INPUT_SRC=1`: C가 8192 byte 전송 후 `tensor_start`
- PS-managed 방식을 택하면 `tensor_start`를 NPU에 직접 연결하지 않고
  `INPUT_STAT.TENSOR_READY`를 PS가 폴링한다.
- 두 START 경로를 동시에 활성화하지 않는다.

## 4. AXI/좌표 계약 회신

| A 질문 | C 최종 회신 |
|---|---|
| Base `0x4000_0000`, Range 4 KB | 수용·구현 완료 |
| CHW / `evt_addr=(pol<<12)|(y<<6)|x` | 수용·8192 byte 전수 검증 완료 |
| `CTRL.INPUT_SRC` 0=PS, 1=C | 수용. Direct START MUX 권장 |
| `0x20`~`0x34`, `0x48`~`0x54` RW 출력 | Manual Override/Runtime Limit/Cal 입력으로 수용 |
| `TRACK_ERR_X/Y` | C 하드웨어 Tracking에서는 미사용. 기존 RW 유지 가능 |
| PT#2 좌표 변환 | `theta_pan1 + k*(target-32) + LASER_CAL` 수용·구현 완료 |
| `SAFE_LIMIT2` | 필수 조건으로 구현 완료 |
| Servo 4채널 | 구현·단독 실물 검증 완료. A 통합 XDC 반영 대기 |

## 5. 추가 RO 상태

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

`LASER_REARM_REQUIRED=1`이면 Target Lock이 다시 성립해도 출력은 OFF다.
Power-on Arm HIGH, E-stop release, max-on timeout 뒤에는 Laser Arm LOW→HIGH 수동
재무장이 필요하다. Servo Enable OFF→ON은 이 절차를 대신하지 않는다.

## 6. 실제 광원 핀/전원 경계

```text
JD1/JD2 = Camera PT#1 PAN/TILT
JD3/JD4 = Laser PT#2 PAN/TILT
JD7/U14 = KY-008 전원선이 아닌 external High-side switch Enable
```

KY-008 `S`는 5 V/약 30 mA 전원 입력이므로 FPGA GPIO에 직접 연결하지 않는다.
실제 전원 경로에는 current limit/fuse, Key Arm, NC E-stop, default-OFF High-side
load switch를 둔다. 세부 승인 순서는 `KY008_PREARRIVAL_CHECKLIST_C.md`를 따른다.

## 7. C 검증 근거

```text
C 자동판정 TB 12종       287 PASS, errors=0
c_event_control_top OOC  LUT 829 / Register 582 / BRAM 4 / DSP 6
                          WNS +1.138 ns / WHS +0.147 ns / DRC 0 Error
KY-008 board Top          LUT 448 / Register 373 / DSP 4
                          WNS +1.529 ns / WHS +0.153 ns / DRC 0 Error
```

OOC와 KY-008 전용 수치는 A/C 전체 시스템 수치가 아니다. A는 stub 교체 후
`top_system + npu_axi + npu_core + C actual` 전체 implementation을 다시 실행한다.

## 8. A 통합 체크리스트

- [ ] A Phase 4 산출물 md5를 `integration_manifest.md`와 대조
- [ ] `c_module_stub`를 `c_event_control_top`으로 교체
- [ ] Event Source와 물리 Arm/E-stop 포트 추가
- [ ] START Direct/PS-managed 중 하나만 연결
- [ ] `0x58/0x5C` RO Register 추가 또는 ILA 임시 연결
- [ ] Servo 4채널과 JD7 Enable을 통합 XDC에 반영
- [ ] C TB 후 A NPU `INPUT_SRC=1` Golden 비교
- [ ] 전체 implementation DRC/타이밍 재측정
- [ ] 실제 광원 없이 LED/dummy load로 Closed-loop 먼저 검증

위 항목이 끝나기 전에는 `BOARD_VERIFIED`를 A/C 전체 통합 완료로 올리지 않는다.
