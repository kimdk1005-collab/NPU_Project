# A 역할 — NPU Testbench

> 소유: A · Golden: `../../test_vectors/caseNN/`

| Testbench | 검증 범위 |
|---|---|
| `tb_npu_requant.v` | Q24 반올림·Clamp 경계 |
| `tb_npu_pe.v` | signed INT8 MAC |
| `tb_npu_conv_dense.v` | Conv1 Dense 연산 |
| `tb_npu_full.v` | Conv1~4 Layer bit-exact, Argmax, latency |

AXI/Top Testbench는 `../integration/`에 있다. 기본 실행은 `case00`, 다른 Case는
`TV_DIR`로 선택한다.

```bash
./sim/run_sim.sh
TV_DIR=../test_vectors/case01/ ./sim/run_sim.sh
TV_DIR=../test_vectors/case02/ ./sim/run_sim.sh
```

각 실행은 A 6종, C 9종, A/C 통합 1종의 자동판정 결과를 출력한다.
