# Interface Contract — A(NPU RTL / SoC) 확정본 v0.5

> **상태:** C 기본 계약 수용·구현 완료. B 확인 항목과 A Phase 3 확장 회신 대기.
> **기준 문서:** `TEAM_COMMON_AI_INTEGRATION_SPEC.md` **v1.5**
> **작성 시점:** NPU Core RTL 구현 + Golden 일치 검증 완료 후
> **갱신:** 2026-08-25 — C Laser 수동 재무장 정책과 `CONTROL_STAT[16]` 반영.
>
> 공통 스펙에서 이미 Freeze된 항목(Weight Layout OIHW, Bias 미사용,
> Rounding ties-away-from-zero, Requantize M×2^24 / >>24, Clamp, Heatmap Mapping,
> Conv 경계 규칙)은 여기서 반복하지 않는다.
>
> **v1.3 반영 위치 대조표**
>
> | 이 문서 절 | 공통 지침 v1.3 위치 | 승인 상태 |
> |---|---|---|
> | 1. Tensor Memory Order (CHW) | §7.4 | C 승인 완료 / B 확인 대기 |
> | 2. Conv Padding | **§8.1 (Freeze 완료)** | A 승인 완료 |
> | 3. Argmax Tie-Break | §14.2 | B 승인 대기 |
> | 4. target_valid 조건 | §16.1 | B 승인 대기 |
> | 6. Event Tensor 전달 (ext_*) | §7.3 | C 승인·구현 완료 |
> | **10. AXI Register Bit Field** | **§20.1** | **C 기본 계약 승인·구현 / A Phase 3 확장 회신 대기** |
> | **11. PT#2 레이저 헤드 좌표 변환** | **§15.2** | **C 승인·구현 완료** |
>
> 승인이 모두 끝나면 이 문서는 공통 지침 v1.5를 참조하는 요약본으로 유지한다.

---

## 1. Tensor Memory Order — **CHW 확정**

`TEAM_COMMON_AI_INTEGRATION_SPEC v1.2 §21`의 `[ ] Tensor Memory Order` 항목.

```text
TENSOR_MEMORY_ORDER = CHW
ADDR = (c << (2*log2(W))) + (y << log2(W)) + x
```

레이어별 실제 주소식:

| 텐서 | Shape | 주소식 | 크기 |
|---|---|---|---:|
| Event Tensor (Conv1 입력) | 2×64×64 | `(c<<12) + (y<<6) + x` | 8192 B |
| Conv1 출력 | 8×32×32 | `(c<<10) + (y<<5) + x` | 8192 B |
| Conv2 출력 | 16×16×16 | `(c<<8) + (y<<4) + x` | 4096 B |
| Conv3 출력 | 32×8×8 | `(c<<6) + (y<<3) + x` | 2048 B |
| Conv4 출력 (Heatmap) | 1×8×8 | `(y<<3) + x` | 64 B |

### B가 지켜야 할 것
`input_event.hex` / `conv{N}_out.hex` 덤프 순서를 위 CHW 순서로 맞춘다.
PyTorch 텐서가 `(C,H,W)`이면 `tensor.flatten()` 순서 그대로다. 별도 transpose 불필요.

### C가 지켜야 할 것
Event Accumulator가 NPU 입력 버퍼에 쓸 때:

```text
addr = (polarity << 12) | (event_y << 6) | event_x
       polarity 0 = Positive, 1 = Negative   (spec §7.1)
```

---

## 2. Conv Padding — **pad=1 확정 (유도값)**

공통 스펙 어디에도 padding 값이 없다. 그러나 §8의 고정 출력 형상에서 유일하게 결정된다.

```text
out = floor((in + 2*pad - k) / stride) + 1

pad=1 : (64+2-3)/2+1 = 32  ✔   (32+2-3)/2+1 = 16 ✔   (16+2-3)/2+1 = 8 ✔
pad=0 : (64-3)/2+1   = 31  ✘   (32-3)/2+1   = 15 ✘   (16-3)/2+1   = 7 ✘
```

확정:

```text
CONV1_PAD = 1   (zero padding, 상하좌우 대칭)
CONV2_PAD = 1
CONV3_PAD = 1
CONV4_PAD = 0   (1x1 / stride 1)
PAD_VALUE = 0   (양자화 zero_point = 0 이므로 정수 0 그대로)
```

### B 확인 필요 (1줄 회신)
> `nn.Conv2d(..., padding=?)` 값이 Conv1~3 모두 `1`인지 확인.
> 만약 다르면 §8 출력 형상이 안 나오므로 모델 재확인 대상.

불일치 시 첫 Conv1 Golden 비교에서 즉시 드러난다 (A쪽 TB가 8192 byte 전수 비교).

---

## 3. Argmax 동점(Tie) 처리 — **raster first-max 확정**

§14.1이 좌표 Mapping은 정했지만 **같은 최대값이 2개 이상일 때 어느 cell을 고르는지** 규정이 없다.
Python `np.argmax`는 flatten 순서 첫 번째를 고른다. RTL이 `>=` 비교를 쓰면 마지막이 선택되어
Golden과 bit-exact가 깨진다.

```text
ARGMAX_SCAN_ORDER = raster (addr = y*8 + x, y major / x minor)
ARGMAX_TIE_RULE   = FIRST_MAX  (비교는 strict '>' 사용)
ARGMAX_COMPARE    = signed INT8
```

B의 `integer_golden.py`도 `np.argmax(heatmap.reshape(-1))` 그대로 쓰면 자동으로 일치한다.
`np.argmax(..., axis=)` 조합이나 `np.where(h==h.max())[-1]` 같은 변형을 쓰지 않는다.

---

## 4. `target_valid` 생성 조건 — **score 임계값 방식**

§16은 `target_valid == 0`일 때 C의 동작만 규정하고, **무엇이 0을 만드는지**가 없다.

```text
target_valid = (heatmap_max_score > SCORE_TH)
SCORE_TH     = signed INT8, npu_core 입력 포트 (추후 AXI 0x1C 상위 비트 또는 전용 레지스터)
SCORE_TH_DEFAULT = 0
```

> **B 확인 필요:** 표적 없는 프레임의 Heatmap max score 분포를 알려주면
> `SCORE_TH` 실제 값을 확정한다. 그 전까지는 0 (= score>0 이면 valid).

---

## 5. A → C Target Interface (v1.2 §14 그대로, RTL 포트명 확정)

```verilog
// npu_core.v
output wire        target_valid;
output wire  [5:0] target_x;      // 4,12,20,28,36,44,52,60 만 출력됨
output wire  [5:0] target_y;
output wire signed [7:0] target_score;
```

C의 Tracking Controller는 `abs(error) <= 4`를 최소 Dead Zone으로 쓴다 (v1.2 §15).

---

## 6. C → A Event Tensor 전달 — **1차 구현 = 직접 write 포트**

v1.2 §7.3 / §21.2에서 계속 TBD인 항목. **MVP 구현으로 아래를 제안한다.**

```verilog
// npu_core.v
input wire        ext_we;
input wire [12:0] ext_addr;      // CHW 주소 (위 1절)
input wire signed [7:0] ext_data;
```

규칙:

```text
- ext_* 는 npu_core 의 busy == 0 일 때만 유효하다.
- C: event_window_end 펄스 -> Tensor 전송 -> NPU start
- 1 byte / cycle, 8192 cycle (= 82 us @100MHz)
```

### 제약 (후속 상태는 `docs/PROJECT_STATUS.md` 참조)
현재 입력 버퍼가 내부 ping-pong 버퍼 2개 중 하나를 공유한다.
따라서 **NPU 추론 중에는 다음 Window Tensor를 미리 쓸 수 없다.**
연속 실시간 동작이 필요해지면 입력 전용 버퍼 1개(BRAM 4개)를 추가한다.
현재 Latency(1.26 ms)가 Event Window(5~10 ms)보다 훨씬 짧아 MVP에서는 문제가 없다.

---

## 7. Weight / Requant 파라미터 전달

B는 공통 스펙 §11.1 형식 그대로 주면 된다.

```text
weights/conv1_weight_int8.mem     OIHW, 1 line = 1 byte, two's complement hex
weights/conv2_weight_int8.mem
weights/conv3_weight_int8.mem
weights/conv4_weight_int8.mem
weights/requant_M.mem             4 line, 각 32bit hex (Conv1~4 순서)
```

A가 `tools/pack_weights.py`로 RTL용 8-bank 형식(`w_bank0..7.mem`)으로 변환한다.
**B는 bank 형식을 신경 쓸 필요 없다.**

`requant_M.mem` 형식 예:

```text
0000A0A5
0001E84D
0000655F
00014C2A
```

---

## 8. NPU 내부 구현 파라미터 (A 소유, 변경 시 B/C 영향 없음)

```text
PE_COUNT        = 8            (spec §18 권장 시작점)
DATAFLOW        = output-stationary
WEIGHT_BANKING  = out_channel % 8
REQUANT_LATENCY = 4 cycle
MAC_LATENCY     = 2 cycle
ACT_BUFFER      = 8192 B x 2 (ping-pong)
WEIGHT_ROM      = 770 B x 8 bank
```

---

## 9. 검증 완료 상태 (2026-08-21)

| 항목 | 결과 |
|---|---|
| `tb_npu_requant` | PASS — 3150 case, Python golden과 bit-exact |
| `tb_npu_pe` | PASS — 300 MAC + clr/en |
| `tb_npu_conv_dense` | PASS — Conv1 8192 byte 전수 일치 |
| `tb_npu_full` | PASS — Conv1/2/3/4 + Argmax 전부 일치 |
| `tb_npu_axi` | PASS — AXI Register 74 check (protocol / sticky / W1C / wstrb / 오류경로) |
| `tb_top_system` | PASS — PS 시나리오 end-to-end 17 check, **PS 경로 / C 직결 경로 둘 다 golden 일치** |
| 배치배선 `npu_core` (OOC) | LUT 573 (1.08%), FF 279, BRAM 8 tile (5.71%), DSP 12 (5.45%) |
| 배치배선 `top_system` (OOC) | LUT 1060 (1.99%), FF 849, BRAM 8 tile, DSP 12 |
| **Bitstream 전체 시스템** | LUT 1441 (2.71%), FF 1392 (1.31%), BRAM 8, DSP 12 |
| Timing @100MHz | **MET** — 전체 시스템 배치배선 WNS **+0.782 ns** / WHS +0.043 ns, Fmax **107.7 MHz** |
| NPU Latency | **125,845 cycle = 1.258 ms @100MHz** |
| 산출물 | `results/npu_soc.bit` , `results/npu_soc.xsa` |

> 현재 Golden은 A가 만든 dummy weight 기준(`tools/gen_dummy.py`)이다.
> B의 실제 weight/golden이 오면 파일만 교체하고 같은 TB를 다시 돌린다.

---

## 10. AXI Register 계약 — C 기본 계약 승인·구현 / A Phase 3 확장 회신 대기

전체 bit 표와 PS 코드 예시는 **`docs/D3_FREEZE_REQUEST_A_002.md`**,
정본 편입 위치는 **공통 지침 v1.4 §20.1** 이다. 여기서는 C 가 반드시 알아야 할
3가지만 적는다.

### 10.1 주소

```text
NPU AXI4-Lite Base = 0x4000_0000 , Range 0x1000 (4 KB)
PS7 M_AXI_GP0 -> AXI SmartConnect -> top_system.s_axi
FCLK_CLK0 = 100 MHz = NPU clk = s_axi_aclk   (단일 클럭 도메인, CDC 없음)
```

### 10.2 C 가 정해서 A 에게 알려 줘야 할 것

`0x08 EVENT_CFG`, `0x0C INPUT_STAT`, `0x20`~`0x34` (PAN/TILT/LASER/SAFE/TRACK_ERR)
**6+2개의 bit 의미는 A 가 정하지 않았다.** Servo Command Format 이 미정이기 때문이다.

현재 A 구현:

```text
0x08 EVENT_CFG    RW  + 하드웨어 출력 포트 top_system.event_cfg[31:0]
0x0C INPUT_STAT   RO  + 하드웨어 입력 포트 top_system.input_stat[31:0]  (C 가 구동)
0x20~0x34         RW  + 하드웨어 출력 포트 (PS 가 쓰고 하드웨어가 읽는 방향)
                      -> PT#1 = 카메라 헤드
0x48~0x54         RW  + 하드웨어 출력 포트  (v0.4 신규)
                      PAN2_CMD / TILT2_CMD / SAFE_LIMIT2 / LASER_CAL
                      -> PT#2 = 레이저 헤드
```

**C 회신 완료:** 기존 Command RW 값은 Manual Override로 사용한다. C 자동 위치는
`0x58 SERVO_POS_STAT`, `0x5C CONTROL_STAT` 신규 RO로 공개하고 `TRACK_ERR_X/Y`는
유지 또는 RO Status 교체를 A가 결정한다 (`C_TO_A_REPLY_003.md`).

실제 광원 전환 전 C 안전 확장:

```text
0x5C CONTROL_STAT bit16 = LASER_REARM_REQUIRED

Power-on Arm HIGH       -> Laser OFF, REARM_REQUIRED=1
E-stop assert/release   -> Laser OFF, REARM_REQUIRED=1
Max-on timeout          -> Laser OFF, REARM_REQUIRED=1
Laser Arm LOW 관측      -> latch clear
Laser Arm LOW->HIGH 후  -> 새 Target Lock 3회부터 다시 qualification
```

Servo Enable은 광원 qualification 조건이지만 Laser Arm LOW 이력을 대신하지 않는다.
따라서 Servo OFF→ON만으로 Power-on/E-stop 수동 재무장이 완료되지 않는다.

### 10.3 C 의 Event Accumulator 연결 방법

```text
CTRL(0x00) bit3 INPUT_SRC
  0 = PS 가 AXI INBUF_DATA(0x40) 로 입력버퍼를 채운다   (bring-up / 회귀시험)
  1 = C 의 Event Accumulator 가 evt_we/evt_addr/evt_data 로 직접 채운다

C 쪽 포트 (top_system 입력, spec §7.3 그대로)
  evt_we          1 bit
  evt_addr [12:0] CHW 주소 = (polarity << 12) | (y << 6) | x
  evt_data  [7:0] signed INT8
  input_stat [31:0]  Event Count 등 (0x0C 로 PS 가 읽음)

규칙: STATUS.BUSY == 1 인 동안 evt_we 를 올리지 마라.
```

두 경로 모두 `tb_top_system` 에서 **같은 golden 결과**를 내는 것을 확인했다
(CASE 1 / CASE 2). C 는 `INPUT_SRC=1` 로 두고 위 4개 신호만 구동하면 된다.

### 10.4 PS 소프트웨어가 지켜야 할 것 하나

```text
STATUS.DONE(bit0) 을 폴링해라. STATUS.BUSY(bit1) 를 폴링하지 마라.
  - done 은 RTL 에서 1 cycle 펄스라 AXI 폴링으로는 절대 못 잡는다.
    그래서 DONE 을 sticky 로 만들었다.
  - START 직후에는 busy 가 아직 0 이다(레지스터 1 cycle 지연).
    BUSY 를 폴링하면 "시작하자마자 끝났다"로 오판한다.
```

---

## 11. Pan/Tilt 2 헤드 — v0.4 신규 / v0.5 Laser 재무장 확장

정본: 공통 지침 **v1.5 §15.0 / §15.2 / §17**,
근거서 `docs/D3_FREEZE_REQUEST_A_002.md` rev.2 §2.13~2.15.

```text
   PT#1  0x20 PAN_CMD / 0x24 TILT_CMD / 0x2C SAFE_LIMIT
     -> 이벤트 카메라 헤드. 표적을 화면 중앙에 유지 (closed-loop)

   PT#2  0x48 PAN2_CMD / 0x4C TILT2_CMD / 0x50 SAFE_LIMIT2 / 0x54 LASER_CAL
     -> 레이저 전용 헤드. 표적 절대방향 조준

   baseline (두 헤드 간 거리) <= 10 cm
```

### 11.1 A 가 보장하는 것

```text
- NPU 출력은 안 바뀐다. target_valid / target_x / target_y / target_score 그대로
- AXI Register 4개(0x48~0x54)를 제공한다. 구현·검증 완료 (tb_npu_axi 84 check PASS)
- 기존 Offset(0x00~0x44)은 하나도 안 바뀌었다
```

### 11.2 C 가 해야 하는 것

```text
theta_pan_target  = theta_pan1  + k_x * (target_x - 32)      k_x = FOV_X/64
theta_tilt_target = theta_tilt1 + k_y * (target_y - 32)      k_y = FOV_Y/64

PAN2_CMD  = theta_pan_target  + LASER_OFFSET_PAN
TILT2_CMD = theta_tilt_target + LASER_OFFSET_TILT
```

`theta_pan1` = Tracking Controller 가 방금 낸 `PAN_CMD` 값. 센서 불필요.

**금지:** `PAN2_CMD = f(error_x)`.
표적이 화면 중앙에 오면 레이저가 0도를 가리킨다. 완전히 틀린 동작이다.

**부호는 실측:** `k_x` 부호는 서보 회전 방향 × 카메라 장착 방향에 따라 뒤집힌다.

### 11.3 안전 (필수)

```text
Laser ON 조건에 PT#2 검사가 반드시 들어간다:
    PT#1 servo inside SAFE_LIMIT   (0x2C)
    PT#2 servo inside SAFE_LIMIT2  (0x50)

헤드가 분리되면서 "카메라가 보는 곳 = 레이저가 가는 곳" 이라는
기구적 자동 보장이 사라졌다. 좌표 변환 첫 검증은 반드시 LED 로 한다.
```
