# 프로젝트 진행상황

> 기준점: 2026-08-30 A RTL/SoC/PS 합류 + B v04 데모 전달물 + C `c_event_v04/c_control_v09`
>
> 현재 판정: **통합 소스·호스트 회귀 완료, 최신 보드·카메라 Closed-loop 재검증 대기**

## 한눈에 보기

공유 저장소에 A의 Dense INT8 NPU, AXI/SoC, PS 드라이버와 A/C 통합 Top이 합류했다.
B의 활성 모델은 `model_v04_demo_masked_radius1_x1`이며 통제된 파란 표적용
`DEMO-MASKED-PASS / DEMO_ONLY`다. C의 Event/Control/4-Servo/Laser Interlock은 기존
`c_event_v04/c_control_v09`를 보존했다.

```text
PC Color Camera
  -> HSV Blue Mask + Frame Difference
  -> UART -> PS Tensor Load (INPUT_SRC=0)
  -> AXI -> PL Dense INT8 NPU
  -> target_valid/x/y/score
  -> C Tracking -> 4 Servo -> Laser Safety Interlock
```

Live 구현은 존재하지만 실제 카메라·Servo·레이저 전체 경로 성공을 아직 주장하지 않는다.

## 역할별 상태

| 영역 | 현재 상태 | 검증 |
|---|---|---|
| B Model/Golden | v04 데모 전달물 반영 | B Validation Gate PASS, A Integer/RTL 회귀 PASS |
| A NPU RTL | `a_npu_v01` 반영 | Case 3개 × 전체 16 TB = 48/48 PASS |
| A AXI/SoC | `a_soc_v02`, `ifc_v0.5` | AXI/Top/A-C 통합 TB PASS |
| A PS Software | `a_sw_v05` | Driver 76 + CPU 21 check PASS |
| A Live Runtime | `a_live_v01` | Protocol/Host 90 check PASS; 실물 미실시 |
| C Event/Control | `c_event_v04/c_control_v09` 보존 | C 13 TB 341 PASS 및 기존 실물 기록 유지 |
| Timing | A+C full 100 MHz MET | WNS +0.618 ns, WHS +0.043 ns |
| 최신 보드 조합 | Bit/ELF 생성 기록 있음 | **v04 보드 재시험 대기** |

상세 재현 결과는 `A_INTEGRATION_VERIFICATION.md`, Version과 산출물 지문은
`integration_manifest.md`를 따른다.

## 현재 Golden

| Case | Target `(x,y)` | Score | Valid | Cycle |
|---|---:|---:|:---:|---:|
| case00 | `(36,28)` | 43 | 1 | 125,845 |
| case01 | `(4,4)` | 101 | 1 | 125,845 |
| case02 | `(4,4)` | 0 | 0 | 125,845 |

## 완료된 핵심 항목

- A NPU RTL, AXI wrapper, A-only/A+C Top과 Testbench 반영
- `0x58/0x5C` C 상태 RO, `CTRL[5] HW_START_EN`, VERSION `0x4E50_0101`
- C 실제 Event/Control RTL 연결과 100 MHz implementation MET 기록
- PS Driver, MMIO Mock, 자체시험, CPU Baseline, Unified/Classic Vitis 빌드 경로
- PC↔보드 NPUL v1 UART/CRC protocol과 Live Runtime 구현
- v04 Weight/Golden/Test Vector 및 생성 헤더/bank 일관성 반영
- 생성 가능한 Bitstream/XSA/ELF를 Git에서 제외하고 체크섬만 기록

## 남은 Gate

| 우선순위 | 작업 | 담당 |
|---:|---|---|
| 1 | 최신 v04 `npu_soc_cfull.bit + npu_test.elf`로 STEP 1~7 재시험 | A |
| 2 | Golden replay/zero/corrupt UART 시험 | A |
| 3 | 실제 Camera에서 Mask·Tensor·연속 추론 확인, Laser 미연결 | A/B |
| 4 | Servo 축 방향, FOV, 2 m Offset, 안전 범위 실측 | C |
| 5 | 소비전류·광출력 등급·default-OFF·물리 NC E-stop 확인 | C/팀 |
| 6 | Laser 미연결 Closed-loop 확인 후에만 최종 안전 승인 | A/C |
| 7 | PS→PL Event bridge와 `WINDOW_SRC=1` 필요 여부 결정 | A/C |

## 안전·표현 제한

- v04는 `model_v04 FINAL`이나 범용 인식 모델이 아니다.
- No-target FPR 0%는 승인된 Color Mask 적용 조건의 수치다.
- 실제 Laser는 물리 안전 Gate 전부 확인 전 연결하지 않는다.
- 정적 Golden/호스트 PASS를 실제 Camera Closed-loop 성공으로 바꿔 기록하지 않는다.
