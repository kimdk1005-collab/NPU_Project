# B 역할 — CNN·Quantization·Integer Golden

> 소유: B · 정본: `../docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md` §5.2
> 상태: `model_v03 / weight_v03 / golden_v03 / testvec_v03` 최종 전달

## 파일

| 파일 | 용도 |
|---|---|
| `dataset.py` | 카메라 Preview, 표적/무표적 수집, 품질 Gate 및 Dataset 검사 |
| `train.py` | 고정 Tiny CNN 학습, Session Split, Hybrid Detection Loss |
| `eval_int8.py` | FP32/INT8 Cell Accuracy·MAE 평가 |
| `calibrate_score_th.py` | 표적/무표적 INT8 max-score 분포와 AUC 측정 |
| `export_b_delivery.py` | OIHW Weight, Q24 Multiplier, Test Vector·Golden 생성 |
| `verify_b_delivery.py` | checkpoint→INT8 Weight와 Conv1~4 Golden 독립 bit-exact 검증 |
| `generate_repo_manifest.py` | 공유 저장소 Weight·Golden·Handoff checksum Manifest 생성 |
| `benchmark_latency.py` | CPU FP32 및 Python/Numpy INT8 Golden 지연 실측 |
| `finalize_split_manifest.py` | Validation 선택 후 최종 Test 1회 평가 상태 고정 |
| `promote_v03_candidate.py` | 선택 후보를 canonical v03 checkpoint로 승격 |
| `V03_RESHOOT_RUNBOOK.md` | 강화 재촬영 조건과 품질 Gate 기록 |

## 고정 계약

```text
입력           64×64×2, signed INT8 logical Event Count
채널           ch0=Positive, ch1=Negative
NPU Memory     CHW
Conv           2→8→16→32→1, bias 없음
Conv1~3        3×3, stride=2, pad=1, Cross-Correlation, ReLU
Conv4          1×1, stride=1, pad=0, ReLU 없음
출력           8×8×1 signed INT8 Heatmap
Argmax         YX raster FIRST_MAX
좌표           target = heatmap_cell × 8 + 4
```

실제 표적은 파란 라벨을 부착한 흰 물체이며, 라벨 중심을 Teacher로 사용했다. 레이저
점은 학습·검출 대상이 아니다. 원본 카메라 Dataset과 Audit 이미지는 개인정보·용량
정책에 따라 공개 저장소에서 제외하고, Split·품질·checksum Manifest만 보존한다.

## 환경

Python 3.12 기준이며 의존성은 `requirements.txt`에 기록했다.

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r ai/requirements.txt
```

## 검증

Dataset 없이 공유 저장소의 최종 Weight·Golden을 검증할 수 있다.

```bash
python ai/train.py --mode self-test
python ai/verify_b_delivery.py --root .
./tools/check_repository_structure.sh
```

예상 결과:

```text
[PASS] B repository format / Version Lock / checksum
[PASS] checkpoint -> OIHW INT8 Weight / Q24 Multiplier
[PASS] case00~02 Conv1~4 Integer Golden bit-exact
```

## 최종 결과

| 항목 | FP32 | INT8 |
|---|---:|---:|
| Held-out Validation Cell Accuracy | 99.22% | 97.66% |
| Held-out Test Cell Accuracy | 98.44% | 97.66% |
| Held-out Test Mean MAE | 0.219 px | 0.359 px |

상세 학습 명령, seed, Dataset Gate와 알려진 제한은
[`B_MODEL_HANDOFF.md`](../handoff/B_MODEL_HANDOFF.md)를 따른다.
