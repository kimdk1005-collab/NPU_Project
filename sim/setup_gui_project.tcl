#=====================================================================
# setup_gui_project.tcl : NPU_Pr_vivado GUI 프로젝트 동기화/빌드
#
# 목적
#   - 비어 있는 NPU_Pr_vivado 프로젝트에 현재 A Phase 1~4 설계를 등록한다.
#   - 소스/weight/test vector를 복사하지 않고 저장소 정본을 참조한다.
#   - 이미 만들어진 npu_bd는 보존한다. 따라서 이후 C 실물 연결을 덮지 않는다.
#   - -build 옵션이면 bitstream/XSA/리포트를 GUI 프로젝트 export/에 만든다.
#
# 사용법 (저장소 루트에서)
#   vivado -mode batch -source sim/setup_gui_project.tcl
#   vivado -mode batch -source sim/setup_gui_project.tcl -tclargs -build
#
# 기본 프로젝트가 아닌 다른 .xpr에 적용할 때
#   vivado -mode batch -source sim/setup_gui_project.tcl \
#       -tclargs -project /absolute/path/to/project.xpr -build
#
# 주의
#   이 스크립트는 A-only bring-up BD가 없을 때만 새로 만든다.
#   기존 npu_bd를 A-only로 되돌리는 기능은 의도적으로 제공하지 않는다.
#   C 통합 후에도 안전하게 재실행할 수 있어야 하기 때문이다.
#=====================================================================

set PART       xc7z020clg400-1
set BOARD_PART digilentinc.com:zybo-z7-20:part0:1.1

set HERE [file normalize [file dirname [info script]]]
set ROOT [file normalize [file join $HERE ..]]
set RTL_ROOT [file join $ROOT rtl]
set RTL_NPU  [file join $RTL_ROOT npu]
set TB_ROOT  [file join $ROOT tb]
set WDIR     [file join $ROOT weights]
set TVDIR    [file join $ROOT test_vectors case00]
set XDC_A    [file join $ROOT constraints zybo_z7_20_top.xdc]
set DEFAULT_PROJECT [file join $ROOT NPU_Pr_vivado NPU_Pr_vivado.xpr]
set BOARD_REPO [file join $::env(HOME) .Xilinx Vivado 2024.2 xhub \
                     board_store xilinx_board_store]

set DO_BUILD 0
set PROJECT_XPR $DEFAULT_PROJECT
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    switch -- $arg {
        -build {
            set DO_BUILD 1
        }
        -project {
            incr i
            if {$i >= [llength $argv]} {
                error "-project 뒤에 .xpr 경로가 필요하다"
            }
            set PROJECT_XPR [file normalize [lindex $argv $i]]
        }
        default {
            error "알 수 없는 옵션: $arg (허용: -build, -project <xpr>)"
        }
    }
}

proc collect_files_recursive {root extensions} {
    set found {}
    if {![file isdirectory $root]} {
        return $found
    }
    foreach entry [glob -nocomplain -directory $root *] {
        if {[file isdirectory $entry]} {
            set found [concat $found [collect_files_recursive $entry $extensions]]
        } elseif {[lsearch -exact $extensions [string tolower [file extension $entry]]] >= 0} {
            lappend found [file normalize $entry]
        }
    }
    return [lsort -unique $found]
}

proc add_file_once {fileset path} {
    set path [file normalize $path]
    set basename [file tail $path]
    set existing [get_files -quiet -of_objects [get_filesets $fileset] $basename]
    if {[llength $existing] == 0} {
        add_files -fileset $fileset -norecurse $path
        puts "  ADD $fileset: $path"
    }
}

proc tie_zero {cell_name width pin_name} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant $cell_name
    set_property -dict [list CONFIG.CONST_WIDTH $width CONFIG.CONST_VAL 0] \
        [get_bd_cells $cell_name]
    connect_bd_net [get_bd_pins $cell_name/dout] [get_bd_pins $pin_name]
}

proc create_a_only_bd {} {
    puts "=== npu_bd 없음: A-only Phase 4 Block Design 생성 ==="
    create_bd_design npu_bd

    create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7
    apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR" apply_board_preset "1" \
                 Master "Disable" Slave "Disable"} [get_bd_cells ps7]

    set_property -dict [list \
        CONFIG.PCW_USE_M_AXI_GP0            {1}   \
        CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
        CONFIG.PCW_USE_FABRIC_INTERRUPT     {1}   \
        CONFIG.PCW_IRQ_F2P_INTR             {1}   \
    ] [get_bd_cells ps7]

    # top_system은 C 연결 포트까지 이미 가진 최종 A 통합 경계다.
    create_bd_cell -type module -reference top_system npu_0
    if {[llength [get_bd_intf_pins -quiet npu_0/s_axi]] != 1} {
        error "top_system의 AXI interface가 npu_0/s_axi로 추론되지 않았다"
    }

    apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
        -config [list Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
                      Master {/ps7/M_AXI_GP0} Slave {/npu_0/s_axi} \
                      ddr_seg {Auto} intc_ip {New AXI SmartConnect} master_apm {0}] \
        [get_bd_intf_pins npu_0/s_axi]

    # Phase 4 A-only: PS가 INBUF_DATA로 tensor를 넣는다. C 직결 입력은 0.
    tie_zero const0_1  1  npu_0/evt_we
    tie_zero const0_13 13 npu_0/evt_addr
    tie_zero const0_8  8  npu_0/evt_data
    tie_zero const0_32 32 npu_0/input_stat

    connect_bd_net [get_bd_pins npu_0/irq] [get_bd_pins ps7/IRQ_F2P]
    create_bd_port -dir O -from 3 -to 0 led
    connect_bd_net [get_bd_pins npu_0/status_led] [get_bd_ports led]

    assign_bd_address
    set npu_map [get_bd_addr_segs -quiet -of_objects \
        [get_bd_addr_spaces ps7/Data] -filter {NAME =~ "*SEG_npu_0_reg0"}]
    if {[llength $npu_map] != 1} {
        error "PS7 Data 주소공간에서 NPU segment를 하나로 찾지 못했다: $npu_map"
    }
    set_property offset 0x40000000 $npu_map
    set_property range  4K          $npu_map

    validate_bd_design
    regenerate_bd_layout
    save_bd_design
}

if {![file isdirectory $BOARD_REPO]} {
    error "Zybo Z7-20 board repo 없음: $BOARD_REPO"
}
set_param board.repoPaths [list $BOARD_REPO]

if {[file exists $PROJECT_XPR]} {
    puts "=== 기존 GUI 프로젝트 열기: $PROJECT_XPR ==="
    open_project $PROJECT_XPR
} else {
    set project_dir [file dirname $PROJECT_XPR]
    set project_name [file rootname [file tail $PROJECT_XPR]]
    puts "=== GUI 프로젝트 신규 생성: $PROJECT_XPR ==="
    file mkdir $project_dir
    create_project $project_name $project_dir -part $PART
}

if {[get_property PART [current_project]] ne $PART} {
    error "Part 불일치: 기대=$PART 실제=[get_property PART [current_project]]"
}
set_property board_part $BOARD_PART [current_project]
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

puts "=== 저장소 정본 source 연결 ==="
foreach path [collect_files_recursive $RTL_ROOT [list .v .sv]] {
    add_file_once sources_1 $path
}
set npu_header [file join $RTL_NPU npu_defs.vh]
add_file_once sources_1 $npu_header
set header_obj [get_files -quiet npu_defs.vh]
set_property file_type "Verilog Header" $header_obj
set_property is_global_include true $header_obj

# RTL이 실제로 읽는 packed bank/requant 파일만 Design Sources에 보이게 한다.
set runtime_weights [lsort [concat \
    [glob -nocomplain -directory $WDIR w_bank*.mem] \
    [glob -nocomplain -directory $WDIR requant_M.mem]]]
foreach path $runtime_weights {
    add_file_once sources_1 $path
}

add_file_once constrs_1 $XDC_A

puts "=== GUI Simulation Sources 연결 ==="
foreach path [collect_files_recursive $TB_ROOT [list .v .sv]] {
    add_file_once sim_1 $path
}

set_property include_dirs [list $RTL_NPU] [get_filesets sources_1]
set_property verilog_define \
    [list "NPU_WEIGHT_DIR=\"$WDIR/\""] [get_filesets sources_1]
set_property include_dirs [list $RTL_NPU] [get_filesets sim_1]
set_property verilog_define \
    [list "NPU_WEIGHT_DIR=\"$WDIR/\"" "NPU_TV_DIR=\"$TVDIR/\""] \
    [get_filesets sim_1]
set_property top tb_npu_full [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set bd_file [get_files -quiet npu_bd.bd]
if {[llength $bd_file] == 0} {
    create_a_only_bd
    set bd_file [get_files -quiet npu_bd.bd]
} else {
    puts "=== 기존 npu_bd 보존 (C 통합 내용 자동 덮어쓰기 안 함) ==="
    open_bd_design $bd_file
    foreach required_cell {ps7 npu_0} {
        if {[llength [get_bd_cells -quiet $required_cell]] != 1} {
            error "기존 npu_bd에 필수 cell '$required_cell'이 없다"
        }
    }
    validate_bd_design
    save_bd_design
}

# 주소 계약은 A-only와 이후 C 통합 모두 동일해야 한다.
set npu_map [get_bd_addr_segs -quiet -of_objects \
    [get_bd_addr_spaces ps7/Data] -filter {NAME =~ "*SEG_npu_0_reg0"}]
if {[llength $npu_map] != 1} {
    error "NPU 주소 계약 불일치: segment=$npu_map"
}
set npu_offset [string map {_ ""} [get_property OFFSET $npu_map]]
set npu_range  [string map {_ ""} [get_property RANGE $npu_map]]
if {[expr {$npu_offset + 0}] != 0x40000000 || [expr {$npu_range + 0}] != 0x1000} {
    error "NPU 주소 계약 불일치: segment=$npu_map offset=$npu_offset range=$npu_range"
}

generate_target all $bd_file
set wrapper [get_files -quiet npu_bd_wrapper.v]
if {[llength $wrapper] == 0} {
    set wrapper [make_wrapper -files $bd_file -top]
    add_files -fileset sources_1 -norecurse $wrapper
}
set_property top npu_bd_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

puts "=== GUI 프로젝트 구성 완료 ==="
puts "  project : $PROJECT_XPR"
puts "  synth top: [get_property top [get_filesets sources_1]]"
puts "  sim top  : [get_property top [get_filesets sim_1]]"
puts "  AXI      : 0x40000000 / 4K"
puts "  mode     : 현재 npu_bd 내용 유지 (신규면 A-only Phase 4)"

if {$DO_BUILD} {
    puts "=== synth_1/impl_1 재빌드 시작 ==="
    reset_run synth_1
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1

    set progress [get_property PROGRESS [get_runs impl_1]]
    set status [get_property STATUS [get_runs impl_1]]
    puts "  impl_1: $status ($progress)"
    if {$progress ne "100%"} {
        error "impl_1 실패: $status"
    }

    open_run impl_1
    set export_dir [file join [file dirname $PROJECT_XPR] export]
    file mkdir $export_dir
    report_utilization -file [file join $export_dir gui_util.rpt]
    report_timing_summary -delay_type min_max \
        -file [file join $export_dir gui_timing.rpt]

    set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
    set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
    puts "  WNS=$wns ns, WHS=$whs ns"
    if {$wns < 0 || $whs < 0} {
        error "GUI 프로젝트 timing violation: WNS=$wns, WHS=$whs"
    }

    set run_dir [get_property DIRECTORY [get_runs impl_1]]
    set bit_src [file join $run_dir npu_bd_wrapper.bit]
    set bit_dst [file join $export_dir NPU_Pr_vivado.bit]
    if {![file exists $bit_src]} {
        error "bitstream 없음: $bit_src"
    }
    file copy -force $bit_src $bit_dst
    set xsa_dst [file join $export_dir NPU_Pr_vivado.xsa]
    write_hw_platform -fixed -include_bit -force $xsa_dst
    puts "  BIT -> $bit_dst"
    puts "  XSA -> $xsa_dst"
    puts "  RPT -> $export_dir/gui_util.rpt, gui_timing.rpt"
}

close_project
puts "=== NPU_Pr_vivado 동기화 종료 ==="
