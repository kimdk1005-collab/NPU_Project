# C 역할 — Control Testbench

> 소유: C · 대상: `rtl/control/`

Tracking, 4-Servo, 동적 Limit, Laser Interlock, E-stop, Timeout과 수동 재무장을 검증한다.
안전 관련 변경은 정상 경로뿐 아니라 Power-on, 신호 상실, Fault latch와 재활성화 금지 경로를
반드시 함께 시험한다.
