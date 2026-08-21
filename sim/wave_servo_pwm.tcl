# ---------------------------------------------------------------------------
# 파형 창 구성 - tb_servo_pwm_sweep 용
#
#   Vivado 시뮬레이터의 Tcl Console 에서:
#     source <프로젝트루트>/sim/wave_servo_pwm.tcl
#
#   기존 파형을 지우고 보기 좋은 순서로 다시 배치한다.
# ---------------------------------------------------------------------------

set tb "/tb_servo_pwm_sweep"

# 이미 열린 파형 정리
catch { remove_wave -of [get_wave_config] [get_waves -of [get_wave_config] *] }

# --- Clock / Reset --------------------------------------------------------
add_wave_group "Clock / Reset"
add_wave -into [get_wave_groups "Clock / Reset"] $tb/clk
add_wave -into [get_wave_groups "Clock / Reset"] $tb/rst_n

# --- 입력 -----------------------------------------------------------------
add_wave_group "Input"
add_wave -into [get_wave_groups "Input"] -radix unsigned $tb/pos
add_wave -into [get_wave_groups "Input"] $tb/en

# --- Clamp 없음 -----------------------------------------------------------
add_wave_group "dut_free (Clamp 없음)"
add_wave -into [get_wave_groups "dut_free (Clamp 없음)"] $tb/pwm_free
add_wave -into [get_wave_groups "dut_free (Clamp 없음)"] $tb/tick_free
add_wave -into [get_wave_groups "dut_free (Clamp 없음)"] -radix unsigned \
         $tb/dut_free/pos_clamped
add_wave -into [get_wave_groups "dut_free (Clamp 없음)"] -radix unsigned \
         $tb/dut_free/pulse_cyc

# --- Safe Angle Limit 적용 ------------------------------------------------
add_wave_group "dut_lim (Safe Limit 64~192)"
add_wave -into [get_wave_groups "dut_lim (Safe Limit 64~192)"] $tb/pwm_lim
add_wave -into [get_wave_groups "dut_lim (Safe Limit 64~192)"] -radix unsigned \
         $tb/dut_lim/pos_clamped
add_wave -into [get_wave_groups "dut_lim (Safe Limit 64~192)"] -radix unsigned \
         $tb/dut_lim/pulse_cyc

# --- 측정값 (us 단위) -----------------------------------------------------
add_wave_group "측정 펄스폭 (us)"
add_wave -into [get_wave_groups "측정 펄스폭 (us)"] -radix unsigned $tb/pulse_free_us
add_wave -into [get_wave_groups "측정 펄스폭 (us)"] -radix unsigned $tb/pulse_lim_us

catch { zoom fit }

puts ""
puts "파형 구성 완료."
puts ""
puts "보는 법"
puts "  - pos 가 0 -> 255 로 올라갈 때 pwm_free 의 High 폭이 넓어진다"
puts "  - pos 가 0~63, 193~255 구간에서 pwm_lim 의 폭은 더 이상 변하지 않는다"
puts "    -> Safe Angle Limit 이 걸린 구간이다"
puts "  - Frame 주기는 20 ms 로 항상 일정하다. 바뀌는 것은 High 구간뿐이다"
puts "  - tick_free 는 Frame 시작 1-cycle pulse (상위 Slew Limit 이 쓸 신호)"
puts ""
puts "확대해서 볼 구간"
puts "  0 ~ 60 ms      : pos=0   최소 펄스"
puts "  180 ~ 220 ms   : pos=128 중립 1500 us"
puts "  340 ~ 380 ms   : pos=255 최대 펄스, Clamp 차이가 가장 크다"
puts ""
