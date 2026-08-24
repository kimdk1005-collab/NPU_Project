# D3 체크리스트 — 담당 C

> **문서 등급** — SPEC §1 기준 4순위 개인 작업 메모.
> **D3 목표** (`TEAM_ROLE_PLAN.md`의 당시 D3 계획) — Event Accumulator + Pan/Tilt 단독 테스트
> **날짜** 2026-08-21

## 완료 판정

**C 소유 Day 3 범위는 완료했다.** Event Accumulator RTL과 판정 TB가 통과했고,
PAN/TILT는 시뮬레이션에서 두 축의 독립 동작을 확인했다. 기존 보드 브링업에서
두 축의 실물 구동도 완료했다. A NPU 및 B Golden과의 시스템 통합은 별도 Gate다.

| D3 산출물 | 구현 | 완료 기준 | 결과 |
|---|---|---|---|
| Event Accumulator | `rtl/event/event_accumulator.v` | 64×64×2 누적, 127 포화, Ping-Pong, Direct Handshake | 완료 |
| Accumulator TB | `tb/event/tb_event_accumulator.v` | Window별 8192 B 전수 비교 | **15/15 PASS** |
| Pan/Tilt 단독 TB | `tb/control/tb_board_io.v` | PAN/TILT 축별 조그·Hold·중립·범위·Sweep | **19/19 PASS** |
| Pan/Tilt 실물 | Zybo Z7-20 + MG996R 2축 | 축 전환 및 양 축 동작 | 완료 |

## 1. Event Accumulator

- [x] CHW 주소식: `(polarity << 12) | (y << 6) | x`
- [x] Positive Ch0 / Negative Ch1 분리
- [x] 셀당 Event Count `0~127` 포화, Wrap 방지
- [x] 연속 동일 주소의 Read-Modify-Write 포워딩
- [x] Window 경계 시 Ping-Pong 버퍼 전환
- [x] `npu_busy` 동안 `tensor_we=0`
- [x] 8192 byte 순차 전송 후 `tensor_start` 1-cycle pulse
- [x] 전송과 동시에 이전 버퍼 초기화
- [x] 전송 중 다음 Window 이벤트 보존
- [x] 지정 자극·무작위 2000 이벤트의 Tensor 전수 비교

전송 포트는 A의 Direct Handshake 규격에 대응한다.

```text
tensor_we    -> ext_we
tensor_addr  -> ext_addr[12:0]
tensor_data  -> ext_data[7:0]
tensor_start -> start
npu_busy     <- busy
```

## 2. Pan/Tilt 단독 테스트

`tb_board_io`는 기존 PAN 중심 검증에 다음 TILT 독립축 항목을 추가했다.

- [x] TILT 선택 후 좁은 범위 상·하한까지 양방향 조그
- [x] TILT 조그 중 PAN 중립 유지
- [x] PAN으로 전환한 뒤에도 TILT 위치 유지
- [x] TILT만 중립 복귀
- [x] TILT 복귀 중 PAN 위치 유지

기존 검증인 PWM disable, 20 ms Frame, PAN 상·하한, Wide→Narrow 안전 복귀,
1 Hz Heartbeat, Sweep 범위/방향 반전을 포함해 총 **19/19 PASS**다.

실물 브링업 결과는 PAN/TILT 모두 정상이며 안전 위치 범위는 `32~224`, 측정
스케일은 약 `0.469°/step`이다. Closed-loop Tracking은 D4 범위다.

## 3. 회귀 테스트

```bash
./sim/run_xsim.sh tb_event_adapter
./sim/run_xsim.sh tb_event_accumulator
./sim/run_xsim.sh tb_servo_pwm
./sim/run_xsim.sh tb_board_io
```

| 테스트 | 기대 결과 |
|---|---:|
| `tb_event_adapter` | 23/23 PASS |
| `tb_event_accumulator` | 15/15 PASS |
| `tb_servo_pwm` | 6/6 PASS |
| `tb_board_io` | 19/19 PASS |

## 4. 공유 결정과 남은 통합 Gate

완료된 결정:

- Direct Handshake와 CHW 주소 순서 수용·구현
- C 통합 모듈 `CLK_HZ=100 MHz` 반영 (`board_io` 브링업 Top만 125 MHz)
- `event_polarity`: C 구현은 A 제안인 `0=Positive`, `1=Negative` 반영

남은 팀 확인:

- A: Block Design에서 C 모듈에 100 MHz 공급 확인
- A: CR C-001 Servo Command Format 및 PAN/TILT Register Bit Field 확정
- A/B: CR C-002 Event Window 33,333 us 및 Webcam 입력 경로 결정
- B: CR C-004 polarity와 Dataset 채널 순서 확인
- A/B/C: `event_accumulator` 출력과 실제 NPU/Golden의 통합 비교

## 5. D4 인계

- `tracking_controller.v`와 단위 TB 구현
- `target_valid=0`일 때 위치 Hold 검증
- `abs(error_x/y) <= 4` Dead Zone 검증
- PAN/TILT soft limit와 frame당 Slew Limit 검증
- B Golden이 합류하면 Event Tensor 통합 비교 수행

```text
[DAILY STATUS]

담당: C
날짜: 2026-08-21 (D3)

오늘 완료:
- event_accumulator.v 구현 및 15/15 PASS, 8192 B 전수 비교
- tb_board_io TILT 독립축 검증 보강, 19/19 PASS
- Day 3 체크리스트와 C Handoff/프로젝트 상태 동기화

현재 막힌 점:
- C 단독 D3 작업에는 블로커 없음
- 전체 통합은 A NPU/B Golden 및 공유 CR 회신 필요

다음 목표:
- D4 Event Tensor 통합 검증 + Tracking Controller
```
