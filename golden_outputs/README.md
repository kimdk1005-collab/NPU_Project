# B 역할 — Integer Golden Manifest

> 현재: `golden_v04`, `model_v04_demo_masked_radius1_x1`, `DEMO_ONLY`

Layer Golden 본체는 `../test_vectors/case00~02/`에만 두고 이 폴더에는 Version Lock,
결과와 파일별 SHA-256을 묶는 Manifest를 둔다.

- `model_v04_demo_manifest.json`: 현재 배포 후보의 Weight/Test Vector/Handoff 지문
- `model_v03_manifest.json`: 이전 v03 전달 이력; 현재 Weight와 함께 검증하는 정본이 아님

```bash
python ai/generate_repo_manifest.py --root .
python ai/verify_b_delivery.py --root .
```

검증기는 checkpoint→INT8 Weight, Q24 Multiplier, case00~02 Conv1~4 전 Tensor와
FIRST_MAX 결과를 독립 계산한다.
