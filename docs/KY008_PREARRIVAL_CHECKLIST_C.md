# KY-008 실제 광원 사전 준비 및 도착 후 브링업 체크리스트

> 기준일: 2026-08-25
>
> 상태: **RTL/XDC/자동판정 사전 준비 완료. 실제 광원·외부 전원 스위치 미연결.**
>
> 적용 Top: `rtl/control/ky008_laser_board_io.v`

## 1. 구매품 확정 정보

| 항목 | 값 | 상태 |
|---|---:|---|
| 모듈 | KY-008 점형 Red Laser | 확정 |
| 동작 전압 | DC 5 V | 확정 |
| 동작 전류 | 30 mA | 확정 |
| 파장 | 650 nm | 확정 |
| 동작 온도 | -10~+40 ℃ | 확정 |
| 핀 | `S=+5 V`, middle=`NC`, `-=GND` | 판매처 자료 기준 확정 |
| 광출력/등급 | mW / IEC Class | **미확인 — 실제 발광 전 필수** |

`S`는 고임피던스 TTL 입력이 아니라 광원 전류가 흐르는 5 V 전원 입력이다.
JD7/U14 또는 다른 FPGA GPIO에 직접 연결하지 않는다. middle 핀은 NC로 절연한다.

## 2. 전기 연결 기준

```text
regulated/current-limited 5 V
  -> fuse/current limit
  -> physical Key Arm
  -> normally-closed E-stop
  -> default-OFF High-side load switch
  -> KY-008 S

KY-008 middle -> NC
KY-008 -      -> external 5 V GND
Zybo GND      -> external 5 V GND

JD7/U14 laser_gate_cmd -> load switch Enable only
```

### High-side switch 요구 조건

- 5 V 입력 지원
- 3.3 V Enable 호환
- 100 mA 이상 연속 전류
- Enable floating/Power-on 상태에서 기본 OFF
- 가능하면 Quick Output Discharge 지원
- 실제 PCB 장착 후 case/bracket 접촉으로 우회 경로가 생기지 않을 것

Low-side 스위치는 절연된 벤치 dummy 시험에만 허용한다. 금속 레이저 헤드나 브래킷이
GND와 접촉할 수 있는 최종 장착에는 High-side 방식만 사용한다.

## 3. 준비 부품

- [ ] 전류 제한 가능한 정전압 5 V 전원
- [ ] 위 조건을 만족하는 High-side load switch/driver
- [ ] 물리 Key Arm 스위치
- [ ] NC 방식 E-stop
- [ ] 실제 측정 전류에 맞춘 소형 퓨즈 또는 독립 전류 제한
- [ ] 5 V/GND/Enable 분리 커넥터와 절연 하네스
- [ ] 실제 광출력에 맞는 650 nm 보호안경
- [ ] 전체 Servo 안전 범위를 수용하는 비반사 빔 스톱
- [ ] 출입을 통제할 수 있는 실내 시험 공간

보호안경의 OD는 파장만으로 결정하지 않는다. 판매처의 최대 광출력 또는 실측 광출력과
레이저 등급을 확인한 뒤 선정한다.

## 4. 구현된 사전 안전 동작

공통 `laser_interlock.v`에 다음 조건을 추가했다.

- Power-on 때 Laser Arm이 이미 HIGH면 출력 금지
- Reset 해제 후 Laser Arm LOW를 한 clock 이상 관측해야 최초 재무장 가능
- E-stop을 놓아도 자동 재점등 금지
- E-stop 뒤 Laser Arm LOW→HIGH 수동 사이클 필수
- Max-on timeout 뒤 Laser Arm LOW 전까지 fault 유지
- Servo enable과 Laser Arm을 분리해 Servo OFF가 Arm LOW 이력을 대신하지 못함
- `CONTROL_STAT[16] = LASER_REARM_REQUIRED`

KY-008 전용 Top은 다음 값을 강제한다.

| 항목 | Bring-up 값 |
|---|---:|
| PT#1/PT#2 Servo 안전 범위 | 112~144 |
| Neutral | 128 |
| 최대 연속 Gate | 5 frame |
| 50 Hz 기준 최대 시간 | 약 100 ms |
| Gate 극성 | Active High |

`MAX_ON_FRAMES`는 1~5만 허용하며 0 또는 6 이상은 elaboration에서 오류를 낸다.

## 5. 자동판정

```bash
./sim/run_xsim.sh tb_laser_interlock
./sim/run_xsim.sh tb_dual_head_control
./sim/run_xsim.sh tb_dual_head_board_io
./sim/run_xsim.sh tb_c_event_control_top
./sim/run_xsim.sh tb_ky008_laser_board_io
```

KY-008 전용 TB 판정 범위:

- Boot Arm HIGH에서 Gate OFF
- Arm LOW→HIGH 후에만 3회 Lock 확인 가능
- PT#1/PT#2 112~144 유지
- E-stop 즉시 OFF
- E-stop release만으로 복구 금지
- 100 ms max-on timeout
- timeout 자동 복구 금지
- Arm LOW에서만 timeout/rearm latch clear

## 6. 프로젝트 및 Bitstream

```bash
vivado -mode batch -source sim/create_ky008_laser_gate_project.tcl
```

사용 파일:

```text
Top        rtl/control/ky008_laser_board_io.v
Constraint constraints/c_ky008_laser_gate_test.xdc
Gate pin   JD7 / U14 / LVCMOS33
```

2026-08-25 Zybo Z7-20 배치배선/Bitstream 결과:

| 항목 | 결과 |
|---|---:|
| Slice LUT | 448 (0.84%) |
| Slice Register | 373 (0.35%) |
| BRAM Tile | 0 |
| DSP | 4 (1.82%) |
| Setup WNS | +1.529 ns |
| Hold WHS | +0.153 ns |
| Timing failing endpoint | 0 |
| DRC Error | 0 |

Vivado의 PL-only Zynq PS7 권고와 비파이프라인 DSP 권고 Warning은 남지만 실제 Error,
unrouted net, setup/hold violation은 없다.

JD7에는 최초에 KY-008이 아니라 dummy LED/load와 High-side switch Enable만 연결한다.
생성 가능한 Vivado 프로젝트와 Bitstream은 Git에 커밋하지 않는다.

## 7. 모듈 도착 후 순서

1. 실제 수령품 앞/뒤 패턴과 `S/NC/-` 실크 확인
2. 판매처에서 최대 광출력 mW 또는 Laser Class 확인
3. KY-008 미연결 상태에서 High-side 출력에 dummy load 연결
4. Boot/E-stop/Arm/timeout 표를 오실로스코프 또는 로직 분석기로 실측
5. KY-008을 고정하고 Servo 전원을 끈 상태에서 전류 제한 5 V 연결
6. 빔 스톱/보호구/통제구역 준비 후 100 ms 이하 최초 단발 점등
7. 소비전류가 30 mA 기준에서 크게 벗어나면 즉시 차단
8. 물리 E-stop이 FPGA 상태와 무관하게 5 V를 차단하는지 확인
9. PT#2 112~144 좁은 범위에서 방향 확인
10. 2 m 거리 중앙+네 모서리 5점에서 `LASER_CAL` 측정
11. LED로 전체 Event→NPU→Target→Servo 폐루프를 먼저 재검증
12. 최종 승인 후에만 실제 광원을 자동 Target 경로에 연결

## 8. 실제 광원 연결 승인 조건

- [ ] 광출력 mW/등급 확인
- [ ] 보호안경 OD 적합성 확인
- [ ] High-side driver dummy load PASS
- [ ] Power-on Arm HIGH Gate OFF 실측
- [ ] E-stop release 자동 재점등 없음 실측
- [ ] Max-on 100 ms와 수동 재무장 실측
- [ ] Key Arm/NC E-stop이 광원 5 V를 물리 차단
- [ ] PT#2 전체 범위가 빔 스톱 내부
- [ ] 사람이 없는 통제구역 확보

하나라도 미충족이면 KY-008을 연결하지 않고 JD7 dummy LED 단계로 돌아간다.
