# B 역할 — Model v03 결과

> 소유: B · Dataset/Model/Quantization 결과 정본

## 최종 측정

| 항목 | FP32 | INT8 |
|---|---:|---:|
| Validation Cell Accuracy (256) | 99.22% | 97.66% |
| Validation Mean MAE | 0.031 px | 0.188 px |
| Test Cell Accuracy (256) | 98.44% | 97.66% |
| Test Mean MAE | 0.219 px | 0.359 px |
| FP32↔INT8 Cell Agreement | 98.44% | 98.44% |

Test는 Validation으로 후보를 확정한 뒤 한 번만 평가했다. 이전 보류본 INT8 55.47%와
비교하면 최종 INT8은 42.19 percentage points 높다. 강화 품질 Gate로 모집단이 달라
절대 비교에는 제한이 있다.

## 파일

| 파일 | 내용 |
|---|---|
| `model_v03_fp32_accuracy_report.md` | Dataset, 학습 설정, FP32 결과 |
| `model_v03_int8_accuracy.json` | 최종 held-out Test FP32/INT8 결과 |
| `model_v03_int8_validation.json` | 후보 선택 Validation FP32/INT8 결과 |
| `model_v03_train_history.json` | 두 단계 학습 설정·history·seed |
| `model_v03_split.json` | Session 기반 Train/Validation/Test 고정 목록 |
| `model_v03_latency.json` | CPU FP32·Python Golden INT8 지연 실측 |
| `model_v03_score_th_calibration.*` | 표적/무표적 score 분포와 AUC |
| `no_target_v03_manifest.json` | 비공개 무표적 NPZ 450개의 checksum·촬영 통계 |

## CPU Latency 환경

- Linux x86_64, Python 3.12.3, PyTorch 2.13.0+cpu, thread 1
- FP32 PyTorch eager: median 0.302 ms, p90 0.375 ms
- INT8 Python/Numpy Golden: median 0.690 ms, p90 0.771 ms
- INT8 값은 최적화 NPU kernel 지연이 아니며 FPGA 지연으로 사용하지 않는다.

## 알려진 제한

Held-out Validation의 표적/무표적 max-score AUC는 0.2972다. `SCORE_TH=0`의 TPR은
1.0이지만 FPR은 0.8이므로 단일 score threshold로 무표적 움직임을 안정적으로 억제하지
못한다. 위치 정확도와 별개의 제한이며, A는 N프레임 연속·위치 반경 R 시간 일관성 Gate를
우선 평가한다. 재학습이나 인터페이스 변경은 별도 합의 전 수행하지 않는다.
