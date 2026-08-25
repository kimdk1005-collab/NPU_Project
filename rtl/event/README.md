# C 역할 — Event RTL

> 소유: C · 정본: `handoff/C_EVENT_CONTROL_HANDOFF.md`

Event Source 좌표를 64×64로 변환하고 2채널 CHW Tensor를 생성하는 경로다.

주요 소스:

- `event_adapter.v`
- `event_accumulator.v`

검증:

```bash
./sim/run_xsim.sh tb_event_adapter
./sim/run_xsim.sh tb_event_accumulator
./sim/run_xsim.sh tb_event_pipeline
```

Tensor order, polarity, Window 또는 A NPU write 포트를 바꿀 때는 공통 SPEC과 Interface
Contract를 먼저 갱신하고 A/B 영향을 확인한다.
