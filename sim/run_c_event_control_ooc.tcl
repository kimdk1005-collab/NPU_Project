# ---------------------------------------------------------------------------
# run_c_event_control_ooc.tcl -- C 통합 래퍼 100 MHz OOC 배치배선 검증
#
# 실행:
#   vivado -mode batch -source sim/run_c_event_control_ooc.tcl
#
# 생성 프로젝트와 보고서는 /tmp 아래에 두어 저장소를 오염시키지 않는다.
# A의 top_system_c 전체 타이밍을 대신하지 않으며, C 수정본의 독립 회귀용이다.
# ---------------------------------------------------------------------------

set root      [file normalize [file dirname [info script]]/..]
set proj_dir  /tmp/npu_c_event_control_ooc
set proj_name c_event_control_ooc
set part      xc7z020clg400-1

if {[file exists $proj_dir]} {
    file delete -force $proj_dir
}

create_project $proj_name $proj_dir -part $part -force

add_files -fileset sources_1 [list \
    $root/rtl/event/event_adapter.v          \
    $root/rtl/event/event_accumulator.v      \
    $root/rtl/control/servo_pwm.v            \
    $root/rtl/control/tracking_controller.v  \
    $root/rtl/control/laser_head_controller.v \
    $root/rtl/control/laser_interlock.v      \
    $root/rtl/control/dual_head_control.v    \
    $root/rtl/control/c_event_control_top.v  \
]
set_property top c_event_control_top [get_filesets sources_1]

set xdc_file $proj_dir/c_event_control_ooc.xdc
set xdc_fd [open $xdc_file w]
puts $xdc_fd {create_clock -name c_clk -period 10.000 [get_ports clk]}
puts $xdc_fd {set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]}
puts $xdc_fd {set_false_path -from [get_ports rstn]}
close $xdc_fd
add_files -fileset constrs_1 $xdc_file

set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
             -value {-mode out_of_context} -objects [get_runs synth_1]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "c_event_control_top OOC synthesis failed"
}

launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "route_design Complete!"} {
    error "c_event_control_top OOC implementation failed"
}

open_run impl_1
report_timing_summary -file $proj_dir/timing_summary.rpt
report_utilization -file $proj_dir/utilization.rpt
report_drc -file $proj_dir/drc.rpt

set limit_regs [get_cells -hierarchical -regexp \
    {.*(pan1|tilt1|pan2|tilt2)_(min|max)_eff_reg.*}]
if {[llength $limit_regs] > 0} {
    report_timing -from $limit_regs -max_paths 10 \
        -file $proj_dir/runtime_limit_registered_paths.rpt
}

set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path  [get_timing_paths -delay_type min -max_paths 1]
set wns [get_property SLACK $setup_path]
set whs [get_property SLACK $hold_path]
set drc_errors [llength [get_drc_violations -filter {SEVERITY == Error}]]

puts ""
puts "C_OOC_RESULT WNS=$wns ns WHS=$whs ns"
puts "C_OOC_RESULT DRC_ERRORS=$drc_errors"
puts "C_OOC_REPORT $proj_dir/timing_summary.rpt"
puts "C_OOC_REPORT $proj_dir/utilization.rpt"
puts "C_OOC_REPORT $proj_dir/drc.rpt"

if {$wns < 0.0 || $whs < 0.0} {
    error "c_event_control_top OOC timing failed: WNS=$wns ns WHS=$whs ns"
}
if {$drc_errors != 0} {
    error "c_event_control_top OOC DRC failed: errors=$drc_errors"
}
