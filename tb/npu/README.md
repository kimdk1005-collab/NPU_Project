# A 역할 — NPU Testbench

> 소유: A · 대상 RTL: `rtl/npu/`, `rtl/integration/`

예상 Testbench:

- `tb_npu_pe.v`
- `tb_npu_conv_dense.v`
- `tb_npu_requant.v`
- `tb_npu_full.v`
- 필요 시 `tb_npu_axi.v`, `tb_top_system.v`

판정은 B가 제공한 공식 `test_vectors/`와 `golden_outputs/`를 사용한다. 각 TB는 PASS 수,
실패 위치, 재현 명령을 로그에 명확히 출력하고 변경 PR에 실행 결과를 기록한다.
