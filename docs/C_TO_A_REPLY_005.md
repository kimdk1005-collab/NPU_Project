# C → A 회신 005 — A/C 실물 통합 요청 #001 대응

> 회신일: 2026-08-27
>
> 대상: `docs/A_TO_C_V01_REQUEST_001.md`
>
> 참조: `CHANGE_REQUEST_A_003_c_integration.md`의 세 항목은 A 요청서 §5에
> 인용된 내용을 기준으로 회신한다. 해당 원문 파일은 현재 C 체크아웃에 없다.
>
> 상태: **SAFE_LIMIT RTL/TB 반영 및 필수 승인 회신 완료 / 실물 계측 항목 대기**
>
> C 버전: `C_EVENT=c_event_v04`, `C_CONTROL=c_control_v09`, `INTERFACE=ifc_v0.5`
>
> 버전 영향: 포트/bit 계약 `ifc_v0.5`는 유지한다.

## 1. Runtime SAFE_LIMIT 파이프라인 — 수정 완료

선택: **(A) C가 파이프라인을 추가한다.**

`rtl/control/dual_head_control.v`에서 8개 Runtime Limit의 조합 판정과 Servo/
Interlock 경로를 Register로 분리했다. 판정 비트만 등록하고 원본 AXI 값을 바로
사용하면 AXI write 전이 중 이전 판정과 새 값이 한 cycle 섞일 수 있으므로,
검증된 8개 유효 제한값 자체를 한 묶음으로 등록한다.

동작 계약은 다음과 같다.

```text
reset                       -> 정적 parameter 한계, ACTIVE=0, FAULT=0
enable + 8개 값 모두 valid -> 다음 clock에 8개를 원자적으로 적용, ACTIVE=1
enable + 하나라도 invalid  -> 정적 parameter 한계, ACTIVE=0, FAULT=1
disable                     -> 정적 parameter 한계, ACTIVE=0, FAULT=0
```

Invalid raw 값이 이전 valid 판정과 섞여 한 cycle 출력되는 전이 조건을
`tb/control/tb_dual_head_control.v`에 추가했다. 변경은 아직 작업 트리에 있으며
전달용 C 커밋 해시는 커밋 생성 후 기입한다.

## 2. `D3_FREEZE_REQUEST_A_002` rev.2 §2.13 — 승인

선택: **승인. 요청서에 적힌 식대로 구현되어 있다.**

별도 승인서: `docs/C_TO_A_APPROVAL_D3_A002_rev2.md`

핵심 구현 위치:

```text
rtl/control/laser_head_controller.v
  error_x/y                 = target_x/y - 32
  pan/tilt_target_raw       = camera_pan/tilt_pos + residual + offset
  laser_pan/tilt_target     = 위 절대 목표를 target_update 시 등록
```

`theta_pan1/theta_tilt1`은 Tracking Controller의 현재 PT#1 출력 명령이다.
오차만으로 PT#2를 계산하지 않는다.

## 3. 실제 Event Source 규격

### 3.1 통합 대상 입력원

선택: **PS — 640×480 YUYV Webcam Frame Difference 경로.**

```text
APKO APC850 USB Webcam
  -> PS/소프트웨어 Frame Difference 및 polarity 생성
  -> A 소유 PS→PL Event Stream bridge
  -> C src_valid/src_x/src_y/src_pol/src_window_end
```

현재 C 저장소에는 USB/UVC PS 소프트웨어와 PS→PL bridge가 없으므로, 위 선택은
통합 인터페이스 확정이며 실물 입력 경로 완료를 뜻하지 않는다. 실시간 PS 경로가
준비되지 않으면 같은 5신호 계약으로 저장 Event Trace를 먼저 재생한다.

### 3.2 `src_*` 신호 계약

| 신호 | 계약 |
|---|---|
| `src_valid` | 100 MHz `clk` 기준, 이벤트 하나당 1 cycle HIGH. Backpressure 없음 |
| `src_x` | 원본 X 좌표 `0..639`, `SRC_COORD_W=11` |
| `src_y` | 원본 Y 좌표 `0..479`, `SRC_COORD_W=11` |
| `src_pol` | `0=Positive`, `1=Negative`; `EVENT_CFG[1]`로 선택적 반전 |
| `src_window_end` | 한 Frame Difference 묶음의 마지막 경계. pulse 또는 Level 입력 가능하며 C가 상승엣지 검출 |

PS→PL bridge는 `src_valid`가 1일 때 좌표와 polarity를 같은 cycle 동안 안정적으로
제공해야 한다. C 입력에는 `ready`가 없으므로 bridge 쪽 FIFO에서 유실을 막아야 한다.

### 3.3 Window 경계

선택: **외부 프레임 경계 (`WINDOW_SRC=1`)**.

`src_window_end`는 PS/입력원 쪽에서 30 FPS Frame Difference 한 묶음이 끝날 때
발생시킨다. 내부 자유 진행 타이머는 카메라 프레임과 위상이 어긋나므로 사용하지 않는다.

### 3.4 센서 해상도

**`SENSOR_W=640`, `SENSOR_H=480`을 승인한다.** 입력 모드는 YUYV 30 FPS이며,
C Adapter가 이를 64×64 좌표로 Binning한다.

## 4. `CHANGE_REQUEST_A_003` — 세 항목 승인

| 변경 | C 회신 | 조건 |
|---|---|---|
| `0x58 SERVO_POS_STAT`, `0x5C CONTROL_STAT` RO | **승인** | 현재 C wrapper의 32-bit 포트/bit 배치를 그대로 AXI RO에 연결 |
| Direct START | **승인** | `npu_start = INPUT_SRC ? tensor_start : axi_start_pulse`; 두 START 동시 활성화 금지 |
| Event Window 33.333 ms | **승인** | `WINDOW_US=33333`, `WINDOW_SRC=1`, 640×480 YUYV 30 FPS |

PS-managed START 우회는 Direct START가 반영되면 기본 경로에서 제거한다.
`TENSOR_READY` sticky status는 진단/PS 관찰용으로 유지한다.

## 5. 핀·전원·안전 회신

### 5.1 통합 XDC 핀

| 신호 | 승인 핀 | 상태 |
|---|---|---|
| PAN1 | JD1 / T14 | 승인 |
| TILT1 | JD2 / T15 | 승인 |
| PAN2 | JD3 / P14 | 승인 |
| TILT2 | JD4 / R14 | 승인 |
| Laser Gate | JD7 / U14, DRIVE 4, SLEW SLOW | 승인 — 수령품 S에 외부 1 kΩ 직렬 보호 필수 |
| `laser_arm_hw` | SW1 / P15 | active-HIGH 논리 입력으로 승인 |
| `emergency_stop_hw` | SW3 / T16 | active-HIGH 논리 입력으로 승인 |

SW3는 개발용 논리 E-stop이다. 최종 물리 E-stop은 **NC** 방식으로 KY-008 5 V
전원 경로를 직접 차단해야 한다. NC 접점을 `emergency_stop_hw` 포트에도 감시용으로
연결하려면 정상 폐회로를 LOW, 단선/누름을 HIGH로 바꾸는 외부 감시 회로가 필요하다.

### 5.2 전원과 기구 값

| 항목 | 회신 |
|---|---|
| Servo 외부전원 | 별도 5~6 V, 최소 6 A 여유/4축 동시 Hold는 8 A급 권장. **실제 확보·정격 증빙 대기** |
| RTL 중심/범위 | `POS_NEUTRAL=128`, 정적 `32..224` 유지 |
| 실물 안전 중심/범위 | 축별 기구 간섭·전류 확인 전 **미확정**. 수동 점검은 보수적으로 `112..144` 사용 |
| Servo 축 방향 | 실물 축별 확인 대기 |
| Camera/Laser FOV, baseline | 2 m 중앙+네 모서리 실측 대기 |
| KY-008 | 650 nm 판매 표기, 소비전류 실측 및 mW/IEC Class **미확인** |

미확정 항목은 수치가 없는 것이 아니라 아직 측정 근거가 없다는 뜻이다. 이 값들이
확정되기 전에는 실제 자동 광원 경로를 승인하지 않고 LED/dummy-load까지만 사용한다.

## 6. `target_valid` 관련 안전 통지 — 유지

다음 기본값을 변경하지 않는다.

```text
LOCK_CONFIRM_UPDATES  = 3
TARGET_TIMEOUT_FRAMES = 3
MAX_ON_FRAMES         = 25
Target Safe Zone      = 4..60
Lock Zone             = center 32 기준 ±4
PT#1/PT#2 Safe Limit  = 모두 필수
```

특히 `LOCK_CONFIRM_UPDATES`를 1로 낮추지 않는다. `target_valid` 하나만으로 Laser
Gate를 열지 않으며 시간축 확인, 공간축 Lock/Safe Zone, freshness watchdog,
두 헤드 Safe Limit, Aim Ready, Arm/E-stop을 모두 통과해야 한다.

## 7. 검증 및 전달 상태

| 항목 | 결과 |
|---|---|
| `tb_dual_head_control` | **43/43 PASS** — 원자 적용/invalid 전이 10개 판정 포함 |
| C 전체 회귀 | 자동판정 13 TB **341 PASS, errors=0** + `tb_servo_pwm_sweep` 완료 |
| C 래퍼 OOC | xc7z020, 100 MHz: LUT 902 / Register 650 / BRAM 4 / DSP 6, DRC Error 0 |
| C 래퍼 OOC timing | WNS **+1.394 ns** / WHS **+0.061 ns**, failing endpoint 0 |
| 등록된 Limit 이후 최악 경로 | Slack **+2.011 ns**, 7 logic levels; 전체 최악은 Servo PWM 경로 |
| A `top_system_c` 100 MHz timing | C 커밋 반영 후 A 통합 저장소에서 재측정 필요 |
| 전달 커밋 | 작업 트리 검토 및 커밋 후 해시 기입 |

100 MHz 완료 판정은 C 단독 TB가 아니라 A가 수정본을 가져가 `top_system_c` 전체
implementation에서 기본 전략으로 재측정한 결과를 기준으로 한다.

C OOC 재현 명령:

```bash
vivado -mode batch -source sim/run_c_event_control_ooc.tcl
```
