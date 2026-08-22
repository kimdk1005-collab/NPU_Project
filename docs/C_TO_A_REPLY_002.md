# C → A 회신 002 — PT#2 좌표식 / 4-Servo / LED Interlock

> 회신일: 2026-08-22
> 수신 문서: `C_TO_A_DELIVERY_SPEC.md` §8~§10
> 기준 변경안: 공통 통합 명세 v1.5 §15.0/§15.2/§17

## 결론

1. **PT#2 좌표 변환식에 동의하며 그대로 구현했다.**
2. PT#1 Camera 2축과 PT#2 Laser 2축을 분리한 **4-Servo 출력 경로를 구현했다.**
3. 실제 광원 대신 **LED가 동일한 Fail-Closed Interlock을 사용**하게 했다.
4. `SAFE_LIMIT2` 검사를 필수 조건으로 넣었다.
5. Camera PT#1 + Laser PT#2 네 Servo와 JD7 RED를 실물 검증했다.

## 전달 RTL

| 파일 | A가 연결할 핵심 신호 |
|---|---|
| `rtl/control/dual_head_control.v` | 통합 Wrapper. 아래 모듈과 4개 `servo_pwm` 인스턴스 |
| `rtl/control/laser_head_controller.v` | PT#1 자세 + Target 잔차 → PT#2 절대 명령 |
| `rtl/control/laser_interlock.v` | `laser_enable_safe`, 상태 출력 |

`dual_head_control` 입력:

```verilog
clk                    // 100 MHz FCLK_CLK0
rst_n
servo_enable
target_update          // 새 NPU 결과 1-cycle pulse. NPU done에 연결
target_valid
target_x[5:0]
target_y[5:0]
signed target_score[7:0]
laser_arm
emergency_stop
```

물리 출력:

```verilog
camera_pan_pwm
camera_tilt_pwm
laser_pan_pwm
laser_tilt_pwm
laser_led              // 현재 단계에서는 실제 광원 대신 사용
```

진단/통합 출력:

```verilog
camera_pan_pos[7:0]
camera_tilt_pos[7:0]
laser_pan_pos[7:0]
laser_tilt_pos[7:0]
laser_pan_target[7:0]
laser_tilt_target[7:0]
laser_aim_ready
laser_lock_qualified
laser_target_fresh
laser_timeout_fault
laser_enable_safe
```

## §15.2 구현 확인

Servo `pos` 단위에서 다음 식으로 구현했다.

```text
PAN2 = PAN1 + error_x * PAN_ERR_NUM / PAN_ERR_DEN + PAN_OFFSET_POS
TILT2 = TILT1 + error_y * TILT_ERR_NUM / TILT_ERR_DEN + TILT_OFFSET_POS
```

따라서 금지된 `PAN2=f(error_x)` 구현이 아니다. 화면 오차가 같아도 PT#1 자세가
바뀌면 PT#2 절대 목표도 같은 양만큼 바뀌는 것을 TB에서 확인했다.

FOV/부호/Offset은 실측 전 값이 아니므로 RTL parameter로 남겼다. 기본 1/1과 Offset 0은
LED 브링업용이며 실제 레이저 장착 전에 반드시 교체한다.

## Servo Command와 AXI Register 정합

C의 물리 Servo 명령은 다음과 같다.

```text
형식        unsigned 8-bit pos
안전 범위   32~224 inclusive
중립        128
PWM         50 Hz, 500~2500 us scale, 출력단 clamp
```

현재 A의 `PAN_CMD/TILT_CMD/PAN2_CMD/TILT2_CMD`는 **RW 저장소에서 C 방향 출력**이고,
C 자동 Tracking 명령은 반대로 C에서 생성된다. 따라서 바로 연결하면 자동 명령을
AXI에서 읽어 볼 수 없다.

A 통합 시 다음 중 하나를 결정해야 한다.

- 권장: 기존 RW 값은 Manual Override 명령으로 유지하고, C의 실제 4개 `*_pos[7:0]`를
  별도 RO Status Register 또는 ILA에 연결한다.
- 대안: 네 Command Register를 C 실제 명령 입력형 RO로 변경한다.

현재 D5 RTL은 자동 추적 경로를 구현했으며 AXI Manual Override MUX는 넣지 않았다.
이 결정은 A의 `npu_axi.v/top_system.v` 소유 범위라 A 회신 후 연결한다.

`SAFE_LIMIT` / `SAFE_LIMIT2`도 현재 RTL parameter로 적용된다. AXI 런타임 변경을
허용하려면 A 출력값을 검증한 뒤 Clamp에 연결하는 별도 통합 변경이 필요하다.

## 핀 제안 — A가 XDC에 반영

| 신호 | Zybo Z7-20 | FPGA Pin |
|---|---|---|
| `camera_pan_pwm` | JD1 | T14 |
| `camera_tilt_pwm` | JD2 | T15 |
| `laser_pan_pwm` | JD3 | P14 |
| `laser_tilt_pwm` | JD4 | R14 |
| `laser_led` | JD7 | U14 |
| LED/Servo 공통 GND | JD11 | GND |

공유 Master XDC는 A 소유다. C는 `constraints/c_dual_head_drive_test.xdc`의 별도
브링업 경로에서 위 핀을 검증했다. A가 최종 Top 포트명으로 추가한 뒤 DRC,
Implementation, Timing을 재검증해 달라.

## 자동 검증

```text
tb_laser_head_controller  23/23 PASS
tb_laser_interlock        28/28 PASS
tb_dual_head_control      30/30 PASS
신규 합계                 81/81 PASS
tb_dual_head_board_io     32/32 PASS
전체 C 회귀              221/221 PASS
```

실물 결과: Camera/Laser 네 Servo, Center 복귀, JD7 RED Lock, 500 ms Max-On,
E-stop, Servo Disable 전 항목 PASS. 보드 Top은 가상 Target 입력을 사용하므로 실제
Camera/NPU Closed-loop 검증은 A 통합 후 수행한다.

## A에게 필요한 회신

1. `target_update`를 NPU `done` 1-cycle pulse에 연결 가능한지
2. AXI Command Register를 Manual Override로 유지할지, RO Status로 바꿀지
3. 위 JD1~JD4 + JD7 핀 배치 승인 및 XDC 반영 여부
4. `laser_arm`과 `emergency_stop`의 실제 입력원(AXI bit / 보드 버튼) 결정
