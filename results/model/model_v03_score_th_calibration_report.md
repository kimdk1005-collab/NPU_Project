# SCORE_TH INT8 Calibration Report

## 입력과 판정 경로

- Checkpoint: `weights/tiny_cnn_fp32_model_v03.pt`
- Target Dataset: `ai/dataset_samples_target_v03_strict`
- No-target Dataset: `ai/no_target_samples_v03`
- Evaluation Scope: **held-out `validation` only**
- Quantization Calibration: target `train_target` split (1152 Sample)
- Score Domain: **signed INT8 Conv4 output — 전달물 Integer Golden/RTL과 동일 경로**
- Valid 식: `target_valid = (heatmap_max_score > SCORE_TH)`

## 실측 분포

| 구분 | Sample | Min | Median | P90 | P95 | P99 | Max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 표적 있음 | 256 | 4 | 13.0 | 27.5 | 35.2 | 74.9 | 127 |
| 표적 없음 | 100 | 0 | 40.5 | 88.2 | 102.0 | 127.0 | 127 |

- AUC: `0.2972` (`0.5`는 무작위 수준)
- No-target p99 후보 임계값: `127`
- `SCORE_TH=0`: TPR `1.0000`, FPR `0.8000`
- `SCORE_TH=127`: TPR `0.0000`, FPR `0.0000`
- Youden 진단 후보 `1`: TPR `1.0000`, FPR `0.7900`

## 전체 수집분 진단

학습에 사용한 Sample까지 포함한 값은 임계값 선택 근거로 사용하지 않고 분포 이동 확인용으로만 기록한다.

- 품질 통과 표적 / 전체 무표적: 1664 / 450 Sample
- AUC: `0.2742`
- 표적/무표적 Score 중앙값: `14.0` / `55.0`

## 판정

Held-out 분리도와 전체 수집분 진단 사이에 차이가 있어 일반화된 임계값으로 동결하기에는
근거가 부족하다. 따라서 p99와 Youden 값은 **측정 결과일 뿐 확정 SCORE_TH가 아니다.**
A가 별도 정책 또는 Change Request를 승인하기 전까지 공통 규격 기본값 `SCORE_TH=0`을
유지하고, 본 보고서를 A의 미해결 질의에 대한 실측 회신으로 전달한다.
