# NPU Core Out-of-Context 합성 -- 리소스/타이밍 확인용
# 대상 보드: Digilent Zybo Z7-20 (XC7Z020)  -- docs/NPU_DEVELOPMENT_PLAN_v1.1.md 1.3
# 사용법: cd build && vivado -mode batch -source ../sim/run_synth.tcl
set PART xc7z020clg400-1
set HERE [file normalize [file dirname [info script]]]
set ROOT [file normalize [file join $HERE ..]]
set RTL  [file join $ROOT rtl npu]
set XDC  [file join $ROOT constraints npu_core_ooc.xdc]
set RES  [file join $ROOT results]

read_verilog [glob $RTL/*.v]
read_xdc $XDC
synth_design -top npu_core -part $PART -mode out_of_context -include_dirs $RTL
opt_design

# 증거 파일은 results/ 에 바로 쓴다. build/ 에만 두면 results/ 가 옛날 수치로 남는다.
report_utilization    -file [file join $RES npu_core_util.rpt]
report_timing_summary -delay_type max -file [file join $RES npu_core_timing.rpt]

puts "=========== NPU_CORE UTILIZATION ==========="
report_utilization
puts "=========== NPU_CORE TIMING ==========="
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
puts "WNS = $wns ns   (clk period 10.000 ns = 100 MHz)"
if {$wns >= 0} { puts "TIMING: MET" } else { puts "TIMING: VIOLATED" }
