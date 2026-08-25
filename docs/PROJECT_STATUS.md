# 프로젝트 진행상황

> 기준점: 2026-08-25 Day 06 A Phase 3 연동 + KY-008 실제 광원 사전 안전 준비 완료
>
> 최종 검증: 2026-08-25, C 자동판정 TB 12개 전체 재실행 결과
>
> 범위: 현재 체크아웃에는 주로 C(Event/Control) 산출물이 있으며, A/B 작업은 아직 합쳐지지 않았다.

## 한눈에 보기

Day 05의 4축+LED 경로 위에 Day 06에는 A Phase 3 `c_module_stub` 계약과 C RTL을
연결하는 `c_event_control_top.v`를 추가했다. Event Adapter→Accumulator, NPU Target,
4-Servo, Fail-Closed Interlock이 한 모듈로 이어졌고 AXI Manual Override, Runtime
SAFE_LIMIT/SAFE_LIMIT2, signed LASER_CAL, INPUT_STAT을 구현했다. 실제 광원 준비로
Power-on/E-stop/max-on 뒤 수동 재무장 latch, `CONTROL_STAT[16]`, KY-008 전용
100 ms gate Top을 추가했다. 자동판정 TB 12개에서 로그 기준 **287 PASS, errors=0**이다.
C 래퍼의 기존 D6 OOC implementation은 100 MHz에서
WNS +1.138 ns / WHS +0.147 ns, DRC 0 Error를 확인했다. 기존 네 Servo와 JD7 RED 실물 결과는 유지되며,
전체 시스템 기준으로는 A/B 실제 산출물 합류와 Camera/NPU Closed-loop 검증이 남아 있다.

| 전체 성공 기준 | 현재 저장소 상태 | 다음 Gate |
|---|---|---|
| Event Tensor 생성 | **C 경로 구현 완료** — Adapter + Ping-Pong Accumulator | B Golden 및 A NPU와 통합 |
| A Phase 3 C 포트 연동 | **C 래퍼 구현 완료** — 설정/상태/START 요청 포함 | A 실제 `top_system/npu_axi`에 인스턴스 |
| Tiny CNN 학습/INT8 변환 | **산출물 미반영** | B 브랜치/산출물 합류 |
| Python Integer Golden | **산출물 미반영** | B Golden 및 Test Vector 합류 |
| Dense INT8 NPU RTL | **산출물 미반영** | A NPU RTL 합류 |
| NPU Target `(x, y)` 출력 | **산출물 미반영** | Argmax Decoder 및 통합 |
| Camera PT#1 Closed-loop Tracking | **C RTL 완료** — Tracking + Slew + 2 PWM | A Target 출력 연결 및 실물 Closed-loop |
| Laser PT#2 Follower | **C RTL 완료** — PT#1 자세 + 잔차 + Offset | FOV/방향/Offset 실측 |
| Laser 안전 출력 | **LED Interlock + KY-008 Gate RTL 완료** — 수동 재무장/100 ms 제한 | High-side driver dummy 실측 후 실제 광원 승인 |

## 완료 및 검증 결과

| 항목 | 상태 | 2026-08-24 재검증 |
|---|---|---|
| `rtl/event/event_adapter.v` | D2 구현 완료 | `tb_event_adapter` **23/23 PASS** |
| `rtl/event/event_accumulator.v` | D3 구현 완료 | `tb_event_accumulator` **15/15 PASS**, 8192 B 전수 비교 |
| Adapter→Accumulator 통합 경로 | D4 검증 완료 | `tb_event_pipeline` **15/15 PASS**, 2 Window × 8192 B 전수 비교 |
| `rtl/control/servo_pwm.v` | D1 구현 완료 | `tb_servo_pwm` **6/6 PASS** |
| `rtl/control/board_io.v` | D3 축별 단독 검증 완료 | `tb_board_io` **19/19 PASS**, PAN/TILT 실물 구동 완료 |
| `rtl/control/tracking_controller.v` | D4 구현 완료 | `tb_tracking_controller` **30/30 PASS** |
| `rtl/control/laser_head_controller.v` | D6 Runtime LASER_CAL 반영 | `tb_laser_head_controller` **27/27 PASS** |
| `rtl/control/laser_interlock.v` | 수동 재무장 안전 확장 완료 | `tb_laser_interlock` **38/38 PASS** |
| `rtl/control/dual_head_control.v` | 4-Servo + 재무장 통합 완료 | `tb_dual_head_control` **33/33 PASS**, 네 PWM 펄스폭 확인 |
| `rtl/control/c_event_control_top.v` | A Phase 3 + 재무장 상태 완료 | `tb_c_event_control_top` **27/27 PASS**, 8192 B/AXI/상태/E-stop latch |
| `rtl/control/ky008_laser_board_io.v` | KY-008 사전 브링업 Top 완료 | `tb_ky008_laser_board_io` **19/19 PASS**, 112~144 / 100 ms / 수동 재무장 |
| KY-008 Gate implementation | Zybo Z7-20 Bitstream 경로 완료 | LUT 448 / Register 373 / DSP 4, DRC 0 Error, WNS +1.529 ns / WHS +0.153 ns |
| C 통합 래퍼 OOC implementation | D6 타이밍 검증 완료 | xc7z020, 100 MHz: LUT 829 / Register 582 / BRAM 4 / DSP 6, DRC 0 Error, WNS +1.138 ns / WHS +0.147 ns |
| `rtl/control/laser_board_io.v` | PT#2 단독 실물 브링업 완료 | JD3/JD4 Servo 방향·범위 정상, DRC 0 Error, WNS +0.396 ns / WHS +0.165 ns |
| `rtl/control/dual_head_board_io.v` | 4축+JD7 RED 최종 실물 검증 완료 | 32/32 PASS + 실물 전 항목 PASS, DRC 0 Error, WNS +1.068 ns / WHS +0.179 ns |
| Zybo Z7-20 제약/Tcl 빌드 경로 | 준비 완료 | WNS +0.357 ns, WHS +0.047 ns |
| 웹캠 Fallback 능력 측정 도구 | 구현 완료 | APC850 기준 640×480 YUYV 30 fps 확인 |
| C Handoff | `c_control_v07` | A Phase 3 + KY-008 실제 광원 사전 안전 계약 반영 |

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
```

## 현재 블로커와 결정 요청

| 우선순위 | 요청 | 영향 | 담당 |
|---:|---|---|---|
| 1 | A Phase 3 실제 RTL/PS 소프트웨어 브랜치 합류 | 문서가 아닌 실제 `top_system/npu_axi` 통합 | A |
| 2 | `tensor_start` Direct 또는 PS-managed START 중 하나 선택 | 중복 START 방지 | A |
| 3 | A stub에 실제 Event Source 입력 5개 추가 | 카메라/Event 입력 연결 | A/C |
| 4 | `0x58 SERVO_POS_STAT`, `0x5C CONTROL_STAT` RO 추가 | C 자동 명령의 PS 가시성 | A |
| 5 | JD1~JD4 + JD7 핀을 통합 XDC에 반영 | A `top_system`의 4축+RED 출력 | A |
| 6 | 웹캠 FOV/축 방향 및 2 m Offset 실측 | FOV Scale / LASER_CAL 확정 | C |
| 7 | CR C-002 Event Window + Webcam Fallback 검토 | Dataset/Golden 재생성 가능성 | A/B |
| 8 | KY-008 최대 광출력 mW/IEC Class 확인 | 보호안경 OD와 실제 발광 승인 결정 | C/판매처 |
| 9 | 5 V High-side driver + Key Arm + NC E-stop dummy 실측 | 실제 광원 전원 연결 승인 | C |

해결된 핵심 결정은 Tensor Direct Handshake, CHW 주소 순서, C/NPU 100 MHz 단일
클럭, `npu_done -> target_update`, AXI Command의 Manual Override 용도, 동적 Safe Limit의
Fail-Safe fallback이다. 상세 bit 배치는 `handoff/C_EVENT_CONTROL_HANDOFF.md` §11이다.

## 다음 액션

- A: `docs/C_TO_A_REPLY_003.md`의 START 방식, Event Source 포트, RO 상태 Register를 회신한다.
- B: CR C-004 채널 순서와 CR C-002의 33.3 ms Window 영향을 검토한다.
- C: `docs/KY008_PREARRIVAL_CHECKLIST_C.md`의 dummy load 승인표를 먼저 수행한다.
- C: 레이저 부품 도착 후 광출력/핀/소비전류를 확인하고 2 m에서 FOV Scale과 Offset을 실측한다.
- A/C: A Phase 3 stub 대신 `c_event_control_top`을 연결하고 실제 NPU Target으로 검증한다.
- A/C: `event_accumulator` Direct Handshake를 NPU 입력에 연결해 Golden과 비교한다.
- 팀: A/B 브랜치를 `integration`에 합쳐 이 문서를 전체 프로젝트 기준으로 갱신한다.

## 공유 규칙

- 구현 상태가 바뀔 때 이 문서의 표와 날짜를 함께 갱신한다.
- 공유 인터페이스 변경은 먼저 `docs/CHANGE_REQUEST_*.md`로 제안한다.
- 생성 가능한 Vivado 산출물, 로그, 비트스트림은 Git에 올리지 않는다.
- 진행 중 작업은 기능 브랜치와 Draft PR로 공유하고, 검증 후 `integration`에 합친다.
