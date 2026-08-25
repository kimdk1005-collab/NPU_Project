# A 역할 — NPU RTL

> 소유: A · 정본: `docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md` §5.1

Dense INT8 NPU와 Argmax RTL의 정식 작업 경로다.

예상 소스:

- `npu_pe.v`
- `npu_conv_dense.v`
- `npu_requant.v`
- `npu_datapath.v`
- `npu_controller.v`
- `npu_core.v`
- `argmax_decoder.v`
- 선택 확장: `npu_conv1_sparse.v`

규칙:

1. B의 `weights/`, `test_vectors/`, `golden_outputs/`를 수치 기준으로 사용한다.
2. signed INT8, CHW 주소, Requant 규칙은 공통 SPEC과 `docs/interface_contract.md`를 따른다.
3. 검증 코드는 `tb/npu/`에 둔다.
4. C 연결 포트를 바꿀 때는 Change Request와 팀 승인 후 반영한다.
5. Vivado 생성물과 Bitstream은 이 폴더에 커밋하지 않는다.
