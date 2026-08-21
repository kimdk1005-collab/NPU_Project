# ---------------------------------------------------------------------------
# create_bringup_project.tcl -- 서보 브링업 비트스트림 생성
#
#   순수 PL 설계다. Block Design / PS / Vitis 를 쓰지 않으므로
#   이 스크립트 하나로 비트스트림까지 나온다.
#
#   실행 (비트스트림까지):
#     vivado -mode batch -source sim/create_bringup_project.tcl
#
#   프로젝트만 만들고 GUI 로 열기:
#     vivado -mode batch -source sim/create_bringup_project.tcl -tclargs project_only
#     vivado vivado_bringup/c_servo_bringup.xpr
#
#   생성물은 vivado_bringup/ 에 들어가며 .gitignore 로 제외된다.
# ---------------------------------------------------------------------------

set root      [file normalize [file dirname [info script]]/..]
set proj_dir  $root/vivado_bringup
set proj_name c_servo_bringup
set part      xc7z020clg400-1

set project_only 0
if {[llength $argv] > 0 && [lindex $argv 0] eq "project_only"} {
    set project_only 1
}

if {[file exists $proj_dir]} {
    puts "INFO: 기존 $proj_dir 삭제"
    file delete -force $proj_dir
}

create_project $proj_name $proj_dir -part $part -force

# --- Design Sources -------------------------------------------------------
#   add_files 는 참조만 한다 (사본을 만들지 않는다).
#   rtl/ 이 유일한 master 로 남는다.
add_files -fileset sources_1 [list \
    $root/rtl/control/servo_pwm.v \
    $root/rtl/control/board_io.v  \
]
set_property top board_io [get_filesets sources_1]

# --- Constraints ----------------------------------------------------------
add_files -fileset constrs_1 $root/constraints/c_servo_bringup.xdc

update_compile_order -fileset sources_1

if {$project_only} {
    puts ""
    puts "============================================================"
    puts " 프로젝트만 생성: $proj_dir/$proj_name.xpr"
    puts "============================================================"
    puts ""
    return
}

# --- 합성 / 구현 / 비트스트림 ---------------------------------------------
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "합성 실패. vivado_bringup/ 아래 로그를 확인하라."
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "구현/비트스트림 실패. vivado_bringup/ 아래 로그를 확인하라."
}

open_run impl_1

set bit [glob -nocomplain $proj_dir/$proj_name.runs/impl_1/*.bit]
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]

puts ""
puts "============================================================"
puts " 비트스트림 생성 완료"
puts ""
puts "   $bit"
puts ""
puts " Timing  WNS = $wns ns   WHS = $whs ns   (둘 다 양수여야 한다)"
puts ""
puts " 다음 단계"
puts "   1) Zybo 부트 모드 점퍼를 JTAG 로"
puts "   2) vivado -mode gui  ->  Open Hardware Manager  ->  Program Device"
puts "   3) 서보를 붙이기 전에 led\[0\] 이 정확히 1 초 주기인지 먼저 확인"
puts "============================================================"
puts ""
