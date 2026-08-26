# KY-008 실제 광원 브링업 체크리스트 및 결과

> 기준일: 2026-08-26
>
> 상태: **수령품 핀 확인 및 C 독립 100 ms 단발 발광 완료. 최종 광학/물리 안전 승인과 A 통합은 미완료.**
>
> 적용 Top: `rtl/control/ky008_laser_board_io.v`

## 1. 수령품 확인 결과

| 항목 | 값 | 상태 |
|---|---:|---|
| 모듈 | KY-008 계열 점형 Red Laser | 실물 도착 |
| 동작 전압 | DC 5 V | 수령품 배선에서 동작 확인 |
| 파장 | 650 nm 표기 | 판매 정보 기준, 실측 안 함 |
| 핀 | `S=control`, middle=`+5 V`, `-=GND` | 100 ms 단발로 기능 확인 |
| S 연결 | JD7/U14에서 외부 1 kΩ 직렬 보호 후 연결 | 수령품 브링업 전용 |
| 소비전류 | 판매 정보 약 30 mA | **실측값 미기록** |
| 광출력/등급 | mW / IEC Class | **미확인 — 자동 시연 전 필수** |

KY-008이라는 이름으로 서로 다른 내부회로와 핀 용도의 제품이 유통된다. 이 문서의
배선은 2026-08-26 수령품에만 적용한다. `S`라는 글자만 보고 다른 제품을 FPGA에
직결하지 않으며, JD7은 5 V 전원이나 레이저 전류 공급선으로 사용하지 않는다.

## 2. 수령품 브링업 배선

```text
regulated/current-limited 5 V
  -> fuse/current limit
  -> physical Key Arm
  -> normally-closed E-stop
  -> KY-008 middle (+5 V)

JD7/U14 laser_gate_cmd
  -> external 1 kOhm series protection
  -> KY-008 S

KY-008 -      -> external 5 V GND
Zybo GND      -> external 5 V GND
Servo current -> separate external power path; do not route through Zybo/Nucleo 5 V
```

### 전기 경계

- JD7/U14는 3.3 V active-HIGH 논리 출력이다.
- 수령품 S에는 1 kΩ 직렬 보호를 유지한다. 저항을 제거한 FPGA 직결은 승인하지 않는다.
- FPGA 미프로그램/재프로그램 중 S 기본-OFF를 보장하는 외부 회로는 최종 승인 전에 확인한다.
- Key와 NC E-stop은 논리 신호가 아니라 광원 5 V를 물리적으로 차단해야 한다.
- 독립 전원 차단이 더 필요하면 3.3 V Enable 호환 default-OFF High-side load switch를
  5 V 경로에 추가한다.
- Servo와 광원은 동일한 보드 5 V 핀에서 전원을 공급하지 않는다. GND 기준만 공통으로 둔다.

## 3. 최종 시연 전 필요한 부품/환경

- [ ] 전류 제한 가능한 정전압 5 V 전원
- [x] JD7-S 외부 1 kΩ 직렬 보호
- [ ] 물리 Key Arm 스위치
- [ ] NC 방식 E-stop
- [ ] 실제 측정 전류에 맞춘 소형 퓨즈 또는 독립 전류 제한
- [ ] FPGA 미프로그램 상태의 S default-OFF 보장 회로
- [ ] 5 V/GND/Signal 분리 커넥터와 절연 하네스
- [ ] 실제 광출력에 맞는 650 nm 보호안경
- [ ] 전체 Servo 안전 범위를 수용하는 비반사 빔 스톱
- [ ] 출입을 통제할 수 있는 실내 시험 공간

보호안경의 OD는 파장만으로 결정하지 않는다. 판매처의 최대 광출력 또는 실측 광출력과
레이저 등급을 확인한 뒤 선정한다.

## 4. 구현된 안전 동작

공통 `laser_interlock.v`는 다음을 강제한다.

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
Gate pin   JD7 / U14 / LVCMOS33 / DRIVE 4 / SLEW SLOW
```

2026-08-26 XDC의 JD7 `DRIVE 4`/`SLEW SLOW`를 반영한 Zybo Z7-20
배치배선/Bitstream 재검증 결과:

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

생성 가능한 Vivado 프로젝트와 Bitstream은 Git에 커밋하지 않는다.

## 7. 2026-08-26 실물 브링업 결과

| 단계 | 결과 |
|---|---|
| Vivado Hardware Manager에서 `xc7z020_1` 프로그램 | PASS |
| `SW=0000`에서 LED0 heartbeat, LED1~3 OFF | PASS |
| Servo Enable/Target Valid 상태 LED1/LED2 | PASS |
| Arm LOW→HIGH 뒤 LED3 약 100 ms 점등 | PASS |
| 수령품 KY-008이 LED3과 함께 단발 발광 | PASS |
| Timeout 뒤 Arm HIGH 유지 시 자동 재점등 없음 | PASS |
| Arm LOW→HIGH 수동 재무장 뒤 단발 반복 | PASS |

시험 배선은 `S <- JD7/U14(1 kΩ 직렬)`, middle=`+5 V`, `-`=공통 GND이며
Servo 전원은 끈 독립 브링업이었다. 이 결과는 수령품의 단발 동작과 C 인터록 경로를
검증한 것이며, 소비전류·광출력 등급·물리 E-stop·자동 Target 경로 승인을 뜻하지 않는다.

## 8. 남은 최종 승인 조건

- [x] 수령품 `S/middle/-` 기능 확인
- [x] JD7/LED3 active-HIGH Gate 동기 확인
- [x] 약 100 ms 단발과 timeout latch 확인
- [x] Arm LOW→HIGH 수동 재무장 확인
- [ ] 소비전류 실측 및 기록
- [ ] 광출력 mW/IEC Class 확인
- [ ] 보호안경 OD 적합성 확인
- [ ] FPGA 미프로그램/재프로그램 중 S default-OFF 실측
- [ ] Key Arm/NC E-stop이 광원 5 V를 물리 차단
- [ ] E-stop release 자동 재점등 없음을 실제 광원 전원 경로에서 실측
- [ ] PT#2 전체 범위가 빔 스톱 내부
- [ ] 2 m 중앙+네 모서리 `LASER_CAL` 실측
- [ ] A NPU Target을 연결한 LED Closed-loop 선행 검증
- [ ] 최종 승인 뒤 실제 광원 자동 Target 경로 검증

하나라도 미충족이면 C 독립 단발 브링업 결과까지만 인정하고 자동 광원 시연은 승인하지 않는다.
