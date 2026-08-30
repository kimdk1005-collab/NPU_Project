#=====================================================================
# build_vitis.tcl : XSA -> Vitis Platform + Application 자동 생성
#
#  사용법:  (Vitis 설치 경로는 PC 마다 다르다. 본인 경로로 바꿔라)
#     source <VITIS>/2024.2/settings64.sh
#     cd build && xsct ../sw/build_vitis.tcl
#
#  <VITIS> 후보 : /tools/Xilinx/Vitis , $HOME/Xilinx/Vitis , /opt/Xilinx/Vitis
#
#  결과: build/vitis_ws/npu_test/Debug/npu_test.elf
#
#  보드에 올리는 법 (보드 도착 후):
#     1. Vivado Hardware Manager 로 results/npu_soc.bit 프로그램
#        또는 Vitis 에서 Program FPGA
#     2. UART 115200-8-N-1 열기 (Zybo 는 USB-UART)
#     3. npu_test.elf 실행
#=====================================================================
set HERE [file normalize [file dirname [info script]]]
set ROOT [file normalize [file join $HERE ..]]
if {[info exists ::env(NPU_XSA)] && $::env(NPU_XSA) ne ""} {
    set XSA [file normalize $::env(NPU_XSA)]
} else {
    set XSA [file join $ROOT results npu_soc.xsa]
}
set WS   [file join $ROOT build vitis_ws]

set PLAT npu_platform
set APP  npu_test
set PROC ps7_cortexa9_0

if {![file exists $XSA]} {
    puts "ERROR: XSA 없음 : $XSA"
    puts "  먼저 실행: cd build && vivado -mode batch -source ../sim/run_bd.tcl"
    exit 1
}

file mkdir $WS
setws $WS

# ---------------------------------------------------------- Platform
puts "=== Platform 생성 ($PLAT) ==="
platform create -name $PLAT -hw $XSA -proc $PROC -os standalone -no-boot-bsp
platform generate

# ---------------------------------------------------------- Application
puts "=== Application 생성 ($APP) ==="
app create -name $APP -platform $PLAT -domain "standalone_domain" \
           -template "Empty Application(C)"

# 소스는 복사하지 않고 링크한다. sw/ 를 고치면 바로 반영된다.
importsources -name $APP -path [file join $ROOT sw npu_driver.c] -soft-link
importsources -name $APP -path [file join $ROOT sw npu_test.c]   -soft-link
importsources -name $APP -path [file join $ROOT sw npu_driver.h] -soft-link
importsources -name $APP -path [file join $ROOT sw npu_regs.h]   -soft-link
importsources -name $APP -path [file join $ROOT sw test_tensor.h] -soft-link
importsources -name $APP -path [file join $ROOT sw cpu_baseline.c] -soft-link
importsources -name $APP -path [file join $ROOT sw cpu_baseline.h] -soft-link
importsources -name $APP -path [file join $ROOT sw int8_weights.h] -soft-link
importsources -name $APP -path [file join $ROOT sw fp32_weights.h] -soft-link

app config -name $APP include-path [file join $ROOT sw]
app config -name $APP -set compiler-optimization "Optimize (-O1)"

# ---------------------------------------------------------- Build
puts "=== Build ==="
app build -name $APP

set ELF [file join $WS $APP Debug $APP.elf]
if {[file exists $ELF]} {
    puts "ELF OK -> $ELF"
} else {
    puts "ERROR: ELF 생성 실패"
    exit 1
}
