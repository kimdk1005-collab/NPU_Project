# A 역할 — PS 소프트웨어

> 소유: A · 대상: Zynq PS와 NPU AXI 제어

예상 소스:

- `npu_regs.h` — AXI 레지스터 정의
- `npu_driver.c` — NPU 제어 드라이버
- `npu_test.c` — 보드 자체시험
- `sim/` — 호스트 Mock과 드라이버 테스트
- Vitis 재현용 빌드 스크립트

레지스터 값은 `docs/interface_contract.md`와 공통 SPEC을 따른다. ELF, BSP, Vitis
workspace와 자동 생성 파일은 커밋하지 않고 재현 가능한 소스·스크립트만 관리한다.
