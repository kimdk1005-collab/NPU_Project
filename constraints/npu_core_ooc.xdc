# NPU Core Out-of-Context 타이밍 제약 (100 MHz 목표)
create_clock -period 10.000 -name clk [get_ports clk]
set_input_delay  -clock clk 2.000 [get_ports -filter {DIRECTION == IN  && NAME != "clk"}]
set_output_delay -clock clk 2.000 [get_ports -filter {DIRECTION == OUT}]
