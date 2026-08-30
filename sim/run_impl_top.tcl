# top_system (npu_axi + npu_core) Out-of-Context Implementation
# AXI 계층을 얹은 뒤 타이밍/자원이 어떻게 변했는지 실측한다.
# 사용법: cd build && vivado -mode batch -source ../sim/run_impl_top.tcl
set PART xc7z020clg400-1
set HERE [file normalize [file dirname [info script]]]
set ROOT [file normalize [file join $HERE ..]]
set RTL  [file join $ROOT rtl npu]
set RTLI [file join $ROOT rtl integration]
set XDC  [file join $ROOT constraints top_system_ooc.xdc]
set RES  [file join $ROOT results]

read_verilog [concat [glob $RTL/*.v] [glob $RTLI/*.v]]
read_xdc $XDC
synth_design -top top_system -part $PART -mode out_of_context -include_dirs $RTL

opt_design
place_design
phys_opt_design
route_design

# 증거 파일은 results/ 에 바로 쓴다.
report_utilization    -file [file join $RES top_system_impl_util.rpt]
report_timing_summary -delay_type min_max -file [file join $RES top_system_impl_timing.rpt]
report_timing -delay_type max -max_paths 5 -file [file join $RES top_system_impl_critpath.rpt]

puts "=========== IMPL UTILIZATION ==========="
report_utilization
puts "=========== IMPL TIMING ==========="
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "WNS = $wns ns   (setup,  clk period 10.000 ns = 100 MHz)"
puts "WHS = $whs ns   (hold)"
if {$wns >= 0 && $whs >= 0} { puts "IMPL TIMING: MET" } else { puts "IMPL TIMING: VIOLATED" }
set fmax [expr {1000.0 / (10.0 - $wns)}]
puts [format "Fmax = %.1f MHz" $fmax]
