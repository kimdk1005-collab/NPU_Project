# ---------------------------------------------------------------------------
# c_laser_servo_bringup.xdc -- PT#2 레이저 헤드 Servo 단독 브링업 제약
#
#   대상 : Digilent Zybo Z7-20 (xc7z020clg400-1)
#   Top  : rtl/control/laser_board_io.v
#
#   최종 top_system용 Master XDC가 아니다. 카메라 PT#1의 JD1/JD2 배치를
#   변경하지 않고 레이저 PT#2의 JD3/JD4만 독립 검증하기 위한 C 로컬 제약이다.
# ---------------------------------------------------------------------------

## Clock -- PL sysclk 125 MHz
set_property -dict { PACKAGE_PIN K17   IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }]

## Switches
#   sw[0] Servo enable / sw[1] sweep / sw[2] range / sw[3] axis
#   axis: 0 = Laser PAN(JD3), 1 = Laser TILT(JD4)
set_property -dict { PACKAGE_PIN G15   IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]
set_property -dict { PACKAGE_PIN P15   IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]
set_property -dict { PACKAGE_PIN W13   IOSTANDARD LVCMOS33 } [get_ports { sw[2] }]
set_property -dict { PACKAGE_PIN T16   IOSTANDARD LVCMOS33 } [get_ports { sw[3] }]

## Buttons
#   btn[0] pos- / btn[1] pos+ / btn[2] neutral / btn[3] reset
set_property -dict { PACKAGE_PIN K18   IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN P16   IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]
set_property -dict { PACKAGE_PIN K19   IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]
set_property -dict { PACKAGE_PIN Y16   IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]

## LEDs
#   led[0] heartbeat / led[1] enable / led[2] sweep / led[3] selected axis
set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN M15   IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN G14   IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## PT#2 Servo PWM -- Pmod JD
#   laser_pan_pwm  -> JD pin 3 / P14
#   laser_tilt_pwm -> JD pin 4 / R14
#   Servo GND      -> JD pin 5와 외부 5~6 V 전원 GND를 공통 연결
#   JD pin 6의 3.3 V는 Servo 전원으로 사용하지 않는다.
set_property -dict { PACKAGE_PIN P14   IOSTANDARD LVCMOS33 } [get_ports { laser_pan_pwm  }]
set_property -dict { PACKAGE_PIN R14   IOSTANDARD LVCMOS33 } [get_ports { laser_tilt_pwm }]
