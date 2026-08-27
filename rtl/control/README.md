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
./sim/run_xsim.sh tb_component_manual_test_top
```

수령품 KY-008의 C 독립 100 ms 단발은 완료했다. 실제 자동 광원 경로는
`docs/KY008_PREARRIVAL_CHECKLIST_C.md`의 남은 광학·물리 안전 승인 이후에만 수행한다.
시뮬레이션 PASS와 실물 PASS를 구분해 Handoff에 기록한다.

연결 부품을 하나씩 수동 확인할 때는 `component_manual_test_top.v`와
`docs/C_COMPONENT_MANUAL_TEST.md`를 사용한다. Zybo의 물리 버튼은 네 개이므로
BTN0+BTN1을 논리 BTN4, BTN2+BTN3을 논리 BTN5로 사용한다.

Runtime `SAFE_LIMIT/SAFE_LIMIT2`는 8개 값의 유효성을 한 cycle에 판정한 뒤,
검증된 값 자체를 원자적으로 등록한다. Invalid 조합은 raw 값을 출력 경로에 적용하지
않고 정적 parameter 범위로 복귀하며 `LIMIT_FAULT`를 세운다. C 래퍼 OOC 재현은
다음 명령을 사용한다.

```bash
vivado -mode batch -source sim/run_c_event_control_ooc.tcl
```
