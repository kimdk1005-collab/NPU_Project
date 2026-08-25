# B Handoff — Model·Quantization·Integer Golden

> 상태: **TEMPLATE — B 실제 산출물 전달 전**
>
> 소유: B · 상위 권한: `docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md`

아래 항목을 실제 산출물과 함께 채우고, 전달 시 `docs/integration_manifest.md`의 B 버전을
같이 갱신한다. 확인하지 않은 값은 추정하지 않고 `PENDING`으로 둔다.

## 1. Version

```text
MODEL          = PENDING
WEIGHT         = PENDING
GOLDEN         = PENDING
TEST_VECTOR    = PENDING
DATASET        = PENDING
```

## 2. 입력·출력 Shape

| 항목 | Shape / dtype / order | 비고 |
|---|---|---|
| NPU Input | `64×64×2`, signed INT8, CHW | 공통 SPEC 기준 |
| Conv1~4 | PENDING | Layer별 기록 |
| Heatmap | `8×8×1`, signed INT8 | ReLU 없음 |
| Target | `(valid, x, y, score)` | Argmax 규칙 포함 |

## 3. Dataset·Label

- Dataset 버전·출처:
- Train/Validation/Test 분할:
- Label 생성 방식:
- 실제 표적 중심 Label 확인:
- Laser 점을 학습 대상으로 사용하지 않았는지:

## 4. Weight·Quantization

- Weight 파일과 checksum:
- Layout·dtype·shape:
- Scale / Multiplier / Shift:
- Rounding / Clamp:
- 생성 명령과 random seed:

## 5. Test Vector·Integer Golden

- 입력 Vector 파일과 checksum:
- Layer별 Golden 파일과 checksum:
- `integer_golden.py` 재현 명령:
- Argmax / target_valid 판정 결과:

## 6. 품질·성능

| 항목 | 결과 | 환경·명령 |
|---|---:|---|
| FP32 Accuracy | PENDING | |
| INT8 Accuracy | PENDING | |
| FP32↔INT8 차이 | PENDING | |
| CPU FP32 Latency | PENDING | |
| CPU INT8 Latency | PENDING | |

## 7. A/C 영향과 승인 요청

- A가 적용해야 할 파일·Parameter:
- C Event Window/Polarity 영향:
- 공유 Interface 변경 요청:
- 필요한 승인:

## 8. Known Limitation·남은 작업

- PENDING

## 9. 전달 체크리스트

- [ ] `weights/` 실제 산출물과 checksum
- [ ] `test_vectors/` 공식 입력
- [ ] `golden_outputs/` bit-exact 기준
- [ ] `results/model/` Accuracy·Quantization 보고서
- [ ] 재현 명령·환경·seed
- [ ] `docs/integration_manifest.md` 버전 갱신
- [ ] A NPU TB 비교 결과 또는 전달 요청
