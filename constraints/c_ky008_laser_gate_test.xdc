# ---------------------------------------------------------------------------
# c_ky008_laser_gate_test.xdc -- KY-008 사전 브링업 전용 제약
#   Board : Zybo Z7-20
#   Top   : rtl/control/ky008_laser_board_io.v
#
# JD7/U14는 KY-008의 S 핀이나 5 V 전원에 직접 연결하지 않는다.
# 3.3 V compatible, default-OFF High-side load switch의 Enable만 구동한다.
# 실제 5 V 경로에는 별도 Key Arm, NC E-stop, 전류 제한/퓨즈가 필요하다.
# ---------------------------------------------------------------------------

## PL Clock 125 MHz
set_property -dict { PACKAGE_PIN K17   IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }]

## Switches: Servo Enable / Laser Arm / Target Valid / Logical E-stop
set_property -dict { PACKAGE_PIN G15   IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]
set_property -dict { PACKAGE_PIN P15   IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]
set_property -dict { PACKAGE_PIN W13   IOSTANDARD LVCMOS33 } [get_ports { sw[2] }]
set_property -dict { PACKAGE_PIN T16   IOSTANDARD LVCMOS33 } [get_ports { sw[3] }]

## Buttons: Target X- / X+ / Y- / Y+
set_property -dict { PACKAGE_PIN K18   IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN P16   IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]
set_property -dict { PACKAGE_PIN K19   IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]
set_property -dict { PACKAGE_PIN Y16   IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]

## On-board LEDs: Heartbeat / Servo / Target Valid / Safe Gate Command
set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN M15   IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN G14   IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## Pmod JD: Camera PT#1 + Laser PT#2 Servo
set_property -dict { PACKAGE_PIN T14   IOSTANDARD LVCMOS33 } [get_ports { camera_pan_pwm  }]
set_property -dict { PACKAGE_PIN T15   IOSTANDARD LVCMOS33 } [get_ports { camera_tilt_pwm }]
set_property -dict { PACKAGE_PIN P14   IOSTANDARD LVCMOS33 } [get_ports { laser_pan_pwm   }]
set_property -dict { PACKAGE_PIN R14   IOSTANDARD LVCMOS33 } [get_ports { laser_tilt_pwm  }]

## JD7 / U14 -> external High-side load switch Enable only
set_property -dict { PACKAGE_PIN U14   IOSTANDARD LVCMOS33 } [get_ports { laser_gate_cmd }]
