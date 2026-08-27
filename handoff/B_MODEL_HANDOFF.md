# B Handoff — Model·Quantization·Integer Golden v03

> 상태: **B 최종 전달 완료 · A v03 RTL 회귀 18/18 PASS**
> 소유: B · 상위 권한: `../docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md` v1.5
> 전달 형식: `../docs/B_TO_A_DELIVERY_SPEC.md`

## 1. Version

```text
MODEL          = model_v03
WEIGHT         = weight_v03
GOLDEN         = golden_v03
TEST_VECTOR    = testvec_v03
DATASET        = v03_reshoot_1
BASE_SPEC      = common_v1.5
```

네 Version은 함께 고정한다. 이 PR은 이미 A가 검증한 v03 파일을 공유 저장소 형식으로
옮기는 작업이며 모델·Quantization·공통 인터페이스를 변경하지 않는다.

## 2. 입력·출력 Shape

| 항목 | Shape / dtype / order | 연산 |
|---|---|---|
| NPU Input | `(2,64,64)`, signed INT8, CHW | ch0 Positive, ch1 Negative |
| Conv1 | `(8,32,32)` | 3×3/s2/p1, bias 없음, ReLU |
| Conv2 | `(16,16,16)` | 3×3/s2/p1, bias 없음, ReLU |
| Conv3 | `(32,8,8)` | 3×3/s2/p1, bias 없음, ReLU |
| Conv4/Heatmap | `(1,8,8)`, signed INT8 | 1×1/s1/p0, bias 없음, ReLU 없음 |
| Target | `(valid,x,y,score)` | YX raster FIRST_MAX |

- Convolution은 kernel flip 없는 Cross-Correlation이다.
- Dataset 저장 HWC는 NPU dump 전에 `np.transpose(input, (2,0,1))`로 CHW 변환한다.
- 좌표는 `heatmap_x/y × 8 + 4`다.
- 기본 판정은 `target_valid = (target_score > SCORE_TH)`, `SCORE_TH=0`이다.

## 3. Dataset·Label

### 3.1 표적 있음

| Split | Session | Sample |
|---|---|---:|
| Train | `strict_train_a/b/c` | 1,152 |
| Validation | `strict_validation` | 256 |
| Test | `strict_test` | 256 |

총 1,664개이며 64개 Cell이 각 Split에서 균등하다. Validation/Test는 Train과 독립
촬영 Session이고 Test는 Validation으로 후보를 선택한 뒤 한 번만 평가했다.

품질 Gate:

```text
active_pixel_count              8..1200
target_positive_pixel_count     >= 4
target_event_pixel_count        >= 8
target/active_event_ratio       >= 0.10
positive_energy_argmax          == label_cell
```

### 3.2 무표적

Train/Validation/Test `250/100/100`, 총 450개다. Quiet와 손·케이블·비파란 물체
Motion을 독립 Session으로 수집했다. 모델 학습에는 Train Negative 250개를 포함했다.

### 3.3 Label과 공개 정책

- 실제 표적: 파란 라벨을 부착한 흰 물체
- Label: 동기 RGB Teacher의 파란 라벨 중심을 8×8 One-hot으로 변환
- 카메라: `/dev/video2`, 640×480, 30 FPS, 제조사 기본 자동 제어, 강제 보정 없음
- Laser 점은 학습·검출 대상이 아니다.
- 원본 NPZ와 RGB Audit은 공개 저장소에 넣지 않는다.
- Split과 no-target 파일별 checksum·통계는
  `../results/model/model_v03_split.json`과
  `../results/model/no_target_v03_manifest.json`에 기록한다.
- A 요청 무표적 원본 보충 ZIP은 별도 비공개 전달했다.
  SHA-256: `070e9029088772817b4a63d5a7a39a3d0aa66daa7a6f01750bf6e9b2d77b6523`

## 4. Weight·Quantization

### 4.1 파일

| 파일 | 줄 수 / 형식 |
|---|---|
| `../weights/conv1_weight_int8.mem` | 144, OIHW HEX byte |
| `../weights/conv2_weight_int8.mem` | 1,152, OIHW HEX byte |
| `../weights/conv3_weight_int8.mem` | 4,608, OIHW HEX byte |
| `../weights/conv4_weight_int8.mem` | 32, OIHW HEX byte |
| `../weights/requant_M.mem` | 4, 32-bit HEX |
| `../weights/scales.json` | Scale·Multiplier·Clamp·Version |
| `../weights/tiny_cnn_fp32_model_v03.pt` | canonical FP32 checkpoint |

FP32 checkpoint SHA-256:

```text
7592abb6ee06a3b41650e8013aefc4f4dcfbb556d1fc3cc66e7e185ab627ff53
```

### 4.2 Scale·Multiplier

| Layer | Input Scale | Weight Scale | Output Scale | M | Shift | Clamp |
|---|---:|---:|---:|---:|---:|---|
| Conv1 | 0.007874016 | 0.007793675 | 0.026933788 | 38226 | 24 | `[0,127]` |
| Conv2 | 0.026933788 | 0.007820195 | 0.060079364 | 58818 | 24 | `[0,127]` |
| Conv3 | 0.060079364 | 0.006448395 | 0.231290156 | 28102 | 24 | `[0,127]` |
| Conv4 | 0.231290156 | 0.015865157 | 2.678351695 | 22985 | 24 | `[-128,127]` |

- Weight: symmetric per-layer INT8, zero-point 0, clamp `[-127,127]`
- Activation: symmetric per-layer INT8, zero-point 0
- Rounding: ties-away-from-zero
- Requant: `(acc × M) / 2^24` 후 Layer clamp
- Bias: 없음
- 파일별 SHA-256: `../golden_outputs/model_v03_manifest.json`

## 5. 학습·재현 정보

- Seed: 42
- Split: capture Session 기반
- Train 증강: D4, polarity swap 사용 안 함
- Stage 1: 전체 Conv, `localization_weight=2`, `score_weight=0`, LR 0.0002
- Stage 2: Stage 1 checkpoint에서 `score_weight=0.01`, LR 0.00001
- 후보 선택: Validation FP32 위치 성능 후 Validation INT8 비교
- Test 정책: `ONE_TIME_AFTER_VALIDATION_SELECTION`

세부 명령과 epoch는 `../results/model/model_v03_train_history.json` 및
`../ai/V03_RESHOOT_RUNBOOK.md`를 따른다.

## 6. Test Vector·Integer Golden

각 `../test_vectors/caseNN/`은 `input_event.hex`, Conv1~4 출력과 `result_xy.txt` 6개를
포함한다. 모든 `.hex`는 CHW, 대문자 2자리 two's-complement byte다.

| Case | 목적 | Heatmap `(x,y)` | Target `(x,y)` | Score | Valid@0 |
|---|---|---:|---:|---:|:---:|
| case00 | 실제 held-out 표적 | `(4,3)` | `(36,28)` | 8 | 1 |
| case01 | 합성 경계·Padding | `(0,0)` | `(4,4)` | 126 | 1 |
| case02 | 합성 zero-input | `(0,0)` | `(4,4)` | 0 | 0 |

공유 저장소 독립 검증:

```bash
python ai/train.py --mode self-test
python ai/verify_b_delivery.py --root .
```

검증 범위:

- checkpoint FP32→INT8 Weight 5,936개 전수 일치
- OIHW, Q24 Multiplier, Version Lock, 파일 checksum
- case00~02 Conv1~4 Integer Golden bit-exact
- `result_xy.txt` 5줄과 FIRST_MAX 결과

## 7. 품질·성능

| 항목 | 결과 | 환경·근거 |
|---|---:|---|
| Validation FP32 Cell Accuracy | 99.22% | 256 target Sample |
| Validation INT8 Cell Accuracy | 97.66% | Integer Golden |
| Test FP32 Cell Accuracy | 98.44% | held-out target 256 |
| Test INT8 Cell Accuracy | **97.66%** | held-out target 256 |
| Test FP32 Mean MAE | 0.219 px | x/y 평균 |
| Test INT8 Mean MAE | **0.359 px** | x/y 평균 |
| FP32↔INT8 Cell Agreement | 98.44% | Test 256 |
| CPU FP32 Latency | median 0.302 ms, p90 0.375 ms | x86_64 PyTorch CPU, n=100 |
| CPU INT8 Golden Latency | median 0.690 ms, p90 0.771 ms | Python/Numpy, 최적화 kernel 아님 |
| A RTL Regression | **18/18 PASS** | 3 case × 6 TB, A 회신 2026-08-26 |
| A NPU Latency | 125,845 cycle = 1.258 ms | A RTL simulation 회신 |

FPGA/PS 보드 수치와 A CPU Baseline은 A 소유 측정이다. B의 host latency를 FPGA 또는
Cortex-A9 성능으로 사용하지 않는다.

## 8. A/C 영향과 승인 요청

### A 적용

1. `weights/` 6개 RTL 파일을 같은 Version 묶음으로 사용
2. `test_vectors/case00~02/`로 Layer 전수 회귀
3. `tools/pack_weights.py`로 bank 파일 생성
4. 무표적 시간축 Gate(N프레임 연속·위치 반경 R) 실측

### C 영향

- Event Tensor CHW 주소, polarity 순서, 64×64×2 계약 변경 없음
- Heatmap 좌표, `target_valid/x/y/score` 포트 변경 없음
- 모델 색상 분류 기능을 가정하지 않는다.

공유 Interface 변경 요청은 없다. 현재 v03 Weight/Golden을 유지하며 A가 별도로 요청하기
전에는 재학습하지 않는다.

## 9. Known Limitation·남은 작업

- 97.66%는 품질 Gate를 통과한 **표적 있음 Test 위치 Cell Accuracy**다.
- Held-out Validation max-score AUC는 0.2972다. `SCORE_TH=0`에서 TPR 1.0,
  FPR 0.8이므로 max score 하나로 무표적 움직임을 안정적으로 구분하지 못한다.
- 무표적 Motion의 Event 밀도가 표적 Dataset보다 높고, 최종 score loss 가중치는 0.01로
  작다. Negative 완전 부재나 AUC 계산 부호 오류는 아니다.
- `SCORE_TH=0`을 유지하지만 이를 무표적 안전판정 PASS로 해석하지 않는다.
- A 시간 일관성 Gate로도 오검출이 남고 일정이 허용될 때만 v04 재학습을 검토한다.

## 10. 전달 체크리스트

- [x] `weights/` FP32 checkpoint·INT8 Weight·Scale·Multiplier
- [x] `test_vectors/case00~02/` 공식 입력·Layer Golden·Argmax
- [x] `golden_outputs/model_v03_manifest.json` checksum 정본
- [x] `results/model/` Accuracy·Quantization·Latency·Split 보고서
- [x] 실행 환경·학습 설정·seed 기록
- [x] A v03 RTL 회귀 18/18 PASS 수신
- [x] 공통 Interface 변경 없음
- [x] 무표적 한계와 후속 담당 명시
