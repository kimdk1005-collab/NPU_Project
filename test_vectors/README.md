# B 역할 — 공식 Test Vector

> 소유: B · C의 `sim/event_vectors/`와 구분되는 팀 공식 입력

NPU 입력 Tensor와 필요 시 각 Layer 비교용 Vector를 둔다. 각 묶음에는 다음 정보를
포함한다.

- 입력 shape·dtype·memory order
- 연결된 Weight/Golden 버전
- 생성 명령과 random seed
- 파일 크기와 checksum

A는 이 경로의 Vector로 `tb/npu/` 회귀시험을 수행한다.
