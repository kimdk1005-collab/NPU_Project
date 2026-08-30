# integration_manifest — 현재 통합 Version과 지문

> 소유: A/B/C · 갱신: 2026-08-30
>
> 아래 Version Lock이나 산출물 조합이 다르면 통합 Debug를 시작하지 않는다.

## 1. Version Lock

```text
PROJECT_SPEC     = common_v1.5-A1
ROLE_SPEC        = role_v1.6
PLAN_SPEC        = plan_v1.4
INTERFACE        = ifc_v0.5

MODEL            = model_v04_demo_masked_radius1_x1
WEIGHT           = weight_v04
GOLDEN           = golden_v04
TEST_VECTOR      = testvec_v04
B_PREPROCESS     = color_masked_event_v02_radius1
B_PROFILE        = DEMO_BLUE_01 / DEMO-MASKED-PASS / DEMO_ONLY

A_NPU            = a_npu_v01
A_SOC            = a_soc_v02
A_SOC_C          = a_soc_c_v03
A_SW             = a_sw_v05
A_LIVE           = a_live_v01
C_EVENT          = c_event_v04
C_CONTROL        = c_control_v09
```

## 2. B 전달물

| 항목 | 값 |
|---|---|
| B source approval commit | `487b2a02dcbfb77fb77a6b591b0d20215f1ae3fa` |
| B payload commit | `1d4421b394e7d675a784ecebd246af718024e142` |
| Final ZIP | `b_deliver_v04_demo_masked_radius1_x1_final.zip`, 77,374 B |
| Final ZIP SHA-256 | `1f3034c16214b087798e945bff2c1ad157be496191524637dc159399e7a4b210` |
| ZIP/Manifest/Payload 검사 | `unzip -t PASS`, `34/34 PASS`, `25/25 identical` |
| Checkpoint SHA-256 | `578d3aaa8ce20ff038c45d290e4b6d8cf6c2ab6ddfcfaed28a5f448754436a96` |
| Preprocess source SHA-256 | `c02d6993ce7ed92e1a8c86ecdb1cf60c6518780a6a66dd250af97efd0857f0f2` |
| Preprocess config SHA-256 | `f6533bc7a8fe97e915ddd8dab7ff397086501a248eb142728c708ab222e47036` |

현재 추적 파일의 전수 지문은 `../golden_outputs/model_v04_demo_manifest.json`이 정본이다.
ZIP과 비공개 Dataset은 Git에 넣지 않는다.

## 3. A/C 통합 측정

| 대상 | LUT | FF | BRAM | DSP | WNS | WHS | 판정 |
|---|---:|---:|---:|---:|---:|---:|:---:|
| A-only BD | 1,465 | 1,393 | 8 | 12 | +1.203 ns | +0.044 ns | MET |
| A+C full BD | 2,324 | 2,188 | 12 | 18 | +0.618 ns | +0.043 ns | MET |
| A+C full no-runtime-limit | 2,164 | 2,055 | 12 | 18 | +0.929 ns | +0.044 ns | MET, debug only |
| `top_system_c` OOC | 1,975 | 1,693 | 12 | 18 | +0.197 ns | +0.106 ns | MET |

환경은 Zybo Z7-20 `xc7z020clg400-1`, Vivado 2024.2, 100 MHz다. 생성 리포트는
정책상 커밋하지 않으며 `A_INTEGRATION_VERIFICATION.md`에 재현 명령을 기록한다.

## 4. 로컬 생성 산출물 체크섬

아래 파일은 **Git에 포함하지 않는다**. 보드에 올릴 때 로컬 산출물과 값이 일치하는지 확인한다.

| 파일 | bytes | md5 | 용도 |
|---|---:|---|---|
| `npu_soc.bit` | 4,045,674 | `a54587d681877b1e52ebb81f916f79a3` | A-only |
| `npu_soc.xsa` | 424,652 | `f4dff11507d3be21741b4a4f6ab10006` | A-only Vitis input |
| `npu_soc_cfull.bit` | 4,045,674 | `b6119c0402d77d615e59cc3333b03c7a` | A+C 정식, 100 MHz MET |
| `npu_soc_cfull.xsa` | 460,714 | `5b62fa40100f356b5938270187360c4a` | A+C Vitis input |
| `npu_test.elf` | 232,960 | `833eb0fbadd7e92b8536d161cd604a18` | 자체시험 STEP 1~7 |
| `live_tracker.elf` | 144,308 | `cb23a4d4306c669d428663d4a8356ed7` | Live Runtime |

Bitstream과 ELF는 Weight/Golden이 내장되므로 반드시 같은 Version Lock의 짝을 사용한다.

## 5. 검증 상태

```text
RTL simulation      Case 3 × 16 TB = 48/48 PASS
PS driver           76 check PASS
CPU baseline        21 check PASS
Live host/protocol  90 check PASS
ARM cross compile   PASS
Repository policy   PASS 목표, PR 전 재실행
Latest board v04    NOT VERIFIED
Live camera         NOT VERIFIED
```

## 6. 현재 결선과 보류 항목

- Live는 `INPUT_SRC=0 + PS-managed START`를 사용하며 Register Map을 바꾸지 않는다.
- C 하드웨어 Event 경로의 `src_*`는 실제 Event Source bridge가 없어 BD에서 0에 묶인다.
- `WINDOW_SRC=1`과 PS→PL Event bridge는 별도 승인·구현 전까지 사용하지 않는다.
- Servo/FOV/Offset과 실제 Laser 안전 수치는 실측 전까지 미확정이다.
