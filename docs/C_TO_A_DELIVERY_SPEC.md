# C → A 전달 규격 (A가 요청하는 최종 형식)

> **작성:** A
> **대상:** C
> **기준:** `TEAM_COMMON_AI_INTEGRATION_SPEC.md` **v1.5** §5.3 / §6 / §7 / §14 / **§15.2** / **§20.1** / §26 / §39
> **갱신:** 2026-08-25 — A Phase 4 문서와 C `c_control_v07` 상태 재조정. §11 포트 골격/추가 포트 확정.
> **목적:** C의 RTL을 A가 **포트만 연결하면 되는** 형태로 고정

A쪽 NPU Core는 완성·검증되어 있고 C가 붙일 포트를 이미 전부 노출하고 있다.
C는 아래 두 지점만 맞춰 주면 된다.

```text
C 출력 -> A 입력 :  Event Tensor  (evt_we / evt_addr / evt_data)
A 출력 -> C 입력 :  Target        (target_valid / target_x / target_y / target_score)
A 제공         :  AXI Register  0x08 / 0x0C / 0x20~0x34 / 0x48~0x54 (bit 의미는 C 가 정의)
Pan/Tilt       :  2 헤드. PT#1=카메라(0x20/0x24), PT#2=레이저(0x48/0x4C). §10 필독
```

**A 쪽은 이미 다 끝났다.** Bitstream 까지 나왔고(`results/npu_soc.bit`),
C 경로(`INPUT_SRC=1`)도 TB 로 검증해서 PS 경로와 **완전히 같은 결과**가 나오는 것을
확인했다. C 는 신호 4개만 구동하면 된다.

> **포트 이름 주의:** `npu_core` 안에서는 `ext_we/ext_addr/ext_data` 지만,
> C 가 실제로 붙는 통합 top(`rtl/integration/top_system.v`)에서는
> **`evt_we / evt_addr[12:0] / evt_data[7:0]`** 이다.
> `CTRL.INPUT_SRC=1` 일 때만 이 경로가 `npu_core` 로 연결된다 (mux).

---

## 1. 전달 위치

```text
NPU_Project/
├─ rtl/event/
│   ├─ event_adapter.v
│   └─ event_accumulator.v
├─ rtl/control/
│   ├─ tracking_controller.v
│   ├─ servo_pwm.v
│   ├─ laser_interlock.v
│   └─ board_io.v            (선택)
├─ tb/event/
├─ tb/control/
└─ handoff/C_EVENT_CONTROL_HANDOFF.md
```

`rtl/integration/top_system.v`는 **A가 작성한다.** C는 건드리지 않는다 (spec §5.4).

---

## 2. C → A : Event Tensor 출력 규격

### 2-1. A가 제공하는 포트 (`rtl/npu/npu_core.v`, 이미 구현됨)

```verilog
input  wire        ext_we;        // 1 = 이번 cycle 쓰기
input  wire [12:0] ext_addr;      // 0 ~ 8191
input  wire signed [7:0] ext_data;// 0 ~ 127
input  wire        start;         // 1 cycle pulse, 전송 끝난 뒤
output wire        busy;          // 1이면 쓰기 금지
output wire        done;          // 1 cycle pulse
```

### 2-2. 주소식 (**이것만 지키면 됨**)

```text
ext_addr = (polarity << 12) | (event_y << 6) | event_x

polarity 0 = Positive  (spec §7.1 Channel 0)
polarity 1 = Negative  (spec §7.1 Channel 1)
event_x  = 0 ~ 63
event_y  = 0 ~ 63
```

즉 CHW 순서다. 확정 근거: `docs/D3_FREEZE_REQUEST_A_001.md` 1번 항목.

### 2-3. 전송 프로토콜

```text
event_window_end pulse
   ↓
busy == 0 확인
   ↓
8192 byte 전송 (1 byte / cycle, 주소 0 → 8191 순차 권장)
   ↓
ext_we = 0
   ↓
start 1 cycle pulse
   ↓
done 대기  (125,845 cycle = 1.258 ms @100MHz)
```

```text
전송 소요 = 8192 cycle = 82 us @100MHz
추론 소요 = 1.258 ms
합계      = 약 1.34 ms  << Event Window 5~10 ms
```

### 2-4. 제약 (반드시 지킬 것)

```text
busy == 1 인 동안 ext_we 를 올리면 안 된다.
   -> 현재 입력 버퍼가 내부 ping-pong 버퍼를 공유하기 때문
   -> 추론 중 다음 Window 를 미리 못 쓴다
   -> Window 5~10 ms 대비 1.34 ms 라 MVP 에서는 문제 없음
   -> 연속 스트리밍이 필요해지면 A 가 입력 전용 버퍼를 추가한다 (BRAM 여유 충분)
```

### 2-5. `event_accumulator.v` 권장 출력 포트

A가 `top_system.v`에서 그대로 연결할 수 있는 형태:

```verilog
module event_accumulator (
    input  wire        clk,
    input  wire        rstn,
    // 내부 표준 Event 입력 (spec §6.1) -- 이름/폭 변경 금지
    input  wire        event_valid,
    input  wire  [5:0] event_x,
    input  wire  [5:0] event_y,
    input  wire        event_polarity,
    input  wire        event_window_end,
    // NPU 로 나가는 Tensor 출력
    input  wire        npu_busy,       // npu_core.busy
    output wire        tensor_we,      // -> ext_we
    output wire [12:0] tensor_addr,    // -> ext_addr
    output wire signed [7:0] tensor_data, // -> ext_data
    output wire        tensor_start    // -> start (전송 완료 후 1 cycle)
);
```

포트 이름이 달라도 되지만 **폭과 의미는 위와 같아야 한다.**
다르면 `handoff/C_EVENT_CONTROL_HANDOFF.md`에 대응표를 적어 준다.

### 2-6. Event Count 값 규칙

```text
Window 안에서 같은 (x, y, polarity) 이벤트를 누적
0 ~ 127 로 saturation  (spec §9.1: Conv1 입력은 0~127 만 사용)
128 이상으로 넘기지 말 것 (signed INT8 에서 음수가 됨)
Window 종료 시 다음 Window 용 버퍼는 0 으로 초기화
범위 밖 좌표(x>63 or y>63) 는 버린다
```

---

## 3. A → C : Target 입력 규격

### 3-1. A가 내보내는 포트 (이미 구현됨)

```verilog
output wire        target_valid;
output wire  [5:0] target_x;       // 4,12,20,28,36,44,52,60 만 나옴
output wire  [5:0] target_y;       // 동일
output wire signed [7:0] target_score;
```

### 3-2. 의미

```text
target_valid = (heatmap_max_score > score_th)     score_th 기본 0
target_x/y   = 64x64 입력 좌표계, Heatmap Cell 중심 (spec §14.1)
               X 왼->오 증가, Y 위->아래 증가
target_score = Conv4 Heatmap 최대값, signed INT8
유효 시점    = done pulse 이후 ~ 다음 start 까지 유지
```

### 3-3. Tracking Controller 필수 규칙

```text
Center X = 32, Center Y = 32
error_x = target_x - 32
error_y = target_y - 32

DEAD_ZONE >= 4    <- 반드시. spec §15
```

`target_x/y`가 `4,12,20,28,36,44,52,60` 8개 값만 나오므로 정확한 32가 안 나온다.
중앙에 가장 가까운 값이 28 또는 36이라 오차가 항상 ±4다.
Dead Zone을 4보다 작게 잡으면 **서보가 영원히 좌우로 진동한다.**

```text
target_valid == 0 -> Target Lost (spec §16)
                     Servo Hold + Laser OFF
```

---

## 4. C 단위 테스트 통과 조건 (A에게 넘기기 전)

역할분담 §5.3 / spec §39 기준.

### Event 입력

- [x] 같은 좌표 Event 누적됨
- [x] Positive / Negative 채널 분리됨
- [x] `event_window_end`에서 Tensor 확정
- [x] 다음 Window 시작 시 버퍼 초기화
- [x] 범위 밖 좌표 무시
- [x] 0~127 saturation 확인
- [x] 저장 Event Trace 입력 테스트 PASS

### Servo / Tracking

- [x] `target_x < 32` → Pan Left
- [x] `target_x = 32` → Hold
- [x] `target_x > 32` → Pan Right
- [x] Tilt 동일
- [x] `abs(error) <= 4` → Hold (Dead Zone)
- [x] Servo Angle Limit 동작
- [x] `target_valid = 0` → Hold + Laser OFF

### Laser

- [x] LOCK_ZONE / SAFE_ZONE / Emergency 조건 확인
- [x] Emergency OFF와 수동 재무장 동작

---

## 5. Handoff 문서 — `handoff/C_EVENT_CONTROL_HANDOFF.md`

spec §26 필수 항목:

```text
Event Input Format / Tensor Output Format / Window Setting
Tracking Input Format / Servo PWM Requirement / Dead Zone
Safe Limit / Target Lost Policy / Laser Interlock / Known Limitation
```

`docs/A_NPU_HANDOFF.md`를 형식 참고용으로 쓰면 된다.

---

## 6. 전달 방법

### 방법 1 — Git (권장, spec §24)

```bash
git checkout -b feature/c-event-control
git add rtl/event/ rtl/control/ tb/event/ tb/control/ handoff/C_EVENT_CONTROL_HANDOFF.md
git commit -m "[C][EVENT] Add event accumulator + tensor output"
git commit -m "[C][CTRL] Add tracking controller / servo pwm / laser interlock"
git push origin feature/c-event-control
```

### 방법 2 — 압축 전달

```text
c_deliver_v01.zip
├─ rtl/event/
├─ rtl/control/
├─ tb/event/
├─ tb/control/
└─ handoff/C_EVENT_CONTROL_HANDOFF.md
```

**폴더 구조를 그대로 유지**한다. A가 그 경로 그대로 `top_system.v`에 연결한다.

---

## 7. C 체크리스트

- [x] `rtl/event/`, `rtl/control/` 실제 C RTL 전달
- [x] 단위/통합/KY-008 TB 12종 존재 — 자동판정 **287 PASS, errors=0**
- [x] `ext_addr = (polarity<<12)|(y<<6)|x` 주소식 준수
- [x] Event Count 0~127 saturation
- [x] `npu_busy == 1`일 때 쓰기 안 함
- [x] Dead Zone >= 4
- [x] `target_valid = 0` 시 Hold + Laser OFF
- [x] `handoff/C_EVENT_CONTROL_HANDOFF.md` (`c_control_v07`)
- [x] A 소유 `top_system.v` / 통합 XDC / Block Design 미수정

---

## 8. A가 C에게 물어본 것 (회신 필요)

| # | 질문 | 상태 |
|---|---|---|
| 1 | `ext_we / ext_addr[12:0] / ext_data[7:0]` 직접 write 방식 수용 여부 | **C 수용·구현 완료** — 회신 001 |
| 2 | `docs/D3_FREEZE_REQUEST_A_001.md` 승인 (특히 1번 CHW, 5번 ext 포트) | **C 전 항목 수용 완료** — 회신 001, B 확인 별도 |
| 3 | Event Window 값 (5 ms / 10 ms) 결정됐는지 — spec §21 빈칸 | **A/B 결정 대기** — C는 CR C-002에서 33.3 ms 제안 |
| 4 | Servo Command Format — spec §21 빈칸 | **C 구현 완료 / A 승인 대기** — CR C-001 |
| 5 | `docs/D3_FREEZE_REQUEST_A_002.md` 승인 (AXI Register Bit Field) | **C 기본 계약 수용·구현 완료** — 회신 002/003 |
| 6 | `0x20`~`0x34` / `0x48`~`0x54` 방향 (RW+출력 / RO+입력) | **RW Manual Override 채택 / 신규 RO는 A 회신 대기** — 회신 003/004 |
| 7 | **PT#2 좌표 변환식 (§10.1) 동의 여부** | **C 수용·구현 완료** — 회신 002 |
| 8 | Servo 4채널 PWM 핀 (어느 PMOD 쓸지) | **C JD 배치 제안·실물 검증 완료 / A 통합 XDC 반영 대기** |

---

## 9. AXI Register — C 가 쓸 수 있는 것 (v1.4 §20.1 신규)

A 가 `rtl/integration/npu_axi.v` 를 구현·검증했다.
전체 표는 공통 지침 **v1.4 §20.1**, 근거서는 `docs/D3_FREEZE_REQUEST_A_002.md`.

```text
Base = 0x4000_0000 , Range 4 KB
PS7 M_AXI_GP0 -> AXI SmartConnect -> top_system.s_axi
FCLK_CLK0 = 100 MHz = NPU clk = s_axi_aclk  (단일 도메인, CDC 없음)
```

### 9.1 C 소유 Register — bit 의미는 **C 가 정한다**

| Offset | 이름 | 현재 A 구현 | `top_system` 포트 |
|---:|---|---|---|
| `0x08` | `EVENT_CFG` | RW 32-bit 저장소 | `event_cfg[31:0]` (출력) |
| `0x0C` | `INPUT_STAT` | RO, C 하드웨어가 구동 | `input_stat[31:0]` (입력) |
| `0x20` | `PAN_CMD` | RW 32-bit 저장소 | `pan_cmd[31:0]` (출력) |
| `0x24` | `TILT_CMD` | RW | `tilt_cmd[31:0]` (출력) |
| `0x28` | `LASER_CTRL` | RW | `laser_ctrl[31:0]` (출력) |
| `0x2C` | `SAFE_LIMIT` | RW | `safe_limit[31:0]` (출력) |
| `0x30` | `TRACK_ERR_X` | RW | `track_err_x[31:0]` (출력) |
| `0x34` | `TRACK_ERR_Y` | RW | `track_err_y[31:0]` (출력) |
| `0x48` | `PAN2_CMD` | RW | `pan2_cmd[31:0]` (출력) — **PT#2 레이저 헤드** |
| `0x4C` | `TILT2_CMD` | RW | `tilt2_cmd[31:0]` (출력) — **PT#2** |
| `0x50` | `SAFE_LIMIT2` | RW | `safe_limit2[31:0]` (출력) — **PT#2, 필수** |
| `0x54` | `LASER_CAL` | RW | `laser_cal[31:0]` (출력) — 조준 보정 계수 |

> `0x20 PAN_CMD` / `0x24 TILT_CMD` / `0x2C SAFE_LIMIT` 는 **PT#1 = 카메라 헤드**다.
> Offset/의미는 안 바뀌었고 용도만 명확해졌다. 상세는 §10.

**A 는 이 8개의 bit 배치를 정하지 않았다.** Servo Command Format 이 §21 에서
아직 `[ ] C 미정` 이기 때문이다. C 가 정해서 `docs/interface_contract.md` 에 적어라.

### 9.2 C 가 회신해야 할 것

| # | 질문 | A 기본값 |
|---:|---|---|
| 1 | Base `0x4000_0000` / 4 KB 괜찮은가 | 그대로 |
| 2 | `0x20`~`0x34` 를 지금처럼 **RW + 하드웨어 출력**으로 둘까 | RW + 출력 |
| 3 | `TRACK_ERR_X/Y` 를 C 하드웨어가 계산하나, PS 소프트웨어가 계산하나 | PS 계산 가정 |
| 4 | `CTRL.INPUT_SRC` (0=PS, 1=C 직결) 동의하는가 | 동의로 간주 |
| 5 | `IRQ_F2P` 인터럽트를 쓸 것인가 | 둘 다 가능하게 열어 둠 |
| 6 | `EVENT_CFG` bit 배치 | 32-bit 통짜 |
| 7 | **`0x48`~`0x54` 4개로 충분한가** | 부족하면 `0x58` 부터 추가 |
| 8 | **§10 PT#2 좌표 변환식 동의 여부** | 그대로 구현 (제일 중요) |

**`TRACK_ERR_X/Y` 를 C 하드웨어가 계산할 거면 RO + 입력 포트로 바꿔야 한다. A 가 바꿔 준다.**
지금 말해라. PS 소프트웨어까지 다 만든 뒤에 바꾸면 양쪽 다 고쳐야 한다.

### 9.3 C 가 A 에게 RTL 을 넘길 때 추가로 알려 줄 것

```text
- 모듈이 쓰는 클럭이 100 MHz 단일 도메인 맞는가 (아니면 CDC 를 C 가 처리)
- 예상 LUT / FF / BRAM / DSP 대략치
  (현재 전체 시스템이 LUT 2.46% / DSP 5.45% 이므로 여유는 크지만,
   타이밍 여유가 7.1% 라 큰 조합 논리가 들어오면 재측정이 필요하다)
- 외부 핀이 필요하면 어느 커넥터인가 (PMOD JA/JB/JC/JD, Servo/Laser)
  -> A 가 constraints/zybo_z7_20_top.xdc 에 핀을 추가한다
```

### 9.4 지금 BD 상태 (C 모듈이 없어서)

```text
evt_we / evt_addr / evt_data / input_stat  -> xlconstant 0 으로 묶여 있음
event_cfg / pan_cmd / ... / track_err_y    -> 미연결 (합성에서 제거됨)
```

C 모듈은 전달 완료됐다. A가 tie를 지우고 `c_event_control_top`과 §11 추가 포트를
연결한 뒤 `sim/run_bd.tcl`로 리소스·타이밍을 다시 측정한다.

---

## 10. Pan/Tilt 2 헤드 — C 가 반드시 지킬 것 (신규)

정본: 공통 지침 **v1.5 §15.2**, 근거서 `docs/D3_FREEZE_REQUEST_A_002.md` rev.2 §2.13.

```text
   PT#1                                 PT#2
 ┌──────────────┐                     ┌──────────────┐
 │ Event Camera │   baseline <=10cm   │ Laser Module │
 └──────────────┘                     └──────────────┘
 0x20 PAN_CMD                          0x48 PAN2_CMD
 0x24 TILT_CMD                         0x4C TILT2_CMD
 0x2C SAFE_LIMIT                       0x50 SAFE_LIMIT2
 화면 중앙 유지 (closed-loop)            표적 절대방향 조준
```

### 10.1 좌표 변환 (이거 하나만 지키면 됨)

```text
k_x = FOV_X / 64        [deg/pixel]
k_y = FOV_Y / 64        [deg/pixel]

theta_pan_target  = theta_pan1  + k_x * (target_x - 32)
theta_tilt_target = theta_tilt1 + k_y * (target_y - 32)

PAN2_CMD  = theta_pan_target  + LASER_OFFSET_PAN
TILT2_CMD = theta_tilt_target + LASER_OFFSET_TILT
```

`theta_pan1 / theta_tilt1` = **Tracking Controller 가 방금 자기가 낸
`PAN_CMD` / `TILT_CMD` 값**이다. 센서 필요 없다.

```text
[가장 흔한 오구현]
  PAN2_CMD = f(error_x)
  -> 레이저가 표적이 아니라 "오차"를 따라간다.
     표적이 화면 중앙에 오면 레이저가 0도를 가리킨다.
     AI 한테 시키면 이렇게 짜기 쉽다. 반드시 확인해라.
```

**좋은 소식:** 위 식은 카메라가 아직 중앙 정렬을 끝내지 못한 상태에서도 정확하다.
**레이저가 카메라보다 먼저 락온된다.**

**부호는 실측으로 정해라.** 서보 회전 방향 × 카메라 장착 방향에 따라 `k_x` 부호가
뒤집힌다. 표적을 오른쪽에 두고 `PAN2_CMD` 가 오른쪽으로 가는지 눈으로 본다.

### 10.2 LASER_OFFSET 보정 (D11)

```text
1. 고정 거리 D (권장 2 m) 에 표적을 둔다
2. PT#1 이 표적을 화면 중앙에 잡게 한다
3. 레이저가 표적에 맞을 때까지 PAN2_CMD / TILT2_CMD 를 손으로 조정
4. (PAN2_CMD - theta_pan_target) = LASER_OFFSET_PAN
5. 중앙 + 네 모서리 5 지점 측정 후 평균
```

Parallax 는 baseline<=10cm + 고정 거리면 이 오프셋이 통째로 흡수한다.
거리가 2.0 m ± 0.5 m 흔들리면 잔차 ±0.7° ≈ **±2.5 cm**. 표적판을 그보다 크게.

### 10.3 안전 — 이번 변경으로 새로 생긴 위험

```text
[헤드 1개였을 때]  카메라가 보는 곳 = 레이저가 가는 곳. 기구적으로 자동 보장.
[헤드 2개]         레이저가 카메라 시야 밖을 조준할 수 있다.
```

그래서:

```text
- SAFE_LIMIT2 (0x50) 는 선택이 아니라 필수
- Laser ON 조건에 "PT#2 servo inside SAFE_LIMIT2" 반드시 추가
- 좌표 변환 첫 검증은 반드시 레이저 대신 LED 로
```

### 10.4 하드웨어

```text
Servo 채널  2 -> 4  (PAN1 / TILT1 / PAN2 / TILT2)
전류        2배. 외부 5V 전원 용량 확인. 보드 5V 에서 뽑지 마라.
PWM 핀      4개 필요. 어느 PMOD 쓸지 알려주면 A 가 XDC 에 추가한다.
```

---

## 11. A Phase 4 포트 골격과 C 실제 모듈 — `c_event_control_top.v`

A가 통합 측정용으로 만든 `rtl/integration/c_module_stub.v`의 기본 포트는
C의 `rtl/control/c_event_control_top.v`와 일치한다. 다만 실제 Event Source,
물리 Arm/E-stop, START 및 RO 상태 포트는 stub에 없으므로 A 통합 시 추가해야 한다.

```verilog
module c_module_stub #(parameter PWM_W = 20) (
    input  wire        clk, rstn,
    // AXI Register 에서 오는 설정 (C 소유)
    input  wire [31:0] event_cfg, pan_cmd, tilt_cmd, laser_ctrl, safe_limit,
    input  wire [31:0] track_err_x, track_err_y,
    input  wire [31:0] pan2_cmd, tilt2_cmd, safe_limit2, laser_cal,
    // NPU 결과 (A -> C)
    input  wire        npu_busy, npu_done, target_valid,
    input  wire [5:0]  target_x, target_y,
    input  wire signed [7:0] target_score,
    // Event Tensor 기록 (C -> A)
    output reg         evt_we,
    output reg  [12:0] evt_addr,
    output reg  signed [7:0] evt_data,
    output wire [31:0] input_stat,
    // 외부 핀
    output wire [3:0]  servo_pwm,   // {TILT2, PAN2, TILT1, PAN1}
    output wire        laser_en
);
```

실제 C 모듈에 들어 있는 것:

```text
1. Servo PWM 4채널 + Slew/동적 Safe Limit
2. Tracking/PT#2 좌표 변환 + Runtime `LASER_CAL`
3. Event Adapter + Ping-Pong Accumulator + CHW 8192-byte 전송
4. Laser Fail-Closed Interlock + Power-on/E-stop/max-on 수동 재무장
```

stub 대비 필수 추가 포트:

```text
src_valid/src_x/src_y/src_pol/src_window_end
tensor_start
laser_arm_hw/emergency_stop_hw
servo_pos_stat[31:0]/control_stat[31:0]
```

정확한 연결과 START 단일 소유권은 `C_TO_A_REPLY_004.md` 및
`handoff/C_EVENT_CONTROL_HANDOFF.md` §11을 따른다.

### 통합 사전측정 결과 — 자리표시자 기준

| | A 단독 | 자리표시자 포함 |
|---|---:|---:|
| Slice LUT | 1441 (2.71%) | 1785 (3.36%) |
| Slice Register | 1392 | 1565 |
| WNS @100MHz | +0.782 ns | **+1.121 ns (MET)** |

**C 규모의 로직이 들어와도 100 MHz 는 안 깨진다.**
FPGA 는 96% 이상 비어 있다. 여유 걱정 말고 짜면 된다.

> 위 수치는 **A 가 만든 자리표시자**의 것이지 C 실물의 수치가 아니다.
> C 실물이 오면 다시 잰다.

### 빌드

```bash
# A 단독 (기본)
cd build && vivado -mode batch -source ../sim/run_bd.tcl

# 자리표시자 포함
cd build && vivado -mode batch -source ../sim/run_bd.tcl -tclargs -stub
```

### 핀 (임시)

`constraints/zybo_z7_20_cstub.xdc` — Pmod JC 에 임시 배치.

```text
servo_pwm[0] PAN1  V15      servo_pwm[2] PAN2  T11
servo_pwm[1] TILT1 W15      servo_pwm[3] TILT2 T10
laser_en           W14      (개발 중에는 LED 로 검증)
```

**실제로 쓸 커넥터를 알려주면 A 가 바꾼다.**
