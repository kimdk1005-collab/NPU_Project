# A 역할 — SoC 통합 RTL

> 소유: A · `top_system.v`는 공유 파일이므로 단독 인터페이스 변경 금지

NPU AXI, PS 연결, C Event/Control 모듈을 묶는 최종 통합 경로다.

예상 소스:

- `npu_axi.v`
- `top_system.v`
- 통합 중 필요한 검증용 stub 또는 wrapper

통합 전 확인 순서:

1. `docs/integration_manifest.md`의 버전·지문 확인
2. `docs/C_TO_A_REPLY_004.md`의 stub → C actual 교체 절차 확인
3. Direct START와 PS-managed START 중 하나만 선택
4. Event Source, Arm/E-stop, `0x58`/`0x5C` 상태 포트 연결
5. 전체 TB, implementation, DRC, timing 재측정

Block Design과 Vivado 프로젝트 사본은 커밋하지 않는다.
