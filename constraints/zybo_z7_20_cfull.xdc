# Zybo Z7-20 — C 실물 통합 빌드(`run_bd.tcl -cfull`) 전용 추가 핀 제약
#
# 출처 : docs/from_c/C_TO_A_REPLY_004.md §6  (C 가 실물로 검증한 배치)
#        C 저장소 constraints/c_dual_head_drive_test.xdc / c_ky008_laser_gate_test.xdc
#        Digilent Zybo-Z7-Master.xdc
#
#   servo_pwm[0] = PAN1  카메라 헤드   -> JD1 / T14
#   servo_pwm[1] = TILT1 카메라 헤드   -> JD2 / T15
#   servo_pwm[2] = PAN2  레이저 헤드   -> JD3 / P14
#   servo_pwm[3] = TILT2 레이저 헤드   -> JD4 / R14
#   laser_en                           -> JD7 / U14
#   laser_arm_hw                       -> SW1 / P15   ** 보드 시험 중 항상 DOWN(0) **
#   emergency_stop_hw                  -> SW3 / T16
#
# ---------------------------------------------------------------------
#  전원 / 안전 (C REPLY_004 §6, KY008_PREARRIVAL_CHECKLIST_C.md)
#   - 서보 전원은 외부 5~6 V 를 쓴다. JD6 의 3.3 V 로 서보를 돌리지 않는다.
#     외부 전원 GND 와 Zybo GND(JD5/JD11)를 반드시 공통으로 묶는다.
#   - laser_en 은 광원 전원선이 아니라 게이트 신호다. JD7/U14 -> 외부 1 kOhm
#     직렬 저항 -> KY-008 S. 5 V 경로에는 물리 Key Arm 과 NC E-stop 을 따로 둔다.
#   - laser_arm_hw 를 상수 0 으로 묶지 않고 SW1 에 연결한 이유:
#     상수로 묶으면 laser_interlock 의 자격 판정 논리가 통째로 최적화돼 사라져
#     통합 리소스/타이밍 수치가 실제보다 낮게 나온다 (§35 위반).
#     ** 대신 보드 시험 절차에서 SW1 을 DOWN(0) 으로 유지한다. **
#     또한 interlock 은 전원 인가 후 Arm 이 LOW 인 것을 한 번 봐야 무장되고
#     (arm_seen_low), LASER_CTRL[1] 도 reset 값이 0 이라 이중으로 막혀 있다.
#     실제 광원을 붙이는 것은 C 승인(§2.13 좌표변환 + 안전조건) 이후다.
# ---------------------------------------------------------------------

## Pmod JD — Servo PWM 4채널
set_property -dict { PACKAGE_PIN T14 IOSTANDARD LVCMOS33 } [get_ports { servo_pwm[0] }]
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 } [get_ports { servo_pwm[1] }]
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports { servo_pwm[2] }]
set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports { servo_pwm[3] }]

## Pmod JD7 — Laser Gate. 구동 전류를 낮추고 slew 를 늦춘다 (C 실물 검증 조건)
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 DRIVE 4 SLEW SLOW } \
    [get_ports { laser_en }]

## SW1 — 물리 Laser Arm 입력 (보드 시험 중 DOWN 유지)
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports { laser_arm_hw }]

## SW3 — 물리 Emergency Stop 입력
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { emergency_stop_hw }]

# 서보/레이저/스위치는 기계·광학·사람 손 신호라 clock 기준 타이밍이 의미 없다.
set_false_path -to   [get_ports { servo_pwm[*] }]
set_false_path -to   [get_ports { laser_en }]
set_false_path -from [get_ports { emergency_stop_hw }]
set_false_path -from [get_ports { laser_arm_hw }]
