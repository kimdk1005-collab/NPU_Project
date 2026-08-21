#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# xsim 단위 시뮬레이션 러너
#   사용법: ./sim/run_xsim.sh tb_servo_pwm
#
# Testbench 는 SPEC §5.3 파일 소유권에 따라 tb/{npu,event,control}/ 에 둔다.
# ---------------------------------------------------------------------------
set -e

TB="${1:-tb_servo_pwm}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XBIN=/opt/tools/Xilinx/Vivado/2024.2/bin

TB_FILE=$(find "$ROOT/tb" -name "$TB.v" -o -name "$TB.sv" | head -1)
if [ -z "$TB_FILE" ]; then
    echo "ERROR: tb/ 아래에서 $TB 를 찾을 수 없습니다" >&2
    exit 1
fi

WORK="$ROOT/sim/work"
mkdir -p "$WORK"
cd "$WORK"

SRCS=$(find "$ROOT/rtl" -name '*.v' | sort)

"$XBIN/xvlog" $SRCS "$TB_FILE"
"$XBIN/xelab" "$TB" -s "${TB}_sim"
"$XBIN/xsim" "${TB}_sim" -runall
