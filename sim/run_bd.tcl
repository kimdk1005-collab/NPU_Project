#=====================================================================
# run_bd.tcl : Zybo Z7-20 Block Design 생성 + Bitstream 생성
#  사용법: cd build && vivado -mode batch -source ../sim/run_bd.tcl
#
#  구성
#    ZYNQ7 PS  --M_AXI_GP0--> AXI SmartConnect --> top_system.S_AXI
#    FCLK_CLK0 (100 MHz) = NPU clk = s_axi_aclk   (단일 클럭 도메인)
#    top_system.irq --> PS IRQ_F2P
#    top_system.status_led[3:0] --> LD0..LD3
#
#  board file 은 Vivado 설치 폴더가 아니라 사용자 홈의 xhub board_store 에 있다.
#
#  옵션 3 가지. 아무것도 안 주면 A 단독 bring-up 용 깨끗한 bitstream.
#
#   -stub   rtl/integration/c_module_stub.v (A 가 만든 자리표시자) 를 넣는다.
#           C 실물이 오기 전 통합 리소스를 미리 재려고 만든 것이다.
#           C 실물이 들어온 지금은 -cfull 을 쓴다. 과거 수치 비교용으로만 남긴다.
#           산출물 접미사 _cstub
#
#   -cfull  ** C 실물 통합. rtl/integration/top_system_c.v 를 top 으로 쓴다. **
#           top_system + c_event_control_top(= event_adapter + event_accumulator
#           + dual_head_control + laser_interlock) 전부 들어간다.
#           산출물 접미사 _cfull.  핀 : constraints/zybo_z7_20_cfull.xdc
#
#   -nortlim  -cfull 과 같이 쓴다. RUNTIME_LIMIT_SUPPORT=0 으로 C 의 런타임
#           SAFE_LIMIT 덮어쓰기를 끈다. 그 조합 cone 이 100 MHz critical path 라
#           타이밍이 안 닫힐 때 쓰는 우회다. 근거: A_TO_C_V01_REQUEST_001.md 요청1
#
#  vivado -mode batch -source ../sim/run_bd.tcl -tclargs -cfull
#  vivado -mode batch -source ../sim/run_bd.tcl -tclargs -cfull -nortlim
#=====================================================================
set WITH_C_STUB 0
set WITH_C_FULL 0
set NO_RT_LIMIT 0
foreach a $argv {
    if {$a eq "-stub"}    { set WITH_C_STUB 1 }
    if {$a eq "-cfull"}   { set WITH_C_FULL 1 }
    if {$a eq "-nortlim"} { set NO_RT_LIMIT 1 }
}
if {$WITH_C_STUB && $WITH_C_FULL} {
    puts "ERROR: -stub 과 -cfull 은 같이 못 쓴다"
    exit 1
}
set PART       xc7z020clg400-1
set BOARD_PART digilentinc.com:zybo-z7-20:part0:1.1
set BOARD_REPO "$::env(HOME)/.Xilinx/Vivado/2024.2/xhub/board_store/xilinx_board_store"

set HERE [file normalize [file dirname [info script]]]
set ROOT [file normalize [file join $HERE ..]]
set RTL  [file join $ROOT rtl npu]
set RTLI [file join $ROOT rtl integration]
set RTLE [file join $ROOT rtl event]
set RTLC [file join $ROOT rtl control]
set WDIR [file join $ROOT weights]
if {$WITH_C_FULL} {
    set TOPMOD top_system_c
    if {$NO_RT_LIMIT} {
        set PROJ   [file join $ROOT build vivado_npu_cfull_nortlim]
        set SUFFIX "_cfull_nortlim"
        puts "=== C 실물 통합 빌드 (top_system_c) ==="
        puts "===   RUNTIME_LIMIT_SUPPORT = 0 (런타임 SAFE_LIMIT 끔, 타이밍 우회) ==="
    } else {
        set PROJ   [file join $ROOT build vivado_npu_cfull]
        set SUFFIX "_cfull"
        puts "=== C 실물 통합 빌드 (top_system_c) ==="
    }
} elseif {$WITH_C_STUB} {
    set PROJ   [file join $ROOT build vivado_npu_cstub]
    set SUFFIX "_cstub"
    set TOPMOD top_system
    puts "=== C 모듈 자리표시자 포함 빌드 (통합 리소스/타이밍 측정용) ==="
} else {
    set PROJ   [file join $ROOT build vivado_npu]
    set SUFFIX ""
    set TOPMOD top_system
    puts "=== A 단독 빌드 (보드 bring-up 용) ==="
}

if {![file isdirectory $BOARD_REPO]} {
    puts "ERROR: board repo 없음 : $BOARD_REPO"
    exit 1
}
set_param board.repoPaths [list $BOARD_REPO]

#---------------------------------------------------------------- project
create_project npu_soc $PROJ -part $PART -force
set_property board_part $BOARD_PART [current_project]

set SRCS [concat [glob $RTL/*.v] [glob $RTLI/*.v]]
if {$WITH_C_FULL} {
    # C 소유 RTL (rtl/event, rtl/control). C 실물 통합 빌드에서만 넣는다.
    set SRCS [concat $SRCS [glob $RTLE/*.v] [glob $RTLC/*.v]]
}
add_files -norecurse $SRCS
# Module Reference 로 쓰려면 include 헤더도 프로젝트에 등록해야 한다
add_files -norecurse [file join $RTL npu_defs.vh]
set_property file_type "Verilog Header" [get_files [file join $RTL npu_defs.vh]]
# is_global_include 없으면 Module Reference 시 include 를 못 찾는다
set_property is_global_include true      [get_files [file join $RTL npu_defs.vh]]
add_files -fileset constrs_1 -norecurse [file join $ROOT constraints zybo_z7_20_top.xdc]
if {$WITH_C_STUB} {
    add_files -fileset constrs_1 -norecurse \
        [file join $ROOT constraints zybo_z7_20_cstub.xdc]
}
if {$WITH_C_FULL} {
    add_files -fileset constrs_1 -norecurse \
        [file join $ROOT constraints zybo_z7_20_cfull.xdc]
}

# npu_defs.vh include 경로 + $readmemh 절대경로 주입
set_property include_dirs   [list $RTL] [get_filesets sources_1]
set_property verilog_define [list "NPU_WEIGHT_DIR=\"$WDIR/\""] [get_filesets sources_1]
update_compile_order -fileset sources_1

#---------------------------------------------------------------- BD
create_bd_design "npu_bd"

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

# top_system 을 Module Reference 로 BD 에 넣는다 (IP 패키징 불필요)
create_bd_cell -type module -reference $TOPMOD npu_0
if {$WITH_C_FULL && $NO_RT_LIMIT} {
    set_property CONFIG.RUNTIME_LIMIT_SUPPORT {0} [get_bd_cells npu_0]
}
puts "=== npu_0 interface pins ==="
foreach p [get_bd_intf_pins npu_0/*] { puts "  intf: $p" }
foreach p [get_bd_pins npu_0/*]      { puts "  pin : $p" }

apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
                  Master {/ps7/M_AXI_GP0} Slave {/npu_0/s_axi} \
                  ddr_seg {Auto} intc_ip {New AXI SmartConnect} master_apm {0}] \
    [get_bd_intf_pins npu_0/s_axi]

proc tie0 {name width pin} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant $name
    set_property -dict [list CONFIG.CONST_WIDTH $width CONFIG.CONST_VAL 0] \
        [get_bd_cells $name]
    connect_bd_net [get_bd_pins $name/dout] [get_bd_pins $pin]
}

if {$WITH_C_FULL} {
    #-------------------------------------------------------------
    # C 실물. Event Tensor 경로는 top_system_c 안에서 이미 배선돼 있으므로
    # 여기서는 외부 핀과 아직 없는 입력만 처리한다.
    #
    #  src_*  : 실제 Event Source 하드웨어가 아직 없다. 0 으로 묶는다.
    #           ** 그래서 event_adapter 의 Binning 곱셈기가 최적화로 사라진다. **
    #           C 전체 포함 수치는 OOC(results/top_system_c_impl_util.rpt)를 봐라.
    #  laser_arm_hw : 상수 0 으로 묶으면 laser_interlock 자격 판정이 통째로
    #           최적화된다. 그래서 SW1 에 연결한다. 보드 시험 중 DOWN 유지.
    #-------------------------------------------------------------
    tie0 const0_src_v  1  npu_0/src_valid
    tie0 const0_src_x 11  npu_0/src_x
    tie0 const0_src_y 11  npu_0/src_y
    tie0 const0_src_p  1  npu_0/src_pol
    tie0 const0_src_w  1  npu_0/src_window_end

    create_bd_port -dir I               laser_arm_hw
    create_bd_port -dir I               emergency_stop_hw
    create_bd_port -dir O -from 3 -to 0 servo_pwm
    create_bd_port -dir O               laser_en
    connect_bd_net [get_bd_ports laser_arm_hw]      [get_bd_pins npu_0/laser_arm_hw]
    connect_bd_net [get_bd_ports emergency_stop_hw] [get_bd_pins npu_0/emergency_stop_hw]
    connect_bd_net [get_bd_pins npu_0/servo_pwm]    [get_bd_ports servo_pwm]
    connect_bd_net [get_bd_pins npu_0/laser_en]     [get_bd_ports laser_en]
    # servo_pos_stat / control_stat / tensor_start 포트는 BD 에서 소비처가 없다.
    # 값 자체는 top_system_c 안에서 이미 0x58/0x5C RO 와 hw_start 로 들어가므로
    # (CR A-003 변경 1·2 구현 완료) 논리가 최적화로 사라지지 않는다.
    # 이 포트는 ILA 를 붙일 때만 쓴다.
} elseif {$WITH_C_STUB} {
    # C 자리표시자를 붙인다. C 포트가 실제로 구동/소비되므로
    # 합성이 지우지 않고, 통합 후 리소스/타이밍이 정직하게 나온다.
    create_bd_cell -type module -reference c_module_stub cstub_0
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0]        [get_bd_pins cstub_0/clk]
    connect_bd_net [get_bd_pins rst_ps7_100M/peripheral_aresetn] \
                   [get_bd_pins cstub_0/rstn]
    foreach sig {event_cfg pan_cmd tilt_cmd laser_ctrl safe_limit \
                 track_err_x track_err_y pan2_cmd tilt2_cmd safe_limit2 \
                 laser_cal npu_busy npu_done} {
        connect_bd_net [get_bd_pins npu_0/$sig] [get_bd_pins cstub_0/$sig]
    }
    connect_bd_net [get_bd_pins npu_0/npu_target_valid] [get_bd_pins cstub_0/target_valid]
    connect_bd_net [get_bd_pins npu_0/npu_target_x]     [get_bd_pins cstub_0/target_x]
    connect_bd_net [get_bd_pins npu_0/npu_target_y]     [get_bd_pins cstub_0/target_y]
    connect_bd_net [get_bd_pins npu_0/npu_target_score] [get_bd_pins cstub_0/target_score]
    foreach sig {evt_we evt_addr evt_data input_stat} {
        connect_bd_net [get_bd_pins cstub_0/$sig] [get_bd_pins npu_0/$sig]
    }
    create_bd_port -dir O -from 3 -to 0 servo_pwm
    create_bd_port -dir O               laser_en
    connect_bd_net [get_bd_pins cstub_0/servo_pwm] [get_bd_ports servo_pwm]
    connect_bd_net [get_bd_pins cstub_0/laser_en]  [get_bd_ports laser_en]
} else {
    # C 모듈 미착수 : Event 직결 입력은 0 으로 묶는다 (INPUT_SRC=0 경로만 사용)
    tie0 const0_1  1  npu_0/evt_we
    tie0 const0_13 13 npu_0/evt_addr
    tie0 const0_8  8  npu_0/evt_data
    tie0 const0_32 32 npu_0/input_stat
}

if {!$WITH_C_FULL} {
    # CR A-003 으로 top_system 에 늘어난 입력들.
    #  hw_start        : Direct START 소스. C 실물이 없으면 0. CTRL[5] 도 0 이라
    #                    어차피 안 먹지만, 입력을 띄워 두면 합성이 못 넘어간다.
    #  servo_pos_stat  : 0x58 RO. C 가 없으면 PS 가 0 을 읽는다.
    #  control_stat    : 0x5C RO. 위와 같다.
    # c_module_stub 은 이 세 신호를 안 만든다 (폐기된 자리표시자라 갱신 안 함).
    tie0 const0_hwst  1 npu_0/hw_start
    tie0 const0_sps  32 npu_0/servo_pos_stat
    tie0 const0_cst  32 npu_0/control_stat
}

# 인터럽트 / LED
connect_bd_net [get_bd_pins npu_0/irq] [get_bd_pins ps7/IRQ_F2P]
create_bd_port -dir O -from 3 -to 0 led
connect_bd_net [get_bd_pins npu_0/status_led] [get_bd_ports led]

assign_bd_address
puts "=== ADDRESS MAP ==="
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data]] {
    puts [format "  %s  offset=%s range=%s" $seg \
        [get_property OFFSET $seg] [get_property RANGE $seg]]
}

validate_bd_design
regenerate_bd_layout
save_bd_design

#---------------------------------------------------------------- wrapper
set BDF [get_files npu_bd.bd]
make_wrapper -files $BDF -top
add_files -norecurse [file join $PROJ npu_soc.gen sources_1 bd npu_bd hdl npu_bd_wrapper.v]
set_property top npu_bd_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

#---------------------------------------------------------------- build
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: impl_1 실패"
    exit 1
}

open_run impl_1
puts "=========== BITSTREAM UTILIZATION ==========="
report_utilization
puts "=========== BITSTREAM TIMING ==========="
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "WNS = $wns ns    WHS = $whs ns"
if {$wns >= 0 && $whs >= 0} { puts "BITSTREAM TIMING: MET" } else { puts "BITSTREAM TIMING: VIOLATED" }
report_utilization    -file [file join $ROOT results bd_util$SUFFIX.rpt]
report_timing_summary -delay_type min_max -file [file join $ROOT results bd_timing$SUFFIX.rpt]

set BIT [file join $PROJ npu_soc.runs impl_1 npu_bd_wrapper.bit]
if {[file exists $BIT]} {
    file copy -force $BIT [file join $ROOT results npu_soc$SUFFIX.bit]
    puts "BITSTREAM OK -> results/npu_soc$SUFFIX.bit"
} else {
    puts "ERROR: bitstream 파일 없음"
    exit 1
}

# PS 소프트웨어(Vitis)용 XSA. 자리표시자 빌드는 1 회성 측정이라 안 만든다.
if {!$WITH_C_STUB} {
    write_hw_platform -fixed -include_bit -force \
        [file join $ROOT results npu_soc$SUFFIX.xsa]
    puts "XSA OK -> results/npu_soc$SUFFIX.xsa"
}
