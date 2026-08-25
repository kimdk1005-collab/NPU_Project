# integration_manifest — 통합 전에 버전이 맞는지 보는 표

> **근거:** 공통 지침 §27 · **소유:** A/C · **갱신:** 2026-08-25
> (A Phase 4 제공 기록 + C `c_event_v04` / `c_control_v07` 조정)
>
> **규칙:** 이 표의 버전이 서로 안 맞으면 통합 Debug 를 시작하지 않는다.
> B/C 산출물이 도착하면 **먼저 여기를 고치고** 그 다음에 파일을 교체한다.

---

## 1. 현재 버전 (§27 형식)

```text
PROJECT_SPEC     = common_v1.5          docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md
ROLE_SPEC        = role_v1.6            docs/TEAM_ROLE_PLAN.md
PLAN_SPEC        = plan_v1.4            docs/NPU_DEVELOPMENT_PLAN.md
INTERFACE        = ifc_v0.5             docs/interface_contract.md

MODEL            = model_v01_dummy      <- B 실물 오면 model_v01
WEIGHT           = weight_v01_dummy     <- weights/*.mem 전부 더미
GOLDEN           = golden_v01_dummy     <- test_vectors/*.hex 전부 더미

A_NPU            = a_npu_v01            RTL 6종 TB PASS
A_SOC            = a_soc_v01            npu_axi + top_system + BD
A_SW             = a_sw_v01             PS 드라이버 45 check PASS
C_EVENT          = c_event_v04          전달 완료, A 실제 NPU 통합 대기
C_CONTROL        = c_control_v07        KY-008 수동 재무장 포함, A 통합 대기

BITSTREAM        = build_v03_a_only     results/npu_soc.bit
BOARD_VERIFIED   = a_soc_v01 @ 2026-08-24  <- Phase 4 보드 기능 판정 16/16 PASS
```

현재 C 체크아웃에는 A의 `rtl/npu/`, `rtl/integration/`, `sw/`, `results/`가 없다.
따라서 A 산출물 지문과 `BOARD_VERIFIED`는 전달 문서 기록이며, A/C 통합 브랜치에서
실제 파일과 다시 대조해야 한다. C RTL/TB는 현재 저장소에서 직접 검증 가능하다.

---

## 2. 산출물 지문 (2026-08-24 재빌드)

| 파일 | 크기 | md5 | 만든 명령 |
|---|---:|---|---|
| `results/npu_soc.bit` | 4,045,674 | `c853ac303d92183aa42b36993bfbcc91` | `run_bd.tcl` |
| `results/npu_soc.xsa` | 429,780 | `76f0fbb414fd05c213e6f2cc7a7fefc3` | `run_bd.tcl` |
| `results/npu_test.elf` | 146,140 | `09a1275f9dd5c0daf89b167af696ca79` | `build_vitis_unified.py` |

> 아래 값은 A가 전달한 Phase 4 기록이다. **보드에 올리기 전에 A 통합 브랜치에서 md5를 대조해라.** 여러 번 빌드하다 보면 어느 게 최신인지
> 헷갈린다. 위 3개는 서로 짝이다 (`.elf` 는 이 `.xsa` 에서 나왔다).

---

## 3. 규격 ↔ 구현 대조 (실측으로 확인된 것만)

| 항목 | 규격 값 | 구현 실측 | 확인 방법 |
|---|---|---|---|
| AXI Base | `0x4000_0000` | `0x40000000` | BD Address Editor 로그 + `XPAR_NPU_0_BASEADDR` |
| AXI Range | 4 KB | `0x00001000` | 동일 |
| VERSION | `0x4E50_0100` | 동일 | `tb_npu_axi` / `npu_mock` |
| 클럭 | 100 MHz 단일 | `clk_fpga_0` 10.000 ns | `results/bd_timing.rpt` |
| IRQ | 61 (`IRQ_F2P[0]`) | 배선 확인, **번호는 미검증** | XSA `npu_bd.hwh` (§ 아래 주의) |
| Tensor | 64×64×2 CHW, 8192 B | 동일 | `tb_top_system` / `test_driver` |
| Heatmap | 8×8 → `cell*8+4` | (52,28) ← cell(6,3) | `tb_npu_full` |
| Latency | — | **125,845 cycle = 1.258 ms** | `tb_npu_full`, `test_driver` |

> **IRQ 번호 주의:** 통합 Vitis(SDT) 는 `XPAR_FABRIC_NPU_0_IRQ_INTR` 을 만들지 않아
> `npu_test.c` 의 컴파일타임 검사가 건너뛴다. Zynq-7000 표준 매핑상 `IRQ_F2P[0] = 61` 이고
> 배선(`npu_0/irq → ps7/IRQ_F2P`)은 XSA 에서 확인했다. 인터럽트를 실제로 쓸 때 재확인한다.

---

## 4. 리소스 / 타이밍 (전체 시스템 bitstream 실측)

| 항목 | A 단독 | + C stub (자리표시자) |
|---|---:|---:|
| Slice LUT | 1441 (2.71%) | 1785 (3.36%) |
| Slice Register | 1392 (1.31%) | 1565 (1.47%) |
| Block RAM Tile | 8 (5.71%) | 8 (5.71%) |
| DSP48 | 12 (5.45%) | 12 (5.45%) |
| WNS | +0.782 ns | +1.121 ns |
| WHS | +0.043 ns | +0.045 ns |

근거: `results/bd_util.rpt` · `bd_timing.rpt` · `bd_util_cstub.rpt` · `bd_timing_cstub.rpt`

**발표·보고에는 A 단독 열을 쓴다.** `+ C stub` 은 C 실물이 아니다 (§35).

---

## 5. 버전을 올려야 하는 시점

| 트리거 | 올릴 항목 | 그 다음 할 일 |
|---|---|---|
| B 실물 weight/golden 도착 | `WEIGHT`, `GOLDEN`, `MODEL` → `_dummy` 제거 | `pack_weights.py` → `gen_test_tensor_c.py` → TB 6종 → `make test` → BD 재빌드 → `A_NPU = a_npu_v02` |
| Phase 4 보드 시험 통과 | `BOARD_VERIFIED = a_soc_v01 @ 2026-08-24` **완료** | `PHASE4_VERIFICATION_LOG.md` §10 (16/16 PASS) |
| C Event 모듈 도착 | **완료: `C_EVENT = c_event_v04`** | `INPUT_SRC=1` 경로 A NPU/실보드 확인 |
| C Control 모듈 도착 | **완료: `C_CONTROL = c_control_v07`** | `c_module_stub.v` 제거 → 추가 포트 연결 → 타이밍 재측정 |
| 레지스터 맵 변경 | `INTERFACE`, `PROJECT_SPEC` | **§22 CHANGE REQUEST 먼저.** 코드부터 고치지 않는다 |

---

## 6. 통합 순서 (§28) 와 현재 위치

```text
Integration 1  B <-> A   Golden Input -> NPU RTL -> Layer 비교
                         [x] 더미 weight 로 bit-exact 통과
                         [ ] 실물 weight 로 재확인          <- B 대기

Integration 2  C Event <-> A NPU     Event -> Tensor -> NPU
                         [x] C Event RTL/8192-byte CHW 단독·통합 TB
                         [ ] A 실제 NPU와 INPUT_SRC=1 결합  <- A/C 통합 대기

Integration 3  A NPU <-> C Control   target_x/y -> Tracking -> Servo
                         [x] C Control RTL/4축/Interlock/KY-008 사전 준비
                         [ ] A 실제 NPU/AXI/0x58·0x5C 결합  <- A/C 통합 대기

Integration 4  전체 + 보드
                         [x] A-only bitstream / XSA / ELF 생성
                         [x] A-only 보드 STEP 1~5 PASS       2026-08-24
                         [ ] B actual + A/C Closed-loop 보드 <- B 산출물·A/C 통합 대기
```

`[~]` = A 쪽 준비는 끝났고 상대 산출물만 기다리는 상태 (§23 준수).

## 7. A Phase 4 stub → C 실제 모듈 교체 조건

```text
stub 기본 포트       event_cfg/pan*/laser*/safe*/target*/evt*/servo_pwm/laser_en
C 필수 추가 입력     src_valid/src_x/src_y/src_pol/src_window_end
                     laser_arm_hw/emergency_stop_hw
C 필수 추가 출력     tensor_start/servo_pos_stat/control_stat
신규 RO 제안         0x58 SERVO_POS_STAT / 0x5C CONTROL_STAT
안전 상태            CONTROL_STAT[16] = LASER_REARM_REQUIRED
START                Direct 또는 PS-managed 중 하나만 선택
```

세부 연결은 `C_TO_A_REPLY_004.md`와 `handoff/C_EVENT_CONTROL_HANDOFF.md` §11을 따른다.
