# top_system Out-of-Context 타이밍 제약 (100 MHz 목표)
# 실제 시스템에서는 PS7 FCLK_CLK0 가 클럭을 공급하므로 BD 구현에서 재확인한다.
create_clock -period 10.000 -name s_axi_aclk [get_ports s_axi_aclk]
set_input_delay  -clock s_axi_aclk 2.000 \
    [get_ports -filter {DIRECTION == IN  && NAME != "s_axi_aclk"}]
set_output_delay -clock s_axi_aclk 2.000 [get_ports -filter {DIRECTION == OUT}]
