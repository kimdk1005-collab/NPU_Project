# A Handoff — Dense INT8 NPU / AXI / SoC / PS

> 상태: **A RTL·PS 소스 및 A/C 통합 Top 반영 완료**
>
> 버전: `a_npu_v01 / a_soc_v02 / a_soc_c_v03 / a_sw_v05 / a_live_v01`
>
> 갱신: 2026-08-30

## 1. NPU 계약

```text
Clock          100 MHz single clock
Reset          active-low
Input          64×64×2 signed INT8, CHW
Address        (polarity << 12) | (y << 6) | x
Conv           2→8→16→32→1, Dense Cross-Correlation, bias 없음
Requant        Q24, ties-away-from-zero
Output         8×8 Heatmap → YX raster FIRST_MAX
Coordinate     target_x/y = heatmap_x/y × 8 + 4
Valid          signed target_score > signed SCORE_TH
Latency        125,845 cycle = 1.258 ms @100 MHz
```

`npu_core`의 `target_*` 출력은 `done` 이후 다음 `start`까지 유지한다. 입력은 `busy=0`일
때만 쓴다.

## 2. AXI/통합 계약

```text
Base/Range     0x4000_0000 / 4 KiB
Interface      ifc_v0.5
VERSION        0x4E50_0101
START          PS-managed 또는 Direct 중 하나만 사용
C Status       0x58 SERVO_POS_STAT / 0x5C CONTROL_STAT
```

`CTRL[5] HW_START_EN=0`이 reset 기본값이다. Direct 모드에서는 `INPUT_SRC=1`과 함께
C `tensor_start`를 사용하며 PS가 `CTRL.START`를 쓰지 않는다. PS-managed 모드는
`TENSOR_READY`를 확인한 뒤 `CTRL.START`를 쓴다.

Top 구성:

- `rtl/integration/top_system.v`: A-only AXI+NPU
- `rtl/integration/top_system_c.v`: A NPU + C `c_event_control_top`
- `rtl/integration/c_module_stub.v`: 합성 비교용, 최종 C 대체물이 아님

## 3. PS 소프트웨어

`npu_driver`는 Xilinx BSP에 직접 의존하지 않아 동일 로직을 호스트 MMIO Mock과 보드에서
검증한다. `STATUS.DONE` sticky bit를 폴링하며 START 직후 `BUSY`만 보고 종료를 판단하지
않는다.

```bash
cd sw
make test       # 76 check
make cpu        # 21 check
make live       # 90 check
make arm        # Cortex-A9 cross compile
```

보드 프로그램은 두 개다.

| 앱 | 목적 |
|---|---|
| `npu_test.elf` | 고정 Case00 자체시험 STEP 1~7 |
| `live_tracker.elf` | PC UART Tensor 수신과 연속 추론 |

ELF와 Bitstream은 저장소에 커밋하지 않고 `integration_manifest.md`의 체크섬으로 짝을
확인한다.

## 4. 활성 모델

```text
MODEL          model_v04_demo_masked_radius1_x1
PROFILE        DEMO_BLUE_01
DECISION       DEMO-MASKED-PASS
SCOPE          DEMO_ONLY
WEIGHT         weight_v04
GOLDEN         golden_v04
TEST_VECTOR    testvec_v04
PREPROCESS     color_masked_event_v02_radius1
```

Case00 기대값은 `valid=1, x=36, y=28, score=43, cycle=125845`다. 이 모델은 PS Color
Mask가 필수이며 일반 환경의 최종 `model_v04`가 아니다.

## 5. 재현과 측정

```bash
./sim/run_sim.sh
TV_DIR=../test_vectors/case01/ ./sim/run_sim.sh
TV_DIR=../test_vectors/case02/ ./sim/run_sim.sh
cd sw && make all
./tools/check_repository_structure.sh
```

2026-08-30 스냅샷에서 A 6종+C 9종+A/C 1종을 Case 3개로 실행해 48/48 TB가 통과했다.
호스트 SW는 Driver 76, CPU 21, Live 90 check가 통과했다. 현재 저장소에서의 재실행 기록은
`A_INTEGRATION_VERIFICATION.md`가 정본이다.

Vivado 2024.2 원본 측정:

| 대상 | LUT | FF | BRAM | DSP | WNS | WHS |
|---|---:|---:|---:|---:|---:|---:|
| A-only BD | 1,465 | 1,393 | 8 | 12 | +1.203 ns | +0.044 ns |
| A+C full BD | 2,324 | 2,188 | 12 | 18 | +0.618 ns | +0.043 ns |

모든 값은 100 MHz implementation 결과이며 합성 추정치가 아니다. `.rpt`와 생성 바이너리는
정책상 Git에서 제외하고 수치·명령·체크섬만 보존한다.

## 6. Known Limitation

- v04 데모 후보의 최신 Bitstream/ELF 보드 재시험은 아직 없다.
- Live의 Event Tensor 생성기는 A 재구성이며 B Dataset Builder와 bit-exact가 미확정이다.
- PS→PL 실제 Event Source bridge와 `WINDOW_SRC=1` 경로는 미구현이다.
- IRQ 배선은 있으나 PS interrupt handler는 없고 현재는 polling을 사용한다.
- 입력 Buffer는 ping-pong 내부 Buffer를 공유해 추론 중 다음 Window 선적재가 불가하다.
- Servo/FOV/Offset 및 실제 Laser의 물리 안전 수치는 별도 실측이 남아 있다.
