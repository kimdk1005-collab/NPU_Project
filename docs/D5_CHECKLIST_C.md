# D5 체크리스트 — 담당 C

> 날짜: 2026-08-22
> 기준: 팀 공통 통합 명세 v1.5 §15.0/§15.2/§17의 2-Head 변경안
> 범위: 레이저 부품 도착 전, 실제 광원 대신 LED로 검증하는 단계

## 완료 판정

**배송 전 구현 가능한 C 범위는 완료했다.** 카메라 PT#1과 레이저 PT#2를 분리한
4-Servo 경로, PT#2 절대방향 변환, Fail-Closed LED Interlock을 구현했다.
기존 카메라 2축 브링업 Top은 실물 재현용으로 변경하지 않았다. PT#2는 같은 검증
로직을 JD3/JD4에만 연결하는 `laser_board_io.v`와 별도 Bitstream 경로를 사용한다.
최종 4축 Servo와 JD7 RED는 2026-08-22 실물 테스트에서 전 항목 PASS했다.

| 산출물 | 역할 | 검증 |
|---|---|---:|
| `rtl/control/laser_head_controller.v` | PT#1 자세 + 화면 잔차 + Offset → PT#2 명령 | **23/23 PASS** |
| `rtl/control/laser_interlock.v` | Score/Zone/Limit/E-stop/Freshness 기반 LED 허용 | **28/28 PASS** |
| `rtl/control/dual_head_control.v` | PT#1 2축 + PT#2 2축 + LED 통합 | **30/30 PASS** |

## 1. PT#2 좌표 변환

각도를 Servo `pos` 단위로 바꾼 다음 v1.5 §15.2 식을 그대로 적용한다.

```text
laser_pan_target
  = camera_pan_pos
  + (target_x - 32) * PAN_ERR_NUM / PAN_ERR_DEN
  + PAN_OFFSET_POS

laser_tilt_target
  = camera_tilt_pos
  + (target_y - 32) * TILT_ERR_NUM / TILT_ERR_DEN
  + TILT_OFFSET_POS
```

- 카메라 자세를 반드시 더한다. `PAN2=f(error_x)` 형태가 아니다.
- `*_ERR_NUM/DEN`은 `FOV/64`를 Servo step으로 환산한 값이다.
- FOV, 축 부호, Offset은 실측 전 미확정이므로 parameter로 분리했다.
- PT#2 명령도 Frame 기반 Slew와 `SAFE_LIMIT2=32~224`를 적용한다.
- 현재 PT#2 출력이 계산 목표에 도달해야 `aim_ready=1`이다.

기본 `1/1` scale은 **LED 브링업 시작값일 뿐 최종 캘리브레이션 값이 아니다.**

## 2. LED Interlock

다음 조건을 모두 만족해야 `laser_enable_safe=laser_led=1`이다.

```text
Servo Enable + Laser Arm
Emergency Stop == 0
target_valid == 1
signed target_score >= SCORE_THRESHOLD
Target inside Safe Zone
Target inside Lock Zone (최소 ±4)
PT#1 inside SAFE_LIMIT
PT#2 inside SAFE_LIMIT2
PT#2 aim_ready
새 NPU 결과가 watchdog 안에 도착
연속 3회 Lock 확인
연속 ON 시간 제한 미초과
```

하나라도 틀리면 1 clock 이내 OFF한다. 기본 연속 ON 제한은 25 Servo Frame,
즉 50 Hz 기준 500 ms이며, 타임아웃 후 Target Lock 이탈 또는 Arm 해제 전에는
자동 재점등하지 않는다.

## 3. 4-Servo 출력

`dual_head_control.v`이 한 `frame_tick` 위상으로 아래 네 PWM을 생성한다.

| 출력 | Head | 제안 핀 |
|---|---|---|
| `camera_pan_pwm` | PT#1 Camera PAN | JD1 / T14 |
| `camera_tilt_pwm` | PT#1 Camera TILT | JD2 / T15 |
| `laser_pan_pwm` | PT#2 Laser PAN | JD3 / P14 |
| `laser_tilt_pwm` | PT#2 Laser TILT | JD4 / R14 |
| `laser_led` | 안전 허용 표시 | JD7 / U14, RGB 모듈 `R` |

최종 `top_system`의 공유 Master XDC는 A 소유다. C는 별도 브링업 XDC에서 위 핀을
검증했으며, A가 같은 매핑을 최종 Top 포트명에 맞춰 반영해야 한다.

서보 네 개는 FPGA/Pmod 3.3 V에서 전원을 공급하지 않는다. 별도 5~6 V 전원을 쓰고
전원 GND와 Zybo GND만 공통으로 연결한다.

## 4. 자동 판정 결과

| 테스트 | 검증 내용 | 결과 |
|---|---|---:|
| `tb_laser_head_controller` | 절대 좌표식, 분수 Scale, 반전, Offset, Slew, Clamp, Hold | 23/23 PASS |
| `tb_laser_interlock` | signed Score, Safe/Lock Zone, 두 Head Limit, E-stop, watchdog, max-on | 28/28 PASS |
| `tb_dual_head_control` | 4개 PWM 실측, 두 Head 독립 위치, LED, Servo Disable, Lost Hold | 30/30 PASS |
| `tb_dual_head_board_io` | 보드 Target 조작, 4 PWM, JD7 RED, E-stop, Max-On | 32/32 PASS |
| **D5 신규 합계** | | **81/81 PASS** |
| **최종 보드 Top 추가** | | **32/32 PASS** |
| **C 전체 누적 판정** | 기존 108 + D5 81 + 보드 Top 32 | **221/221 PASS** |

재현 명령:

```bash
./sim/run_xsim.sh tb_laser_head_controller
./sim/run_xsim.sh tb_laser_interlock
./sim/run_xsim.sh tb_dual_head_control
```

## 5. 실물 검증 결과

PT#2 단독 Bitstream 재생성:

```bash
./sim/run_xsim.sh tb_board_io
vivado -mode batch -source sim/create_laser_bringup_project.tcl
```

이 Bitstream은 Laser PAN=JD3(P14), Laser TILT=JD4(R14)만 구동하며 실제 광원
출력은 없다. 최종 `top_system`용 Master XDC와는 분리된 C 로컬 브링업 경로다.
Vivado 2024.2 Implementation/DRC를 통과했으며 Timing은 WNS **+0.396 ns**,
WHS **+0.165 ns**다.

1. `sw=0000`으로 Program한 뒤 `led[0]` heartbeat가 1초 주기인지 확인한다.
2. PT#2 Servo만 JD3/JD4에 연결하고 외부 5~6 V 전원 GND를 Zybo와 공통 연결한다.
3. `sw[0]=1`, `sw[2]=0` 좁은 범위에서 PAN/TILT 방향을 각각 확인한다.
4. 실제 레이저 대신 On-board LED로 Lock 3회, Target Lost, E-stop을 확인한다.
5. 두 Head 모두 `32~224` 범위에서 기구 간섭이 없는지 축별로 실측한다.
6. 외부 전원 전압 강하와 네 Servo 동시 구동 전류를 확인한다.

Servo의 물리 방향을 기록한 뒤 자동 Target 경로에서
`PAN_ERR_INVERT` / `TILT_ERR_INVERT`를 표적판 좌·우/상·하 이동으로 확정한다.

2026-08-22에는 PT#2 단독 구동에 이어 Camera PT#1 + Laser PT#2 네 Servo,
Center 복귀, RED 3회 Lock, 약 500 ms Max-On, E-stop, Servo Disable을 모두
실물 확인했다. 이 결과는 가상 Target 입력 기준이며 실제 Camera/NPU 연동은 남아 있다.

## 6. 부품 도착 후 남은 Gate

- 고정 시연 거리 권장 2 m에서 `PAN_OFFSET_POS` / `TILT_OFFSET_POS` 실측
- 실제 웹캠 FOV로 `PAN_ERR_NUM/DEN`, `TILT_ERR_NUM/DEN` 확정
- Camera/NPU Target 연동과 FOV/Offset 보정 후 실제 레이저 구동단으로 전환
- 실제 레이저는 FPGA 핀 직결 금지: 정격 전원 + 트랜지스터/MOSFET 구동
- A `top_system`에 `target_update`(NPU done), Target 4신호, 4 PWM, LED 연결
- A가 JD1~JD4/JD7 XDC를 추가하고 Implementation Timing 재측정

현재 남은 항목은 부품/실측 또는 A 통합이 필요한 Gate이며, RTL 단위 구현의 실패가 아니다.
