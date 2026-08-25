# B 역할 — CNN·Quantization·Integer Golden

> 소유: B · 정본: `docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md` §5.2

예상 소스:

- `dataset.py`
- `train.py`
- `quantize.py`
- `integer_golden.py`

학습 Label은 실제 추적 표적의 중심으로 생성한다. 레이저 점은 학습·검출 대상이 아니다.
모든 결과는 고정 seed, 입력 버전, 실행 명령을 기록해 다시 만들 수 있어야 한다.

산출물 경로:

- Weight/Scale: `weights/`
- 공식 입력·Layer Vector: `test_vectors/`
- Integer Golden 출력: `golden_outputs/`
- Accuracy·Quantization 보고서: `results/model/`
