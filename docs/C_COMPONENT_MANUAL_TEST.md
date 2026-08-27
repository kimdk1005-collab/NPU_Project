# C 연결 부품 수동 동작 테스트

> 대상: Zybo Z7-20, Camera PT#1 Servo 2개, Laser PT#2 Servo 2개, 수령품 KY-008
>
> Top: `rtl/control/component_manual_test_top.v`

## 1. 버튼 수 제한

Zybo Z7-20에는 물리 사용자 버튼이 `BTN0~BTN3` 네 개만 있다. 이 테스트에서는
동시 누름을 이용해 다음 두 논리 버튼을 추가한다.

- `BTN4` = `BTN0+BTN1`: 네 Servo 모두 Neutral
- `BTN5` = `BTN2+BTN3`: 논리 E-stop, 누르는 동안 Servo PWM과 Laser Gate 즉시 OFF

`BTN5`는 FPGA 논리 시험용이며 광원 5 V를 끊는 물리 E-stop을 대신하지 않는다.

## 2. 조작표

| 입력 | 동작 |
|---|---|
| `SW0` | 네 Servo PWM Enable |
| `SW1` | Laser Arm. 위치 조정 중에는 반드시 LOW |
| `SW3:SW2=00` | Camera PAN, JD1 선택 |
| `SW3:SW2=01` | Camera TILT, JD2 선택 |
| `SW3:SW2=10` | Laser PAN, JD3 선택 |
| `SW3:SW2=11` | Laser TILT, JD4 선택 |
| `BTN0` | 선택 축 -8 step |
| `BTN1` | 선택 축 +8 step |
| `BTN2` | 선택 축 Neutral |
| `BTN3` | 누르는 동안 Laser ON, 놓으면 즉시 OFF; 한 번에 최대 1초 |
| `BTN0+BTN1` | 논리 BTN4, 네 축 모두 Neutral |
| `BTN2+BTN3` | 논리 BTN5, Servo/Laser 논리 E-stop |

LED는 `LED0=heartbeat`, `LED1=Servo PWM Enable`, `LED2=Laser Ready`,
`LED3=실제 Laser Gate`다.

## 3. 전원 및 배선 전제

- 네 Servo의 전원은 Nucleo/Zybo 5 V 핀이 아니라 별도 5~6 V 대전류 전원을 사용한다.
- 권장 전원 여유는 6 A 이상, 네 축 동시 Hold에는 8 A급이 실용적이다.
- Servo 외부 전원 GND, KY-008 외부 전원 GND, Zybo GND를 공통으로 연결한다.
- `JD1=T14`, `JD2=T15`, `JD3=P14`, `JD4=R14`, `JD7=U14`다.
- 수령품 KY-008은 `JD7 -> 1 kΩ -> S`, middle=`+5 V`, `-`=GND를 유지한다.
- 시작할 때 Servo 전원과 Laser 5 V를 끄고 `SW=0000`으로 둔다.

## 4. Vivado 실행

프로젝트 생성:

```bash
vivado -mode batch -source sim/create_component_manual_test_project.tcl \
       -tclargs project_only
```

생성 프로젝트:

```text
vivado_component_manual_test/c_component_manual_test.xpr
```

Vivado에서 `Generate Bitstream` 후 Hardware Manager에서 사용자가 직접 프로그램한다.

## 5. 실물 시험 순서

1. `SW=0000`, Servo/Laser 외부 전원 OFF 상태에서 FPGA를 프로그램한다.
2. `LED0` heartbeat와 `LED1~LED3=OFF`를 확인한다.
3. Servo 전원을 켜고 `SW0=1`로 올린다. `LED1=ON`을 확인한다.
4. `SW1=0`을 유지한 채 `SW3:SW2`로 각 축을 선택한다.
5. 각 축에서 `BTN0`, `BTN1`, `BTN2`를 눌러 감소·증가·중립을 확인한다.
6. `BTN0+BTN1`을 눌러 네 축이 모두 Neutral로 복귀하는지 확인한다.
7. 빔 스톱을 설치하고 Laser 전원을 켠다.
8. `SW1=0`을 한 번 확인한 뒤 `SW1=1`로 올린다. `LED2=ON`이어야 한다.
9. `BTN3`을 누르고 있는 동안 `LED3`과 Laser가 유지되고, 놓으면 즉시 꺼지는지 확인한다.
10. 1초 이상 계속 누르면 timeout으로 꺼진다. 이 경우 `SW1=0 -> 1`로 수동 재무장한다.
11. 발광 중 `BTN2+BTN3`을 눌러 LED1/LED3과 Servo PWM/Laser가 즉시 꺼지는지 확인한다.
12. 종료할 때 `SW=0000`, Laser 5 V OFF, Servo 전원 OFF 순서로 내린다.

예상과 반대 방향으로 움직이거나 기구 간섭·전원 리셋·과열이 발생하면 즉시
`SW0=0`으로 내리고 외부 전원을 차단한다.

## 6. 자동판정 및 Bitstream 검증

2026-08-26 검증 결과:

| 항목 | 결과 |
|---|---:|
| `tb_component_manual_test_top` | **44/44 PASS, errors=0** |
| 기존 C 회귀 포함 | **13종 331 PASS, errors=0** |
| Slice LUT | 231 (0.43%) |
| Slice Register | 310 (0.29%) |
| BRAM Tile | 0 |
| DSP | 4 (1.82%) |
| Setup WNS | +2.542 ns |
| Hold WHS | +0.066 ns |
| Timing failing endpoint | 0 |
| DRC Error | 0 |

PL-only Zynq PS7 및 Servo PWM DSP 파이프라인 권고 Warning은 있으나 DRC Error,
unrouted net, setup/hold violation은 없다. 실물 4축 개별 조작 결과는 위 §5 순서로
사용자가 확인한 뒤 기록한다.
