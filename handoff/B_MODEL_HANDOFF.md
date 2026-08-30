# B Handoff — v04 데모 Model·Quantization·Integer Golden

> 상태: **B 최종 전달 수령 · A 통합 회귀 완료**
>
> 소유: B · 상위 계약: `../docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md` v1.5
>
> 범위: `DEMO_BLUE_01`의 통제된 파란 표적 시연용 **`DEMO_ONLY`**

## 1. Version Lock

```text
MODEL          = model_v04_demo_masked_radius1_x1
WEIGHT         = weight_v04
GOLDEN         = golden_v04
TEST_VECTOR    = testvec_v04
PREPROCESS     = color_masked_event_v02_radius1
DECISION       = DEMO-MASKED-PASS
SCOPE          = DEMO_ONLY
BASE_SPEC      = common_v1.5
```

이 후보는 `model_v04 FINAL`이 아니며 외부 Test 540개를 후보 선택이나 최종 평가에 사용하지
않았다. 범용 물체 인식 또는 일반 환경 성능으로 표현하지 않는다.

## 2. 모델·수치 계약

| 항목 | 계약 |
|---|---|
| Input | `(2,64,64)` signed INT8, CHW; ch0 Positive, ch1 Negative |
| Conv1 | `2→8`, 3×3/s2/p1, ReLU |
| Conv2 | `8→16`, 3×3/s2/p1, ReLU |
| Conv3 | `16→32`, 3×3/s2/p1, ReLU |
| Conv4 | `32→1`, 1×1/s1/p0, ReLU 없음 |
| Weight | OIHW signed INT8, symmetric per-layer, zero-point 0 |
| Requant | Q24, ties-away-from-zero, bias 없음 |
| Target | 8×8 YX raster FIRST_MAX, `x/y=cell×8+4` |
| Valid | signed `target_score > SCORE_TH`, 현재 `SCORE_TH=0` |

Requant Multiplier는 `36020 / 93889 / 32112 / 26845`다.

## 3. 승인 성능

| Gate | 실측 | 판정 |
|---|---:|:---:|
| FP32 Validation exact Cell Accuracy | 92.6418% (`1045/1128`) | PASS |
| INT8 Validation exact Cell Accuracy | 92.0213% (`1038/1128`) | PASS |
| INT8 error median / p95 | `0 px / 8 px` | PASS |
| FP32→INT8 Accuracy 하락 | 0.6206 pp | PASS |
| FP32/INT8 Cell Agreement | 97.0745% (`1095/1128`) | PASS |
| Target TPR at `SCORE_TH=0` | 99.8227% | PASS |
| No-target FPR at `SCORE_TH=0` | 0.0000% | PASS* |
| Integer Golden | bit-exact | PASS |

`*` FPR은 Color Mask가 적용된 입력에서만 성립한다. Agreement와 p95는 승인 경계에 여유가
없으므로 안정적인 범용 모델로 해석하지 않는다.

## 4. 전달 파일

- `../weights/tiny_cnn_fp32_model_v04_demo_masked_radius1_x1.pt`
- `../weights/conv1_weight_int8.mem`~`conv4_weight_int8.mem`
- `../weights/requant_M.mem`, `../weights/scales.json`
- `../test_vectors/case00~02/`
- `../tools/live_demo/_b_original_color_masked_event.py.ref`
- `../tools/live_demo/color_masked_event_v02_radius1.json`
- `../golden_outputs/model_v04_demo_manifest.json`

B 최종 ZIP 수령 기록:

```text
archive       b_deliver_v04_demo_masked_radius1_x1_final.zip
bytes         77,374
sha256        1f3034c16214b087798e945bff2c1ad157be496191524637dc159399e7a4b210
integrity     unzip -t PASS
manifest      34/34 PASS
payload cmp   25/25 identical
B payload     1d4421b394e7d675a784ecebd246af718024e142
```

ZIP 자체는 저장소에 넣지 않는다. 개별 추적 파일은 현재 Manifest로 다시 검증한다.

## 5. 공식 Test Vector

| Case | 목적 | Target `(x,y)` | Score | Valid@0 |
|---|---|---:|---:|:---:|
| case00 | held-out 표적 | `(36,28)` | 43 | 1 |
| case01 | 합성 경계·Padding | `(4,4)` | 101 | 1 |
| case02 | 합성 zero-input | `(4,4)` | 0 | 0 |

```bash
python ai/verify_b_delivery.py --root .
./sim/run_sim.sh
TV_DIR=../test_vectors/case01/ ./sim/run_sim.sh
TV_DIR=../test_vectors/case02/ ./sim/run_sim.sh
```

## 6. 필수 전처리와 운용 제한

동일 카메라의 이전/현재 Color Frame에서 Event Tensor를 만들고 HSV Blue Gate, Blob 면적
Gate, 64×64 resize, radius-1 dilation을 적용한다. Mask가 없으면 Tensor를 모두 0으로
만든다. Runtime 경로에서 이 전처리를 빼거나 변경하면 승인 입력 분포가 아니다.

Live의 Event Tensor 생성부는 A가 규격과 Case로 재구성한 코드이며 B의 Dataset Builder와
bit-exact하다는 증거는 없다. Golden 재현은 `--replay-hex`를 사용한다.

## 7. 남은 검증

- 최신 v04 Bitstream/ELF 조합의 보드 자체시험
- 실제 카메라에서 Mask와 연속 추적 동작
- Servo 축 방향·FOV·Offset 실측
- KY-008 소비전류, 광출력 등급, 물리 NC E-stop과 default-OFF 확인

위 항목을 완료하기 전에는 실시간 Closed-loop 전체 성공이나 레이저 자동 시연 완료로 표시하지
않는다.
