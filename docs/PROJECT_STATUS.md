# 프로젝트 진행상황

> 기준점: 2026-08-27 B model_v03 최종 전달 + A Phase 4 기록 + C 실물 통합 요청 #001 회신 완료
>
> 최종 검증: 2026-08-27, B v03 자체검증·A 회신 18/18 + C 자동판정 TB 13개·PWM sweep·C 래퍼 OOC
>
> 범위: 현재 체크아웃에는 B Model/Golden과 C Event/Control이 있으며, A 실제 RTL/SoC 소스 합류가 남아 있다.

## 한눈에 보기

Day 05의 4축+LED 경로 위에 Day 06에는 A Phase 3 `c_module_stub` 계약과 C RTL을
연결하는 `c_event_control_top.v`를 추가했다. Event Adapter→Accumulator, NPU Target,
4-Servo, Fail-Closed Interlock이 한 모듈로 이어졌고 AXI Manual Override, Runtime
SAFE_LIMIT/SAFE_LIMIT2, signed LASER_CAL, INPUT_STAT을 구현했다. 실제 광원 준비로
Power-on/E-stop/max-on 뒤 수동 재무장 latch, `CONTROL_STAT[16]`, KY-008 전용
100 ms gate Top을 추가했다. 연결 부품 수동 점검 Top을 포함한 자동판정 TB 13개에서
로그 기준 **341 PASS, errors=0**이다.
수령한 KY-008은 `S <- JD7/U14(1 kΩ 직렬)`, middle=`+5 V`, `-`=공통 GND에서
LED3과 동기된 약 100 ms 단발 및 timeout 뒤 수동 재무장을 실물 확인했다.
C 래퍼는 Runtime SAFE_LIMIT 유효값 8개를 등록한 뒤 100 MHz OOC에서
WNS +1.394 ns / WHS +0.061 ns, DRC 0 Error를 확인했다. 기존 네 Servo와 JD7 RED 실물 결과는 유지되며,
전체 시스템 기준으로는 A 실제 산출물 합류와 B v03·Camera/NPU Closed-loop 검증이 남아 있다.

A가 전달한 문서에는 A-only Zybo Z7-20 Phase 4 기능 판정 16/16 PASS와 B v03 RTL
회귀 18/18 PASS가 기록돼 있다. 현재 공유 저장소에는 B 실제 Weight/Golden이 있지만
A의 `rtl/npu`, `rtl/integration`, `sw`, `results`가 없으므로 A 통합 브랜치에서 다시
대조한다. `C_TO_A_REPLY_004.md`에 stub→C 실제 모듈 교체 조건을 확정했다.

| 전체 성공 기준 | 현재 저장소 상태 | 다음 Gate |
|---|---|---|
| Event Tensor 생성 | **C 경로 구현 완료** — Adapter + Ping-Pong Accumulator | B Golden 및 A NPU와 통합 |
| A Phase 3 C 포트 연동 | **C 래퍼 구현 완료** — 설정/상태/START 요청 포함 | A 실제 `top_system/npu_axi`에 인스턴스 |
| Tiny CNN 학습/INT8 변환 | **B v03 전달 완료** — FP32 98.44%, INT8 97.66% | A 공유 브랜치에서 Weight 적용 |
| Python Integer Golden | **B v03 전달 완료** — 3 case Conv1~4 bit-exact | A RTL과 공유 저장소 재회귀 |
| Dense INT8 NPU RTL | **산출물 미반영** | A NPU RTL 합류 |
| NPU Target `(x, y)` 출력 | **산출물 미반영** | Argmax Decoder 및 통합 |
| Camera PT#1 Closed-loop Tracking | **C RTL 완료** — Tracking + Slew + 2 PWM | A Target 출력 연결 및 실물 Closed-loop |
| Laser PT#2 Follower | **C RTL 완료** — PT#1 자세 + 잔차 + Offset | FOV/방향/Offset 실측 |
| Laser 안전 출력 | **C 독립 KY-008 단발 완료** — 수동 재무장/100 ms 제한 실물 확인 | 소비전류·기본-OFF·Key/NC E-stop·광출력 등급 승인 |

## 완료 및 검증 결과

| 항목 | 상태 | 최신 재검증 |
|---|---|---|
| `rtl/event/event_adapter.v` | D2 구현 완료 | `tb_event_adapter` **23/23 PASS** |
| `rtl/event/event_accumulator.v` | D3 구현 완료 | `tb_event_accumulator` **14/14 PASS**, 8192 B 전수 비교 |
| Adapter→Accumulator 통합 경로 | D4 검증 완료 | `tb_event_pipeline` **15/15 PASS**, 2 Window × 8192 B 전수 비교 |
| `rtl/control/servo_pwm.v` | D1 구현 완료 | `tb_servo_pwm` **6/6 PASS** |
| `rtl/control/board_io.v` | D3 축별 단독 검증 완료 | `tb_board_io` **19/19 PASS**, PAN/TILT 실물 구동 완료 |
| `rtl/control/tracking_controller.v` | D4 구현 완료 | `tb_tracking_controller` **30/30 PASS** |
| `rtl/control/laser_head_controller.v` | D6 Runtime LASER_CAL 반영 | `tb_laser_head_controller` **27/27 PASS** |
| `rtl/control/laser_interlock.v` | 수동 재무장 안전 확장 완료 | `tb_laser_interlock` **38/38 PASS** |
| `rtl/control/dual_head_control.v` | 4-Servo + SAFE_LIMIT 파이프라인 완료 | `tb_dual_head_control` **43/43 PASS**, invalid 전이 raw 값 차단·네 PWM 확인 |
| `rtl/control/c_event_control_top.v` | A Phase 3 + 재무장 상태 완료 | `tb_c_event_control_top` **27/27 PASS**, 8192 B/AXI/상태/E-stop latch |
| `rtl/control/ky008_laser_board_io.v` | KY-008 수령품 브링업 Top 완료 | `tb_ky008_laser_board_io` **19/19 PASS**, 112~144 / 100 ms / 수동 재무장 |
| `rtl/control/component_manual_test_top.v` | 4축·KY-008 수동 점검 Top 준비 완료 | BTN3 hold-to-fire(놓으면 OFF, 최대 1초) **44/44 PASS**, LUT 231 / Register 310 / DSP 4, DRC 0 Error, WNS +2.542 ns / WHS +0.066 ns; 실물 재확인 대기 |
| KY-008 수령품 실물 단발 | C 독립 브링업 완료 | `S <- JD7(1 kΩ)`, middle=`+5 V`, `-`=GND, LED3 동기/100 ms/재무장 PASS |
| KY-008 Gate implementation | Zybo Z7-20 Bitstream 경로 완료 | LUT 448 / Register 373 / DSP 4, DRC 0 Error, WNS +1.529 ns / WHS +0.153 ns |
| C 통합 래퍼 OOC implementation | SAFE_LIMIT 수정 후 타이밍 재검증 | xc7z020, 100 MHz: LUT 902 / Register 650 / BRAM 4 / DSP 6, DRC 0 Error, WNS +1.394 ns / WHS +0.061 ns |
| `rtl/control/laser_board_io.v` | PT#2 단독 실물 브링업 완료 | JD3/JD4 Servo 방향·범위 정상, DRC 0 Error, WNS +0.396 ns / WHS +0.165 ns |
| `rtl/control/dual_head_board_io.v` | 4축+JD7 RED 최종 실물 검증 완료 | 최신 TB **36/36 PASS** + 실물 전 항목 PASS, DRC 0 Error, WNS +1.068 ns / WHS +0.179 ns |
| Zybo Z7-20 제약/Tcl 빌드 경로 | 준비 완료 | WNS +0.357 ns, WHS +0.047 ns |
| 웹캠 Fallback 능력 측정 도구 | 구현 완료 | APC850 기준 640×480 YUYV 30 fps 확인 |
| C Handoff | `c_control_v09` | Runtime SAFE_LIMIT 등록 경로 + KY-008/통합 회신 반영 |
| A Phase 4 문서 조정 | A-only 기능 판정 16/16 기록 수신 | C 상태 회귀 제거, `integration_manifest.md`를 ifc_v0.5/C actual로 갱신 |
| A/C 교체 계약 | `C_TO_A_REPLY_004.md` | stub 추가 포트, START 단일 소유권, 0x58/0x5C, JD7 전원 경계 확정 |
| B Model/Golden | `model_v03 / weight_v03 / golden_v03 / testvec_v03` | B 자체 bit-exact PASS, A 회신 18/18 PASS |
| A 실물 통합 요청 #001 | `C_TO_A_REPLY_005.md` | SAFE_LIMIT 파이프라인·좌표식·Event Source·CR A-003·핀/안전 회신 완료 |

재현 명령:

```bash
./sim/run_xsim.sh tb_event_adapter
./sim/run_xsim.sh tb_event_accumulator
./sim/run_xsim.sh tb_event_pipeline
./sim/run_xsim.sh tb_servo_pwm
./sim/run_xsim.sh tb_board_io
./sim/run_xsim.sh tb_tracking_controller
./sim/run_xsim.sh tb_laser_head_controller
./sim/run_xsim.sh tb_laser_interlock
./sim/run_xsim.sh tb_dual_head_control
./sim/run_xsim.sh tb_dual_head_board_io
./sim/run_xsim.sh tb_c_event_control_top
./sim/run_xsim.sh tb_ky008_laser_board_io
./sim/run_xsim.sh tb_component_manual_test_top
```

## 현재 블로커와 결정 요청

| 우선순위 | 요청 | 영향 | 담당 |
|---:|---|---|---|
| 1 | A Phase 3 실제 RTL/PS 소프트웨어 브랜치 합류 | B v03·C 실제 모듈과 `top_system/npu_axi` 통합 | A |
| 2 | C 승인 Direct START MUX를 A 통합 top에 반영 | 중복 START 방지 | A |
| 3 | PS Webcam/Trace → PL `src_*` stream bridge 구현 | 실제 Event 입력 연결 | A |
| 4 | 승인된 `0x58/0x5C` RO를 A AXI에 연결 | C 자동 명령의 PS 가시성 | A |
| 5 | C 수정본으로 A `top_system_c` 기본 전략 타이밍 재측정 | 100 MHz 최종 판정 | A/C |
| 6 | 웹캠 FOV/축 방향 및 2 m Offset 실측 | FOV Scale / LASER_CAL 확정 | C |
| 7 | 승인된 33,333 us/외부 Frame 경계를 A 입력 경로에 적용 | B v03 재생 조건과 입력 경계 일치 | A/B |
| 8 | KY-008 최대 광출력 mW/IEC Class와 소비전류 확인 | 보호안경 OD와 자동 시연 승인 결정 | C/판매처 |
| 9 | FPGA 미프로그램 default-OFF + Key Arm + NC E-stop 실측 | 실제 광원 자동 경로 승인 | C |

해결된 핵심 결정은 Tensor Direct Handshake, CHW 주소 순서, C/NPU 100 MHz 단일
클럭, `npu_done -> target_update`, AXI Command의 Manual Override 용도, 동적 Safe Limit의
Fail-Safe fallback이다. 상세 bit 배치는 `handoff/C_EVENT_CONTROL_HANDOFF.md` §11이다.

## 다음 액션

- A: `docs/C_TO_A_REPLY_005.md`의 Direct START, 0x58/0x5C RO, PS→PL Event Stream을 구현한다.
- A: C SAFE_LIMIT 수정본을 통합한 `top_system_c` 기본 전략 timing을 재측정한다.
- B: v03 전달 상태를 유지하고 A 통합 RTL에서 3개 Golden case 재회귀를 지원한다.
- C: KY-008 수령품 단발 완료 뒤 남은 소비전류/광출력/default-OFF/물리 E-stop을 승인한다.
- C: 2 m에서 FOV Scale과 Offset을 실측한다.
- A/C: A Phase 4 문서의 stub 대신 `c_event_control_top`을 연결하고 실제 NPU Target으로 검증한다.
- A/C: `C_TO_A_REPLY_004.md` 순서로 Event/물리 안전/RO 상태 포트를 추가하고 전체 implementation을 재측정한다.
- A/C: `event_accumulator` Direct Handshake를 NPU 입력에 연결해 Golden과 비교한다.
- 팀: A 브랜치를 `integration`에 합쳐 B v03·C actual 전체 경로를 검증한다.

## 공유 규칙

- 구현 상태가 바뀔 때 이 문서의 표와 날짜를 함께 갱신한다.
- 공유 인터페이스 변경은 먼저 `docs/CHANGE_REQUEST_*.md`로 제안한다.
- 생성 가능한 Vivado 산출물, 로그, 비트스트림은 Git에 올리지 않는다.
- 진행 중 작업은 기능 브랜치와 Draft PR로 공유하고, 검증 후 `integration`에 합친다.
