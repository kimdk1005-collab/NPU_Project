#!/usr/bin/env bash
# NPU 시뮬레이션 (Vivado xsim). A RTL + C RTL(rtl/event, rtl/control) 전부.
#   ./sim/run_sim.sh [tb_이름 ...]        인자 없으면 자동판정 TB 16 종 전부
#   TV_DIR=../test_vectors/case01/ ./sim/run_sim.sh    테스트 벡터 셋 지정
#   W_DIR=../weights/ ./sim/run_sim.sh                 weight 디렉토리 지정
# 작업 디렉토리는 build/ 이므로 경로는 build/ 기준 상대경로로 준다.
set +u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Vivado 환경. PC 마다 설치 경로가 다르므로 환경변수 우선.
#   XILINX_VIVADO 가 이미 잡혀 있으면(settings64.sh 를 이미 source 했으면) 건너뛴다.
#   아니면 VIVADO_SETTINGS 로 지정. 그것도 없으면 아래 후보를 순서대로 찾는다.
if [ -z "$XILINX_VIVADO" ]; then
  for _s in "$VIVADO_SETTINGS" \
            /media/user7/data/tools/Vivado/2024.2/settings64.sh \
            /tools/Xilinx/Vivado/2024.2/settings64.sh \
            "$HOME"/Xilinx/Vivado/2024.2/settings64.sh \
            "$HOME"/xilinx/Vivado/2024.2/settings64.sh \
            /opt/Xilinx/Vivado/2024.2/settings64.sh; do
    [ -n "$_s" ] && [ -f "$_s" ] && { source "$_s"; break; }
  done
fi
if ! command -v xvlog >/dev/null 2>&1; then
  echo "ERROR: Vivado 를 못 찾았다. 아래 중 하나를 해라." >&2
  echo "  source /your/path/Vivado/2024.2/settings64.sh   # 그 다음 이 스크립트 실행" >&2
  echo "  VIVADO_SETTINGS=/your/path/Vivado/2024.2/settings64.sh ./sim/run_sim.sh" >&2
  exit 1
fi

RTL="$ROOT/rtl/npu"
RTLI="$ROOT/rtl/integration"
RTLE="$ROOT/rtl/event"          # C 소유
RTLC="$ROOT/rtl/control"        # C 소유
TB="$ROOT/tb/npu"
TBI="$ROOT/tb/integration"
TBE="$ROOT/tb/event"            # C 소유
TBC="$ROOT/tb/control"          # C 소유
mkdir -p "$ROOT/build"
cd "$ROOT/build"

# 기본 실행 목록 = 자동판정 TB 전부 (A 6 + C 9 + A/C 통합 1 = 16 종).
# tb_servo_pwm_sweep 은 self-check 가 없는 파형 관찰용이라 기본에서 뺀다.
#   ./sim/run_sim.sh tb_servo_pwm_sweep   <- 필요하면 이름으로 직접 돌린다
TBS=("$@")
if [ ${#TBS[@]} -eq 0 ]; then
  TBS=(tb_npu_requant tb_npu_pe tb_npu_conv_dense tb_npu_full tb_npu_axi tb_top_system
       tb_event_adapter tb_event_accumulator tb_event_pipeline
       tb_servo_pwm tb_tracking_controller tb_laser_head_controller
       tb_laser_interlock tb_dual_head_control tb_c_event_control_top
       tb_top_system_c)
fi

TV_DIR="${TV_DIR:-../test_vectors/case00/}"
W_DIR="${W_DIR:-../weights/}"
echo "=== xvlog ===  TV_DIR=$TV_DIR  W_DIR=$W_DIR"
xvlog --incr -i "$RTL" \
  -d NPU_TV_DIR="\"$TV_DIR\"" -d NPU_WEIGHT_DIR="\"$W_DIR\"" \
  "$RTL"/npu_requant.v "$RTL"/npu_pe.v "$RTL"/npu_act_buf.v \
  "$RTL"/npu_weight_rom.v "$RTL"/npu_conv_dense.v "$RTL"/argmax_decoder.v \
  "$RTL"/npu_datapath.v "$RTL"/npu_controller.v "$RTL"/npu_core.v \
  "$RTLI"/npu_axi.v "$RTLI"/top_system.v \
  "$RTLE"/event_adapter.v "$RTLE"/event_accumulator.v \
  "$RTLC"/servo_pwm.v "$RTLC"/tracking_controller.v \
  "$RTLC"/laser_head_controller.v "$RTLC"/laser_interlock.v \
  "$RTLC"/dual_head_control.v "$RTLC"/c_event_control_top.v \
  "$RTLI"/top_system_c.v \
  "$TB"/tb_npu_requant.v "$TB"/tb_npu_pe.v \
  "$TB"/tb_npu_conv_dense.v "$TB"/tb_npu_full.v \
  "$TBI"/tb_npu_axi.v "$TBI"/tb_top_system.v \
  "$TBE"/tb_event_adapter.v "$TBE"/tb_event_accumulator.v \
  "$TBE"/tb_event_pipeline.v \
  "$TBC"/tb_servo_pwm.v "$TBC"/tb_servo_pwm_sweep.v \
  "$TBC"/tb_tracking_controller.v "$TBC"/tb_laser_head_controller.v \
  "$TBC"/tb_laser_interlock.v "$TBC"/tb_dual_head_control.v \
  "$TBC"/tb_c_event_control_top.v \
  "$TBI"/tb_top_system_c.v \
  || exit 1

FAIL=0
for t in "${TBS[@]}"; do
  echo ""
  echo "=== $t ==="
  xelab -debug off -O2 --incr -s "sim_$t" "$t" > "xelab_$t.log" 2>&1 || {
      echo "xelab 실패, 로그: build/xelab_$t.log"; tail -20 "xelab_$t.log"; FAIL=1; continue; }
  xsim "sim_$t" -runall -log "xsim_$t.log" | grep -v "^$"
  grep -q "\[FAIL\]" "xsim_$t.log" && FAIL=1
done

echo ""
if [ $FAIL -eq 0 ]; then echo "########## ALL TB PASS ##########"; else echo "########## SOME TB FAILED ##########"; fi
exit $FAIL
