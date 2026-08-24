# CHANGE REQUEST / FREEZE REQUEST — A → B, C  (#002)

> **문서 형식:** `TEAM_COMMON_AI_INTEGRATION_SPEC v1.3 §22` CHANGE REQUEST 형식
> **작성자:** A (NPU RTL / SoC / 통합)
> **작성일:** 2026-08-21
> **대상 항목:** 공통 지침 §21 Freeze 목록의 `[ ] Register Bit Fields`
> **승인 필요:** **C (필수)** — `0x20`~`0x34` 는 C 담당 영역이다.
>              B 는 참고만 하면 된다 (B 산출물에 영향 없음).
> **상태:** ✅ **C 기본 계약 수용·구현 완료** (`C_TO_A_REPLY_002/003`).
> START MUX, 신규 RO 상태 Register, 통합 XDC는 A 회신 대기.
> **개정:** **rev.2 (2026-08-21)** — Pan/Tilt **2호기(레이저 전용 헤드)** 반영.
>          `0x48`~`0x54` 4개 추가 + §2.13 좌표 변환 규칙 신규.
>          rev.1 은 배포 전이므로 §22 재요청 없이 이 문서를 갱신한다.
> **선행 문서:** `D3_FREEZE_REQUEST_A_001.md` (Tensor Order / Argmax / target_valid 등)

---

## 0. 왜 지금 이걸 확정해야 하나

공통 지침 §20 은 Offset(`0x00`~`0x34`)만 예약해 두고
**Bit field 는 "D3에 확정한다"** 로 비워 두었다.

A 는 Phase 2 에서 `rtl/integration/npu_axi.v` 를 구현해야 했고,
Bit field 없이는 AXI Slave 를 만들 수 없다. 그래서 A 가 초안을 만들어
**실제로 구현하고 검증까지 마친 뒤** 이 문서로 승인을 요청한다.

```text
구현 상태 : 완료 (rtl/integration/npu_axi.v, 364 line)
검증 상태 : tb_npu_axi 74 check PASS / tb_top_system 17 check PASS
Bitstream : 생성 완료 (results/npu_soc.bit)
```

**C 가 반대하면 A 가 고친다.** 지금 말해 달라. 나중에 바꾸면 PS 소프트웨어까지
같이 고쳐야 한다.

---

## 1. AXI 주소 베이스 (신규 확정 필요)

```text
NPU AXI4-Lite Slave Base Address = 0x4000_0000
Range                            = 0x1000 (4 KB)
연결                             = PS7 M_AXI_GP0 -> AXI SmartConnect -> top_system.s_axi
```

PS 소프트웨어에서:

```c
#define NPU_BASE   0x40000000u
#define NPU_REG(o) (*(volatile uint32_t *)(NPU_BASE + (o)))
```

실제 주소는 Vivado `assign_bd_address` 결과이며 `results/npu_soc.xsa` 에도 들어 있다.
Vitis 에서 XSA 를 읽으면 `XPAR_..._S_AXI_BASEADDR` 로도 나온다.

---

## 2. Register Bit Field — A 제안

`0x00`~`0x34` 는 §20 예약 맵 그대로다. **Offset 도 순서도 의미도 바꾸지 않았다.**
`0x38` 이후는 §20 규칙("새 Register가 필요하면 뒤 Offset에 추가")에 따라 뒤에 붙였다.

기호: **RW** 읽기/쓰기 · **RO** 읽기전용 · **WO** 쓰기전용 · **W1P** 1 쓰면 1 cycle 동작 후 자동 클리어 · **W1C** 1 쓰면 클리어

### 2.1 `0x00 CTRL` — A 소유

| Bit | 이름 | 종류 | 의미 |
|---:|---|---|---|
| 0 | `START` | W1P | 1 쓰면 추론 시작. 읽으면 항상 0. BUSY 중이면 무시되고 `ERROR` 가 선다 |
| 1 | `SOFT_RESET` | W1P | 1 쓰면 NPU 를 16 cycle 리셋. `INBUF_ADDR` 도 0 으로 |
| 2 | `SPARSE_EN` | RO(0) | §19 Optional Sparse 예약. Dense 빌드에서는 항상 0 |
| 3 | `INPUT_SRC` | RW | **0 = PS 가 AXI 로 입력 적재 / 1 = C 의 Event Accumulator 가 직접 기록**. 기본 0 |
| 4 | `IRQ_EN` | RW | 1 이면 `DONE` 시 PS `IRQ_F2P` 인터럽트. 기본 0 |
| 31:5 | — | RO(0) | 예약 |

### 2.2 `0x04 STATUS` — A 소유

| Bit | 이름 | 종류 | 의미 |
|---:|---|---|---|
| 0 | `DONE` | RO / W1C | 추론 완료. **Sticky** — 1 이 되면 유지된다 |
| 1 | `BUSY` | RO | NPU 동작 중 (level) |
| 2 | `ERROR` | RO / W1C | **Sticky.** BUSY 중 START / 잘못된 INBUF write 시 1 |
| 3 | `TARGET_VALID` | RO | `score > SCORE_TH` (spec §16.1) |
| 31:4 | — | RO(0) | 예약 |

> **`DONE` 이 Sticky 인 이유:** `done` 은 RTL 에서 1 cycle 펄스다.
> PS 가 폴링으로 1 cycle 을 잡는 것은 불가능하다.
> **PS 는 `BUSY` 가 아니라 `DONE` 을 폴링해야 한다.**
> `START` 를 쓰면 `DONE` 은 자동으로 0 이 되므로 이전 프레임과 헷갈리지 않는다.

### 2.3 `0x08 EVENT_CFG` — **C 소유**

| Bit | 종류 | 의미 |
|---:|---|---|
| 31:0 | RW | **Bit 의미는 C 가 정한다.** A 는 32-bit 저장소와 출력 포트만 제공한다 |

A 쪽 노출: `top_system.event_cfg[31:0]`. C 의 Event Accumulator 가 이 값을 그대로 받는다.
Event Window 값 자체는 §21 에서 여전히 `[ ] C 미정` 이다.

### 2.4 `0x0C INPUT_STAT` — **C 소유 (C → PS)**

| Bit | 종류 | 의미 |
|---:|---|---|
| 31:0 | RO | **C 의 하드웨어가 구동한다.** A 는 `top_system.input_stat[31:0]` 입력 포트를 열어 두고 그대로 PS 에 보여 준다 |

C 모듈이 없는 현재 빌드에서는 0 으로 묶여 있다.

### 2.5 `0x10 CYCLE_CNT` — A 소유

| Bit | 종류 | 의미 |
|---:|---|---|
| 31:0 | RO | 직전 추론의 소요 cycle. `START` 시 0 으로 초기화 |

측정값: **125,845 cycle** = @100 MHz **1.258 ms** (§35 성능 측정 규칙에 쓸 실측치)

### 2.6 `0x14 RESULT_X` / `0x18 RESULT_Y` — A 소유

| Bit | 종류 | 의미 |
|---:|---|---|
| 5:0 | RO | `target_x` / `target_y` (0~63, 원본 64×64 좌표. spec §15) |
| 31:6 | RO(0) | 예약 |

### 2.7 `0x1C RESULT_SCORE` — A 소유 (RO + RW 혼합)

| Bit | 이름 | 종류 | 의미 |
|---:|---|---|---|
| 7:0 | `TARGET_SCORE` | RO | signed INT8. Heatmap 최댓값 |
| 15:8 | — | RO(0) | 예약 |
| 23:16 | `SCORE_TH` | RW | signed INT8. `target_valid` 임계값. **기본 0** |
| 31:24 | — | RO(0) | 예약 |

> 공통 지침 §16.1 이 `SCORE_TH` 의 노출 위치를 "AXI 0x1C 상위 비트"로 이미 적어 두었다.
> 그 문장을 그대로 구현한 것이다.
> `SCORE_TH` 실값은 B 가 "표적 없는 프레임의 Heatmap max score 분포"를 주면 확정한다.

### 2.8 `0x20`~`0x34` — **전부 C 소유** (Pan/Tilt **1호기 = 카메라 헤드**)

> **rev.2 주의:** 기구가 Pan/Tilt **2개**로 바뀌었다.
> `0x20 PAN_CMD` / `0x24 TILT_CMD` 는 **카메라 헤드(PT#1)** 전용이다.
> 레이저 헤드(PT#2)는 §2.12 의 `0x48` / `0x4C` 를 쓴다.
> Offset 과 의미는 안 바꿨다 — 용도를 좁혀서 명확히 한 것뿐이다 (§20 규칙 준수).

| Offset | 이름 | 종류 | A 가 제공하는 것 |
|---:|---|---|---|
| `0x20` | `PAN_CMD` | RW | 32-bit 저장소 + `top_system.pan_cmd[31:0]` 출력 |
| `0x24` | `TILT_CMD` | RW | 32-bit 저장소 + `top_system.tilt_cmd[31:0]` 출력 |
| `0x28` | `LASER_CTRL` | RW | 32-bit 저장소 + `top_system.laser_ctrl[31:0]` 출력 |
| `0x2C` | `SAFE_LIMIT` | RW | 32-bit 저장소 + `top_system.safe_limit[31:0]` 출력 |
| `0x30` | `TRACK_ERR_X` | RW | 32-bit 저장소 + `top_system.track_err_x[31:0]` 출력 |
| `0x34` | `TRACK_ERR_Y` | RW | 32-bit 저장소 + `top_system.track_err_y[31:0]` 출력 |

**A는 이 6개의 bit 의미를 정하지 않고 C 회신을 요청했다.** 당시 Servo Command
Format과 Safe Limit 정책은 미정이었으나, 현재는 `C_TO_A_REPLY_003.md`의 bit 배치와
Manual Override/Runtime Limit 정책으로 C 구현이 완료됐다.

**C 가 결정해서 알려 줘야 할 것:**

```text
(a) 각 Register 의 bit 배치        -> C 가 정하고 docs/interface_contract.md 에 기록
(b) 방향이 이대로 맞는가?
      지금은 6개 다 "PS 가 쓰고 하드웨어가 읽는다" (RW + 출력 포트) 이다.
      만약 TRACK_ERR_X/Y 를 C 의 하드웨어 Tracking Controller 가 계산해서
      PS 가 읽기만 할 거라면 -> RO + 입력 포트로 바꿔야 한다. A 가 바꿔 준다.
      Tracking 을 PS 소프트웨어로 할 거면 지금 그대로가 맞다.
```

### 2.9 `0x38 VERSION` — A 소유 (신규)

| Bit | 종류 | 값 |
|---:|---|---|
| 31:16 | RO | `0x4E50` = ASCII `"NP"` |
| 15:8 | RO | Major = `0x01` |
| 7:0 | RO | Minor = `0x00` |

읽으면 **`0x4E50_0100`**. AXI 배선이 살아 있는지 확인하는 가장 빠른 방법이다.
보드에 올리고 이 값이 안 나오면 그 아래는 볼 필요도 없다.

### 2.10 `0x3C INBUF_ADDR` / `0x40 INBUF_DATA` — A 소유 (신규)

PS 가 Event Tensor 를 직접 넣기 위한 창구다. **Bring-up / 단위시험용**이며
C 의 직결 경로(§7.3 `ext_*`)를 대체하지 않는다.

| Offset | Bit | 종류 | 의미 |
|---:|---:|---|---|
| `0x3C` | 13:0 | RW | 입력버퍼 byte 포인터. **4 byte 정렬 강제** (하위 2 bit 무시) |
| `0x3C` | 31:14 | RO(0) | 예약 |
| `0x40` | 31:0 | WO | 32-bit 쓰면 포인터 위치에 **4 byte(리틀엔디안)** 기록 후 포인터 +4 |

```text
동작 규칙
  - INBUF_DATA 1회 write = act_buf 에 8-bit write 4회. AXI BVALID 를 4 cycle 늦춘다.
  - wstrb 를 지킨다. byte lane 이 0 이면 그 byte 는 안 쓴다 (포인터는 그래도 +4).
  - 다음 경우 write 는 버려지고 STATUS.ERROR 가 선다:
        BUSY == 1                (추론 중)
        CTRL.INPUT_SRC == 1      (C 하드웨어가 입력 소스)
        INBUF_ADDR >= 8192       (버퍼 넘침)
  - 8192 byte 를 다 넣으면 INBUF_ADDR 이 정확히 8192(0x2000) 가 된다.
    PS 는 이 값을 읽어서 "한 프레임 다 들어갔다"를 확인할 수 있다.
```

### 2.11 `0x44 SCRATCH` — A 소유 (신규)

| Bit | 종류 | 의미 |
|---:|---|---|
| 31:0 | RW | 아무 의미 없음. AXI 읽기/쓰기 경로 시험용 |

### 2.12 `0x48`~`0x54` — **전부 C 소유** (Pan/Tilt **2호기 = 레이저 헤드**, rev.2 신규)

| Offset | 이름 | 종류 | A 가 제공하는 것 |
|---:|---|---|---|
| `0x48` | `PAN2_CMD` | RW | 32-bit 저장소 + `top_system.pan2_cmd[31:0]` 출력 |
| `0x4C` | `TILT2_CMD` | RW | 32-bit 저장소 + `top_system.tilt2_cmd[31:0]` 출력 |
| `0x50` | `SAFE_LIMIT2` | RW | 32-bit 저장소 + `top_system.safe_limit2[31:0]` 출력 |
| `0x54` | `LASER_CAL` | RW | 32-bit 저장소 + `top_system.laser_cal[31:0]` 출력. 조준 보정 계수 |

`0x20`~`0x34` 와 완전히 같은 방식이다. **bit 의미는 C 가 정한다.**
더 필요하면 `0x58` 부터 이어서 추가한다. 말만 해라.

### 2.13 Pan/Tilt 2개 좌표 변환 — **C 가 반드시 지킬 것 (rev.2 신규)**

기구가 이렇게 바뀌었다.

```text
   PT#1                    PT#2
 ┌────────┐              ┌────────┐
 │ Event  │              │ Laser  │        두 헤드 간 거리(baseline) <= 10 cm
 │ Camera │              │ Module │
 └────────┘              └────────┘
 화면 중앙에 표적 유지      표적을 직접 조준
 (closed-loop)            (절대 방향 조준)
```

**카메라가 움직인다는 것이 핵심이다.** `error_x = target_x - 32` 는
**카메라 각도에 상대적인 값**이지 표적의 절대 방향이 아니다.
레이저 헤드는 절대 방향이 필요하므로 카메라 헤드 각도를 더해야 한다.

```text
k_x = FOV_X / 64        [deg/pixel]   가로 화각을 64 로 나눈 값
k_y = FOV_Y / 64        [deg/pixel]

표적 절대 방향
  theta_pan_target  = theta_pan1  + k_x * (target_x - 32)
  theta_tilt_target = theta_tilt1 + k_y * (target_y - 32)

레이저 헤드 명령
  PAN2_CMD  = theta_pan_target  + LASER_OFFSET_PAN
  TILT2_CMD = theta_tilt_target + LASER_OFFSET_TILT
```

`theta_pan1 / theta_tilt1` 은 **Tracking Controller 가 방금 자기가 낸
`PAN_CMD` / `TILT_CMD` 값**이다. 별도 센서 필요 없다. 그냥 더하면 된다.

```text
[하지 마라]  PAN2_CMD = f(error_x)
             -> 레이저가 표적이 아니라 "오차"를 따라간다. 표적이 중앙에 오면
                레이저는 0 도를 가리킨다. 완전히 틀린 동작이다.
```

**부수 효과 (좋은 쪽):** 위 식은 카메라가 아직 중앙 정렬을 못 끝낸 상태에서도
정확하다. 잔차 `error_x` 를 그대로 더하기 때문이다.
**레이저가 카메라보다 먼저 락온된다.** 시연에서 이게 더 잘 보인다.

**부호는 C 가 실측으로 확인해라.** 서보 회전 방향과 카메라 장착 방향에 따라
`k_x` 의 부호가 뒤집힌다. 표적을 오른쪽에 두고 `PAN2_CMD` 가 오른쪽으로
가는지 눈으로 보고 정한다.

### 2.14 Parallax 처리 (rev.2 신규)

두 헤드가 떨어져 있으므로 원리적으로는 표적까지의 거리를 알아야 각도가 나온다.
**baseline <= 10 cm 이고 시연 거리가 고정이면 상수 오프셋으로 흡수된다.**

| 시연 거리 | 시차각 `atan(0.1/D)` | 비고 |
|---:|---:|---|
| 1.0 m | 5.7° | 가까움. 오차 큼 |
| 2.0 m | 2.9° | **권장 시연 거리** |
| 3.0 m | 1.9° | |

`LASER_OFFSET_PAN/TILT` 가 이 값을 통째로 흡수한다.
거리가 2.0 m ± 0.5 m 로 흔들리면 잔차 각도는 약 ±0.7° = 2 m 지점에서 약 ±2.5 cm 다.
표적판을 그보다 크게 만들면 문제 없다.

**보정 절차 (개발 계획 §16.2 확장):**

```text
1. 고정 거리 D 에 표적을 둔다
2. 카메라 헤드가 표적을 화면 중앙에 잡게 한다
3. 레이저가 표적에 맞을 때까지 PAN2_CMD / TILT2_CMD 를 손으로 조정한다
4. 그때의 (PAN2_CMD - theta_pan_target) 가 LASER_OFFSET_PAN 이다
5. 중앙 + 네 모서리 5 지점에서 측정해 평균 (또는 LASER_CAL 에 선형계수 저장)
```

### 2.15 안전 — Pan/Tilt 2개가 되면서 새로 생긴 위험 (rev.2 신규)

```text
[단일 헤드였을 때]
  카메라가 보는 곳 = 레이저가 가는 곳.
  "화면에 보이는 것만 쏜다" 가 기구적으로 자동 보장됐다.

[헤드 2개]
  레이저 헤드가 카메라 시야 밖을 조준할 수 있다.
  좌표 변환이 틀리거나 부호가 뒤집히면 엉뚱한 방향으로 돌아간다.
```

따라서 **`SAFE_LIMIT2`(0x50) 는 선택이 아니라 필수다.**
공통 지침 §17 Laser ON 조건에 다음을 추가한다:

```text
PT#1 servo inside SAFE_LIMIT   (기존)
PT#2 servo inside SAFE_LIMIT2  (신규, 반드시)
```

개발 중에는 레이저 대신 LED 로 먼저 검증한다 (계획서 §16.4 그대로).

### 2.12 미정의 Offset

```text
read  -> 0
write -> 무시
RESP  -> 항상 OKAY (2'b00)
```

일부러 SLVERR 를 안 낸다. PS 에서 Bus Error / Data Abort 로 죽는 것보다
0 이 읽히는 편이 디버깅하기 쉽다.

---

## 3. PS 소프트웨어 사용 순서 (A 검증 시나리오 그대로)

`tb/integration/tb_top_system.v` 가 아래 순서를 AXI 로 그대로 재현해서 통과했다.

```c
// 0) 링크 확인
assert(NPU_REG(0x38) == 0x4E500100);

// 1) 입력 소스 = PS, 임계값 설정
NPU_REG(0x00) = 0;                 // INPUT_SRC = 0
NPU_REG(0x1C) = (SCORE_TH & 0xFF) << 16;

// 2) Event Tensor 8192 byte 적재 (CHW: addr = (c<<12)|(y<<6)|x)
NPU_REG(0x3C) = 0;
for (int i = 0; i < 2048; i++)
    NPU_REG(0x40) = ((uint32_t *)tensor)[i];
assert(NPU_REG(0x3C) == 8192);     // 다 들어갔나
assert((NPU_REG(0x04) & 0x4) == 0);// ERROR 없나

// 3) 추론
NPU_REG(0x00) = 1;                 // START
while ((NPU_REG(0x04) & 0x1) == 0) ;   // DONE 폴링 (BUSY 아님!)

// 4) 결과
uint32_t st    = NPU_REG(0x04);
int      valid = (st >> 3) & 1;
uint32_t x     = NPU_REG(0x14) & 0x3F;
uint32_t y     = NPU_REG(0x18) & 0x3F;
int8_t   score = (int8_t)(NPU_REG(0x1C) & 0xFF);
uint32_t cyc   = NPU_REG(0x10);

// 5) 다음 프레임 전에 DONE 클리어 (START 가 자동으로 해주지만 명시해도 된다)
NPU_REG(0x04) = 0x1;
```

**C 의 하드웨어 경로를 쓸 때는 (2) 를 통째로 빼고 `CTRL.INPUT_SRC = 1` 로 두면 된다.**
나머지 순서는 똑같다. 이것도 TB CASE 2 로 검증했다.

---

## 4. C 에게 묻는 것 — 회신 요청

| # | 질문 | A 기본값 | 회신 기한 |
|---:|---|---|---|
| 1 | Base Address `0x4000_0000` / 4 KB 로 괜찮은가 | 그대로 진행 | D7 |
| 2 | `0x20`~`0x34` 6개를 지금처럼 **RW + 하드웨어 출력**으로 둘까? | RW + 출력 | D7 |
| 2b | **`0x48`~`0x54` (PT#2 레이저 헤드) 4개로 충분한가** | 부족하면 `0x58` 부터 추가 | D7 |
| 2c | **§2.13 좌표 변환식에 동의하는가** (특히 `theta_pan1` 을 더하는 것) | 그대로 구현 | **D7 필수** |
| 3 | `TRACK_ERR_X/Y` 를 C 하드웨어가 계산하나, PS 소프트웨어가 계산하나 | PS 계산 가정 | D7 |
| 4 | `CTRL.INPUT_SRC` 방식(0=PS, 1=C 직결) 동의하는가 | 동의로 간주 | D7 |
| 5 | `IRQ_F2P` 인터럽트를 쓸 것인가, 폴링만 할 것인가 | 둘 다 가능하게 열어 둠 | D7 |
| 6 | `EVENT_CFG` bit 배치 | C 가 정할 때까지 32-bit 통짜 | D7 |

**회신 없으면 A 기본값으로 굳힌다.** 대신 그 뒤에 바꾸면 §22 CHANGE REQUEST 를
다시 써야 하고 PS 소프트웨어도 같이 고쳐야 한다.

---

## 5. B 에게 (참고만)

B 산출물(`.mem`, golden hex)에는 **아무 영향이 없다.**
다만 하나만 기억해 두면 된다.

```text
PS 가 Event Tensor 를 넣는 순서 = CHW = D3_FREEZE_REQUEST_A_001 §2 그대로
   addr = (c << 12) | (y << 6) | x
B 의 input_event.hex 덤프 순서와 PS 의 적재 순서가 동일하다.
```

---

## 6. 승인란

| 담당 | 항목 | 상태 | 일자 |
|---|---|---|---|
| C | §1 Base Address | ✅ 구현 기준 수용 | 2026-08-24 |
| C | §2.3/2.4 `EVENT_CFG` / `INPUT_STAT` | ✅ bit 배치 회신·구현 | 2026-08-24 |
| C | §2.8 `0x20`~`0x34` 방향 (PT#1 카메라 헤드) | ✅ RW Manual Override 채택, RO 확장은 A 회신 대기 | 2026-08-24 |
| C | §2.12 `0x48`~`0x54` (PT#2 레이저 헤드) | ✅ RW Manual Override/Limit/Cal 구현 | 2026-08-24 |
| C | **§2.13 좌표 변환식** | ✅ 수용·구현 | 2026-08-22 |
| C | §2.15 `SAFE_LIMIT2` 필수화 | ✅ 수용·구현 | 2026-08-22 |
| C | §2.1 `CTRL.INPUT_SRC` | ✅ C 권장 MUX 회신, A 연결 결정 대기 | 2026-08-24 |
| B | §5 참고 확인 | ⏳ 대기 | |

C 회신 근거는 `C_TO_A_REPLY_002.md`와 `C_TO_A_REPLY_003.md`다. A가 START MUX와
신규 RO 상태 Register를 확정하면 공통 지침의 Phase 3 통합 항목을 최종 완료 처리한다.
