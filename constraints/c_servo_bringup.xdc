# ---------------------------------------------------------------------------
# c_servo_bringup.xdc -- board_io.v 서보 브링업 전용 제약
#
#   담당 : C
#   대상 : Digilent Zybo Z7-20 (xc7z020clg400-1)
#
#   constraints/ 는 SPEC §5.4 공유 디렉토리다. 마스터 XDC
#   (digilent-xdc-master/Zybo-Z7-Master.xdc) 를 수정하지 않고,
#   이 설계가 쓰는 핀만 여기에 새 파일로 활성화한다.
#   핀 번호는 전부 마스터 XDC 에서 그대로 가져온 값이다.
#
#   PS 를 쓰지 않는 순수 PL 설계다. PL sysclk (K17) 을 직접 받는다.
# ---------------------------------------------------------------------------

## Clock -- PL sysclk 125 MHz (마스터 XDC 8~9 행)
set_property -dict { PACKAGE_PIN K17   IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }]

## Switches
#   sw[0] en / sw[1] sweep / sw[2] range / sw[3] axis
set_property -dict { PACKAGE_PIN G15   IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]
set_property -dict { PACKAGE_PIN P15   IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]
set_property -dict { PACKAGE_PIN W13   IOSTANDARD LVCMOS33 } [get_ports { sw[2] }]
set_property -dict { PACKAGE_PIN T16   IOSTANDARD LVCMOS33 } [get_ports { sw[3] }]

## Buttons
#   btn[0] pos- / btn[1] pos+ / btn[2] 중립 / btn[3] reset
set_property -dict { PACKAGE_PIN K18   IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN P16   IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]
set_property -dict { PACKAGE_PIN K19   IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]
set_property -dict { PACKAGE_PIN Y16   IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]

## LEDs
#   led[0] 1 Hz 심장박동 (CLK_HZ 검증) / led[1] en / led[2] sweep / led[3] axis
set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN M15   IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN G14   IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## Servo PWM -- Pmod JD
#
#   JD 헤더 물리 배치 (보드를 정면에서 봤을 때)
#       상단 : pin1  pin2  pin3  pin4  pin5(GND)  pin6(VCC 3.3V)
#       하단 : pin7  pin8  pin9  pin10 pin11(GND) pin12(VCC 3.3V)
#
#   pan_pwm  -> JD pin 1  (T14)
#   tilt_pwm -> JD pin 2  (T15)
#   GND      -> JD pin 5  <- 서보 전원의 GND 와 반드시 공통 연결
#   VCC      -> JD pin 6  <- 3.3 V 이며 전류도 부족하다. 서보 전원으로 쓰지 않는다
#
set_property -dict { PACKAGE_PIN T14   IOSTANDARD LVCMOS33 } [get_ports { pan_pwm  }]
set_property -dict { PACKAGE_PIN T15   IOSTANDARD LVCMOS33 } [get_ports { tilt_pwm }]
