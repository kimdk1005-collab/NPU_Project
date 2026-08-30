# A/B/C 통합 검증 기록

> 환경: Ubuntu x86_64 · Vivado/xsim 2024.2 · GCC · ARM GNU Toolchain 2024.2
>
> 대상: `model_v04_demo_masked_radius1_x1`, `ifc_v0.5`, `c_event_v04/c_control_v09`
>
> 실행일: 2026-08-30

## 1. RTL 회귀

```bash
./sim/run_sim.sh
TV_DIR=../test_vectors/case01/ ./sim/run_sim.sh
TV_DIR=../test_vectors/case02/ ./sim/run_sim.sh
```

각 실행은 A NPU/AXI 6종, C Event/Control 9종, A/C 통합 1종을 자동 판정한다.

| Vector | Testbench | 결과 | Golden |
|---|---:|:---:|---|
| case00 | 16 | PASS | `(36,28), score=43, valid=1` |
| case01 | 16 | PASS | `(4,4), score=101, valid=1` |
| case02 | 16 | PASS | `(4,4), score=0, valid=0` |
| 합계 | 48 | **48/48 PASS** | latency 125,845 cycle |

## 2. PS/호스트 회귀

```bash
cd sw
make test
make cpu
make live
```

| 시험 | 결과 | 범위 |
|---|---:|---|
| Driver + MMIO Mock | 76 PASS | Register, START/DONE, 오류, C 상태 |
| CPU Baseline | 21 PASS | FP32/INT8 Layer와 Golden |
| Live C protocol | 34 PASS | CRC, Frame parsing, 방어 조건 |
| Live Python protocol | 41 PASS | C와 동일 Frame, Case 왕복 |
| Live host end-to-end | 15 PASS | Python stream→C receiver, 재동기화 |

`make live`는 NumPy가 필요하다. 깨끗한 환경에서는 다음으로 설치한다.

```bash
python3 -m venv .venv
.venv/bin/pip install -r tools/live_demo/requirements.txt
PATH="$PWD/.venv/bin:$PATH" make -C sw live
```

## 3. ARM 컴파일

```bash
make -C sw arm \
  ARMCC=/opt/tools/Xilinx/Vitis/2024.2/gnu/aarch32/lin/gcc-arm-none-eabi/bin/arm-none-eabi-gcc
```

`npu_driver.c`, `npu_test.c`, `cpu_baseline.c`, `live_tracker.c`의 Cortex-A9 object 생성이
통과했다. 생성 object는 `sw/build/`에만 두며 Git에 포함하지 않는다.

## 4. Vivado implementation 기록

2026-08-30 원본 스냅샷에서 재생성한 결과다.

| 대상 | LUT | FF | BRAM | DSP | WNS | WHS |
|---|---:|---:|---:|---:|---:|---:|
| NPU core OOC | 573 | 278 | 8 | 12 | +0.752 ns | +0.122 ns |
| A-only Top OOC | 1,085 | 851 | 8 | 12 | +1.059 ns | +0.050 ns |
| A+C Top OOC | 1,975 | 1,693 | 12 | 18 | +0.197 ns | +0.106 ns |
| A-only BD | 1,465 | 1,393 | 8 | 12 | +1.203 ns | +0.044 ns |
| A+C full BD | 2,324 | 2,188 | 12 | 18 | +0.618 ns | +0.043 ns |

모두 100 MHz timing MET다. 저장소 정책에 따라 `.rpt`, `.bit`, `.xsa`, `.elf`는 추적하지
않고 재현 스크립트와 `integration_manifest.md`의 측정값·체크섬을 보존한다.

## 5. 이 기록이 증명하지 않는 것

- v04 조합의 최신 Zybo 보드 STEP 1~7 통과
- 실제 Camera에서 승인 전처리와 A 재구성 Event Tensor의 동일성
- Servo/FOV/Offset의 실물 보정
- Laser 소비전류·광출력 등급·물리 E-stop·default-OFF
- 실제 Camera→NPU→Servo→Laser 전 구간 Closed-loop 성공

위 항목은 `PROJECT_STATUS.md`에서 `NOT VERIFIED`로 유지한다.
