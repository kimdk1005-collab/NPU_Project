# A → C 요청서 #001 — C 실물 통합 완료 보고 및 잔여 요청

| 항목 | 내용 |
|---|---|
| 문서 ID | `A_TO_C_V01_REQUEST_001` |
| 발신 | A (NPU RTL / SoC 통합 / PS 소프트웨어 / 최종 통합) |
| 수신 | C (Event Camera / Tracking / Servo / Laser) |
| 작성일 | 2026-08-27 |
| 대상 C 커밋 | `fa85a259eaa6bc64e1fcda23f2ae348d1dd38c08` (`kimdk1005-collab/NPU_Project`) |
| C 버전 | `C_EVENT=c_event_v04` / `C_CONTROL=c_control_v08` / `INTERFACE=ifc_v0.5` |
| Base Spec | `TEAM_COMMON_AI_INTEGRATION_SPEC` v1.5 |

---

## 0. 세 줄 요약

1. **C RTL 을 A 저장소에 통합했다. 한 줄도 안 고쳤다.** RTL 회귀 48/48 PASS.
   C Event Stream → A NPU → golden 좌표 재현을 end-to-end TB 로 확인했다.
2. **딱 하나 막힌 게 있다.** `dual_head_control.v` 의 runtime SAFE_LIMIT 검사
   조합 경로가 100 MHz 를 깬다 (실측 WNS **-0.248 ns**). C 만 고칠 수 있다. → **요청 1**
3. 나머지는 전부 **승인·확정 회신**이다. 코드 작업이 아니다. → 요청 2~5

---

## 1. C 가 다시 안 해도 되는 것 (A 가 끝냄)

중복 작업 막으려고 먼저 적는다.

| 항목 | 상태 | 파일 |
|---|---|---|
| C RTL 을 A 저장소로 이식 | **완료** | `rtl/event/` `rtl/control/` (무수정) |
| 통합 top 작성 | **완료** | `rtl/integration/top_system_c.v` (A 소유) |
| A/C end-to-end TB | **완료** | `tb/integration/tb_top_system_c.v` (A 소유) |
| C TB 13종 A PC 재현 | **완료** | **287 check PASS / errors=0** (C 저장소 clone 기준) |
| 그중 A 저장소 이식분 | **완료** | 9 TB / **213 check** — `./sim/run_sim.sh` 로 매번 돈다 |
| 통합 XDC (JD 핀) | **완료** | `constraints/zybo_z7_20_cfull.xdc` |
| 통합 빌드 스크립트 | **완료** | `sim/run_bd.tcl -tclargs -cfull` |
| C 실물 포함 OOC 실측 | **완료** | `results/top_system_c_*.rpt` |
| `sim/run_xsim.sh` 절대경로 | **해당 없음** | 이식 안 했다. A 는 `sim/run_sim.sh` 를 쓴다 |

C 저장소의 `board_io.v` / `dual_head_board_io.v` / `ky008_laser_board_io.v` /
`laser_board_io.v` / `clock_125_to_100.v` 는 **가져오지 않았다.**
단독 브링업용 top 이라 A 통합 top 과 핀이 충돌한다. C 저장소에 그대로 두면 된다.

---

## 2. 요청 1 [필수·최우선] — `dual_head_control.v` runtime SAFE_LIMIT 경로 파이프라인

### 2.1 무엇이 문제인가

`rtl/control/dual_head_control.v:116-124` 의 `runtime_limit_values_ok` 가
**16 항 비교를 한 cycle 안에서 전부 돌린 뒤**, 그 결과가

```text
runtime_limit_values_ok  (8쌍 x 2 = 16 항 비교)
  -> runtime_limits_active
  -> pan1_min_eff .. tilt2_max_eff   (8개 mux)
  -> clamp_u8
  -> laser_interlock.qualification_inputs_ok
  -> confirm_count / on_count
```

로 이어진다. 논리 14 단짜리 조합 cone 하나가 통째로 critical path 다.

### 2.2 실측 (근거 파일 있음)

`top_system_c` OOC 배치배선. 근거: `results/top_system_c_*_util.rpt` / `*_timing.rpt`

| 조건 | LUT | FF | WNS | 판정 |
|---|---:|---:|---:|:---:|
| 기본 전략, runtime limit 켬 | 1871 | 1620 | **-0.248 ns** | **VIOLATED** |
| place/route `Explore`, 켬 | 1871 | 1620 | +0.035 ns | MET (여유 0.35% 뿐) |
| 기본 전략, **runtime limit 끔** | 1790 | 1553 | **+0.306 ns** | **MET** |

즉 이 조합 cone 하나가 **WNS 0.554 ns / LUT 81 개** 를 먹는다.
critical path 의 63% 는 논리가 아니라 배선이다 (data path 10.195 ns 중 6.545 ns).

`results/top_system_c_impl_critpath.rpt` 의 worst path:

```text
Source      : q_safe_limit2_reg[19]/C
Destination : u_c/u_dual_head_control/u_laser_interlock/confirm_count_reg[0]/D
Logic Levels: 14  (CARRY4=3 LUT3=1 LUT4=1 LUT5=3 LUT6=5 MUXF7=1)
Data Path   : 10.195 ns  (logic 3.650 / route 6.545)
Slack       : -0.248 ns  VIOLATED
```

### 2.3 A 가 왜 직접 안 고치는가

공통 지침 **§5.4** — `rtl/control/` 은 C 소유다. A 가 손대면 다음 C 배포본과 충돌한다.
그래서 A 는 **파일을 한 글자도 안 고쳤고**, 대신 wrapper 에 우회 스위치만 뒀다
(`top_system_c.v` parameter `RUNTIME_LIMIT_SUPPORT`, 기본값 1 = 기능 유지).

### 2.4 제안하는 수정 (C 판단으로 바꿔도 된다)

`runtime_limit_values_ok` 는 **PS 가 사람 시간 단위로 쓰는 설정값의 함수**다.
1 cycle 늦게 반영돼도 의미가 안 변한다. 등록만 하면 cone 이 반으로 잘린다.

```verilog
// dual_head_control.v — 제안
wire runtime_limit_values_ok_c =    // (기존 조합식 그대로)
    (runtime_pan1_min  <= runtime_pan1_max)  && ... ;

reg runtime_limit_values_ok_q;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) runtime_limit_values_ok_q <= 1'b0;   // fail-closed
    else        runtime_limit_values_ok_q <= runtime_limit_values_ok_c;
end
wire runtime_limit_values_ok = runtime_limit_values_ok_q;
```

reset 값 0 = "runtime limit 못 믿음" 이므로 정적 한계가 적용된다. Fail-closed 유지.
`*_eff` mux 출력도 같이 등록하면 더 확실하다.

### 2.5 회신 선택지

```text
□ (A) 위 방식으로 C 가 파이프라인 추가한다.  예상 회신일 : ______
□ (B) 지금은 못 고친다. A 가 RUNTIME_LIMIT_SUPPORT=0 으로 빌드해도 좋다.
       -> SAFE_LIMIT / SAFE_LIMIT2 런타임 덮어쓰기 기능이 꺼진다.
          정적 parameter 한계(PAN/TILT 32~224)는 그대로 강제된다.
□ (C) 다른 방법 : ______
```

**(B) 를 고르면 그 사실을 발표 자료에도 적어야 한다.** 기능이 하나 빠지는 것이다.

---

## 3. 요청 2 [필수] — `D3_FREEZE_REQUEST_A_002` rev.2 §2.13 좌표변환식 승인

`C_TO_A_REPLY_004.md` §4 표에 "PT#2 좌표 변환 — 수용·구현 완료" 로 적혀 있다.
하지만 **rev.2 문서 자체에 대한 승인 서명은 A 가 아직 못 받았다.**

확인해 줄 것 하나:

```text
theta_pan_target  = theta_pan1  + k_x * (target_x - 32)
theta_tilt_target = theta_tilt1 + k_y * (target_y - 32)
PAN2_CMD  = theta_pan_target  + LASER_OFFSET_PAN
TILT2_CMD = theta_tilt_target + LASER_OFFSET_TILT
```

`theta_pan1` = **Tracking Controller 가 방금 자기가 낸 PAN_CMD 값**.
`error_x` 만 쓰면 안 된다. 표적이 화면 중앙에 오면 레이저가 0도를 가리키게 된다.

```text
□ 승인. 위 식대로 구현돼 있다.  구현 위치 : ______________
□ 다르게 구현했다. 실제 식 : ______________
```

---

## 4. 요청 3 [필수] — 실제 Event Source 인터페이스 규격

지금 `top_system_c` 의 `src_*` 입력은 **BD 에서 0 으로 묶여 있다.**
실물이 없어서다. 그래서 현재 비트스트림에는 event_adapter 의 Binning 곱셈기가
최적화로 사라져 있다 (`results/bd_util_cfull.rpt` 가 OOC 수치보다 작은 이유).

| # | 물어보는 것 | A 가 필요한 답 |
|---|---|---|
| 3-1 | 이벤트가 **어디서** 들어오나 | PS(웹캠→DDR→AXI) / PL 카메라 IP / Pmod 직결 중 무엇인가 |
| 3-2 | `src_valid/src_x/src_y/src_pol` 의 물리적 출처 | 위 답에 따라 A 가 BD 배선을 만든다 |
| 3-3 | `src_window_end` 를 누가 만드나 | C 내부 타이머(WINDOW_SRC=0) / 외부 프레임 경계(WINDOW_SRC=1) |
| 3-4 | 센서 해상도 | 현재 A 기본값 `SENSOR_W=640 / SENSOR_H=480` 로 뒀다. 맞나 |

**3-3 이 특히 중요하다.** §5 요청 4 의 Event Window 결정과 물려 있다.

---

## 5. 요청 4 [필수] — `CHANGE_REQUEST_A_003` 승인

별도 문서: `docs/CHANGE_REQUEST_A_003_c_integration.md`

세 항목 전부 **C 가 요청한 것** 이고, A 는 §22 때문에 승인 전에 구현하지 않았다.

| # | 항목 | 근거 | 현재 우회 |
|---|---|---|---|
| 1 | `0x58 SERVO_POS_STAT` / `0x5C CONTROL_STAT` RO 신설 | `C_TO_A_REPLY_004.md` §5 | wrapper 포트로만 노출. BD 에서는 최적화로 사라짐 |
| 2 | Direct START (`CTRL.HW_START_EN` + `top_system.hw_start`) | `C_TO_A_REPLY_004.md` §3 | **PS-managed 로 동작 중.** TB 통과 확인 |
| 3 | Event Window 기본값 10 ms → **33.333 ms** | B 학습조건 30 FPS | `top_system_c.v` 기본값을 33_333 으로 뒀다 |

3 번 근거는 측정된 것이다.

```text
b_to_a_no_target_v03_001/B_TO_A_V03_RESPONSE_001.md §1.2
  Frame = 640x480, 30 FPS,  Event noise threshold = 8
b_to_a_no_target_v03_001/results/no_target_v03_manifest.json
  tensor_contract.frame_size_wh = [640, 480]
```

B 모델이 본 Tensor 한 장 = 1/30 초 = **33.333 ms** 분량이다.
C 기본값 10 ms 로 돌리면 학습 때보다 이벤트가 1/3 인 Tensor 가 들어간다.
CR C-002 에서 C 가 제안한 33.3 ms 와 같은 값이다. 이제 근거가 생겼다.

---

## 6. 요청 5 [필수] — 핀 / 전원 / 안전 최종 확정

A 가 `C_TO_A_REPLY_004.md` §6 대로 XDC 를 만들었다.
**틀린 게 있으면 지금 말해라.** 보드에 서보를 물리기 전에 고쳐야 한다.

| 신호 | A 가 배치한 핀 | 출처 |
|---|---|---|
| `servo_pwm[0]` PAN1 (카메라) | JD1 / **T14** | C `c_dual_head_drive_test.xdc` |
| `servo_pwm[1]` TILT1 (카메라) | JD2 / **T15** | 〃 |
| `servo_pwm[2]` PAN2 (레이저) | JD3 / **P14** | 〃 |
| `servo_pwm[3]` TILT2 (레이저) | JD4 / **R14** | 〃 |
| `laser_en` | JD7 / **U14** (DRIVE 4, SLEW SLOW) | C `c_ky008_laser_gate_test.xdc` |
| `laser_arm_hw` | **SW1 / P15** | A 가 정함. §6.1 참고 |
| `emergency_stop_hw` | **SW3 / T16** | A 가 정함 |

### 6.1 `laser_arm_hw` 를 상수 0 이 아니라 스위치에 연결한 이유

`C_TO_A_REPLY_004.md` §2.2 는 "광원 미장착 통합 시험에서는 `laser_arm_hw=0` 으로 묶어라"
고 했다. 그런데 상수 0 으로 묶으면 **Vivado 가 laser_interlock 자격 판정 논리를
통째로 지운다.** 그러면 통합 리소스/타이밍 수치가 실제보다 낮게 나와 §35 위반이다.

그래서 스위치에 연결하고, **보드 시험 절차에서 SW1 을 DOWN(0) 으로 유지** 하기로 했다.
이중 안전장치는 그대로 있다.

```text
1. LASER_CTRL[1] (SW_LASER_ARM) reset 값 = 0
2. laser_interlock 은 전원 인가 후 Arm LOW 를 한 번 봐야 무장 (arm_seen_low)
3. 물리 광원 미장착
```

### 6.2 아직 답이 없는 것

| # | 항목 |
|---|---|
| 6-2-1 | `laser_arm_hw` / `emergency_stop_hw` 의 **active level**. 지금 A 는 active-HIGH 로 배선했다 |
| 6-2-2 | E-stop 을 **NC(Normally Closed)** 로 갈 건가. 그러면 배선이 반대가 된다 |
| 6-2-3 | 서보 4개 외부 5~6 V 전원 실물 확보됐나. 용량 몇 A 인가 |
| 6-2-4 | Servo 중심값 / 가동범위 / 축 방향 (`POS_NEUTRAL=128`, `32~224` 로 두고 있다) |
| 6-2-5 | 카메라·레이저 FOV 와 baseline 실측값. `k_x = FOV_X/64` 계산에 필요 |
| 6-2-6 | KY-008 최종 광출력 등급과 안전 조건 |

---

## 7. [중요 통지] `target_valid` 를 레이저 조건에 그대로 쓰지 마라

이건 요청이 아니라 **A 가 반드시 알려야 하는 사실**이다.

B 의 `model_v03` 은 무표적 분리가 안 된다. B 실측:

```text
AUC = 0.2972   (0.5 미만 = 판별 방향이 뒤집혀 있다는 뜻)
표적 있음  Event Count 중앙값   938 ~ 1,463
표적 없음  Event Count 중앙값 7,468 ~ 13,776
-> score 가 "표적스러움"이 아니라 "이벤트 밀도"를 따라간다
근거: b_to_a_no_target_v03_001/B_TO_A_V03_RESPONSE_001.md §3.1 / §3.4
```

**어떤 SCORE_TH 값을 넣어도 안 걸러진다.** B 도 인정했고, 지금은 재학습하지 않는다.

다행히 C 의 `laser_interlock` 은 이미 필요한 시간축·공간축 게이트를 갖고 있다.

```text
LOCK_CONFIRM_UPDATES = 3   연속 3 회 유효 update 필요   <- 시간축 게이트
target_locked              |target-32| <= LOCK_ZONE(4)  <- 공간축 게이트
target_safe                4 <= target <= 60
TARGET_TIMEOUT_FRAMES = 3  watchdog
MAX_ON_FRAMES = 25         연속 출력 500 ms 제한
```

**요청**: 이 값들을 그대로 유지해라. 특히 `LOCK_CONFIRM_UPDATES` 를 1 로 낮추지 마라.
A 가 무표적 450 샘플로 N/R 후보값을 실측하면 그 결과를 회신하겠다.

---

## 8. A 가 검증한 것 (근거 파일 경로 포함)

### 8.1 C RTL 무수정 이식 확인

```text
C 커밋 fa85a259eaa6bc64e1fcda23f2ae348d1dd38c08 에서 그대로 복사. md5 대조 가능.
```

| 파일 | md5 |
|---|---|
| `rtl/event/event_adapter.v` | `38c263266df76b61b7f3ccbb102d59a6` |
| `rtl/event/event_accumulator.v` | `6a3488b09b35d77e9acc4dfd037a5219` |
| `rtl/control/c_event_control_top.v` | `3553d07003ea44c711128e3302b7c14e` |
| `rtl/control/dual_head_control.v` | `2d9ecdff7c5ca59e9b298f1cfc99e6d5` |
| `rtl/control/laser_head_controller.v` | `ec5fcf5e5dd8c241a6c4c3a9353e9295` |
| `rtl/control/laser_interlock.v` | `2b532426c6a17a30e740e8597c71c44a` |
| `rtl/control/servo_pwm.v` | `66849483d578ce9fa583a00566570eee` |
| `rtl/control/tracking_controller.v` | `1274f1f728079867b864701de91377d3` |

### 8.2 C TB 12종 A PC 재현

```bash
./sim/run_sim.sh          # A 6종 + C 9종 + A/C 통합 1종 = 16종
```

| 어디서 | TB | `[PASS]` check |
|---|---:|---:|
| C 저장소 clone (A PC 에서 재현) | 13 | **287** — C 보고와 일치 |
| A 저장소 이식본 (`./sim/run_sim.sh`) | 9 | **213** |

차이 74 check 는 이식 안 한 3 종이다 (`tb_board_io` 19 / `tb_dual_head_board_io` 36 /
`tb_ky008_laser_board_io` 19). DUT 가 C 단독 브링업 top 이라 A 통합 top 과 핀이 충돌한다.
`tb_servo_pwm_sweep` 은 self-check 가 없어 0 check 다.

**두 경우 모두 `[FAIL]` 0 건.**

### 8.3 A/C end-to-end — 이게 제일 중요하다

`tb/integration/tb_top_system_c.v` (A 신규 작성).
기존 `tb_top_system` 은 A 가 `evt_*` 를 직접 흔들었다. 이번엔 **C 모듈이 만든다.**

```text
src_* -> event_adapter -> event_accumulator -> evt_*
      -> top_system Input Mux(INPUT_SRC=1) -> npu_core -> RESULT_*
```

3 케이스 전부 golden 재현. NPU 입력버퍼 8192 byte 를 golden 과 전수 비교한다.

| case | 주입 이벤트 | 결과 | golden |
|---|---:|---|---|
| case00 | 281 | `X=36 Y=28 score=8 cycle=125845` | 일치 |
| case01 | 16,029 | `X=4 Y=4 score=126 cycle=125845` | 일치 |
| case02 | 0 | `X=4 Y=4 score=0 valid=0 cycle=125845` | 일치 |

각 case 에서 프레임 2 회 반복해도 동일 (ping-pong 버퍼 0 초기화 확인).
`OVERRUN=0`, `laser_en` 은 전 구간 0 (fail-closed).
**25 check × 3 case 전부 PASS.**

### 8.4 전체 회귀

```text
16 TB × 3 test vector case = 48 / 48 PASS,  [FAIL] 0 건
```

---

## 9. C 가 A 에게 줘야 하는 것 — 파일 표

**코드 파일은 요청 1 하나뿐이다. 나머지는 전부 문서 회신이다.**

| # | 무엇을 | 어떤 파일로 | 어디에 두면 되나 | 우선순위 |
|---|---|---|---|:---:|
| 1 | runtime SAFE_LIMIT 파이프라인 수정 | `rtl/control/dual_head_control.v` | C 저장소 커밋 + 커밋 해시 알려주기 | **최우선** |
| 2 | 위 수정 후 재검증 로그 | `tb/control/tb_dual_head_control.v` 결과 (텍스트면 됨) | 회신서 본문 | **최우선** |
| 3 | §2.13 좌표변환 승인 | `C_TO_A_APPROVAL_D3_A002_rev2.md` (새 파일) | C 저장소 `docs/` | 필수 |
| 4 | `CHANGE_REQUEST_A_003` 승인 | `C_TO_A_REPLY_005.md` (새 파일) | C 저장소 `docs/` | 필수 |
| 5 | 실제 Event Source 규격 (§4) | 위 회신서 안에 표로 | 〃 | 필수 |
| 6 | 핀 / 전원 / 안전 확정 (§6.2) | 위 회신서 안에 표로 | 〃 | 필수 |
| 7 | Servo 실측 중심값·가동범위·축 방향 | 위 회신서 안에 표로 | 〃 | 필수 |
| 8 | 카메라/레이저 FOV·baseline 실측 | 위 회신서 안에 숫자로 | 〃 | 보드 조준 시험 전 |
| 9 | (선택) 단독 브링업 top 4 종 | `board_io.v` 등 | **보낼 필요 없다.** A 가 안 쓴다 | — |

**전달 방법**: C 저장소에 커밋하고 커밋 해시만 알려주면 A 가 받아 간다.
지금까지 그렇게 했다 (`fa85a259` 확인 완료).

---

## 10. 회신 양식 (복사해서 채워라)

```text
[요청 1] dual_head_control runtime SAFE_LIMIT 파이프라인
   □ (A) 고친다.  커밋 : __________  예상일 : __________
   □ (B) 못 고친다. RUNTIME_LIMIT_SUPPORT=0 빌드 동의
   □ (C) 다른 방법 : __________

[요청 2] §2.13 좌표변환식
   □ 승인   □ 실제 구현이 다름 : __________

[요청 3] Event Source
   3-1 이벤트 출처      : □ PS  □ PL 카메라 IP  □ Pmod 직결  □ 기타 ______
   3-2 신호 규격        : __________
   3-3 window_end 생성  : □ C 내부 타이머  □ 외부 프레임 경계
   3-4 센서 해상도      : ______ x ______

[요청 4] CHANGE_REQUEST_A_003
   변경1 0x58/0x5C RO   : □ 승인  □ 수정요청 ______  □ 불필요
   변경2 Direct START   : □ 승인  □ PS-managed 유지
   변경3 Window 33.3ms  : □ 승인  □ 외부경계  □ 다른값 ______

[요청 5] 핀 / 전원 / 안전
   JD 핀 배치 (T14/T15/P14/R14/U14) : □ 맞음  □ 틀림 ______
   laser_arm_hw  active level : □ HIGH  □ LOW
   emergency_stop_hw          : □ NO  □ NC   active : □ HIGH  □ LOW
   서보 외부전원 확보         : □ 예 ____ V ____ A   □ 아직
   POS_NEUTRAL / 가동범위     : ______ / ______ ~ ______
   FOV_X / FOV_Y / baseline   : ______ / ______ / ______

[통지 §7] laser_interlock 게이트 값 유지
   □ 유지한다   □ 바꿔야 한다 : __________
```

---

## 11. 상태 표기 (§23)

이 문서에서 "완료" 로 적은 것은 **A 저장소 안에서 A 가 실행하고 로그가 남은 것**뿐이다.
아래는 전부 **[대기]** 다.

```text
[대기] C 실물 보드 동작 (서보 4채널 + 레이저 게이트)
[대기] §2.13 좌표변환 승인
[대기] CHANGE_REQUEST_A_003 승인
[대기] Event Source 규격
[대기] 핀 / 전원 / 안전 최종 확정
[대기] 100 MHz 타이밍 — 요청 1 이 끝나야 MET 로 적을 수 있다
```

C 승인 전까지 A 문서 어디에도 이 항목들을 "확정" 또는 "동결" 로 적지 않는다.
