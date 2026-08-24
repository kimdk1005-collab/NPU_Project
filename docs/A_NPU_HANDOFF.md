# A — NPU Handoff  (a_npu_v01 / a_soc_v01)

> 기준: `TEAM_COMMON_AI_INTEGRATION_SPEC.md` v1.5 §26
> 상태: **Dense INT8 NPU Core + AXI4-Lite + Block Design + Bitstream 완료.**
>       Golden bit-exact 검증 완료. 남은 것은 **보드 실동작(Phase 3)** 과 **C 모듈**.
> 날짜: 2026-08-21 (Phase 2 반영)

---

## 1. NPU Port — `rtl/npu/npu_core.v`

```verilog
module npu_core #(parameter NPE = 8) (
    // ---- Clock / Reset ----
    input  wire        clk,            // 100 MHz
    input  wire        rstn,           // active-low, 동기 해제 권장

    // ---- 제어 ----
    input  wire        start,          // 1 cycle pulse
    output wire        busy,
    output wire        done,           // 1 cycle pulse
    output wire [31:0] cycle_cnt,      // start~done cycle 수

    // ---- A -> C  Target Interface (spec §14) ----
    input  wire signed  [7:0] score_th,      // target_valid 임계값, 기본 0
    output wire        target_valid,
    output wire  [5:0] target_x,             // 4,12,20,28,36,44,52,60
    output wire  [5:0] target_y,
    output wire signed  [7:0] target_score,  // Conv4 Heatmap max, signed INT8

    // ---- C -> A  Event Tensor write (spec §7) ----
    input  wire        ext_we,
    input  wire [12:0] ext_addr,
    input  wire signed  [7:0] ext_data
);
```

## 2. Clock / Reset

```text
CLK        = 100 MHz 단일 클럭 (전 모듈 posedge)
RSTN       = active-low
RESET 규칙 = rstn 해제 후 최소 2 cycle 뒤 start 인가
Timing     = 100 MHz MET (xc7z020clg400-1, 배치배선 후 실측)
             npu_core 단독 (OOC)     WNS +0.994 ns / WHS +0.054 ns / Fmax 111.0 MHz
             top_system (+AXI, OOC)  WNS +0.302 ns  (OOC 인공물)
             전체 시스템 bitstream   WNS +0.782 ns / WHS +0.043 ns / Fmax 107.7 MHz
             실제 시스템 클럭 = PS7 FCLK_CLK0 = 100 MHz (clk_fpga_0)
```

## 3. Input Tensor 요구사항

```text
Shape           = 64 x 64 x 2   (spec §7.1)
Order           = CHW  (D3 FREEZE REQUEST #001 - 1번)
Address         = (polarity << 12) | (event_y << 6) | event_x
                  polarity 0 = Positive, 1 = Negative
Data            = signed INT8, 실제 유효 범위 0~127 (Event Count saturation)
전송            = ext_we / ext_addr / ext_data, 1 byte per cycle
전송 조건       = busy == 0 일 때만
전송 소요       = 8192 cycle = 82 us @100MHz
```

C 쪽 흐름:

```text
event_window_end pulse
  -> 8192 byte 전송
  -> start pulse
  -> done 대기 (1.258 ms)
  -> target_* 읽기
```

## 4. Output Target Format

```text
target_valid  = (heatmap_max_score > score_th)
target_x[5:0] = heatmap_x * 8 + 4      (spec §14.1)
target_y[5:0] = heatmap_y * 8 + 4
target_score  = signed INT8, Conv4 Heatmap 최대값

유효 시점 = done 펄스 이후, 다음 start 까지 값 유지
좌표계    = 64x64 입력 좌표계, X 좌->우 증가, Y 상->하 증가
가능값    = 4, 12, 20, 28, 36, 44, 52, 60  (8개만)
Dead Zone = C 는 abs(error) <= 4 를 최소 Center/Lock 범위로 사용 (spec §15)
```

## 5. AXI Register

```text
현재 상태: 구현 + 검증 완료.  rtl/integration/npu_axi.v
Base     : 0x4000_0000 , Range 0x1000 (4 KB)
경로     : PS7 M_AXI_GP0 -> AXI SmartConnect -> top_system.s_axi
검증     : tb_npu_axi 84 check PASS / tb_top_system 17 check PASS
bit field: 공통 지침 v1.5 §20.1  (C 승인 대기 — 0x20~0x34 / 0x48~0x54 방향)
Pan/Tilt : 2 헤드. PT#1 카메라 0x20/0x24/0x2C , PT#2 레이저 0x48/0x4C/0x50/0x54
           PT#2 각도는 공통 지침 §15.2 좌표 변환식 필수 (C 담당)
근거서   : docs/freeze/D3_FREEZE_REQUEST_A_002.md
```

**PS 가 반드시 지킬 것 하나:** `STATUS.DONE`(bit0, sticky) 을 폴링해라.
`STATUS.BUSY` 를 폴링하면 START 직후 busy 가 아직 0 이라 오판한다.

전체 Offset 표는 §20.1 을 보고, 여기서는 연결만 적는다:

| Offset | Name | 연결 |
|---:|---|---|
| `0x00` | CTRL | bit0 START(W1P) → `start`, bit1 SOFT_RESET, **bit3 INPUT_SRC**, bit4 IRQ_EN |
| `0x04` | STATUS | bit0 `done`(sticky/W1C) / bit1 `busy` / bit2 ERROR(sticky/W1C) / bit3 `target_valid` |
| `0x10` | CYCLE_CNT | `cycle_cnt[31:0]` |
| `0x14` | RESULT_X | `{26'b0, target_x}` |
| `0x18` | RESULT_Y | `{26'b0, target_y}` |
| `0x1C` | RESULT_SCORE | `[7:0] target_score`, `[23:16] score_th` (RW) |

## 6. Version

```text
A_NPU                 = a_npu_v01
PROJECT_SPEC          = common_v1.2
ROLE_SPEC             = role_v1.3

Current Model Version = model_v01_dummy      <- B 실물 미수령
Weight Version        = weight_v01_dummy     <- A 가 tools/gen_dummy.py 로 생성
Verified Golden       = golden_v01_dummy     <- 동일
Test Vector           = testvec_v01_dummy
```

> **주의:** 현재 검증은 A 가 만든 랜덤 INT8 weight 기준이다.
> 이것은 "RTL 이 Python 정수 연산과 bit-exact 하다"는 것을 증명하지만
> "모델이 표적을 잘 찾는다"는 것은 증명하지 않는다.
> B 의 실제 weight/golden 이 오면 파일만 교체하고 동일 TB 를 재실행한다.
> 그때 버전을 `a_npu_v02 / model_v01 / weight_v01 / golden_v01` 로 올린다.

## 7. Known Limitation

```text
L1. 입력 버퍼가 내부 ping-pong 버퍼를 공유
    -> NPU 추론 중 다음 Window Tensor 를 미리 쓸 수 없다.
    -> 현재 Latency 1.258 ms << Window 5~10 ms 라 MVP 문제 없음.
    -> 필요 시 입력 전용 8KB 버퍼 추가 (BRAM 4개, 현재 사용률 5.71%)

L2. [해소] AXI-Lite / Block Design / Bitstream 완료 (Phase 2).
    남은 것은 보드 실동작 확인뿐이다.

L3. Conv4 는 cout=1 이라 PE 8개 중 1개만 사용
    -> 전체 cycle 의 2.5% 라 무시. 구조 변경 안 함.

L4. Weight / Requant 파라미터는 합성 시 .mem 삽입 방식 (spec §12.1)
    -> Runtime Upload 없음. weight 바뀌면 재합성 필요.

L5. [해소] $readmemh 상대경로 문제. sim/run_bd.tcl 이 fileset verilog_define 으로
    NPU_WEIGHT_DIR 절대경로를 주입한다. xsim 은 기존대로 -d 로 넘긴다.

L6. Sparse / Zero-Skip 미구현 (spec §19 선택 확장)

L7. [해소] 100 MHz Timing 여유 2.7% 문제.
    원인은 Vivado 가 PE 8개의 8x8 곱셈기를 LUT/CARRY4 로 합성한 것이었다.
    npu_pe 에 (* use_dsp = "yes" *) 적용 -> 여유 2.7% -> 7.1%.
    Fallback(PS FCLK 50 MHz, Latency 2.52 ms)은 그대로 남겨 둔다.

L8. BD 안에서 C 인터페이스가 0 으로 묶여 있다.
    evt_we/evt_addr/evt_data/input_stat -> xlconstant 0
    event_cfg/pan_cmd/tilt_cmd/laser_ctrl/safe_limit/track_err_* -> 미연결(합성 제거)
    -> C 모듈이 오면 tie 를 지우고 실제 연결. 그때 리소스/타이밍 재측정 필수.

L9. PS 인터럽트 핸들러 미작성.
    IRQ_F2P 배선과 CTRL.IRQ_EN 은 검증했지만 Vitis 쪽 핸들러는 없다.
    폴링만으로도 충분하다 (Latency 1.26 ms).
```

## 8. Timing / Resource Result

xc7z020clg400-1 (Zybo Z7-20), 100 MHz 제약. **전부 배치배선 후 실측.**

| 항목 | `npu_core` | `top_system` (+AXI) | **전체 시스템 (bitstream)** | 전체 | 비율 |
|---|---:|---:|---:|---:|---:|
| Slice LUT | 573 | 1060 | **1441** | 53200 | 2.71% |
| Slice Register | 279 | 849 | **1392** | 106400 | 1.31% |
| Block RAM Tile | 8 | 8 | **8** | 140 | 5.71% |
| DSP48E1 | 12 | 12 | **12** | 220 | 5.45% |

```text
npu_core 단독 (OOC)      WNS = +0.994 ns , WHS = +0.054 ns , Fmax 111.0 MHz
top_system (+AXI, OOC)   WNS = +0.302 ns , WHS = +0.100 ns   (OOC 리셋트리 부재 인공물)
전체 시스템 (bitstream)  WNS = +0.782 ns , WHS = +0.043 ns , Fmax 107.7 MHz
-> 전부 TIMING MET

산출물: results/npu_soc.bit , results/npu_soc.xsa
```

> a_npu_v01 초판(Phase 1)은 LUT 1373 / WNS +0.266 ns / Fmax 102.7 MHz 로 보고했다.
> `npu_pe` 에 `use_dsp="yes"` 를 적용해 재측정한 위 값이 유효하다.

**Latency**

| Layer | 누적 cycle |
|---|---:|
| Conv1 | 35,843 |
| Conv2 | 81,415 |
| Conv3 | 122,635 |
| Conv4 | 125,775 |
| Argmax + 종료 | **125,845** |

```text
125,845 cycle @ 100 MHz = 1.258 ms
```

cycle 수는 데이터에 의존하지 않는 고정 구조라 실제 weight 로 바꿔도 동일하다.

## 9. 검증 결과

| Testbench | 대상 | 결과 |
|---|---|---|
| `tb_npu_requant` | Requantize 3150 case (경계·tie·M 최대값 포함) | PASS, bit-exact |
| `tb_npu_pe` | INT8 MAC 300회 + clr/en | PASS |
| `tb_npu_conv_dense` | Conv1 단독, 8192 byte 전수 비교 | PASS |
| `tb_npu_full` | Conv1/2/3/4 + Argmax 전체 | PASS |

`tb_npu_full` 레이어별 전수 비교:

```text
Conv1  8192 byte  일치
Conv2  4096 byte  일치
Conv3  2048 byte  일치
Conv4    64 byte  일치
Argmax  target=(52,28) score=127  일치
```

재현:

```bash
python3 tools/gen_dummy.py && python3 tools/gen_requant_tv.py
./sim/run_sim.sh
cd build && vivado -mode batch -source ../sim/run_synth.tcl
```

## 10. B / C 에게 필요한 것

| # | 상대 | 내용 |
|---|---|---|
| 1 | B | `nn.Conv2d(padding=?)` = 1 확인 |
| 2 | B | 표적 없는 프레임의 Heatmap max score 분포 → `score_th` 확정 |
| 3 | B | 실제 `conv{1..4}_weight_int8.mem`, `requant_M.mem`, layer별 golden hex |
| 4 | C | `ext_we/ext_addr/ext_data` 방식 수용 여부 |
| 5 | B/C | `docs/freeze/D3_FREEZE_REQUEST_A_001.md` 승인 |
