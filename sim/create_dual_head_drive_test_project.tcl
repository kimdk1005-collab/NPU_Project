# ---------------------------------------------------------------------------
# create_dual_head_drive_test_project.tcl -- 4-Servo + JD7 RED LED Bitstream
#
#   vivado -mode batch -source sim/create_dual_head_drive_test_project.tcl
#   vivado vivado_dual_head_bringup/c_dual_head_drive_test.xpr
# ---------------------------------------------------------------------------

set root      [file normalize [file dirname [info script]]/..]
set proj_dir  $root/vivado_dual_head_bringup
set proj_name c_dual_head_drive_test
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
    $root/rtl/control/clock_125_to_100.v      \
    $root/rtl/control/servo_pwm.v            \
    $root/rtl/control/tracking_controller.v  \
    $root/rtl/control/laser_head_controller.v \
    $root/rtl/control/laser_interlock.v       \
    $root/rtl/control/dual_head_control.v     \
    $root/rtl/control/dual_head_board_io.v    \
]
set_property top dual_head_board_io [get_filesets sources_1]

add_files -fileset constrs_1 $root/constraints/c_dual_head_drive_test.xdc
update_compile_order -fileset sources_1

if {$project_only} {
    puts ""
    puts "============================================================"
    puts " 4축+RED 프로젝트 생성: $proj_dir/$proj_name.xpr"
    puts "============================================================"
    puts ""
    return
}

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "4축+RED 합성 실패. vivado_dual_head_bringup 로그를 확인하라."
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "4축+RED 구현/Bitstream 실패. vivado_dual_head_bringup 로그를 확인하라."
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
puts " 4축 Servo + JD7 RED LED Bitstream 생성 완료"
puts ""
puts "   $bit"
puts ""
puts " Timing  WNS = $wns ns   WHS = $whs ns"
puts ""
puts " Program 전: sw=0000, Servo 외부전원, 공통 GND, 실제 Laser 미연결"
puts " Servo: JD1 Camera PAN / JD2 Camera TILT / JD3 Laser PAN / JD4 Laser TILT"
puts " LED  : JD7 -> module R, JD11 GND -> module '-'"
puts "============================================================"
puts ""
