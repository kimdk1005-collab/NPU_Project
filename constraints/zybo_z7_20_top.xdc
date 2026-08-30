# Zybo Z7-20 보드 제약 (Phase 2 bring-up)
# 출처: Digilent Zybo-Z7-Master.xdc (LED 4개)
#   led[0] heartbeat / led[1] npu_busy / led[2] target_valid / led[3] irq
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

# LED 는 눈으로 보는 신호라 타이밍을 걸 필요가 없다.
set_false_path -to [get_ports { led[*] }]
