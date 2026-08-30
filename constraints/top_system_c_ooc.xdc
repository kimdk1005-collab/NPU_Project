# top_system_c (A NPU SoC + C Event/Control 실물) Out-of-Context 타이밍 제약
# 100 MHz 단일 도메인. 실제 시스템에서는 PS7 FCLK_CLK0 가 공급하므로
# BD 구현(run_bd.tcl -cfull)에서 다시 확인한다.
create_clock -period 10.000 -name s_axi_aclk [get_ports s_axi_aclk]

# Servo PWM / Laser Gate 는 기계·광학 신호라 clock 기준 I/O 타이밍이 의미 없다.
# 여기에 output delay 를 걸면 존재하지 않는 제약으로 WNS 를 깎는다.
set_false_path -to [get_ports {servo_pwm[*]}]
set_false_path -to [get_ports laser_en]

# 진단 출력. 실제 시스템에서는 칩 핀이 아니라 ILA 또는 0x58/0x5C RO Register 로
# 들어간다. OOC 에서만 포트로 나와 있으므로 가상 output delay 를 걸지 않는다.
set_false_path -to [get_ports {servo_pos_stat[*]}]
set_false_path -to [get_ports {control_stat[*]}]
set_false_path -to [get_ports tensor_start]

set_input_delay  -clock s_axi_aclk 2.000 \
    [get_ports -filter {DIRECTION == IN  && NAME != "s_axi_aclk"}]
set_output_delay -clock s_axi_aclk 2.000 \
    [get_ports -filter {DIRECTION == OUT && NAME !~ "servo_pwm*" && NAME != "laser_en" \
                        && NAME !~ "servo_pos_stat*" && NAME !~ "control_stat*" \
                        && NAME != "tensor_start"}]
