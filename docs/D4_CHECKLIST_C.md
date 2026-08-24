# D4 체크리스트 — 담당 C

> **문서 등급** — SPEC §1 기준 4순위 개인 작업 메모.
> **D4 목표** (`TEAM_ROLE_PLAN.md`의 당시 D4 계획) — Event Tensor 단위 TB + Tracking Controller
> **날짜** 2026-08-21

## 완료 판정

**C 소유 Day 4 범위는 완료했다.** Adapter→Accumulator 연결형 TB에서 두 Window의
8192-byte Tensor를 전수 비교했고, Tracking Controller에 P Control, ±4 Dead Zone,
Target Lost Hold, Servo Frame 기반 Slew Limit과 Soft Limit을 구현했다.

| D4 산출물 | 파일 | 완료 기준 | 결과 |
|---|---|---|---|
| Tracking Controller | `rtl/control/tracking_controller.v` | Target→PAN/TILT P Control + 안전 제어 | 완료 |
| Tracking 판정 TB | `tb/control/tb_tracking_controller.v` | 방향·Hold·Dead Zone·Slew·Limit | **30/30 PASS** |
| Event Pipeline 판정 TB | `tb/event/tb_event_pipeline.v` | Adapter→Accumulator 8192 B 전수 비교 | **15/15 PASS** |

## 1. Tracking Controller

- [x] SPEC §14 입력 `target_valid/x/y/score` 사용
- [x] Center `(32,32)`와 signed Error 계산
- [x] `abs(error) <= 4`를 Dead Zone으로 포함
- [x] `target_valid=0`이면 현재 위치 Hold
- [x] `target_valid` Level을 매 Clock이 아니라 `frame_tick`마다 한 번만 처리
- [x] P Gain: `(|error| * P_GAIN) >> P_GAIN_SHIFT`
- [x] Dead Zone 밖의 최소 이동량 1 step 보장
- [x] Servo Frame당 `SLEW_LIMIT` 적용
- [x] PAN/TILT Soft Limit `32~224`
- [x] `PAN_INVERT` / `TILT_INVERT` parameter
- [x] PAN/TILT 독립 및 동시 이동

기본값:

```text
DEAD_ZONE    = 4
P_GAIN       = 1
P_GAIN_SHIFT = 2
SLEW_LIMIT   = 1 step / 20 ms
POS_LIMIT    = 32 ~ 224
```

`SLEW_LIMIT=1`은 실측 `0.469°/step` 기준 약 23.45°/s다. 부드러운 구동을 위한
D4 시작값이며 실제 카메라 하중에서 D5~D10에 1~4 범위를 튜닝한다.

## 2. Tracking TB 결과 — 30/30 PASS

- Reset Neutral 128
- `frame_tick` 없을 때 Hold
- Target Lost 즉시 Hold
- 양자화 중심값 28/36의 ±4 Dead Zone
- PAN Left/Right, TILT Up/Down
- 두 축 독립 및 동시 이동
- `target_valid`가 유지돼도 Frame당 한 번만 갱신
- P Gain과 Slew Clamp
- 이동 중 반대 방향 전환
- 음수 Score에서도 `target_valid` 권위 유지
- 축 방향 반전 parameter
- 상·하한 도달 및 추가 명령 Clamp

## 3. Event Pipeline TB 결과 — 15/15 PASS

```text
Raw 640x480 Event
    -> event_adapter
    -> 64x64 표준 Event
    -> event_accumulator
    -> CHW 8192-byte Tensor
```

- [x] Accumulator INIT 후 Ready
- [x] 640×480→64×64 Binning
- [x] Positive/Negative CHW 채널
- [x] 연속 동일 좌표와 127 포화
- [x] OOR Event 7개 폐기 및 Count
- [x] Window End와 같은 Cycle Event 포함
- [x] `npu_busy` 중 전송 0 byte
- [x] Window 1 8192-byte 전수 비교
- [x] Window 1 전송 중 Window 2 Event 320개 보존
- [x] Window 2 8192-byte 전수 비교
- [x] 주소 순서 0→8191, Overrun 0

## 4. 전체 회귀 기준

| 테스트 | 결과 |
|---|---:|
| `tb_event_adapter` | 23/23 PASS |
| `tb_event_accumulator` | 15/15 PASS |
| `tb_event_pipeline` | 15/15 PASS |
| `tb_servo_pwm` | 6/6 PASS |
| `tb_board_io` | 19/19 PASS |
| `tb_tracking_controller` | 30/30 PASS |
| **합계** | **108/108 PASS** |

## 5. 남은 통합 Gate

- A: 실제 `target_valid/x/y/score`를 Tracking에 연결
- A: Block Design 100 MHz와 PAN/TILT Register Interface 확인
- B: Event Polarity 채널과 33.3 ms Window 영향 확인
- A/B/C: C Tensor와 B Golden/A NPU 전수 비교
- C: 실제 하중에서 PAN/TILT 방향과 `SLEW_LIMIT=1` 속도 확인

## 6. D5 인계

- 실제 서보에서 Dead Zone / Soft Limit / Slew Limit 검증
- `PAN_INVERT` / `TILT_INVERT` 실물 방향 확정
- CR C-002 회신에 따라 Event Window parameter 검증
- A/B 산출물 합류 시 Event Tensor Golden 비교

```text
[DAILY STATUS]

담당: C
날짜: 2026-08-21 (D4)

오늘 완료:
- tracking_controller.v 구현 및 30/30 PASS
- ±4 Dead Zone, Target Lost Hold, P Control, Slew Limit, Soft Limit 구현
- Adapter→Accumulator 통합 TB 15/15 PASS
- 두 Window의 8192-byte Tensor 전수 비교

현재 PASS Test:
- 전체 C 자동 판정 108/108 PASS, errors 0

현재 막힌 점:
- C 단독 D4 범위에는 블로커 없음
- 전체 Closed-loop는 A Target 출력/B Golden 합류 필요

다음 목표:
- D5 실제 서보 제어 파라미터와 Event Window 검증
```
