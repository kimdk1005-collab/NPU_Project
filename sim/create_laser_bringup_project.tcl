# ---------------------------------------------------------------------------
# create_laser_bringup_project.tcl -- PT#2 레이저 헤드 2축 브링업 Bitstream
#
#   실행:
#     vivado -mode batch -source sim/create_laser_bringup_project.tcl
#
#   프로젝트만 생성:
#     vivado -mode batch -source sim/create_laser_bringup_project.tcl -tclargs project_only
#     vivado vivado_laser_bringup/c_laser_servo_bringup.xpr
# ---------------------------------------------------------------------------

set root      [file normalize [file dirname [info script]]/..]
set proj_dir  $root/vivado_laser_bringup
set proj_name c_laser_servo_bringup
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
    $root/rtl/control/servo_pwm.v      \
    $root/rtl/control/board_io.v       \
    $root/rtl/control/laser_board_io.v \
]
set_property top laser_board_io [get_filesets sources_1]

add_files -fileset constrs_1 $root/constraints/c_laser_servo_bringup.xdc
update_compile_order -fileset sources_1

if {$project_only} {
    puts ""
    puts "============================================================"
    puts " PT#2 프로젝트 생성: $proj_dir/$proj_name.xpr"
    puts "============================================================"
    puts ""
    return
}

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "PT#2 합성 실패. vivado_laser_bringup 아래 로그를 확인하라."
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "PT#2 구현/Bitstream 실패. vivado_laser_bringup 아래 로그를 확인하라."
}

open_run impl_1

set bit [glob -nocomplain $proj_dir/$proj_name.runs/impl_1/*.bit]
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]

puts ""
puts "============================================================"
puts " PT#2 레이저 Servo 브링업 Bitstream 생성 완료"
puts ""
puts "   $bit"
puts ""
puts " Timing  WNS = $wns ns   WHS = $whs ns"
puts ""
puts " 연결: Laser PAN=JD3(P14), Laser TILT=JD4(R14), 외부전원 GND 공통"
puts " 시작: sw=0000 확인 -> Program -> led[0] heartbeat 확인 -> sw[0]=1"
puts " 주의: 실제 레이저 광원은 연결하지 않는다. Servo 전원은 외부 5~6 V를 쓴다."
puts "============================================================"
puts ""
