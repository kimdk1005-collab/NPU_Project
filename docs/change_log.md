# Change Log — 공유 규격 변경 이력

> spec §5.4 공유 파일. 규격이 바뀔 때마다 여기에 한 줄 추가한다.
> 상세는 각 문서의 변경 이력 절과 `docs/` 의 요청서를 본다.

| 날짜 | 문서 | 버전 | 변경 | 근거 | 승인 |
|---|---|---|---|---|---|
| 2026-08-20 | 공통 지침 | v1.1 | Quantization / Weight Layout OIHW / Requantize Q24 Freeze | B 요청 | A, B |
| 2026-08-20 | 공통 지침 | v1.2 | Label Mapping Freeze (`target = cell*8+4`, `[Y][X]`) | B 요청 | A, B |
| 2026-08-21 | 공통 지침 | **v1.3** | §8.1 Conv 경계 규칙 Freeze (Padding=1 / Cross-Correlation / flip 없음) | `docs/D3_B_to_A_CNN_Convolution_Freeze_Request.md` | **A 승인 · B 확인 대기** |
| 2026-08-21 | 공통 지침 | v1.3 | §7.4 Tensor Memory Order = CHW | `docs/D3_FREEZE_REQUEST_A_001.md` 1 | A · **C 승인 완료** · B 확인 대기 |
| 2026-08-21 | 공통 지침 | v1.3 | §7.3 Event Tensor 전달 = Direct Handshake (`ext_*`) | 동 5 | A · **C 승인·구현 완료** |
| 2026-08-21 | 공통 지침 | v1.3 | §14.2 Argmax Tie-Break = FIRST_MAX (strict `>`) | 동 3 | A · **B 대기** |
| 2026-08-21 | 공통 지침 | v1.3 | §16.1 `target_valid = score > SCORE_TH` | 동 4 | A · **B 대기** |
| 2026-08-21 | 공통 지침 | v1.3 | §18.1 A NPU Core 실측 기록 (기록, 규격 변경 아님) | Phase 1 | — |
| 2026-08-21 | 개발 계획 | **v1.2** | PE 8 유지 결정 / 실측 리소스·Latency / Zybo board file 위험 / 진척 | Phase 1 | — |
| 2026-08-21 | 역할 분담 | v1.3 | §17 진척 현황 추가 (역할 내용 변경 없음) | Phase 1 | — |
| 2026-08-21 | interface_contract | v0.2 | v1.3 반영 위치 대조표 추가 | Phase 1 | — |
| 2026-08-21 | 공통 지침 / 개발 계획 / Handoff | — | **Timing 수치를 합성 추정 → 배치배선 실측으로 교체** (WNS +1.455 → +0.266 ns, Fmax 102.7 MHz). LUT 1410 → 1373 | `results/npu_core_impl_timing.rpt` | — |
| 2026-08-21 | 공통 지침 | **v1.4** | **§20.1 신규 — AXI Register Bit Field 전체 표 + Base `0x4000_0000`** | `docs/D3_FREEZE_REQUEST_A_002.md` | A · **C 기본 계약 승인·구현** · A 확장 회신 대기 |
| 2026-08-21 | 공통 지침 | v1.4 | §20.1 `CTRL.INPUT_SRC` 신규 (0=PS/AXI 적재, 1=C 직결) | 동 §2.1 | C 권장 MUX 회신 · A 연결 결정 대기 |
| 2026-08-21 | 공통 지침 | v1.4 | `0x38 VERSION` / `0x3C INBUF_ADDR` / `0x40 INBUF_DATA` / `0x44 SCRATCH` 추가 (§20 "뒤에 추가" 규칙 준수, 기존 Offset 무변경) | 동 §2.9~2.11 | A |
| 2026-08-21 | 공통 지침 / 개발 계획 / interface_contract / Handoff | — | **리소스·타이밍 수치 전면 교체.** `npu_pe` 에 `use_dsp="yes"` 적용 → npu_core LUT 1373→**573**, WNS +0.266→**+0.994 ns**. 전체 시스템 bitstream LUT **1310** / WNS **+0.714 ns** / Fmax **107.7 MHz** | `results/bd_timing.rpt`, `build/top_system_impl_timing.rpt` | — |
| 2026-08-21 | 공통 지침 / 개발 계획 | — | **정정: "Zybo board file 미설치" 는 오기록.** `~/.Xilinx/Vivado/2024.2/xhub/board_store/` 에 이미 존재. 해당 리스크 항목 해소 | `get_board_parts *zybo*` | — |
| 2026-08-21 | 개발 계획 | **v1.3** | Phase 2 결과 반영 / §17.3 board file 정정 / §23 리스크 갱신 | Phase 2 | — |
| 2026-08-21 | 역할 분담 | **v1.4** | §17 진척 갱신 — A Phase 2 완료 (역할 내용 변경 없음) | Phase 2 | — |
| 2026-08-21 | interface_contract | **v0.3** | §10 신규 — AXI Register 계약 / C 연결 방법 / PS 폴링 규칙 | Phase 2 | A · **C 기본 계약 승인·구현** |

| 2026-08-21 | 공통 지침 | **v1.5** | **기구 변경: Pan/Tilt 1개 → 2개 분리.** §15.0 / §15.2 신규 (PT#2 좌표 변환), §17 SAFE_LIMIT2 필수화, §20/§20.1 에 `0x48`~`0x54` 추가 | `docs/D3_FREEZE_REQUEST_A_002.md` rev.2 | A · **C 승인·구현 완료** |
| 2026-08-21 | 공통 지침 | v1.5 | §15.2 `PAN2_CMD = f(error_x)` 금지 명문화 (레이저가 오차를 따라가는 오구현 방지) | 동 §2.13 | A · **C 승인·구현 완료** |
| 2026-08-21 | 공통 지침 / 개발 계획 | — | **수치 갱신** (PT#2 Register 4개 추가분). 전체 시스템 LUT 1310→**1441**, FF 1264→**1392**, WNS +0.714→**+0.782 ns**. NPU Core 는 무변경 | `results/bd_timing.rpt` | — |
| 2026-08-21 | 개발 계획 | **v1.4** | §16.1 개정 (카메라+레이저 한 몸 → 2 헤드), §16.2 좌표 변환 신규, §16.3 SAFE_LIMIT2, §21 일정, §23 리스크 4건 추가 | Pan/Tilt 2 헤드 | — |
| 2026-08-21 | 역할 분담 | **v1.5** | §17 C 작업 항목 5개 추가 (Servo 4채널 / 좌표변환 / OFFSET 실측 / SAFE_LIMIT2 / 전원) | 동 | — |
| 2026-08-21 | interface_contract | **v0.4** | §11 신규 — Pan/Tilt 2 헤드 계약 | 동 | A · **C 승인·구현 완료** |

| 2026-08-21 | 역할 분담 | **v1.6** | §17 A Phase 3 완료 반영 (PS 소프트웨어 / C 통합 사전검증). 역할 경계 변경 없음 | Phase 3 | — |
| 2026-08-21 | (규격 변경 아님) | — | **A Phase 3**: `sw/` PS 드라이버·시험프로그램 추가, 호스트 목으로 45 check 검증, Vitis ELF 빌드. `rtl/integration/c_module_stub.v` 자리표시자로 C 통합 타이밍 사전측정 (LUT 1441→1785, WNS +0.782→**+1.121 ns**, 100MHz MET) | `docs/A_NPU_HANDOFF.md` 요약 | — |
| 2026-08-22 | 공통 지침 / 개발 계획 / 역할 분담 | 운영 정정 | **Dataset/Label Target 경계 명확화.** 단일 지정 표적의 Event Tensor와 실제 표적 중심을 학습에 사용하고, 레이저 포인터는 추론 이후의 출력 장치로 한정. Red Laser 기반 Sample은 최종 학습에서 제외하고 B가 실제 표적 Label 방식으로 교체 | 설계 재검토 | A · **B 확인 필요** |
| 2026-08-22 | 공통 지침 / 개발 계획 / 역할 분담 | 인터페이스 무변경 | Tensor `64×64×2`, Heatmap `8×8`, 좌표 Mapping, Quantization, NPU RTL, A→C `target_*`, C Tracking/Servo/PT#2 좌표변환은 그대로 유지 | 동 | — |
| 2026-08-24 | C Event/Control | D6 | A Phase 3 포트용 `c_event_control_top` 구현, AXI 설정/상태·Manual Override·Runtime Limit 계약 및 249 PASS/OOC 타이밍 확인 | `C_TO_A_REPLY_003.md` | C 완료 · A 통합 대기 |
| 2026-08-24 | 문서 구조 | — | `docs/`를 버전 없는 최신 정본으로 통일하고 대체된 버전 사본과 `(1)` 중복본 제거 | `00_DOCUMENT_INDEX.md` | — |
| 2026-08-24 | 문서 경로·승인 상태 | — | `docs/freeze`·`handoff`의 잘못된 내부 참조를 실제 정본 경로로 통일하고 C 회신 001~003의 승인·구현 상태 반영. Interface 값 변경 없음 | `C_TO_A_REPLY_001.md`~`003.md` | — |
| 2026-08-25 | interface_contract / C Handoff / KY-008 checklist | **v0.5 / c_control_v07** | 실제 광원 안전 확장. Power-on Arm HIGH, E-stop release, max-on timeout 뒤 Laser Arm LOW→HIGH 수동 재무장 필수. `CONTROL_STAT[16]=LASER_REARM_REQUIRED`, KY-008 100 ms Gate Top/XDC/TB 추가. C TB 12종 **287 PASS, errors=0** | `KY008_PREARRIVAL_CHECKLIST_C.md` | C 구현 완료 · A 상태 bit 연동 대기 |
| 2026-08-25 | A Phase 4 문서 / integration manifest / C 회신 | — | A-only 보드 기능 판정 16/16과 Fmax 108.5 MHz 기록을 정본에 반영. 배포본의 C 미착수·잘못된 `docs/freeze` 경로는 현재 승인/구현 상태로 재조정. `C_TO_A_REPLY_004.md`에 stub→C actual 교체 포트와 START 단일 소유권 확정 | A 제공 Phase 4 문서 묶음 | C 완료 · A/C 실제 통합 대기 |
| 2026-08-26 | C Handoff / KY-008 checklist / XDC | **c_control_v08** | 수령품 핀 계약을 `S=control`, middle=`+5 V`, `-=GND`로 정정. JD7/U14는 외부 1 kΩ 직렬 보호 뒤 S를 구동하고 DRIVE 4/SLEW SLOW를 명시. LED3 동기 100 ms 단발과 timeout 수동 재무장을 실물 확인. C TB 12종 287 PASS, XDC 재빌드 DRC 0 Error, WNS +1.529 ns / WHS +0.153 ns | 수령품 브링업 + 독립 재검증 | C 독립 브링업 완료 · 소비전류/광출력/물리 E-stop/A 통합 대기 |
| 2026-08-26 | C 연결 부품 수동 점검 Top / XDC / TB | — | Zybo 물리 BTN0~BTN3와 조합 BTN4/BTN5를 이용한 4축 개별 이동·전체 Neutral·KY-008 100 ms 단발·논리 E-stop 점검 경로 추가. C TB 13종 **327 PASS**, DRC 0 Error, WNS +2.586 ns / WHS +0.155 ns | `C_COMPONENT_MANUAL_TEST.md` | 실물 순차 확인 대기 · 통합 인터페이스/`c_control_v08` 변경 없음 |
| 2026-08-26 | C 연결 부품 수동 점검 Top | — | 사용자 수동 점검 요구에 따라 BTN3을 단발 요청에서 hold-to-fire로 변경. 버튼을 놓으면 즉시 OFF, 계속 누르면 1초 상한 뒤 timeout·SW1 수동 재무장. 공통 C 통합 인터록의 100 ms 정책은 변경하지 않음. C TB 13종 **331 PASS**, DRC 0 Error, WNS +2.542 ns / WHS +0.066 ns | `C_COMPONENT_MANUAL_TEST.md` | 실물 재확인 대기 |
| 2026-08-27 | A/C 실물 통합 요청 #001 / C Control | **c_control_v09 / ifc_v0.5 유지** | Runtime SAFE_LIMIT 8개 유효값을 원자 등록해 조합 critical cone을 분리하고 invalid AXI 전이 raw 값 차단 TB 추가. 좌표식·Event Source·Direct START·0x58/0x5C·33.333 ms·JD 핀/안전 회신 완료. C 자동판정 13 TB **341 PASS**, OOC LUT 902 / Register 650 / BRAM 4 / DSP 6, DRC 0 Error, WNS +1.394 ns / WHS +0.061 ns | `C_TO_A_REPLY_005.md` | C 작업 트리 완료 · A 전체 timing/실물 계측 대기 |

## 대기 중인 요청

```text
D3_FREEZE_REQUEST_A_001   A -> B/C   C는 C_TO_A_REPLY_001에서 전 항목 수용
                          B 확인 및 공통 정본 승인 상태 갱신 대기

D3_FREEZE_REQUEST_A_002   A -> C     C_TO_A_REPLY_002에서 좌표식·4축·SAFE_LIMIT2 수용
                          C_TO_A_APPROVAL_D3_A002_rev2에서 §2.13 공식 승인 완료

A_TO_C_V01_REQUEST_001    A -> C     C_TO_A_REPLY_005에서 코드 수정·필수 회신 완료
                          A top_system_c timing 재측정과 실물 계측값 대기
```

## 2026-08-30 통합 갱신

| 날짜 | 범위 | 버전 | 변경 | 검증 |
|---|---|---|---|---|
| 2026-08-30 | A NPU/SoC/PS | `a_npu_v01 / a_soc_v02 / a_sw_v05` | 누락돼 있던 NPU RTL, AXI/Top, TB, PS Driver/자체시험/CPU Baseline과 Vivado/Vitis 재현 스크립트를 공유 저장소 형식으로 반영 | Case 3×16 TB 48/48, Driver 76, CPU 21 PASS |
| 2026-08-30 | A/C 통합 | `a_soc_c_v03 / ifc_v0.5` | C actual을 보존한 `top_system_c`, `0x58/0x5C` RO, `CTRL[5] HW_START_EN`, VERSION `0x4E50_0101` 반영 | 통합 TB PASS, A+C full 100 MHz WNS +0.618 ns MET 기록 |
| 2026-08-30 | B 전달물 | `model_v04_demo_masked_radius1_x1 / weight_v04 / golden_v04 / testvec_v04` | B 최종 전달 Weight/Golden/checkpoint와 `color_masked_event_v02_radius1` 반영 | `DEMO-MASKED-PASS / DEMO_ONLY`; 외부 Test 미평가 |
| 2026-08-30 | Live Runtime | `a_live_v01` | NPUL v1 UART/CRC, PC Camera sender, PS live tracker, 양 언어 교차시험 추가 | Host 90 check PASS; 보드/Camera 미실시 |
| 2026-08-30 | 저장소 정책 | — | Bitstream/XSA/ELF/로그는 제외하고 소스·재현 명령·체크섬만 보존 | Repository Policy 대상으로 정리 |
