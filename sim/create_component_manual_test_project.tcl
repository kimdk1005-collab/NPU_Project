# ---------------------------------------------------------------------------
# create_component_manual_test_project.tcl -- 연결 부품 수동 점검 프로젝트
#
#   project only:
#     vivado -mode batch -source sim/create_component_manual_test_project.tcl \
#            -tclargs project_only
#   full build:
#     vivado -mode batch -source sim/create_component_manual_test_project.tcl
# ---------------------------------------------------------------------------

set root      [file normalize [file dirname [info script]]/..]
set proj_dir  $root/vivado_component_manual_test
set proj_name c_component_manual_test
set part      xc7z020clg400-1

set project_only 0
if {[llength $argv] > 0 && [lindex $argv 0] eq "project_only"} {
    set project_only 1
} elseif {[llength $argv] > 0} {
    # GUI에서 기본 프로젝트가 열려 있을 때 검증 빌드는 별도 디렉터리를 지정한다.
    set proj_dir [file normalize [lindex $argv 0]]
}

if {[file exists $proj_dir]} {
    puts "INFO: 기존 생성 프로젝트 $proj_dir 삭제"
    file delete -force $proj_dir
}

create_project $proj_name $proj_dir -part $part -force

add_files -fileset sources_1 [list \
    $root/rtl/control/clock_125_to_100.v          \
    $root/rtl/control/servo_pwm.v                \
    $root/rtl/control/laser_interlock.v           \
    $root/rtl/control/component_manual_test_top.v \
]
set_property top component_manual_test_top [get_filesets sources_1]

add_files -fileset constrs_1 $root/constraints/c_component_manual_test.xdc
update_compile_order -fileset sources_1

if {$project_only} {
    puts ""
    puts "============================================================"
    puts " 부품 수동 점검 프로젝트 생성: $proj_dir/$proj_name.xpr"
    puts "============================================================"
    puts ""
    return
}

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "부품 수동 점검 합성 실패. vivado_component_manual_test 로그를 확인하라."
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "부품 수동 점검 구현/Bitstream 실패. vivado_component_manual_test 로그를 확인하라."
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
puts " 부품 수동 점검 Bitstream 생성 완료"
puts ""
puts "   $bit"
puts ""
puts " Timing  WNS = $wns ns   WHS = $whs ns"
puts ""
puts " 시작: SW=0000 -> Program -> LED0 heartbeat 확인"
puts " BTN4=BTN0+BTN1, BTN5=BTN2+BTN3 조합 입력"
puts " Laser: All Neutral -> SW1 LOW->HIGH -> LED2 -> BTN3 hold (max 1 s)"
puts "============================================================"
puts ""
