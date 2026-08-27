# model_v03 Final Accuracy Report

## 선택된 Model

- Canonical checkpoint: `weights/tiny_cnn_fp32_model_v03.pt`
- Source candidate: `weights/strict_candidates/c5_score_gentle.pt`
- Model-state SHA-256: `706b01bdab4b66a16d79f2f51f886881bb77dbaa951d6b2a0b82a5f594662aba`
- 선택 원칙: Validation FP32 우선, Validation INT8 안정성 확인 후 Test 1회 평가
- 구조: 동결 `2→8→16→32→1`, bias 없음, Conv1~3 `3×3/s2/p1`, Conv4 `1×1/s1/p0`

## Dataset / Split

- Target Dataset: `ai/dataset_samples_target_v03_strict`
- Train / Validation / Test: **1152 / 256 / 256**
- Session: Train 3개 / Validation 1개 / Test 1개
- 엄격 Gate: active `8~1200`, target positive `>=4`, target event `>=8`, target/active `>=0.10`, positive argmax 필수
- Test policy: **validation 선택 완료 후 1회만 평가; Test에 맞춰 재학습하지 않음**

## 학습 Recipe

1. v02 init, D4 train-only, localization weight `2`, score weight `0`, LR `2e-4`, 350 epochs (best 339)
2. 1단계 checkpoint init, D4 train-only, localization weight `2`, score weight `0.01`, LR `1e-5`, best epoch `25`
3. Test loader는 두 단계 모두 생성하지 않음

## Validation

| 항목 | 결과 |
|---|---:|
| FP32 Cell Accuracy | 99.2188% |
| FP32 Mean MAE | 0.031 px |
| INT8 Cell Accuracy | 97.6562% |
| INT8 Mean MAE | 0.188 px |

## Final Held-out Test

| 항목 | 결과 |
|---|---:|
| FP32 Cell Accuracy | **98.4375%** |
| FP32 Mean MAE | 0.219 px |
| INT8 Cell Accuracy | **97.6562%** |
| INT8 Mean MAE | 0.359 px |
| FP32/INT8 Cell Agreement | 98.4375% |

## 해석 주의

이 정확도는 표적 칸의 Event 근거를 엄격 Gate로 확인한 Dataset에서의 위치 정확도다.
CNN 입력은 색상이 아닌 2채널 명암 Event이므로, 연속 시연의 무표적 오검출률은
`SCORE_TH` calibration 보고서에 별도로 기록한다.
