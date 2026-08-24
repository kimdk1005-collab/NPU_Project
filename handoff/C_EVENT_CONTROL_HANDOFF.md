# C Handoff — Event 입력 / Tracking / Pan-Tilt / Laser

> **상위 권한 문서** — 팀 공통 통합 명세 **v1.5** 작업본 (이하 SPEC)
> 본 문서와 SPEC이 다르면 **SPEC이 우선한다** (SPEC §1 문서 우선순위).
>
> 본 문서는 SPEC §26이 요구하는 C의 Handoff 문서다.
> C가 **단독으로 정할 수 있는 범위**만 확정하고, 공유 규격은 TBD로 남긴다 (SPEC §0-10).
>
> | | |
> |---|---|
> | 담당 | C (김도근) |
> | 버전 | `c_control_v06` |
> | 최종 갱신 | 2026-08-24 (D6) |
> | 기준 SPEC | **v1.5** |
> | 상태 | D6 — A Phase 3 포트용 C 통합 래퍼 + AXI 설정/상태 계약 완료 |
>
> **SPEC v1.1 반영분** — `target_score` = signed INT8 (§7, §10),
> Event Count 포화 상한 = 127 (§2). 두 항목은 더 이상 TBD가 아니다.
>
> **SPEC v1.2 반영분** — 아래 세 항목이 새로 확정되어 C의 TBD에서 빠졌다.
>
> **D2 확정** — `CLK_HZ = 100 MHz` 단일 clock domain (CR C-003).
> `board_io.v`만 예외로 125 MHz다 (브링업 전용, PL sysclk K17 직결).
>
> | v1.2 확정 항목 | C 측 반영 위치 |
> |---|---|
> | §14.1 Source → 64×64 Mapping `min(63, floor(raw*64/frame))` | §1.1 `event_adapter.v` Binning |
> | §14.1 8×8 Argmax → 64×64 `target = heatmap*8 + 4` | §10 A → C 입력 해석 |
> | §15 Center Dead Zone 최소 `abs(error) <= 4` | §4 `DEAD_ZONE` |
>
> **SPEC v1.5 반영분** — 카메라 PT#1과 레이저 PT#2를 분리했고, PT#2는
> `PT#1 자세 + 화면 잔차 + Offset`으로 절대방향을 계산한다. Laser 출력은
> `SAFE_LIMIT2`를 포함한 Interlock을 통과하며 첫 실물 검증은 LED로 한다.
>
> **2026-08-22 Dataset/Label 운영 정정** — Laser는 NPU 추론 이후의 출력 장치다.
> C는 영상에서 레이저 점을 검출하지 않으며 기존 `target_*` 인터페이스는 변경 없다.

---

## 0. 현재 구현 상태

| 파일 | 소유 | 상태 | 검증 |
|---|---|---|---|
| `rtl/control/servo_pwm.v` | C | **구현 완료** | `tb_servo_pwm` 6/6 PASS (xsim) |
| `rtl/control/board_io.v` | C | **구현 완료** (브링업 전용) | `tb_board_io` 19/19 PASS + PAN/TILT 실물 검증 |
| `rtl/event/event_adapter.v` | C | **구현 완료** (D2) | `tb_event_adapter` 23/23 PASS (xsim) |
| `rtl/event/event_accumulator.v` | C | **구현 완료** (D3) | `tb_event_accumulator` 15/15 PASS |
| `rtl/control/tracking_controller.v` | C | **구현 완료** (D4) | `tb_tracking_controller` 30/30 PASS |
| Adapter→Accumulator 연결 | C | **검증 완료** (D4) | `tb_event_pipeline` 15/15 PASS |
| `rtl/control/laser_head_controller.v` | C | **런타임 LASER_CAL 포함** (D6) | `tb_laser_head_controller` 27/27 PASS |
| `rtl/control/laser_interlock.v` | C | **LED 우선 구현 완료** (D5) | `tb_laser_interlock` 28/28 PASS |
| `rtl/control/dual_head_control.v` | C | **4-Servo + Manual/동적 Limit** (D6) | `tb_dual_head_control` 30/30 PASS |
| `rtl/control/c_event_control_top.v` | C | **A Phase 3 연동 래퍼 완료** (D6) | `tb_c_event_control_top` 25/25 PASS |

---

## 1. Event Input Format

SPEC §6.1을 그대로 따른다. **C가 변경하지 않는다.**

```verilog
event_valid
event_x[5:0]        // 0 ~ 63
event_y[5:0]        // 0 ~ 63
event_polarity      // Positive / Negative Channel 선택
event_window_end    // Window 종료 Pulse
```

### C가 D1에 확정한 구현 세부 (C 내부 범위)

| 항목 | 값 | 근거 |
|---|---|---|
| `event_window_end` 형태 | **1-cycle pulse** (Level 아님) | SPEC §6.1 "Pulse" |
| 같은 clock에 `event_valid`와 `event_window_end`가 동시 | 해당 이벤트를 **현재 Window에 포함** | C 내부 결정 |
| 좌표 범위 밖 이벤트 | Adapter에서 **폐기** (NPU로 전달 안 함) | C 내부 결정 |
| `event_polarity` 인코딩 | **0 = Positive(Ch0) / 1 = Negative(Ch1)** | CR C-004 — A 규격 채택 |

> **polarity 인코딩은 D2에 정정됐다.** SPEC §6.1이 어느 값이 어느 채널인지 정하지 않아
> A는 `0 = Positive`, C는 `1 = Positive`로 서로 반대로 가정하고 있었다.
> 그대로 두면 Positive/Negative 채널이 통째로 뒤바뀐 Tensor가 NPU에 들어가고,
> RTL도 Golden도 오류를 내지 않아 "정확도가 왜 낮지"로만 보인다.
> A 안(`0 = Positive`)을 채택했다 — 그래야 `ext_addr = (polarity<<12)｜…`가 문자 그대로 성립한다.
> `event_adapter.v`는 polarity를 해석하지 않고 통과만 시키므로 주석만 바뀌었다.

### Fallback

SPEC §34에 따라 Event Camera가 D2까지 해결되지 않으면
`1순위 저장된 Event Trace → 2순위 Webcam Frame Difference`로 전환한다.
**어느 경우에도 위 5개 신호는 유지**하므로 NPU 이하 구조는 영향 없다.

SPEC v1.2 §14.1이 입력원을 **640×480 Webcam Fallback으로 전제**하고 있으므로
사실상 Fallback 2순위가 발동한 상태다. 사용할 웹캠은 **앱코(APKO) APC850**
(USB `322e:2233`, Sonix)이며 D2에 실측했다 (§2). 명시적 확정은
`docs/CHANGE_REQUEST_C_002_event_window_and_input_source.md`로 올렸다.

---

## 1.1 `event_adapter.v` — D2 구현 완료

### 역할 (SPEC §7.2 C 책임 경계)

```text
원본 Event Source
→ Spatial Binning (SENSOR_W × SENSOR_H → 64 × 64)
→ 범위 밖 이벤트 처리
→ Event Window 경계 pulse 생성
→ SPEC §6.1 내부 표준 5신호
```

Tensor 누적은 하지 않는다. `event_accumulator.v` (D3) 담당이다.

### 인터페이스

| 신호 | 방향 | 폭 | 의미 |
|---|---|---|---|
| `clk` / `rst_n` | In | 1 | Active-Low 비동기 Reset |
| `src_valid` | In | 1 | 원본 이벤트 유효 |
| `src_x` / `src_y` | In | `SRC_COORD_W` | **원본 센서 좌표** (64×64 아님) |
| `src_pol` | In | 1 | 1 = Positive, 0 = Negative |
| `src_window_end` | In | 1 | `WINDOW_SRC=1`일 때만. Level 입력 허용 (상승엣지 검출) |
| `event_valid` | Out | 1 | SPEC §6.1 |
| `event_x` / `event_y` | Out | 6 | SPEC §6.1 — 0~63 |
| `event_polarity` | Out | 1 | SPEC §6.1 |
| `event_window_end` | Out | 1 | SPEC §6.1 — **1-cycle pulse** |
| `win_evt_count` | Out | `EVT_CNT_W` | 진단. 직전 Window의 채택 이벤트 수 |
| `win_drop_count` | Out | `EVT_CNT_W` | 진단. 직전 Window의 폐기 이벤트 수 |

`win_*_count`는 **SPEC §6.1 밖의 진단 신호**다. 하위 모듈은 무시해도 된다.
Event Rate 실측(§2)과 D5 Window 검증에 쓰려고 뺐다.

### Binning — SPEC v1.2 §14.1 확정식을 나눗셈 없이 구현

SPEC §14.1이 Freeze한 식은 다음과 같다.

```text
x64 = min(63, floor(x_raw * 64 / frame_width))
y64 = min(63, floor(y_raw * 64 / frame_height))
Crop 없음 / Padding 없음 / 좌우 반전 없음
```

`frame_width`가 640, 346처럼 2의 거듭제곱이 아니라 시프트로 안 되므로 역수 곱셈을 쓴다.

```text
MUL_X = ceil(64 * 2^BIN_SHIFT / SENSOR_W)
bx    = min(63, (x * MUL_X) >> BIN_SHIFT)
```

정수 나눗셈과 **항상** 같으려면 다음이 성립해야 한다. 모듈이 elaboration 시점에 검사한다.

```text
ERR_X = MUL_X * SENSOR_W - 64 * 2^BIN_SHIFT
(SENSOR_W - 1) * ERR_X < 2^BIN_SHIFT
```

`BIN_SHIFT = 22`(기본값)는 센서 폭 2048까지 이 조건을 만족한다.

> **조건식만 믿지 않는다.** 조건식 자체가 틀렸을 가능성은 조건식으로 잡을 수 없다.
> `tb_event_adapter`가 64 / 346 / 640 / 1280 네 해상도의 **전 좌표를 실제로 훑어**
> 정수 나눗셈 결과와 대조한다 (T1/T2). `tools/gen_event_vector.py`의 참조 모델과
> 같은 값이므로 D3 Golden 비교에서 어긋나지 않는다.

`SENSOR_W`가 2의 거듭제곱이면 `MUL_X`도 2의 거듭제곱이 되어 합성기가 곱셈기를
통째로 없앤다. 640×480 같은 경우에만 DSP 2개를 쓴다.

### 범위 밖 이벤트 — `OOR_POLICY`

| 값 | 동작 | 근거 |
|---|---|---|
| `0` **(기본)** | 폐기 | HANDOFF §1 C 내부 결정 (D1) |
| `1` | 63으로 물림 | SPEC §14.1 `min(63, ·)`를 문자 그대로 적용 |

정상 입력(`x_raw < frame_width`)에서는 **두 정책의 결과가 같다.**
차이는 입력이 규격을 벗어났을 때뿐이며, 그때 물림을 쓰면 가짜 카운트가
Tensor 가장자리 열(63)에 쌓여 Argmax를 끌어당긴다. 그래서 폐기를 기본값으로 둔다.
팀이 물림을 원하면 parameter 하나만 바꾸면 되므로 별도 CR로 올리지 않았다
(CR C-002 부수 항목에 질의로만 남겼다).

### 파이프라인 2단 — Window 경계를 같은 깊이로 지연시킨다

```text
stage0 : 입력 등록 + 범위 판정 + Window pulse 등록
stage1 : 곱셈 결과 시프트 → 출력 등록
```

`window_end`만 지연 없이 내보내면 그 Window의 마지막 이벤트들이 `window_end` 뒤에
도착해 **다음 Window로 새는 버그**가 된다. 두 신호가 같은 깊이를 지나므로 순서가 보존된다.

이 구조가 HANDOFF §1의 "같은 clock이면 현재 Window에 포함" 규칙을 그대로 만족한다.
계수기도 그 이벤트를 센 뒤 비운다. `tb_event_adapter` T9가 이것을 확인한다.

Backpressure는 없다. SPEC §6.1 내부 표준에 `ready`가 없으므로 **1 event/clock을 항상 받는다**
(T7에서 연속 입력으로 확인). 하위 `event_accumulator.v`도 이 처리율을 맞춰야 한다 (D3 과제).

### 검증 결과 (xsim, `tb/event/tb_event_adapter.v`)

`CLK_HZ = 1 MHz`로 축소하여 1 cycle = 1 us로 측정.

| # | 항목 | 결과 |
|---|---|---|
| T1 | Binning X — 64 / 346 / 640 / 1280 해상도 x 전 좌표(0~1279) | PASS |
| T2 | Binning Y — 64 / 260 / 480 / 720 해상도 y 전 좌표(0~719) | PASS |
| T3 | 범위 밖 `OOR_POLICY` 0 폐기 / 1 물림, 범위 안은 동일 | PASS |
| T4 | 파이프라인 지연 = 2 cycle | PASS |
| T5 | Polarity 통과 | PASS |
| T6 | 내부 Window 주기 = `WINDOW_US` | PASS |
| T7 | Window당 계수 (연속 1 event/clock, 채택 50 / 폐기 7) | PASS |
| T8 | 외부 Window — Level 입력의 상승엣지만 1회 | PASS |
| T9 | 이벤트와 Window 경계 동시 → 현재 Window에 포함 | PASS |

**23/23 PASS, errors=0**

Binning 상수는 `tools/probe_webcam.py`와 무관한 별도 경로로도 재확인했다 —
Python으로 64 / 128 / 240 / 260 / 346 / 480 / 640 / 720 / 1024 / 1280 / 1920 / 2048
전 좌표를 정수 나눗셈과 대조해 불일치 0.

### Parameter 현황

| Parameter | 기본값 | 상태 |
|---|---:|---|
| `SENSOR_W` / `SENSOR_H` | 640 / 480 | SPEC v1.2 §14.1이 전제한 값. 카메라 변경 시 이것만 교체 |
| `SRC_COORD_W` | 11 | C 내부 |
| `OOR_POLICY` | 0 (폐기) | C 내부 결정 |
| `CLK_HZ` | 100,000,000 | **C 측 확정·반영** (CR C-003). A Block Design 공급 확인만 남음 |
| `WINDOW_US` | 10,000 | **[TBD]** CR C-002 승인 대기. 확정 시 33,333 |
| `WINDOW_SRC` | 0 (내부 타이머) | **[TBD]** CR C-002 승인 시 1 (프레임 경계) |
| `BIN_SHIFT` | 22 | C 내부. 센서 폭 2048까지 유효 |
| `EVT_CNT_W` | 20 | C 내부. 포화 계수, Wrap 금지 |

---

## 1.2 `event_accumulator.v` — D3 구현 완료

### 역할

```text
SPEC §6.1 Event Stream
→ 64×64×2 Tensor 누적 (0~127 포화)
→ Window 종료 시 8192 byte 를 npu_core 로 전송
→ 전송하면서 그 버퍼를 0 으로 초기화
```

### 인터페이스 — A 규격(`C_TO_A_DELIVERY_SPEC` §2-5) 대응표

A가 제안한 포트명과 다른 것은 `rstn` 하나뿐이다. C의 다른 모듈(`servo_pwm`,
`event_adapter`, `board_io`)이 전부 `rst_n`을 쓰므로 일관성을 택했다.
A의 문서가 "이름이 다르면 대응표를 적어 달라"고 했으므로 아래에 적는다.

| A 규격 | C 구현 | 폭 | 비고 |
|---|---|---|---|
| `rstn` | **`rst_n`** | 1 | 이름만 다름. Active-Low 동일 |
| `clk` | `clk` | 1 | |
| `event_valid/x/y/polarity/window_end` | 동일 | SPEC §6.1 | 변경 없음 |
| `npu_busy` | `npu_busy` | 1 | `npu_core.busy` |
| `tensor_we` | `tensor_we` | 1 | → `ext_we` |
| `tensor_addr` | `tensor_addr` | 13 | → `ext_addr` |
| `tensor_data` | `tensor_data` | signed 8 | → `ext_data` |
| `tensor_start` | `tensor_start` | 1 | → `start` |
| — | `acc_ready` | 1 | **추가.** 0이면 INIT 중이라 이벤트를 안 받는다 |
| — | `overrun` | 1 | **추가.** 진단. 무시해도 된다 |

추가된 두 신호는 진단용이며 A가 연결하지 않아도 동작에 지장이 없다.

### 설계상 까다로웠던 세 지점

**(1) RMW 포워딩** — 카운트 +1은 읽고·더하고·쓰기다. BRAM 읽기가 1 cycle
지연되므로 **같은 좌표 이벤트가 연속으로 오면 두 번째가 갱신 전 값을 읽는다.**
그대로 두면 2개가 들어와도 카운트가 1만 오르고 Golden과 어긋난다. 실제
이벤트 스트림에서 같은 픽셀이 연달아 튀는 것은 흔하다.
한 단계 뒤에 쓴 주소/값을 들고 있다가 일치하면 그것을 쓴다. 두 단계 뒤부터는
BRAM에 반영되어 있어 한 단계면 충분하다.

**(2) Ping-Pong** — `npu_busy` 동안 쓰기가 금지되고 전송에 8192 cycle이 걸린다.
그 사이 이벤트를 잃지 않으려면 버퍼 2개가 필요하다 (8 KB × 2 = BRAM 4개).
다만 `window_end` 시점에 RMW 파이프라인에 남아 있는 이벤트는 **이전 Window
소속**이다. 버퍼 선택을 즉시 바꾸면 그것들이 새 버퍼로 샌다. 그래서 선택
비트를 이벤트와 함께 파이프라인에 실어 보내고, 전송은 배수 후에 시작한다.

**(3) 전송 중 0 초기화** — 따로 지우면 8192 cycle을 더 쓰므로 전송하면서
같이 지운다. 단 읽기 주소와 0 쓰기 주소를 **한 박자 어긋내** 서로 다른 포트가
같은 주소를 동시에 치는 상황을 아예 만들지 않는다 (그 경우 하드웨어 동작이
보장되지 않는다).

전원 인가 직후 BRAM은 미정의이므로 `S_INIT`에서 두 버퍼를 0으로 채운 뒤
첫 Window를 받는다. `acc_ready`가 그 완료 신호다.

### 검증 결과 (xsim, `tb/event/tb_event_accumulator.v`) — **15/15 PASS**

TB 안에 참조 Tensor를 두고 같은 규칙으로 갱신한 뒤, DUT가 전송한
**8192 byte를 전량 대조**한다. 셀 하나만 달라도 Golden 비교가 깨지므로
표본 검사로는 부족하다.

| # | 항목 | 결과 |
|---|---|---|
| T1 | INIT 완료 후 `acc_ready` | PASS |
| T7 | Window1 전량 대조 + 주소 순서 0→8191 | PASS |
| T8 | `tensor_start` 1 cycle pulse | PASS |
| T9 | `npu_busy` 중 `tensor_we` 금지 | PASS |
| T10/T11 | Ping-Pong + 버퍼 초기화 (전송 중 300개 투입) | PASS |
| T12 | 무작위 2000 이벤트 전량 대조 (비영점 1773 셀) | PASS |

**돌연변이 시험으로 TB의 유효성을 확인했다.** 다음 세 가지를 일부러 망가뜨렸을 때
TB가 전부 잡아냈다 — 통과가 우연이 아님을 보이기 위한 것이다.

| 망가뜨린 것 | TB 결과 |
|---|---|
| RMW 포워딩 제거 | FAIL (errors=2) |
| Ping-Pong 제거 | FAIL (errors=1) |
| 127 포화 제거 | FAIL (errors=1) |

### Known Limitation

`overrun`은 직전 전송이 끝나기 전에 다음 `window_end`가 온 경우에 서는 sticky
플래그다. 그때 그 Window는 버려진다. 설계 여유가 **33.3 ms 대 1.34 ms로 25배**라
정상 동작에서는 서지 않아야 한다. 서면 그것 자체가 설계 전제가 깨졌다는 신호다.

---

## 2. Tensor Output Format / Window Setting

### 확정 (SPEC §7.1)

```text
Shape     = 64 × 64 × 2
Channel 0 = Positive Event Count
Channel 1 = Negative Event Count
```

### 확정 — SPEC v1.1

| 항목 | 값 | 근거 |
|---|---|---|
| Event Count 포화 상한 | **127** (Wrap 금지, 포화) | SPEC §9.1 `Conv1 Input Event Count = 0 ~ 127` |

`event_accumulator.v`는 셀당 카운트가 127에 도달하면 증가를 멈춘다.
`tools/gen_event_vector.py`의 참조 모델도 같은 규칙이다 (`--saturate` 기본값 127).

### TBD — C가 단독으로 정하지 않는다

| 항목 | 상태 | 결정 주체 | 기한 |
|---|---|---|---|
| ~~Tensor Memory Order~~ | **확정 — CHW** `(pol<<12)｜(y<<6)｜x` | A (D3 Freeze A-001 1번) | 완료 |
| ~~Physical Transfer 방식~~ | **확정 — Direct Handshake** | A+C (D3 Freeze A-001 5번) | 완료 |
| ~~NPU Input Buffer Interface~~ | **확정 — `ext_we`/`ext_addr[12:0]`/`ext_data`/`start`/`busy`/`done`** | A (동상) | 완료 |
| ~~C 모듈 구동 클럭~~ | **C 측 100 MHz 확정·코드 반영** — A Block Design 공급 확인만 남음 | A/C | 통합 시 확인 |
| `event_polarity` 인코딩 | **CR C-004 회신 대기** — 0=Positive 로 C 측 반영 완료 | A+B | D3 |
| Event Window 값 | **CR C-002 승인 대기** | 팀 확정 | D3 |
| ~~원본 해상도 → 64×64 Binning 규칙~~ | **확정 — SPEC v1.2 §14.1** | ~~C~~ → A/B/C 공통 | ~~D2~~ 완료 |

> **물리 전달 방식은 해결됐다.** A의 D3 Freeze A-001과 C 회신 #001에 따라
> Direct Handshake를 채택했고 `event_accumulator.v`의 `tensor_*` 출력으로 구현했다.

### Window 길이 — **5 ms / 10 ms 후보는 둘 다 물리적으로 불가능하다** (D2 실측)

SPEC v1.2 §14.1이 입력원을 640×480 웹캠으로 전제한다.
사용할 웹캠 **앱코(APKO) APC850** (USB `322e:2233`, Sonix)을 실측한 결과:

```bash
python3 tools/probe_webcam.py
```

| 포맷 | 해상도 | 최대 fps | 프레임 간격 |
|---|---:|---:|---:|
| MJPG | 1280×720 이하 전 해상도 | 30 | 33.33 ms |
| YUYV | **640×480** | **30** | **33.33 ms** |
| YUYV | 800×600 | 20 | 50.00 ms |
| YUYV | 1280×720 | 10 | 100.00 ms |

프레임 차분은 두 프레임 **사이의 변화**만 만들 수 있으므로
프레임 간격보다 짧은 Event Window는 존재할 수 없다.
**60 fps 모드는 어떤 해상도에도 없다.**

APC850은 FHD로 판매되지만 **1920×1080 모드가 장치에 없다.** 실측 최대는 1280×720이다.
30 fps 선택지는 `MJPG 1280×720`과 `YUYV 640×480` 둘인데 **MJPG는 쓰지 않는다.**
JPEG은 손실 압축이라 정지 장면에서도 블록마다 프레임별 양자화 오차가 남고,
프레임 차분이 그것을 **8×8 블록 격자 모양의 가짜 이벤트로 만들어내** Argmax를 해친다.
YUYV는 첫 바이트가 곧 luma라 디코드 없이 차분이 된다.
어느 쪽을 골라도 30 fps라 Window 결론은 바뀌지 않는다.

따라서 `Event Window = 33,333 us`가 강제된다.
SPEC §21 D3 Freeze 항목이라 C가 단독으로 못 정하므로
`docs/CHANGE_REQUEST_C_002_event_window_and_input_source.md`로 올렸다.
**B의 Dataset 재생성이 필요하므로 B 영향이 가장 크다.**

> 아래는 `tools/gen_event_vector.py`가 만든 **합성** 스트림 수치다.
> 실제 카메라 Event Rate가 아니므로 **결정 근거가 아니고** 스케일 감각용이다 (SPEC §0-12).
>
> | 조건 | 합성 Event Rate | Window당 이벤트 | Tensor 비영점 비율 |
> |---|---:|---:|---:|
> | 64×64, 10 ms Window | 15.9 /ms | 약 159 | 1.9 % |
> | 346×260, 5 ms Window | 311.4 /ms | 약 1,557 | 1.0 % |
>
> 실제 Event Rate는 `event_adapter.v`의 `win_evt_count`로 실측한다.

---

## 3. Servo PWM Requirement — **제안, D3 확정 대상**

> SPEC §21은 `Servo Command Format`을 D3 Freeze 항목으로 지정했고, 현재 값이 정해져 있지 않다.
> 아래는 **C의 제안이며 팀 승인 전까지 확정이 아니다.**
> 승인 절차는 `docs/CHANGE_REQUEST_C_001_servo_command_format.md` 참조.

### 3.1 좌표계 (SPEC §15 — 확정, 변경 금지)

```text
Center X = 32
Center Y = 32

error_x = target_x - 32       // -32 ~ +31
error_y = target_y - 32       // -32 ~ +31
```

`target_x`, `target_y`는 **64×64 입력 좌표계 기준**이다 (SPEC §14).
8×8 Heatmap Index → 64×64 변환은 **A의 Argmax Decoder와 B의 Golden Model이 담당**한다.
C는 변환된 좌표만 받는다.

**SPEC v1.2 §14.1에서 이 변환이 Freeze됐다** (D1 시점에는 TBD였다).

```text
target_x = heatmap_x * 8 + 4
target_y = heatmap_y * 8 + 4
```

따라서 C가 받는 값은 연속값이 아니라 **8칸 격자의 8개 값뿐**이다.
이것이 §4 `DEAD_ZONE`의 하한을 강제한다.

### 3.2 Servo Position 표현 (제안)

| 항목 | 제안값 | 근거 |
|---|---|---|
| `pos` 폭 | `8 bit` unsigned (0~255) | 180° / 256 ≈ 0.7°. 서보 실사용 해상도로 충분 |
| `pos = 0` | `PULSE_MIN_US` = 1000 us (최소각) | |
| `pos = 128` | `PULSE_MIN_US + SPAN/2` = 1500 us (중립) | |
| `pos = 255` | `PULSE_MAX_US - SPAN/256` = 1996.09 us | 최대각 − 1 LSB. 아래 참고 |

> **`pos = 255`가 `PULSE_MAX_US`에 정확히 닿지 않는다.**
> 스케일링이 `>>8`이라 255가 아니라 256으로 나누기 때문이다.
> 1000~2000 us 기준 **1996.09 us**로 3.91 us 모자란다.
>
> 의도된 선택이다. 1 step = `SPAN/256` = 3.91 us는 하비 서보 dead band
> (MG996R 약 5 us)보다 작아 **물리적으로 구분되지 않는** 반면, 나눗셈 없이
> 시프트 하나로 끝나 DSP를 쓰지 않는다.
> 정확히 `PULSE_MAX_US`가 필요하면 `SPAN/255`로 바꿔야 하고 나눗셈이 붙는다.

### 3.3 PWM 타이밍

| 파라미터 | 값 | 상태 |
|---|---:|---|
| `CLK_HZ` | **100,000,000** | **CR C-003 확정** — A의 `npu_core`와 단일 clock domain |
| PWM 주파수 | 50 Hz (20 ms) | 제안 |
| `PULSE_MIN_US` | **500** | **D2 실물 확정** — 아래 참조 |
| `PULSE_MAX_US` | **2500** | **D2 실물 확정** |

> **PWM 스케일 1000~2000 → 500~2500으로 확장 (D2, 2026-08-21).**
> D1에는 기구 가동 범위를 몰라 좁게 제안했으나, D2에 실물 2축을 구동했다.
> 실제 브링업은 `board_io.v`의 안전 clamp `pos=32~224`, 즉 750~2250 us에서
> 기구 간섭 없이 약 90°를 확인했다. `servo_pwm.v`의 전체 변환 스케일은
> 500~2500 us이며 출력 clamp가 실제 허용 범위를 제한한다.
> `docs/CHANGE_REQUEST_C_001_servo_command_format.md`에 정정 이력으로 기록했다.

```text
SPAN_CYC     = PULSE_MAX_CYC - PULSE_MIN_CYC
pulse_cycles = PULSE_MIN_CYC + ((pos * SPAN_CYC) >> 8)
```

> 브링업에서는 항상 `POS_MIN/POS_MAX` clamp를 먼저 적용하고, 실측 없이
> 500~2500 us 끝점까지 개방하지 않는다.

> **`CLK_HZ` 근거** — Digilent 공식 마스터 XDC
> [`constraints/digilent-xdc-master/Zybo-Z7-Master.xdc:9`](../constraints/digilent-xdc-master/Zybo-Z7-Master.xdc#L9)가
> K17 핀 `sysclk`을 `-period 8.00`, 즉 **125 MHz**로 선언한다.
>
> 다만 이것은 **보드 sysclk 값이지 C 모듈의 구동 클럭이 아니다.**
> Zynq 설계에서는 PS의 FCLK를 PL에 공급하는 경우가 흔하고, 그 값은 A의
> Block Design 설정에 달렸다. **A가 확정해야 할 것은 "C 모듈에 어떤 클럭을
> 넣을 것인가"다.** 어느 쪽이든 `servo_pwm.v`는 parameter만 교체하면 되고
> 로직은 그대로다.

### 3.4 `servo_pwm.v` 인터페이스 (구현 완료)

| 신호 | 방향 | 폭 | 의미 |
|---|---|---|---|
| `clk` | In | 1 | 시스템 클럭 |
| `rst_n` | In | 1 | Active-Low 비동기 Reset |
| `en` | In | 1 | 0이면 펄스 정지 (서보 무부하) |
| `pos` | In | 8 | 목표 위치 |
| `pwm_out` | Out | 1 | 서보 PWM |
| `frame_tick` | Out | 1 | Frame 시작 1-cycle pulse. 상위 Slew Limit용 |

Parameter: `CLK_HZ` / `PWM_HZ` / `PULSE_MIN_US` / `PULSE_MAX_US` / `POS_MIN` / `POS_MAX`

### 3.5 검증 결과 (xsim, `tb/control/tb_servo_pwm.v`)

`CLK_HZ = 1 MHz`로 축소하여 1 cycle = 1 us로 측정. `POS_MIN=32`, `POS_MAX=224`로 Clamp 검증.

| 항목 | 측정 | 기대 | 결과 |
|---|---:|---:|---|
| Frame 주기 | 20000 us | 20000 | PASS |
| `pos=128` 중립 | 1500 us | 1500 | PASS |
| `pos=0` → 하한 Clamp | 1125 us | 1125 | PASS |
| `pos=255` → 상한 Clamp | 1875 us | 1875 | PASS |
| `pos=192` 범위내 | 1750 us | 1750 | PASS |
| `en=0` | 0 us | 0 | PASS |

**6/6 PASS, errors=0**

---

## 4. Tracking Controller / Dead Zone / 제어 파라미터

SPEC §15에 따라 **P Control + Dead Zone**으로 시작한다.
Full PID / Kalman / Velocity Predictor / Trajectory Planner는 기본 시스템 완성 전 추가하지 않는다.

```text
DEAD_ZONE      = 4      // 하한 확정 (SPEC v1.2 §15). |error| <= DEAD_ZONE -> Servo Hold
P_GAIN         = 1      // D4 시작값. 실제 Closed-loop에서 튜닝
P_GAIN_SHIFT   = 2      // prop_step = (|error| * P_GAIN) >> P_GAIN_SHIFT
SLEW_LIMIT     = 1      // D4 부드러운 구동 시작값. Servo Frame당 최대 pos 변화량
```

위 값은 C 내부의 안전한 시작값이며 공유 Interface를 바꾸지 않는다.
최종 `P_GAIN` / `SLEW_LIMIT`은 실제 Closed-loop를 보고 D5~D10에 튜닝한다.

### `DEAD_ZONE`은 더 이상 자유값이 아니다 — SPEC v1.2 §15

SPEC v1.2가 §14.1에서 Mapping을 Freeze하면서 `target_x/y`가 **Cell 중심값만** 나오게 됐다.

```text
target_x, target_y ∈ { 4, 12, 20, 28, 36, 44, 52, 60 }
```

Center가 `(32, 32)`이므로 **정확한 0 오차는 NPU 출력으로 나타날 수 없다.**
중앙에 가장 가까운 값이 `28` 또는 `36`이라 최소 오차가 `±4`다.

```text
error_x = target_x - 32  ∈  { -28, -20, -12, -4, +4, +12, +20, +28 }
```

따라서 SPEC v1.2 §15는 다음을 **최소 Center/Lock 허용 범위**로 규정한다.

```text
abs(error_x) <= 4
abs(error_y) <= 4
```

**비교가 `<`가 아니라 `<=`인 점이 중요하다.** D1 시점 본 문서는 `|error| < DEAD_ZONE`으로
적혀 있었는데, 그대로 두고 `DEAD_ZONE = 4`를 넣으면 `error = 4`가 Hold에 들지 않아
표적이 중앙에 있는데도 서보가 매 Window마다 좌우로 움직인다. 양자화 오차가
그대로 진동이 된다. **`<=`로 정정했다.**

| 방향 | 허용 여부 | 근거 |
|---|---|---|
| `DEAD_ZONE`을 4보다 **크게** | C 단독 가능 | SPEC §15 "더 큰 Dead Zone이 필요하면 C가 확대할 수 있다" |
| `DEAD_ZONE`을 4보다 **작게** | **불가** | SPEC §15 — A/B/C가 좌표 Mapping/제어 정책 영향을 재검토해야 한다 |

시작값은 `4`로 두고, 실제 서보에서 헌팅이 보이면 C가 키운다.

### D2 실측 — 각도 스케일

D1에는 가동범위를 `120°`로 **가정**했는데, D2 실물 측정이 그 값을 뒷받침했다.

| 측정 | 방법 | 결과 |
|---|---|---|
| 좁은 범위 (`sw[2]=0`, pos 112~144 = 32 step) | 실물 구동 | **약 15°** |
| 넓은 범위 (`sw[2]=1`, pos 32~224 = 192 step) | 실물 구동 | 약 90° (사진 관찰) |

두 측정이 같은 스케일을 가리킨다.

```text
15° / 32 step        = 0.469 °/step
0.469 × 256 step     = 120°        <- 펄스 500~2500 us 전 구간
0.469 / 7.8125 us    = 0.06 °/us
```

> **주의 — D1 문서와 기준선이 다르다.** D1은 `1 step = 3.91 us`(펄스 1000~2000)에
> 가동범위 120°를 가정해 `0.469 °/step`을 얻었다. D2 실측은 `1 step = 7.8125 us`
> (펄스 500~2500)에서 같은 `0.469 °/step`이 나왔다.
> **즉 실제 서보는 1000~2000 us 구간에서 60°밖에 못 돈다.**
> `°/step` 숫자가 우연히 같을 뿐 전제가 다르므로, 각도를 환산할 때는
> 반드시 500~2500 us 기준임을 확인한다.
>
> 넓은 범위 90°는 각도기 실측이 아니라 사진 관찰이다. 정밀값이 필요해지면 다시 잰다
> (SPEC §0-12). 다만 `POS_MIN/MAX`는 여유를 두고 잡는 안전값이라 이 정밀도로 충분하다.

### `SLEW_LIMIT` 상한 — 위 스케일 기준

MG996R 동작 속도는 `0.14 s/60°` @ 6V, `0.17 s/60°` @ 4.8V다 (데이터시트).
Servo Frame 20 ms 동안 물리적으로 갈 수 있는 거리는:

| 전압 | Frame당 각도 | Frame당 `pos` step |
|---|---:|---:|
| 6.0 V | 8.57° | **약 18 step** |
| 4.8 V | 7.06° | **약 15 step** |

`0.469 °/step` 실측값 기준이다. D1의 숫자와 같지만 이제는 가정이 아니라 측정에 근거한다.

> **`SLEW_LIMIT`을 18보다 크게 잡는 것은 의미가 없다.** 서보가 따라오지 못하므로
> 명령만 앞서 나가고 실제 위치는 뒤처진다. 그 상태로 P Control이 계속 오차를 보면
> 적분 없는 P 제어인데도 오버슈트처럼 보이는 거동이 나온다.
> 무부하 기준이므로 카메라+레이저를 달면 더 낮아진다. D4에서는 사용자가 관찰한
> 단계적 움직임을 줄이기 위해 **1 step/Frame**으로 더 보수적으로 시작한다.
> 실측 `0.469°/step` 기준 약 23.45°/s이며, 부족하면 2~4로 올린다.
>
> 가동범위 120°는 MG996R 공표값이며 **실측으로 확정해야 한다**.

### Window와 Servo Frame의 주기가 다르다

```text
Event Window  = 10 ms 기본값 / 33.3 ms C 제안 (CR C-002 승인 대기)
Servo Frame   = 20 ms       (50 Hz 고정)
```

어느 Window 값이 확정되더라도 NPU의 `target_valid/x/y`는 done 이후 다음 start까지
유지되는 Level이다. Tracking이 이를 매 clock 누적하면 즉시 Limit에 닿으므로
Servo Frame에서만 현재 Target을 한 번 적용해야 한다.

**대응** — Tracking Controller의 출력 갱신을 `servo_pwm`의 `frame_tick`에 맞춘다.
`frame_tick`을 출력으로 뺀 이유가 이것이다. 그러면 `SLEW_LIMIT`의 단위가
Servo Frame으로 고정되어 위 표가 그대로 적용된다.

### D4 `tracking_controller.v` 구현 결과

```text
target_valid/x/y
    -> error = target - 32
    -> abs(error) <= 4 이면 Hold
    -> P Gain
    -> Frame당 Slew Limit
    -> PAN/TILT Soft Limit 32~224
    -> pan_pos / tilt_pos
```

- `target_valid=0`: 진행 중이던 이동을 계속하지 않고 현재 출력 위치 Hold
- `target_valid=1`: `frame_tick`마다 한 번만 P 제어량 적용
- 기본 방향: 화면 X/Y 증가 → Servo pos 증가
- 기구 방향이 반대면 `PAN_INVERT` / `TILT_INVERT` parameter 사용
- `target_score`는 Tracking이 재판정하지 않는다. A의 `target_valid`가 권위이며
  Score는 D5 Laser Interlock이 signed INT8로 사용한다
- Tracking의 32~224 Soft Limit과 `servo_pwm` 출력 Clamp를 겹쳐 2중 보호한다

`tb_tracking_controller`는 Reset/No-Tick/Target Lost/±4 Dead Zone/PAN·TILT 방향/
동시 이동/P Gain/Slew Clamp/축 반전/Soft Limit을 검증해 **30/30 PASS**했다.

### D4 Adapter→Accumulator 통합 TB

`tb_event_pipeline`은 Raw 640×480 Event를 실제 두 RTL에 연결하고 두 Window의
Tensor를 각각 8192 byte 전수 비교했다. OOR 7개 폐기, 같은 좌표 127 포화,
Window 경계 Event 포함, `npu_busy` 게이팅, 전송 중 다음 Window 320개 보존을
포함해 **15/15 PASS**했다.

---

## 5. Safe Limit — D2 실측 반영

```text
PAN_POS_MIN  = 32       PAN_POS_MAX  = 224
TILT_POS_MIN = 32       TILT_POS_MAX = 224
```

Clamp 위치는 `servo_pwm.v` **출력단**이다. 상위 모듈이 잘못된 값을 줘도 기구가 한계를 넘지 않는 최후 방어선으로 둔다.

### 근거 (D2, 2026-08-21)

D2에 팬틸트 브래킷을 조립한 상태로 2축을 실제 구동했다.

- 넓은 범위 `pos 32~224` 전 구간에서 **기구 간섭이 없었다.** 어느 쪽 끝에서도
  걸리거나 스톨하지 않았다
- 카메라(앱코 APC850)를 얹어도 **하중이 가동 범위를 제한하지 않는다** — 담당 C 확인
- 즉 **기구가 아니라 서보 자체의 가동 범위가 한계**다. 좁힐 이유가 없다

`32 / 224`는 `0 / 255`에서 양 끝에 여유를 남긴 값이다. `pos 0`이나 `255`는
서보 내부의 기계적 스톱을 넘겨 스톨시킬 수 있어 열지 않는다.

### 두 축이 같은 값이다 — 지금은 문제 없다

현재 `board_io.v`는 두 축에 **같은** `POS_MIN/MAX`를 넘긴다. 실측 결과 축별 차이가
없었으므로 이대로 둔다. 나중에 레이저까지 얹어 TILT 아래쪽이 제한되면
그때 축별 파라미터로 분리한다. 파라미터 추가만으로 끝나는 변경이다.

---

## 6. Target Lost Policy — C 결정 (SPEC §16)

SPEC §16이 **"Servo의 정확한 Hold/Neutral 정책은 C가 정한다"**고 명시했다. C의 제안:

| `target_valid` | Servo 동작 | Laser |
|---|---|---|
| `1` | 정상 Tracking | 조건 만족 시 ON |
| `0` (1회) | **현재 위치 Hold** — 새 이동 명령 생성 안 함 | **OFF** |
| `0` 이 `TARGET_LOST_N` Window 연속 | **Hold 유지** (Neutral 복귀 안 함) | **OFF** |

```text
TARGET_LOST_N = TBD     // 실제 Tracking 안정성 확인 후. 담당 C / D9~D10
```

> **Neutral 복귀를 택하지 않은 이유** — 표적이 잠깐 가려졌다 다시 나타나는 경우가 흔한데,
> 그때마다 중립으로 돌아가면 재포착이 느려지고 시연에서 서보가 크게 흔들린다.
> Hold가 재포착과 안전 양쪽에서 낫다.
> 팀 이견이 있으면 Change Request로 처리한다.

---

## 7. Laser Interlock (SPEC §17 — 확정, 변경 금지)

아래 **전부 AND**이고 새 Target Lock이 3회 연속 확인될 때만 `laser_enable = 1`:

```text
target_valid == 1
target_score >= threshold
Target inside Safe Zone
PT#1/PT#2 Servo inside Safe Limit
Target inside Lock Zone
PT#2 aim_ready == 1
Target update watchdog 정상
Servo Enable + Laser Arm == 1
Emergency Stop == 0
```

하나라도 불만족 → `laser_enable = 0`

| 파라미터 | 상태 | 결정 |
|---|---|---|
| `SCORE_THRESHOLD` | 기본값 `0`, 최종값 TBD | B의 Heatmap 분포 확인 후 |
| `LOCK_ZONE_X/Y` | 기본값 `4` | 최소 ±4, 실제 추적 안정성으로 최종 조정 |
| `LASER_OFFSET_X/Y` | `TBD` | C 고정 거리 실측 / D11 |
| `LOCK_CONFIRM_UPDATES` | `3` | 새 Target 3회 연속 확인 |
| `TARGET_TIMEOUT_FRAMES` | `3` | 새 결과가 없으면 Fail-Closed |
| `MAX_ON_FRAMES` | `25` | 50 Hz 기준 약 500 ms 후 OFF/Fault |
| `target_score` 폭 | **확정 — signed INT8** | SPEC v1.1 §14 / §21 `[x]` (v1.2 유지) |

`target_score`가 signed INT8(`-128 ~ 127`)이므로 `SCORE_TH` 비교는
**signed 비교**로 구현한다. unsigned로 비교하면 음수 Score가 큰 값으로 뒤집혀
Interlock이 잘못 열린다. SPEC §9.1이 Conv4 Heatmap을 ReLU 없는 signed INT8로
규정했으므로 음수 Score는 실제로 발생한다.

### 안전 원칙

- 개발 초기에는 실제 Laser 대신 **LED로 검증**
- **사람 또는 동물을 Demo Target으로 사용하지 않는다**
- 관객 방향 조준 금지, Target Board 영역만 사용
- Pan/Tilt 하드·소프트 리밋 적용
- 보드 버튼에 **Emergency OFF**
- 카메라 PT#1과 레이저 PT#2를 분리하고 두 Head 모두 Safe Limit 적용
- 실제 광원은 Camera/NPU 연동과 FOV/Offset 보정 전까지 연결 금지

---

## 8. Known Limitation

1. **`CLK_HZ = 100 MHz`로 확정했다 (CR C-003).** A의 `npu_core`와 같은
   clock domain에 둔다. `event_accumulator.v`가 `ext_*`로 직결되므로 CDC가
   없어야 하고, 타이밍 압박을 받는 블록은 NPU뿐인데 A가 이미 100 MHz로 닫았다.
   전송+추론 1.34 ms 대 Event Window 33.3 ms라 속도를 올릴 이유도 없다.

   **A가 Block Design에서 이 클럭을 공급하는지 확인이 필요하다.**
   PS `FCLK_CLK0` 기본값이 100 MHz이므로 그대로 쓰면 된다.
   만약 A가 다른 값을 준다면 parameter만 바꾸면 되고 로직 변경은 없다.

   `board_io.v`는 **125 MHz를 유지한다.** 브링업 전용 top이고 PL sysclk K17을
   직결하며 `top_system`에 들어가지 않는다. 오늘 확인한 `led[0]` 1초 심장박동이
   그 근거다. 여기를 100 MHz로 "고치면" 오히려 깨진다.
2. **Camera PT#1 + Laser PT#2 4축 Servo와 JD7 RED 실물 구동은 완료했다.**
   Switch/Button 가상 Target 기준이며, A의 실제 Target 출력과 연결한 영상 기반
   Closed-loop는 아직 검증하지 않았다.
3. **`event_accumulator.v`는 구현·단위 검증 완료했다.** Ping-Pong 버퍼와
   Direct Handshake 전송을 포함하며 `tb_event_accumulator` 15/15 PASS,
   Window별 8192 byte 전수 비교를 통과했다. A `npu_core` 및 B Golden과의
   통합 비교는 A/B 산출물 합류 후 수행한다.
4. **`event_adapter.v`는 실제 카메라 스트림으로 검증하지 않았다.** xsim 자극만 통과했다.
   `win_evt_count`로 실제 Event Rate를 재는 것은 입력 경로가 붙은 뒤(D6~D8)다.
5. **Event Rate 수치는 합성 데이터다.** 실제 카메라 측정값이 아니다.
   다만 **웹캠의 최대 fps는 실측이다** (§2, `tools/probe_webcam.py`).
6. **Slew Rate Limit은 구현 완료했지만 실제 하중 튜닝 전이다.** 기본값은
   `1 step/20 ms`이며 D5~D10 Closed-loop에서 1~4 범위를 확인한다.
7. **`WINDOW_US` / `WINDOW_SRC`는 확정이 아니다.** CR C-002 승인 대기 중이며
   승인 시 `33333` / `1`로 바뀐다. parameter 교체만으로 끝나고 로직 변경은 없다.
8. `tools/gen_event_vector.py`의 출력은 **C의 로컬 개발용 자극**이다.
   팀 공식 Test Vector(`test_vectors/`, `golden_outputs/`)는 SPEC §5.2에 따라 **B 소유**다.
9. **현재 브랜치에는 A Phase 3의 `top_system.v`, `npu_axi.v`, `c_module_stub.v`,
   PS 소프트웨어가 없다.** `c_event_control_top.v`는 A 문서의 포트 계약을 C RTL과
   연결해 xsim으로 검증한 상태이며, 실제 A NPU/AXI 결합은 A 브랜치 합류 후 다시 검증한다.
10. A Phase 3 stub에는 실제 Event Source 입력과 NPU `start` 요청 포트가 없다.
    C 래퍼는 두 포트를 명시적으로 제공한다. A는 §11.4의 START 방식 하나를 선택하고
    `top_system`에 Event Source 입력을 추가해야 한다.
11. 동적 Safe Limit을 바꾸는 동안은 Laser Arm을 해제한다. 잘못된 범위는 적용하지 않고
    정적 parameter 범위로 Fail-Safe fallback하며 `CONTROL_STAT.LIMIT_FAULT`를 세운다.

---

## 9. C → A 출력 신호 (SPEC §8 팀 인터페이스)

```text
CAMERA PAN PWM
CAMERA TILT PWM
LASER PAN PWM
LASER TILT PWM
LOCK
LASER ENABLE SAFE / LED
```

## 10. A → C 입력 신호 (SPEC §14 — 변경 금지)

```verilog
target_valid
target_x[5:0]              // 64×64 좌표계
target_y[5:0]              // 64×64 좌표계
signed [7:0] target_score  // signed INT8 — SPEC §14 확정 (v1.1~)
```

**SPEC v1.2 §14.1 Mapping Freeze에 따라 `target_x` / `target_y`는 8개 값만 나온다.**

```text
target_x, target_y ∈ { 4, 12, 20, 28, 36, 44, 52, 60 }     // heatmap_* * 8 + 4
Heatmap 인덱스 순서 = [Y][X]
```

C는 이 값을 **연속 좌표로 취급하지 않는다.** 최소 오차가 ±4이므로
§4의 `DEAD_ZONE >= 4`, `abs(error) <= DEAD_ZONE` 비교가 여기서 나온다.

`target_score`는 Conv4 Heatmap의 signed INT8 최대값이다 (SPEC §14).
Conv4는 ReLU를 적용하지 않으므로 `-128 ~ 127` 전 범위가 나온다 (SPEC §9.1).
C 측 비교 연산은 전부 signed로 처리한다.

---

## 11. A Phase 3 통합 계약 — `c_event_control_top.v` (D6)

`rtl/control/c_event_control_top.v`는 C 소유 모듈만 조합하며 A 소유
`rtl/integration/c_module_stub.v`를 직접 수정하지 않는다. A는 stub 대신 이 모듈을
인스턴스하거나 동일 포트로 감싼다.

### 11.1 A stub 대비 추가 포트

```verilog
// 실제 Event Source
src_valid
src_x[SRC_COORD_W-1:0]
src_y[SRC_COORD_W-1:0]
src_pol
src_window_end

// Tensor 8192 byte 전송 완료
tensor_start

// Fail-Closed 물리 입력
laser_arm_hw
emergency_stop_hw

// A가 0x58 / 0x5C RO Register 또는 ILA에 연결
servo_pos_stat[31:0]
control_stat[31:0]
```

`npu_done`은 내부에서 `target_update` 1-cycle pulse로 직접 사용한다. PT#2 목표는 이
pulse에서 현재 PT#1 자세, 화면 잔차, `LASER_CAL`을 합산해 레지스터에 저장한다.
이후 Servo frame tick은 저장된 목표만 따라가므로 NPU 출력 변경 중간값은 사용하지 않는다.

### 11.2 C 소유 AXI bit 계약

| Register | Bit | 의미 |
|---|---:|---|
| `EVENT_CFG 0x08` | 0 | `EVENT_ENABLE` |
|  | 1 | `POLARITY_INVERT` |
| `LASER_CTRL 0x28` | 0 | `SERVO_ENABLE` |
|  | 1 | `SW_LASER_ARM` — 실제 Arm은 이 bit와 `laser_arm_hw`의 AND |
|  | 2 | `SW_ESTOP` — 실제 E-stop과 OR |
|  | 3 | `MANUAL_OVERRIDE` |
|  | 4 | `MANUAL_AIM_READY` — Manual 조준 확인 후에만 1 |
|  | 8 | `RUNTIME_LIMIT_EN` |
|  | 9 | `RUNTIME_CAL_EN` |
| `PAN/TILT/PAN2/TILT2_CMD` | 7:0 | Manual Override용 unsigned Servo pos |
| `SAFE_LIMIT` | 7:0 / 15:8 | PT#1 PAN MIN / MAX |
|  | 23:16 / 31:24 | PT#1 TILT MIN / MAX |
| `SAFE_LIMIT2` | 동일 | PT#2 PAN/TILT MIN/MAX |
| `LASER_CAL` | 15:0 / 31:16 | PAN/TILT signed offset, Servo pos step 단위 |

Runtime Limit은 정적 `32~224` 범위의 부분집합일 때만 적용한다. 범위를 벗어나거나
MIN>MAX이면 정적 Limit으로 fallback하고 fault를 표시한다.

### 11.3 `INPUT_STAT 0x0C`

| Bit | 이름 | 의미 |
|---:|---|---|
| 0 | `ACC_READY` | 초기 BRAM clear 완료 |
| 1 | `TENSOR_READY` | Sticky. `tensor_start`에서 1, NPU BUSY에서 0 |
| 2 | `OVERRUN` | Window 처리 여유 위반 sticky |
| 3 | `EVENT_ENABLE` | 설정 반영값 |
| 4 | `NPU_BUSY` | A 입력 mirror |
| 5 | `TARGET_VALID` | A 입력 mirror |
| 6 | `LASER_LOCK` | 현재 Interlock qualification |
| 7 | `LASER_TIMEOUT` | Laser max-on/watchdog fault |
| 19:8 | `WIN_EVT_COUNT` | 직전 Window 채택 수, 12-bit saturation |
| 31:20 | `WIN_DROP_COUNT` | 직전 Window 폐기 수, 12-bit saturation |

추가 RO 상태 제안:

```text
0x58 SERVO_POS_STAT = {TILT2, PAN2, TILT1, PAN1}   // 각 8 bit
0x5C CONTROL_STAT:
  [0] LASER_EN        [1] LASER_LOCK       [2] TARGET_FRESH
  [3] LASER_TIMEOUT   [4] AIM_READY        [5] MANUAL_OVERRIDE
  [6] LIMIT_ACTIVE    [7] LIMIT_FAULT      [8] SERVO_ENABLE
  [9] HW_ARM          [10] SW_ARM          [11] EMERGENCY_STOP
  [12] TENSOR_READY   [13] ACC_READY       [14] OVERRUN
  [15] TARGET_VALID   [31:16] 0
```

기존 `TRACK_ERR_X/Y`는 C 하드웨어 Tracking에서 소비하지 않는다. A가 이 두 Register를
RW 출력으로 유지할 필요가 없으며, 위 실제 위치/상태 RO Register로 교체하는 안을 권장한다.

### 11.4 START 소유권 — A 선택 필요

둘 중 **정확히 하나만** 선택한다.

```text
Direct 방식 (C 권장):
  npu_start = INPUT_SRC ? C tensor_start : AXI start pulse

PS-managed 방식:
  PS가 INPUT_STAT.TENSOR_READY 폴링 -> CTRL.START 기록
  NPU BUSY가 올라가면 TENSOR_READY 자동 clear
```

두 경로를 동시에 연결하면 같은 Tensor에 START가 두 번 발생할 수 있으므로 금지한다.

### 11.5 검증

`tb_c_event_control_top`에서 다음 25개 판정을 통과했다.

```text
Event Disable / Accumulator Ready
8192 byte 전송 / CHW Positive·Negative count / Polarity Invert
tensor_start + Sticky TENSOR_READY / BUSY clear
Manual 4-Servo Command / Runtime SAFE_LIMIT clamp + invalid fallback
NPU done -> target_update / 3회 Lock
Hardware E-stop Fail-Closed
```

전체 C 자동판정 TB 11개를 재실행해 로그 기준 **249 PASS, errors=0**을 확인했다.

Zybo Z7-20 (`xc7z020clg400-1`) 100 MHz 기준 `c_event_control_top` OOC
implementation 결과는 다음과 같다.

| 항목 | 결과 |
|---|---:|
| Slice LUT | 829 (1.56%) |
| Register | 582 (0.55%) |
| BRAM Tile | 4 (2.86%) |
| DSP | 6 (2.73%) |
| Setup WNS | +1.138 ns |
| Hold WHS | +0.147 ns |
| DRC Error | 0 |

이는 C 래퍼 단독 OOC 결과다. A의 `top_system/npu_axi/npu_core`와 통합한 뒤에는
전체 경로 기준 implementation과 타이밍을 다시 측정한다.
