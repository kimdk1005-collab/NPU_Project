# Zybo Z7-20 — C 모듈 자리표시자용 추가 핀 제약
# sim/run_bd.tcl 을 WITH_C_STUB=1 로 돌릴 때만 읽힌다.
#
# !! 이 핀 배치는 A 의 임시 안이다. C 가 실제로 쓸 커넥터를 알려주면 바꾼다. !!
# 출처: Digilent Zybo-Z7-Master.xdc  Pmod Header JC
#
#   servo_pwm[0] = PAN1  (카메라 헤드)
#   servo_pwm[1] = TILT1 (카메라 헤드)
#   servo_pwm[2] = PAN2  (레이저 헤드)
#   servo_pwm[3] = TILT2 (레이저 헤드)
#   laser_en                       -- 개발 중에는 LED 를 붙여 검증한다

set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports { servo_pwm[0] }]
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports { servo_pwm[1] }]
set_property -dict { PACKAGE_PIN T11 IOSTANDARD LVCMOS33 } [get_ports { servo_pwm[2] }]
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { servo_pwm[3] }]
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports { laser_en    }]

# 서보 PWM 과 레이저는 기계/광학 신호라 클럭 타이밍을 걸 필요가 없다.
set_false_path -to [get_ports { servo_pwm[*] }]
set_false_path -to [get_ports { laser_en }]
