# ---------------------------------------------------------------------------
# c_dual_head_drive_test.xdc -- 4-Servo + JD7 RED LED 최종 구동 테스트
#   대상: Zybo Z7-20 / Top: dual_head_board_io
#   C 로컬 실물 검증용이며 A의 최종 top_system Master XDC와 분리한다.
# ---------------------------------------------------------------------------

## PL Clock 125 MHz
set_property -dict { PACKAGE_PIN K17   IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }]

## Switches: Servo / RED Arm / Target Valid / Emergency Stop
set_property -dict { PACKAGE_PIN G15   IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]
set_property -dict { PACKAGE_PIN P15   IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]
set_property -dict { PACKAGE_PIN W13   IOSTANDARD LVCMOS33 } [get_ports { sw[2] }]
set_property -dict { PACKAGE_PIN T16   IOSTANDARD LVCMOS33 } [get_ports { sw[3] }]

## Buttons: Target X- / X+ / Y- / Y+
set_property -dict { PACKAGE_PIN K18   IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN P16   IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]
set_property -dict { PACKAGE_PIN K19   IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]
set_property -dict { PACKAGE_PIN Y16   IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]

## On-board LEDs: heartbeat / Servo / Target Valid / Interlock RED
set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN M15   IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN G14   IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## Pmod JD: Camera PT#1 + Laser PT#2
set_property -dict { PACKAGE_PIN T14   IOSTANDARD LVCMOS33 } [get_ports { camera_pan_pwm  }]
set_property -dict { PACKAGE_PIN T15   IOSTANDARD LVCMOS33 } [get_ports { camera_tilt_pwm }]
set_property -dict { PACKAGE_PIN P14   IOSTANDARD LVCMOS33 } [get_ports { laser_pan_pwm   }]
set_property -dict { PACKAGE_PIN R14   IOSTANDARD LVCMOS33 } [get_ports { laser_tilt_pwm  }]

## JD7 / U14 -> RGB LED module R pin. Module '-' pin -> JD11 GND.
#  모듈에 331(330 ohm) 직렬저항이 내장되어 있으므로 추가 저항은 넣지 않는다.
set_property -dict { PACKAGE_PIN U14   IOSTANDARD LVCMOS33 } [get_ports { laser_red }]
