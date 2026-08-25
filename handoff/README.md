# 역할별 Handoff

통합 전에 각 역할은 자신의 산출물 버전, 포트·수치 계약, 검증 결과와 제한사항을 전달한다.

| 역할 | 정본 Handoff | 주요 내용 |
|---|---|---|
| A | `../docs/A_NPU_HANDOFF.md` | NPU/AXI/SoC 포트, Timing, PS 소프트웨어, Known Limitation |
| B | `B_MODEL_HANDOFF.md` | Model/Weight/Quantization/Golden/Accuracy |
| C | `C_EVENT_CONTROL_HANDOFF.md` | Event/Tracking/Servo/Laser 계약과 안전 검증 |

Handoff에 기록한 버전 조합은 `../docs/integration_manifest.md`와 일치해야 한다. 아직 전달되지
않은 산출물은 PASS나 완료로 표시하지 않고 `TEMPLATE`, `PENDING`, `NOT_VERIFIED`로 구분한다.
