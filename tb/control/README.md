# C 역할 — Control Testbench

> 소유: C · 대상: `rtl/control/`

Tracking, 4-Servo, 동적 Limit, Laser Interlock, E-stop, Timeout과 수동 재무장을 검증한다.
안전 관련 변경은 정상 경로뿐 아니라 Power-on, 신호 상실, Fault latch와 재활성화 금지 경로를
반드시 함께 시험한다.

`tb_dual_head_control.v`는 Runtime Limit valid 적용뿐 아니라, 적용 중인 유효값을
정적 범위 밖 invalid raw 값으로 바꾸는 전이 clock에도 그 raw 값이 Servo 명령으로
한 cycle조차 전달되지 않는지 판정한다.

`tb_component_manual_test_top.v`는 SW0~SW3, 물리 BTN0~BTN3과 두 조합 입력
(논리 BTN4/BTN5)으로 4축 개별 이동, Neutral, 100 ms Laser Gate, 논리 E-stop을 검증한다.
