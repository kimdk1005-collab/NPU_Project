# NPU Core Out-of-Context Implementation -- 배치배선 후 실제 타이밍 확인
# 합성 추정치(WNS)와 배치배선 후 실측은 다르므로 반드시 여기까지 본다.
# 사용법: cd build && vivado -mode batch -source ../sim/run_impl.tcl
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
place_design
phys_opt_design
route_design

# 증거 파일은 results/ 에 바로 쓴다. build/ 에만 두면 results/ 가 옛날 수치로 남는다.
report_utilization    -file [file join $RES npu_core_impl_util.rpt]
report_timing_summary -delay_type min_max -file [file join $RES npu_core_impl_timing.rpt]

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
