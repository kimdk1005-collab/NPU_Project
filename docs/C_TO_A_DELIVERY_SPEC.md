# C → A 전달 규격 (A가 요청하는 최종 형식)

> **작성:** A
> **대상:** C
> **기준:** `TEAM_COMMON_AI_INTEGRATION_SPEC.md` v1.2 §5.3 / §6 / §7 / §14 / §26 / §39
> **목적:** C의 RTL을 A가 **포트만 연결하면 되는** 형태로 고정

A쪽 NPU Core는 완성·검증되어 있고 C가 붙일 포트를 이미 전부 노출하고 있다.
C는 아래 두 지점만 맞춰 주면 된다.

```text
C 출력 -> A 입력 :  Event Tensor  (ext_we / ext_addr / ext_data + start)
A 출력 -> C 입력 :  Target        (target_valid / target_x / target_y / target_score)
```

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

- [ ] 같은 좌표 Event 누적됨
- [ ] Positive / Negative 채널 분리됨
- [ ] `event_window_end`에서 Tensor 확정
- [ ] 다음 Window 시작 시 버퍼 초기화
- [ ] 범위 밖 좌표 무시
- [ ] 0~127 saturation 확인
- [ ] 저장 Event Trace 입력 테스트 PASS

### Servo / Tracking

- [ ] `target_x = 10` → Pan Left
- [ ] `target_x = 32` → Hold
- [ ] `target_x = 50` → Pan Right
- [ ] Tilt 동일
- [ ] `abs(error) <= 4` → Hold (Dead Zone)
- [ ] Servo Angle Limit 동작
- [ ] `target_valid = 0` → Hold + Laser OFF

### Laser

- [ ] LOCK_ZONE / SAFE_ZONE / Emergency 조건 확인
- [ ] Emergency OFF 즉시 동작

---

## 5. Handoff 문서 — `handoff/C_EVENT_CONTROL_HANDOFF.md`

spec §26 필수 항목:

```text
Event Input Format / Tensor Output Format / Window Setting
Tracking Input Format / Servo PWM Requirement / Dead Zone
Safe Limit / Target Lost Policy / Laser Interlock / Known Limitation
```

`handoff/A_NPU_HANDOFF.md`를 형식 참고용으로 쓰면 된다.

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

- [ ] `rtl/event/` 2파일, `rtl/control/` 3파일
- [ ] 각 모듈 단위 TB 존재 + PASS
- [ ] `ext_addr = (polarity<<12)|(y<<6)|x` 주소식 준수
- [ ] Event Count 0~127 saturation
- [ ] `npu_busy == 1`일 때 쓰기 안 함
- [ ] Dead Zone >= 4
- [ ] `target_valid = 0` 시 Hold + Laser OFF
- [ ] `handoff/C_EVENT_CONTROL_HANDOFF.md`
- [ ] `top_system.v` / `constraints/` / Block Design 안 건드림 (spec §5.4)

---

## 8. A가 C에게 물어본 것 (회신 필요)

| # | 질문 | 상태 |
|---|---|---|
| 1 | `ext_we / ext_addr[12:0] / ext_data[7:0]` 직접 write 방식 수용 여부 | **회신 대기** |
| 2 | `docs/D3_FREEZE_REQUEST_A_001.md` 승인 (특히 1번 CHW, 5번 ext 포트) | **회신 대기** |
| 3 | Event Window 값 (5 ms / 10 ms) 결정됐는지 — spec §21 빈칸 | **회신 대기** |
| 4 | Servo Command Format — spec §21 빈칸 | **회신 대기** |
