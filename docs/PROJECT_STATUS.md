# 프로젝트 진행상황

> 기준점: 2026-08-21 Day 04 C 범위 종료
>
> 최종 검증: 2026-08-21, 현재 폴더의 RTL과 xsim 재실행 결과
>
> 범위: 현재 체크아웃에는 주로 C(Event/Control) 산출물이 있으며, A/B 작업은 아직 합쳐지지 않았다.

## 한눈에 보기

Day 04 C 목표인 Event Tensor 연결형 TB와 Tracking Controller를 완료했다.
Raw 640×480 Event가 Adapter→Accumulator를 거쳐 만든 두 Window의 8192-byte Tensor를
전수 비교했고, Tracking은 ±4 Dead Zone, Target Lost Hold, P Control, Frame 단위
Slew Limit, 방향 반전, 32~224 Soft Limit을 구현했다. C 자동 판정 Test는 총
108/108 PASS다. 전체 시스템 기준으로는 CNN/INT8 Golden, Dense NPU와 실제
Closed-loop 경로가 아직 합쳐지지 않았다.

| 전체 성공 기준 | 현재 저장소 상태 | 다음 Gate |
|---|---|---|
| Event Tensor 생성 | **C 경로 구현 완료** — Adapter + Ping-Pong Accumulator | B Golden 및 A NPU와 통합 |
| Tiny CNN 학습/INT8 변환 | **산출물 미반영** | B 브랜치/산출물 합류 |
| Python Integer Golden | **산출물 미반영** | B Golden 및 Test Vector 합류 |
| Dense INT8 NPU RTL | **산출물 미반영** | A NPU RTL 합류 |
| NPU Target `(x, y)` 출력 | **산출물 미반영** | Argmax Decoder 및 통합 |
| Pan/Tilt Closed-loop Tracking | **C RTL 완료** — Tracking + Slew Limit + Servo PWM | A Target 출력 연결 및 실물 Closed-loop |

## 완료 및 검증 결과

| 항목 | 상태 | 2026-08-21 재검증 |
|---|---|---|
| `rtl/event/event_adapter.v` | D2 구현 완료 | `tb_event_adapter` **23/23 PASS** |
| `rtl/event/event_accumulator.v` | D3 구현 완료 | `tb_event_accumulator` **15/15 PASS**, 8192 B 전수 비교 |
| Adapter→Accumulator 통합 경로 | D4 검증 완료 | `tb_event_pipeline` **15/15 PASS**, 2 Window × 8192 B 전수 비교 |
| `rtl/control/servo_pwm.v` | D1 구현 완료 | `tb_servo_pwm` **6/6 PASS** |
| `rtl/control/board_io.v` | D3 축별 단독 검증 완료 | `tb_board_io` **19/19 PASS**, PAN/TILT 실물 구동 완료 |
| `rtl/control/tracking_controller.v` | D4 구현 완료 | `tb_tracking_controller` **30/30 PASS** |
| Zybo Z7-20 제약/Tcl 빌드 경로 | 준비 완료 | WNS +0.357 ns, WHS +0.047 ns |
| 웹캠 Fallback 능력 측정 도구 | 구현 완료 | APC850 기준 640×480 YUYV 30 fps 확인 |
| SPEC v1.2 및 C Handoff | 동기화 완료 | D4 결과 반영, CR C-001/C-002/C-004 회신 대기 |

재현 명령:

```bash
./sim/run_xsim.sh tb_event_adapter
./sim/run_xsim.sh tb_event_accumulator
./sim/run_xsim.sh tb_event_pipeline
./sim/run_xsim.sh tb_servo_pwm
./sim/run_xsim.sh tb_board_io
./sim/run_xsim.sh tb_tracking_controller
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
- C: D5 실제 서보에서 `SLEW_LIMIT=1` 시작값과 Dead Zone/방향을 확인하고 Event Window를 검증한다.
- A/C: `event_accumulator` Direct Handshake를 NPU 입력에 연결해 Golden과 비교한다.
- 팀: A/B 브랜치를 `integration`에 합쳐 이 문서를 전체 프로젝트 기준으로 갱신한다.

## 공유 규칙

- 구현 상태가 바뀔 때 이 문서의 표와 날짜를 함께 갱신한다.
- 공유 인터페이스 변경은 먼저 `docs/CHANGE_REQUEST_*.md`로 제안한다.
- 생성 가능한 Vivado 산출물, 로그, 비트스트림은 Git에 올리지 않는다.
- 진행 중 작업은 기능 브랜치와 Draft PR로 공유하고, 검증 후 `integration`에 합친다.
