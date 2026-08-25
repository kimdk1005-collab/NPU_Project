# B 역할 — Weight·Quantization Parameter

> 소유: B · 전달 규격: `docs/B_TO_A_DELIVERY_SPEC.md`

FP32/INT8 Weight, Scale, Multiplier, Shift 등 A의 RTL 재현에 필요한 확정 산출물을 둔다.
파일마다 모델 버전, Tensor 순서, dtype, shape, 생성 명령과 checksum을 함께 기록한다.
임시 학습 checkpoint와 재생성 가능한 대용량 캐시는 커밋하지 않는다.
