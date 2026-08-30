# A 역할 — Dense INT8 NPU RTL

> 소유: A · 수치 계약: `../../docs/interface_contract.md`

`64×64×2` CHW signed INT8 Tensor를 4-Layer TinyCNN으로 계산하고, 8×8 Heatmap의
FIRST_MAX 좌표를 출력한다.

## 구성

| 파일 | 역할 |
|---|---|
| `npu_core.v` | NPU 최상위, 입력 쓰기·제어·결과 출력 |
| `npu_controller.v` | Conv1~4 실행 순서와 cycle 제어 |
| `npu_datapath.v` | Activation/Weight/Requant 데이터 경로 |
| `npu_conv_dense.v` | Dense convolution engine |
| `npu_pe.v` | 병렬 MAC PE, DSP 사용 지시 포함 |
| `npu_requant.v` | Q24 ties-away-from-zero Requant |
| `npu_act_buf.v` | Activation memory |
| `npu_weight_rom.v` | 8-bank Weight ROM |
| `argmax_decoder.v` | 8×8 YX raster FIRST_MAX 및 좌표 변환 |
| `npu_defs.vh` | Layer 형상·주소·기본 경로 상수 |

현재 Weight는 `model_v04_demo_masked_radius1_x1`용이며 `DEMO_ONLY`다. 모델 파일을
바꿀 때는 `weights/`, `test_vectors/`, 생성 헤더와 bank 파일을 하나의 Version Lock으로
함께 갱신한다.

```bash
./sim/run_sim.sh
TV_DIR=../test_vectors/case01/ ./sim/run_sim.sh
TV_DIR=../test_vectors/case02/ ./sim/run_sim.sh
```

Vivado/Vitis 프로젝트와 Bitstream은 커밋하지 않는다.
