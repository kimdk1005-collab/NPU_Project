# B 역할 — Integer Golden Output v03

> 소유: B · Version: `golden_v03` · A RTL의 bit-exact 판정 기준

전달 규격상 Layer 출력은 입력과 함께 `test_vectors/case00~02/`에 둔다. 이 폴더의
`model_v03_manifest.json`은 Weight·Test Vector·Layer Golden·Handoff 25개 파일의
버전과 SHA-256을 묶는 정본 Manifest다. Golden을 이 폴더에 중복 복사하지 않는다.

정수 기준:

- Dense Cross-Correlation, bias 없음
- OIHW Weight
- INT32 accumulator
- Q24, ties-away-from-zero requantization
- Conv1~3 ReLU/clamp `[0,127]`, Conv4 clamp `[-128,127]`
- YX raster FIRST_MAX Argmax

```bash
python ai/verify_b_delivery.py --root .
```

이 명령은 checkpoint→Weight 5,936개와 case 3개 Conv1~4 전체 Tensor를 독립 정수
연산으로 비교한다.
