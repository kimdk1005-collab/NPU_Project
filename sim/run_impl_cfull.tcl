# top_system_c = A(npu_axi + npu_core) + C(event/control 실물) OOC Implementation
#   사용법: cd build && vivado -mode batch -source ../sim/run_impl_cfull.tcl
#          cd build && vivado -mode batch -source ../sim/run_impl_cfull.tcl -tclargs -explore
#   -nortlim : RUNTIME_LIMIT_SUPPORT=0. C 의 런타임 SAFE_LIMIT 덮어쓰기를 끄고
#              그 조합 cone 이 빠졌을 때 타이밍이 얼마나 도는지 잰다.
#   -explore : place/route directive 를 Explore 로 올린다. 기본 전략으로
#              닫히는지부터 보고, 안 닫히면 이 옵션으로 여유를 확인한다.
#              리포트는 results/top_system_c_explore_*.rpt 로 따로 나간다.
#
# 왜 따로 재나
#   results/bd_util_cstub.rpt 는 A 가 만든 '자리표시자'(c_module_stub) 수치다.
#   C 실물이 들어온 지금은 그 숫자를 그대로 쓰면 공통규격 §35 위반이다.
#   이 스크립트가 C 실물 포함 수치의 근거파일을 만든다.
set EXPLORE 0
set NORTL  0
foreach a $argv {
    if {$a eq "-explore"}  { set EXPLORE 1 }
    if {$a eq "-nortlim"}  { set NORTL  1 }
}
set TAG "impl"
if {$EXPLORE} { set TAG "explore" }
if {$NORTL}   { set TAG "${TAG}_nortlim" }

set PART xc7z020clg400-1
set HERE [file normalize [file dirname [info script]]]
set ROOT [file normalize [file join $HERE ..]]
set RTL  [file join $ROOT rtl npu]
set RTLI [file join $ROOT rtl integration]
set RTLE [file join $ROOT rtl event]
set RTLC [file join $ROOT rtl control]
set XDC  [file join $ROOT constraints top_system_c_ooc.xdc]
set RES  [file join $ROOT results]
set WDIR [file join $ROOT weights]

# c_module_stub.v 는 자리표시자라 C 실물과 같이 넣지 않는다 (top 이 아니라 무해하지만
# 리포트에 섞이면 헷갈린다). glob 대신 명시적으로 나열한다.
read_verilog [glob $RTL/*.v]
read_verilog [list [file join $RTLI npu_axi.v] \
                   [file join $RTLI top_system.v] \
                   [file join $RTLI top_system_c.v]]
read_verilog [glob $RTLE/*.v]
read_verilog [glob $RTLC/*.v]
read_xdc $XDC

synth_design -top top_system_c -part $PART -mode out_of_context \
    -include_dirs $RTL -verilog_define NPU_WEIGHT_DIR="$WDIR/" \
    -generic RUNTIME_LIMIT_SUPPORT=[expr {$NORTL ? 0 : 1}]

opt_design
if {$EXPLORE} {
    place_design    -directive Explore
    phys_opt_design -directive AggressiveExplore
    route_design    -directive Explore
    phys_opt_design -directive AggressiveExplore
} else {
    place_design
    phys_opt_design
    route_design
}

report_utilization    -file [file join $RES top_system_c_${TAG}_util.rpt]
report_timing_summary -delay_type min_max -file [file join $RES top_system_c_${TAG}_timing.rpt]
report_timing -delay_type max -max_paths 5 -file [file join $RES top_system_c_${TAG}_critpath.rpt]

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
