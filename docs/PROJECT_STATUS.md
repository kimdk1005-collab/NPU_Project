# 프로젝트 진행상황

> 기준점: 2026-08-21 Day 02 종료
>
> 최종 검증: 2026-08-21, 현재 폴더의 RTL과 xsim 재실행 결과
>
> 범위: 현재 체크아웃에는 주로 C(Event/Control) 산출물이 있으며, A/B 작업은 아직 합쳐지지 않았다.

## 한눈에 보기

Day 02 목표인 Servo PWM과 Event Adapter는 RTL·시뮬레이션·보드 브링업까지 완료했다.
계획상 D3 산출물인 Event Accumulator도 선행 구현해 8192-byte Tensor 전수 비교를
통과했다. 전체 시스템 기준으로는 CNN/INT8 Golden, Dense NPU, Target Decoder,
Closed-loop Tracking이 아직 합쳐지지 않아 C 경로만 앞서 있는 상태다.

| 전체 성공 기준 | 현재 저장소 상태 | 다음 Gate |
|---|---|---|
| Event Tensor 생성 | **C 경로 구현 완료** — Adapter + Ping-Pong Accumulator | B Golden 및 A NPU와 통합 |
| Tiny CNN 학습/INT8 변환 | **산출물 미반영** | B 브랜치/산출물 합류 |
| Python Integer Golden | **산출물 미반영** | B Golden 및 Test Vector 합류 |
| Dense INT8 NPU RTL | **산출물 미반영** | A NPU RTL 합류 |
| NPU Target `(x, y)` 출력 | **산출물 미반영** | Argmax Decoder 및 통합 |
| Pan/Tilt Closed-loop Tracking | **부분 완료** — Servo PWM 및 2축 구동 완료 | Tracking Controller 구현 |

## 완료 및 검증 결과

| 항목 | 상태 | 2026-08-21 재검증 |
|---|---|---|
| `rtl/event/event_adapter.v` | D2 구현 완료 | `tb_event_adapter` **23/23 PASS** |
| `rtl/event/event_accumulator.v` | D3 선행 구현 완료 | `tb_event_accumulator` **15/15 PASS**, 8192 B 전수 비교 |
| `rtl/control/servo_pwm.v` | D1 구현 완료 | `tb_servo_pwm` **6/6 PASS** |
| `rtl/control/board_io.v` | 브링업 Top 구현 완료 | `tb_board_io` **13/13 PASS**, PAN/TILT 실물 구동 완료 |
| Zybo Z7-20 제약/Tcl 빌드 경로 | 준비 완료 | WNS +0.357 ns, WHS +0.047 ns |
| 웹캠 Fallback 능력 측정 도구 | 구현 완료 | APC850 기준 640×480 YUYV 30 fps 확인 |
| SPEC v1.2 및 C Handoff | 동기화 완료 | D3 Freeze A-001 반영, CR C-001/C-002/C-004 회신 대기 |

재현 명령:

```bash
./sim/run_xsim.sh tb_event_adapter
./sim/run_xsim.sh tb_event_accumulator
./sim/run_xsim.sh tb_servo_pwm
./sim/run_xsim.sh tb_board_io
```

## 현재 블로커와 결정 요청

| 우선순위 | 요청 | 영향 | 담당 |
|---:|---|---|---|
| 1 | CR C-004: `event_polarity` 0=Positive 확인 | Dataset 채널과 실입력 정합 | B |
| 2 | CR C-002: Event Window 33,333 us + Webcam Fallback 검토 | Dataset/Golden 재생성 가능성 | A/B |
| 3 | CR C-001 Servo Command Format 승인 | Tracking Controller 인터페이스 | A |
| 4 | PAN/TILT 레지스터 Bit Field 확정 | SoC↔Control 인터페이스 | A |
| 5 | Webcam Frame Difference 실행 위치 확정 | PC 또는 Zybo PS 입력 경로 | A |

해결된 핵심 결정은 Tensor 전달 방식 Direct Handshake, CHW 주소 순서
`(polarity << 12) | (y << 6) | x`, C/NPU 100 MHz 단일 클럭 도메인이다.

## 다음 액션

- A: PAN/TILT 레지스터 필드와 Frame Difference 실행 위치를 확정한다.
- B: CR C-004 채널 순서와 CR C-002의 33.3 ms Window 영향을 검토한다.
- C: D4 `tracking_controller.v`를 구현하고 실측된 0.469°/step을 기준으로 튜닝한다.
- A/C: `event_accumulator` Direct Handshake를 NPU 입력에 연결해 Golden과 비교한다.
- 팀: A/B 브랜치를 `integration`에 합쳐 이 문서를 전체 프로젝트 기준으로 갱신한다.

## 공유 규칙

- 구현 상태가 바뀔 때 이 문서의 표와 날짜를 함께 갱신한다.
- 공유 인터페이스 변경은 먼저 `docs/CHANGE_REQUEST_*.md`로 제안한다.
- 생성 가능한 Vivado 산출물, 로그, 비트스트림은 Git에 올리지 않는다.
- 진행 중 작업은 기능 브랜치와 Draft PR로 공유하고, 검증 후 `integration`에 합친다.
