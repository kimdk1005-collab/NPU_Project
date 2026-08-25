# C 역할 — Tracking·Pan/Tilt·Laser RTL

> 소유: C · 정본: `handoff/C_EVENT_CONTROL_HANDOFF.md`

NPU Target을 Camera PT#1과 Laser PT#2 명령으로 변환하고 Servo Limit, E-stop, Arm,
Timeout과 수동 재무장 Interlock을 적용한다.

대표 검증:

```bash
./sim/run_xsim.sh tb_tracking_controller
./sim/run_xsim.sh tb_laser_interlock
./sim/run_xsim.sh tb_dual_head_control
./sim/run_xsim.sh tb_c_event_control_top
./sim/run_xsim.sh tb_ky008_laser_board_io
```

실제 광원 연결은 `docs/KY008_PREARRIVAL_CHECKLIST_C.md`의 dummy load와 안전 승인 이후에만
수행한다. 시뮬레이션 PASS와 실물 PASS를 구분해 Handoff에 기록한다.
