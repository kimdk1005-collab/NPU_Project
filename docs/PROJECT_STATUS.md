# 프로젝트 진행상황

> 기준점: 2026-08-22 Day 05 C 4축 Servo + RED 실물 검증 완료
>
> 최종 검증: 2026-08-22, 현재 폴더의 RTL과 xsim 재실행 결과
>
> 범위: 현재 체크아웃에는 주로 C(Event/Control) 산출물이 있으며, A/B 작업은 아직 합쳐지지 않았다.

## 한눈에 보기

Day 04의 Event/Camera Tracking 경로에 이어 Day 05에는 카메라 PT#1과 레이저 PT#2를
분리한 4-Servo 제어를 구현했다. PT#2는 카메라 현재 자세에 화면 잔차와 Offset을
더해 절대방향을 계산하며, 실제 레이저 대신 LED가 Fail-Closed Interlock을 표시한다.
최종 4축+RED 보드 Top 32개를 포함한 C 자동 판정 Test는 총 **221/221 PASS**이며,
Camera PT#1 + Laser PT#2 네 Servo와 JD7 RED도 실물 전 항목 PASS했다. 전체 시스템
기준으로는 CNN/INT8 Golden, Dense NPU, 실제 Camera/NPU Target과의 Closed-loop 연결이 남아 있다.

| 전체 성공 기준 | 현재 저장소 상태 | 다음 Gate |
|---|---|---|
| Event Tensor 생성 | **C 경로 구현 완료** — Adapter + Ping-Pong Accumulator | B Golden 및 A NPU와 통합 |
| Tiny CNN 학습/INT8 변환 | **산출물 미반영** | B 브랜치/산출물 합류 |
| Python Integer Golden | **산출물 미반영** | B Golden 및 Test Vector 합류 |
| Dense INT8 NPU RTL | **산출물 미반영** | A NPU RTL 합류 |
| NPU Target `(x, y)` 출력 | **산출물 미반영** | Argmax Decoder 및 통합 |
| Camera PT#1 Closed-loop Tracking | **C RTL 완료** — Tracking + Slew + 2 PWM | A Target 출력 연결 및 실물 Closed-loop |
| Laser PT#2 Follower | **C RTL 완료** — PT#1 자세 + 잔차 + Offset | FOV/방향/Offset 실측 |
| Laser 안전 출력 | **LED Interlock 실물 검증 완료** — Fail-Closed + Watchdog | Camera/NPU 연동·보정 후 실제 구동단 전환 |

## 완료 및 검증 결과

| 항목 | 상태 | 2026-08-22 재검증 |
|---|---|---|
| `rtl/event/event_adapter.v` | D2 구현 완료 | `tb_event_adapter` **23/23 PASS** |
| `rtl/event/event_accumulator.v` | D3 구현 완료 | `tb_event_accumulator` **15/15 PASS**, 8192 B 전수 비교 |
| Adapter→Accumulator 통합 경로 | D4 검증 완료 | `tb_event_pipeline` **15/15 PASS**, 2 Window × 8192 B 전수 비교 |
| `rtl/control/servo_pwm.v` | D1 구현 완료 | `tb_servo_pwm` **6/6 PASS** |
| `rtl/control/board_io.v` | D3 축별 단독 검증 완료 | `tb_board_io` **19/19 PASS**, PAN/TILT 실물 구동 완료 |
| `rtl/control/tracking_controller.v` | D4 구현 완료 | `tb_tracking_controller` **30/30 PASS** |
| `rtl/control/laser_head_controller.v` | D5 구현 완료 | `tb_laser_head_controller` **23/23 PASS** |
| `rtl/control/laser_interlock.v` | D5 LED 우선 구현 완료 | `tb_laser_interlock` **28/28 PASS** |
| `rtl/control/dual_head_control.v` | D5 4-Servo 통합 완료 | `tb_dual_head_control` **30/30 PASS**, 네 PWM 펄스폭 확인 |
| `rtl/control/laser_board_io.v` | PT#2 단독 실물 브링업 완료 | JD3/JD4 Servo 방향·범위 정상, DRC 0 Error, WNS +0.396 ns / WHS +0.165 ns |
| `rtl/control/dual_head_board_io.v` | 4축+JD7 RED 최종 실물 검증 완료 | 32/32 PASS + 실물 전 항목 PASS, DRC 0 Error, WNS +1.068 ns / WHS +0.179 ns |
| Zybo Z7-20 제약/Tcl 빌드 경로 | 준비 완료 | WNS +0.357 ns, WHS +0.047 ns |
| 웹캠 Fallback 능력 측정 도구 | 구현 완료 | APC850 기준 640×480 YUYV 30 fps 확인 |
| C Handoff | D5 갱신 | PT#2 식 승인, 4축/LED 포트와 JD1~JD4 핀 제안 |

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
```

## 현재 블로커와 결정 요청

| 우선순위 | 요청 | 영향 | 담당 |
|---:|---|---|---|
| 1 | A `target_update`를 NPU done에 연결 | Interlock의 새 결과/Watchdog 판정 | A |
| 2 | AXI 4개 Servo Command의 Manual/Status 방향 결정 | C 자동 명령의 PS 가시성 | A/C |
| 3 | JD1~JD4 + JD7 핀을 통합 XDC에 반영 | A `top_system`의 4축+RED 출력 | A |
| 4 | 웹캠 FOV와 PT#2 축 방향 실측 | `*_ERR_NUM/DEN`, `*_INVERT` 확정 | C |
| 5 | 고정 시연 거리에서 PT#2 Offset 실측 | Parallax 보정 | C |
| 6 | CR C-002 Event Window + Webcam Fallback 검토 | Dataset/Golden 재생성 가능성 | A/B |

해결된 핵심 결정은 Tensor 전달 방식 Direct Handshake, CHW 주소 순서
`(polarity << 12) | (y << 6) | x`, C/NPU 100 MHz 단일 클럭 도메인이다.

## 다음 액션

- A: `docs/C_TO_A_REPLY_002.md`의 Target Update, AXI Command 방향, JD 핀을 회신한다.
- B: CR C-004 채널 순서와 CR C-002의 33.3 ms Window 영향을 검토한다.
- C: 레이저 부품 도착 후 2 m 고정 거리에서 FOV Scale과 Offset을 실측한다.
- A/C: 실제 NPU `target_update/valid/x/y/score`를 연결해 영상 기반 중앙 판정을 검증한다.
- A/C: `event_accumulator` Direct Handshake를 NPU 입력에 연결해 Golden과 비교한다.
- 팀: A/B 브랜치를 `integration`에 합쳐 이 문서를 전체 프로젝트 기준으로 갱신한다.

## 공유 규칙

- 구현 상태가 바뀔 때 이 문서의 표와 날짜를 함께 갱신한다.
- 공유 인터페이스 변경은 먼저 `docs/CHANGE_REQUEST_*.md`로 제안한다.
- 생성 가능한 Vivado 산출물, 로그, 비트스트림은 Git에 올리지 않는다.
- 진행 중 작업은 기능 브랜치와 Draft PR로 공유하고, 검증 후 `integration`에 합친다.
