# D5 최종 구동 테스트 — Camera PT#1 + Laser PT#2 + RED

> 대상: Zybo Z7-20 순수 PL 실물 검증
> 실제 Laser 광원: **연결 금지**
> 출력: Camera Servo 2축 + Laser Servo 2축 + 저항 내장 RGB LED 모듈의 RED
> 결과: **2026-08-22 실물 전 항목 PASS**

## 1. 검증 Bitstream

```text
vivado_dual_head_bringup/
  c_dual_head_drive_test.runs/impl_1/dual_head_board_io.bit
```

재생성:

```bash
./sim/run_xsim.sh tb_dual_head_board_io
vivado -mode batch -source sim/create_dual_head_drive_test_project.tcl
```

Vivado 2024.2 결과:

- `tb_dual_head_board_io`: **32/32 PASS**
- 기존 D5 RTL 회귀: **81/81 PASS**
- DRC: **0 Error**
- Timing: WNS **+1.068 ns**, WHS **+0.179 ns**
- 외부 125 MHz에서 MMCM으로 100 MHz 제어 Clock 생성
- Servo 위치 제한: `112~144` 좁은 범위

## 2. 배선

| 기능 | Zybo JD | FPGA Pin | 연결 |
|---|---:|---|---|
| Camera PAN | JD1 | T14 | Camera PAN Servo signal |
| Camera TILT | JD2 | T15 | Camera TILT Servo signal |
| Laser PAN | JD3 | P14 | Laser PAN Servo signal |
| Laser TILT | JD4 | R14 | Laser TILT Servo signal |
| RED Interlock | JD7 | U14 | RGB LED module `R` |
| Common GND | JD5 또는 JD11 | GND | Servo 외부전원 GND + LED module `-` |

RGB LED module의 `G`, `B`는 연결하지 않는다. 모듈의 `331` 저항은 330 ohm
직렬저항이므로 외부 저항을 추가하지 않는다.

Servo 전원은 Zybo JD6/JD12에서 공급하지 않는다. 외부 5~6 V 전원을 사용하고
외부전원 GND와 Zybo GND만 공통 연결한다.

## 3. Switch와 Button

| 입력 | 기능 |
|---|---|
| `sw[0]` | 네 Servo PWM Enable |
| `sw[1]` | RED Interlock Arm |
| `sw[2]` | Test Target Valid |
| `sw[3]` | Emergency Stop — 1이면 RED 즉시 OFF |
| `btn[0]` | Target X -8 |
| `btn[1]` | Target X +8 |
| `btn[2]` | Target Y -8 |
| `btn[3]` | Target Y +8 |
| `btn[0]+btn[1]` | Target X를 Center 32로 복귀 |
| `btn[2]+btn[3]` | Target Y를 Center 32로 복귀 |

Button 한 번은 Target 좌표만 한 단계 바꾼다. NPU 영상 피드백이 없는 테스트라
Off-center Target을 유지하면 Servo는 좁은 안전 Limit까지 계속 이동한다. 방향을
확인한 즉시 해당 Center Button 조합을 눌러 이동을 멈춘다.

## 4. 실물 테스트 순서

1. 실제 Laser 광원이 분리됐는지 확인한다.
2. Servo 외부전원은 끄고 Zybo `sw=0000`에서 Bitstream을 Program한다.
3. On-board `led[0]`의 1 Hz heartbeat를 확인한다.
4. 네 Servo가 JD1~JD4에 올바르게 연결됐는지 다시 확인하고 외부전원을 켠다.
5. `sw[0]=1`로 네 Servo를 중립에 Hold한다.
6. `sw[2]=1`로 Test Target을 Valid하게 한다. `sw[1]`은 아직 0으로 둔다.
7. `btn[1]` 후 `btn[0]+btn[1]`로 두 PAN 방향을 확인한다.
8. `btn[3]` 후 `btn[2]+btn[3]`로 두 TILT 방향을 확인한다.
9. Target X/Y가 Center인 상태에서 `sw[1]=1`로 RED를 Arm한다.
10. 연속 3회 Lock과 PT#2 Aim Ready 후 JD7 RED 및 On-board `led[3]`가 켜진다.
11. RED는 기본 25 Frame, 즉 약 500 ms 후 자동으로 꺼지고 Fault가 유지된다.
12. `sw[1]=0`으로 Fault를 Clear한 뒤 다시 1로 올리면 재시험할 수 있다.
13. RED가 켜진 동안 `sw[3]=1`로 올려 즉시 꺼지는지 확인한다.
14. Servo까지 즉시 정지하려면 `sw[0]=0`으로 내린다.

## 5. 판정 기록

| 항목 | 기대 결과 | 실물 결과 |
|---|---|---|
| Camera PAN X+ | 좁은 범위에서 정상 방향 이동 | **PASS** |
| Camera TILT Y+ | 좁은 범위에서 정상 방향 이동 | **PASS** |
| Laser PAN X+ | PT#1 자세 + X 잔차 방향 이동 | **PASS** |
| Laser TILT Y+ | PT#1 자세 + Y 잔차 방향 이동 | **PASS** |
| Center 복귀 | Camera Hold, Laser가 Camera 자세에 도달 | **PASS** |
| RED 3회 Lock | JD7 RED + LED3 ON | **PASS** |
| Max-On | 약 500 ms 후 RED OFF | **PASS** |
| E-stop | RED 즉시 OFF | **PASS** |
| Servo Disable | 네 PWM OFF + RED OFF | **PASS** |

위 PASS는 Switch/Button이 만드는 **가상 Target** 기준의 구동·안전 검증이다.
실제 카메라 영상에서 Target 중앙을 판정하는 Camera/NPU Closed-loop 검증은 포함하지 않는다.

축 방향이 반대면 즉시 `sw[0]=0`으로 내리고
`CAMERA_*_INVERT` 또는 `LASER_*_INVERT` parameter를 수정해 다시 생성한다.
