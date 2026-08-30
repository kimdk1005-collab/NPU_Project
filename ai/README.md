# B 역할 — CNN·Quantization·Integer Golden

> 소유: B · 활성 배포: `model_v04_demo_masked_radius1_x1` · 범위: `DEMO_ONLY`

이 폴더의 학습·평가 코드는 v03 계보를 재현한다. 현재 배포 후보 v04는 B 최종 전달물에서
checkpoint, INT8 Weight, Golden과 전처리 정본을 가져왔으며, 비공개 Dataset과 원본 평가
묶음은 이 저장소에 포함하지 않는다.

## 공통 계약

```text
입력           64×64×2 signed INT8, CHW
채널           ch0=Positive, ch1=Negative
Conv           2→8→16→32→1, bias 없음
Conv1~3        3×3, stride=2, pad=1, Cross-Correlation, ReLU
Conv4          1×1, stride=1, pad=0, ReLU 없음
출력           8×8 signed INT8 Heatmap
Argmax         YX raster FIRST_MAX
좌표           target = heatmap_cell × 8 + 4
```

v04 데모 후보는 `color_masked_event_v02_radius1` 전처리가 필수다. 전처리 정본과 Live
실행 코드는 `../tools/live_demo/`에 있다.

## 환경과 현재 산출물 검증

```bash
python3 -m venv .venv
.venv/bin/pip install -r ai/requirements.txt
.venv/bin/python ai/train.py --mode self-test
.venv/bin/python ai/verify_b_delivery.py --root .
```

`verify_b_delivery.py`는 활성 Version Lock을 읽어 checkpoint→OIHW INT8 Weight, Q24
Multiplier, case00~02 Conv1~4 Golden과 Manifest SHA-256을 검증한다. 모델을 재학습하거나
현재 승인 파일을 다시 선택하는 명령이 아니다.

현재 성능과 제한은 `../handoff/B_MODEL_HANDOFF.md`, 실제 파일 지문은
`../golden_outputs/model_v04_demo_manifest.json`을 따른다.
