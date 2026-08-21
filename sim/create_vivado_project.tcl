# ---------------------------------------------------------------------------
# Vivado 프로젝트 생성 - C 담당 모듈 시뮬레이션용
#
#   실행:
#     cd <프로젝트 루트>
#     vivado -mode gui -source sim/create_vivado_project.tcl
#
#   또는 배치로 만들고 나중에 GUI 로 열기:
#     vivado -mode batch -source sim/create_vivado_project.tcl
#     vivado vivado_proj/npu_c_sim.xpr
#
#   생성물은 vivado_proj/ 에 들어가며 .gitignore 로 제외된다.
# ---------------------------------------------------------------------------

set root      [file normalize [file dirname [info script]]/..]
set proj_dir  $root/vivado_proj
set proj_name npu_c_sim
set part      xc7z020clg400-1
set board     digilentinc.com:zybo-z7-20:part0:1.2

# 기존 프로젝트가 있으면 지우고 다시 만든다
if {[file exists $proj_dir]} {
    puts "INFO: 기존 $proj_dir 삭제"
    file delete -force $proj_dir
}

create_project $proj_name $proj_dir -part $part -force

# 보드 파일이 있으면 board_part 도 지정 (없어도 시뮬레이션에는 지장 없음)
if {[llength [get_board_parts -quiet $board]] > 0} {
    set_property board_part $board [current_project]
    puts "INFO: board_part = $board"
} else {
    puts "WARNING: 보드 파일을 찾지 못했습니다. part 만 사용합니다."
}

# --- Design Sources (합성 대상) ------------------------------------------
add_files -fileset sources_1 [glob -nocomplain $root/rtl/*/*.v]
set_property top servo_pwm [get_filesets sources_1]

# --- Simulation Sources ---------------------------------------------------
add_files -fileset sim_1 [glob -nocomplain $root/tb/*/*.v]
set_property top tb_servo_pwm_sweep [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# 시뮬레이션 실행 시간
#   스윕 TB 는 pos 11 단계 x 2 Frame x 20 ms = 약 460 ms 필요
set_property -name {xsim.simulate.runtime} -value {500ms} \
             -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {true} \
             -objects [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts ""
puts "============================================================"
puts " 프로젝트 생성 완료: $proj_dir/$proj_name.xpr"
puts ""
puts " Simulation Top : [get_property top [get_filesets sim_1]]"
puts " Design Top     : [get_property top [get_filesets sources_1]]"
puts " Part           : $part"
puts ""
puts " 다음 단계"
puts "   1) Flow Navigator > SIMULATION > Run Simulation"
puts "                     > Run Behavioral Simulation"
puts "   2) 파형 창이 열리면 Tcl Console 에서:"
puts "        source [file normalize $root/sim/wave_servo_pwm.tcl]"
puts "   3) 판정용 TB 로 바꾸려면:"
puts "        set_property top tb_servo_pwm \[get_filesets sim_1\]"
puts "============================================================"
puts ""
