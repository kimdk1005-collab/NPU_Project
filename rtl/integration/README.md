# A 역할 — AXI/SoC 통합 RTL

> 소유: A · 공유 인터페이스 변경은 Change Request 승인 후 반영

| 파일 | 역할 |
|---|---|
| `npu_axi.v` | AXI4-Lite Register, 입력 RAM 접근, START/상태/IRQ |
| `top_system.v` | NPU와 AXI wrapper의 A-only Top |
| `top_system_c.v` | A NPU + C Event/Control 실제 RTL 통합 Top |
| `c_module_stub.v` | C 실물 없이 합성할 때만 쓰는 자리표시자 |

현재 계약은 `ifc_v0.5`, AXI Base `0x4000_0000/4 KiB`, VERSION
`0x4E50_0101`이다. `0x58/0x5C` C 상태 RO와 `CTRL[5] HW_START_EN`을 포함한다.
PS-managed START와 Direct START는 동시에 사용하지 않는다.

```bash
./sim/run_sim.sh tb_npu_axi tb_top_system tb_top_system_c
```

전체 구성과 검증 상태는 `../../docs/A_NPU_HANDOFF.md`와
`../../docs/A_INTEGRATION_VERIFICATION.md`를 따른다. `top_system_c.v`에서 C 소유 RTL의
동작이나 포트를 임의 변경하지 않는다.
