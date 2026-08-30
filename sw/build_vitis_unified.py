#!/usr/bin/env python3
#=====================================================================
# build_vitis_unified.py : XSA -> Vitis Platform + Application -> ELF
#   *** 통합(Unified) Vitis 2024.2 용. classic IDE 가 없어도 된다. ***
#
#  사용법:
#     source <VITIS>/2024.2/settings64.sh
#     vitis -s sw/build_vitis_unified.py                  <- npu_test.elf (기본)
#     NPU_APP=live_tracker vitis -s sw/build_vitis_unified.py   <- live_tracker.elf
#
#  ** 두 ELF 는 서로를 대체하지 않는다. **
#     npu_test.elf     보드 자체시험 STEP 1~7  (docs/PHASE4_BOARD_TEST_GUIDE.md)
#     live_tracker.elf 실시간 시연 루프        (docs/LIVE_RUNTIME_GUIDE.md)
#
#  왜 이게 따로 있나:
#     sw/build_vitis.tcl (xsct) 은 classic Vitis IDE 컴포넌트를 요구한다.
#     Unified 만 설치된 머신에서는 platform create 가 아래로 죽는다.
#         Error: --classic option is only supported by full Vitis installation.
#     그래서 같은 결과(ELF)를 unified Python API 로 만드는 경로를 하나 더 뒀다.
#     두 스크립트는 같은 XSA / 같은 소스 / 같은 산출물 이름을 쓴다.
#
#  결과: build/vitis_ws[_<APP>]/<APP>/build/<APP>.elf  ->  results/<APP>.elf
#=====================================================================
import os
import shutil
import sys

import vitis

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
XSA  = os.path.abspath(os.environ.get(
    "NPU_XSA", os.path.join(ROOT, "results", "npu_soc.xsa")
))
WS   = os.path.join(ROOT, "build", "vitis_ws")   # APP 별로 아래에서 갈라진다

PLAT   = "npu_platform"
CPU    = "ps7_cortexa9_0"
DOMAIN = "standalone_ps7_cortexa9_0"

# 어떤 Application 을 굽나.  NPU_APP 로 고른다 (기본 npu_test).
APP = os.environ.get("NPU_APP", "npu_test")

APP_SOURCES = {
    # 보드 자체시험 STEP 1~7
    "npu_test": ["npu_driver.c", "npu_test.c", "cpu_baseline.c",
                 "npu_driver.h", "npu_regs.h", "test_tensor.h",
                 "cpu_baseline.h", "int8_weights.h", "fp32_weights.h"],
    # 실시간 시연 루프 (PC UART -> Tensor -> NPU)
    "live_tracker": ["npu_driver.c", "live_tracker.c",
                     "npu_driver.h", "npu_regs.h", "live_protocol.h"],
}

if APP not in APP_SOURCES:
    print(f"ERROR: NPU_APP 이 이상하다 : {APP}")
    print(f"  쓸 수 있는 값: {', '.join(sorted(APP_SOURCES))}")
    sys.exit(1)

SRC_FILES = APP_SOURCES[APP]
# 워크스페이스는 App 마다 따로 둔다. 하나를 구워도 다른 하나가 안 지워진다.

if not os.path.exists(XSA):
    print(f"ERROR: XSA 없음 : {XSA}")
    print("  먼저 실행: cd build && vivado -mode batch -source ../sim/run_bd.tcl")
    sys.exit(1)

if APP != "npu_test":
    WS = WS + "_" + APP        # npu_test 워크스페이스를 안 건드린다

# 워크스페이스는 매번 새로 만든다. 남은 캐시 때문에 옛 XSA 로 빌드되는 걸 막는다.
if os.path.isdir(WS):
    shutil.rmtree(WS)
os.makedirs(WS, exist_ok=True)
print(f"=== APP = {APP} ===")
print(f"    XSA = {XSA}")
print(f"    WS  = {WS}")

client = vitis.create_client()
client.set_workspace(WS)

# ---------------------------------------------------------- Platform
print(f"=== Platform 생성 ({PLAT}) ===")
platform = client.create_platform_component(
    name        = PLAT,
    hw_design   = XSA,
    cpu         = CPU,
    os          = "standalone",
    domain_name = DOMAIN,
    no_boot_bsp = True,
)
platform.build()

platform_xpfm = client.find_platform_in_repos(PLAT)
print(f"    xpfm = {platform_xpfm}")

# ---------------------------------------------------------- Application
print(f"=== Application 생성 ({APP}) ===")
app = client.create_app_component(
    name     = APP,
    platform = platform_xpfm,
    domain   = DOMAIN,
    template = "empty_application",
)

# unified 플로우는 soft-link 를 안 쓴다. src/ 로 복사한다.
# sw/ 를 고쳤으면 이 스크립트를 다시 돌려야 반영된다.
app.import_files(from_loc=HERE, files=SRC_FILES, dest_dir_in_cmp="src")

# classic tcl 쪽 설정(-O1)과 맞춘다.
try:
    app.set_app_config(key="USER_COMPILE_OPTIMIZATION_LEVEL", values="-O1")
except Exception as e:                                   # 키 이름은 버전마다 다르다
    print(f"    (최적화 레벨 설정 건너뜀: {e})")

# ---------------------------------------------------------- Build
print("=== Build ===")
app.build()

# ---------------------------------------------------------- ELF 회수
elf = None
for cand in (
    os.path.join(WS, APP, "build", APP + ".elf"),
    os.path.join(WS, APP, "Debug", APP + ".elf"),
):
    if os.path.exists(cand):
        elf = cand
        break
if elf is None:                                          # 경로가 바뀌었으면 찾아본다
    for dirpath, _, names in os.walk(os.path.join(WS, APP)):
        for n in names:
            if n.endswith(".elf"):
                elf = os.path.join(dirpath, n)
                break
        if elf:
            break

if elf is None:
    print("ERROR: ELF 생성 실패")
    vitis.dispose()
    sys.exit(1)

dst = os.path.join(ROOT, "results", APP + ".elf")
shutil.copyfile(elf, dst)
print(f"ELF OK -> {elf}")
print(f"        -> {dst}")

vitis.dispose()
