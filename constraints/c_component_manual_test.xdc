# ---------------------------------------------------------------------------
# c_component_manual_test.xdc -- 연결 부품 수동 점검 제약
#   Board : Zybo Z7-20
#   Top   : rtl/control/component_manual_test_top.v
#
# Zybo에는 물리 BTN0~BTN3만 있다.
# BTN4 = BTN0+BTN1 (All Neutral), BTN5 = BTN2+BTN3 (Logical E-stop)로 정의한다.
# ---------------------------------------------------------------------------

## PL Clock 125 MHz
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }]

## SW0 Servo Enable / SW1 Laser Arm / SW3:SW2 Axis Select
set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports { sw[2] }]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { sw[3] }]

## BTN0 - / BTN1 + / BTN2 Neutral / BTN3 Laser Trigger
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]
set_property -dict { PACKAGE_PIN K19 IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]
set_property -dict { PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]

## LED0 Heartbeat / LED1 Servo PWM / LED2 Laser Ready / LED3 Laser Gate
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## Pmod JD: Camera PT#1 + Laser PT#2 Servo
set_property -dict { PACKAGE_PIN T14 IOSTANDARD LVCMOS33 } [get_ports { camera_pan_pwm  }]
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 } [get_ports { camera_tilt_pwm }]
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports { laser_pan_pwm   }]
set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports { laser_tilt_pwm  }]

## JD7/U14 -> received KY-008 S through external 1 kOhm series protection
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 DRIVE 4 SLEW SLOW } [get_ports { laser_gate_cmd }]
