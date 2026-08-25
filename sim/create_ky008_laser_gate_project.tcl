# ---------------------------------------------------------------------------
# create_ky008_laser_gate_project.tcl -- KY-008 안전 게이트 브링업 Bitstream
#
#   vivado -mode batch -source sim/create_ky008_laser_gate_project.tcl
#   project only:
#   vivado -mode batch -source sim/create_ky008_laser_gate_project.tcl \
#          -tclargs project_only
# ---------------------------------------------------------------------------

set root      [file normalize [file dirname [info script]]/..]
set proj_dir  $root/vivado_ky008_bringup
set proj_name c_ky008_laser_gate_test
set part      xc7z020clg400-1

set project_only 0
if {[llength $argv] > 0 && [lindex $argv 0] eq "project_only"} {
    set project_only 1
}

if {[file exists $proj_dir]} {
    puts "INFO: 기존 생성 프로젝트 $proj_dir 삭제"
    file delete -force $proj_dir
}

create_project $proj_name $proj_dir -part $part -force

add_files -fileset sources_1 [list \
    $root/rtl/control/clock_125_to_100.v       \
    $root/rtl/control/servo_pwm.v             \
    $root/rtl/control/tracking_controller.v   \
    $root/rtl/control/laser_head_controller.v \
    $root/rtl/control/laser_interlock.v        \
    $root/rtl/control/dual_head_control.v      \
    $root/rtl/control/dual_head_board_io.v     \
    $root/rtl/control/ky008_laser_board_io.v   \
]
set_property top ky008_laser_board_io [get_filesets sources_1]

add_files -fileset constrs_1 $root/constraints/c_ky008_laser_gate_test.xdc
update_compile_order -fileset sources_1

if {$project_only} {
    puts ""
    puts "============================================================"
    puts " KY-008 안전 게이트 프로젝트 생성: $proj_dir/$proj_name.xpr"
    puts "============================================================"
    puts ""
    return
}

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "KY-008 안전 게이트 합성 실패. vivado_ky008_bringup 로그를 확인하라."
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "KY-008 안전 게이트 구현/Bitstream 실패. vivado_ky008_bringup 로그를 확인하라."
}

open_run impl_1

set bit [glob -nocomplain $proj_dir/$proj_name.runs/impl_1/*.bit]
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]

if {$wns < 0.0 || $whs < 0.0} {
    foreach bit_file $bit {
        file delete -force $bit_file
    }
    error "Timing 실패: WNS=$wns ns, WHS=$whs ns. 생성 Bitstream을 폐기했다."
}

puts ""
puts "============================================================"
puts " KY-008 안전 게이트 Bitstream 생성 완료"
puts ""
puts "   $bit"
puts ""
puts " Timing  WNS = $wns ns   WHS = $whs ns"
puts ""
puts " Program 전: sw=0000, KY-008 미연결, JD7에는 dummy LED/load만 연결"
puts " JD7/U14: High-side load switch Enable 전용. KY-008 S 직접 연결 금지"
puts " 실제 광원: Key Arm + NC E-stop + current limit/fuse 준비 후 별도 승인"
puts "============================================================"
puts ""
