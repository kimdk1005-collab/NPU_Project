# D2 체크리스트 — 담당 C  (개인 작업 메모)

> **문서 등급** — SPEC §1 기준 **4순위 (개인별 메모)**.
> 공유 규격의 근거로 쓰지 않는다. 상위 권한은
> `docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md` (이하 SPEC).
>
> **D2 목표** (`TEAM_ROLE_PLAN.md`의 당시 D2 계획) — **Event Adapter 초안 + Servo PWM**
> **날짜** 2026-08-21
>
> **종료 기록** — 이 문서는 D2 당시의 작업 일지라 아래 D/E 절의 대기 항목과
> 다음 날 목표를 역사 그대로 보존한다. Direct Handshake 확정, Accumulator 구현,
> 서보 실물 검증 이후의 최신 상태는 `docs/D3_CHECKLIST_C.md`와
> `docs/PROJECT_STATUS.md`를 따른다.

---

## 0. SPEC이 v1.1 → v1.2로 올라갔다 — C 영향 정리

D2 도중 A가 SPEC v1.2를 냈다. C에 직접 영향이 오는 것은 아래 네 건이다.

| v1.2 변경 | C 영향 | 처리 |
|---|---|---|
| §14.1 Mapping **Freeze 완료** `x64 = min(63, floor(x_raw*64/frame_width))` | C가 D2에 만들려던 Binning 규칙이 **팀 공통 확정 규격이 됨** | `event_adapter.v`가 이 식을 그대로 구현. TB가 전 좌표 대조 |
| §14.1이 **"현재 640×480 Webcam Fallback"** 명시 | 입력원이 사실상 웹캠으로 전제됨 → **Event Window 33.3 ms 문제 현실화** | **CR C-002** 제출 |
| §14.1 `target = heatmap*8 + 4` | C가 받는 `target_x/y`가 **8개 값만** 나옴 | HANDOFF §10 갱신 |
| §15 Center Dead Zone 최소 `abs(error) <= 4` | `DEAD_ZONE`이 더 이상 완전 TBD 아님 | HANDOFF §4 갱신 |

`docs/` 안의 v1.1 파일은 삭제하고 v1.2로 교체했다.
저장소에 SPEC이 두 개 있으면 SPEC §1 문서 우선순위가 무의미해지기 때문이다.
D1의 v1.0 → v1.1 처리와 같은 방식이다.

> **§14.1 `min(63,·)` 와 C의 "범위 밖 폐기" 정책이 형식상 다르다.**
> 정상 입력에서는 결과가 같고, 다른 것은 입력이 규격을 벗어났을 때뿐이다.
> `event_adapter.v`가 `OOR_POLICY` parameter로 둘 다 지원하며 기본값은 폐기다.
> CR C-002 부수 항목에 질의로 남겼다. 별도 CR로 올리지 않았다.

---

## A. 완료 (저장소 반영)

### A-1. `rtl/event/event_adapter.v` — D2 주 산출물

- [x] Spatial Binning — SPEC v1.2 §14.1 확정식을 **나눗셈 없이** 구현
      역수 곱셈 `bx = min(63, (x * MUL_X) >> BIN_SHIFT)`
- [x] 정확성 조건을 elaboration 시점에 `$error`로 검사
- [x] 범위 밖 이벤트 처리 — `OOR_POLICY` (0 폐기 / 1 물림), 기본 폐기
- [x] Event Window 경계 생성 — 내부 타이머(`WINDOW_SRC=0`) / 외부 pulse(`=1`) 양쪽
- [x] 파이프라인 2단. **Window 경계를 이벤트와 같은 깊이로 지연** (경계 누수 방지)
- [x] Backpressure 없이 1 event/clock 처리 (SPEC §6.1에 `ready`가 없음)
- [x] 진단 출력 `win_evt_count` / `win_drop_count` — 포화, Wrap 금지

### A-2. `tb/event/tb_event_adapter.v` — **23/23 PASS, errors 0** (xsim)

- [x] T1/T2 Binning — 64 / 346 / 640 / 1280 해상도의 **전 좌표**를 정수 나눗셈과 대조
- [x] T3 범위 밖 정책 두 가지
- [x] T4 파이프라인 지연 2 cycle
- [x] T5 Polarity 통과
- [x] T6 Window 주기
- [x] T7 Window당 계수 (연속 입력 채택 50 / 폐기 7)
- [x] T8 외부 Window — Level 입력의 상승엣지만 1회
- [x] T9 이벤트와 Window 경계 동시 → 현재 Window 포함 (HANDOFF §1)
- [x] `tb_servo_pwm` 회귀 6/6 PASS 유지

> **T1/T2를 "조건식 검사"로 하지 않은 이유** — 역수 곱셈의 정확성 조건을 모듈이
> 스스로 검사하지만, 그 **조건식 자체가 틀렸을 가능성은 조건식으로 잡을 수 없다.**
> 실제 정수 나눗셈과 대조하는 것만이 근거가 된다.
> Python으로도 12개 해상도(64~2048)를 독립 경로로 재확인했다. 불일치 0.

### A-3. `tools/probe_webcam.py` — 웹캠 능력 실측기

- [x] V4L2 ioctl 직접 호출 (표준 라이브러리만, OpenCV/v4l2-ctl 불필요)
- [x] CR C-002의 근거를 **팀이 재현할 수 있는 형태**로 저장소에 남김 (SPEC §0-12)

### A-4. 문서

- [x] `docs/CHANGE_REQUEST_C_002_event_window_and_input_source.md` 작성
- [x] `handoff/C_EVENT_CONTROL_HANDOFF.md` — SPEC v1.2 반영, §1.1 신설
- [x] SPEC v1.1 → v1.2 저장소 동기화 및 전 참조 갱신

---

## B. 오늘 직접 해야 할 것 (물리 작업) ★ D2 남은 절반

D2 목표의 "Servo PWM"은 **실물 구동**을 뜻한다. RTL과 비트스트림은 D1에 끝났다.

```text
vivado_bringup/c_servo_bringup.runs/impl_1/board_io.bit   ← 생성 완료
```

D2에 툴체인 상태를 실제로 확인했다. 별도 설치가 필요한 것은 없다.

| 항목 | 상태 |
|---|---|
| `vivado` 실행 경로 | `/opt/tools/Xilinx/Vivado/2024.2/bin/vivado` |
| JTAG 케이블 드라이버 | 설치됨 (`52-xilinx-digilent-usb.rules`) |
| JTAG 체인 검출 | `arm_dap_0` + **`xc7z020_1`** (읽기 전용 스캔으로 확인) |
| 타이밍 | WNS `+0.357 ns` / WHS `+0.047 ns`, failing 0 |
| 자원 | LUT 190 (0.36 %) / FF 145 (0.14 %) |

`vivado_bringup/`은 `.gitignore` 대상이라 이 PC에만 있다.
없어지면 `vivado -mode batch -source sim/create_bringup_project.tcl`로 재생성된다.
**단 이 스크립트는 기존 `vivado_bringup/`을 통째로 지우고 시작한다.**

- [x] 별도 5V 전원 확보
- [x] **GND 공통 연결**
- [x] `board_io.bit` 프로그래밍 → `led[0]` 1 Hz 심장박동 확인
      **통과.** K17 = 125 MHz 확인됨 (통합 시 클럭은 별개 — CR C-003)
- [x] `sw[0] = 0`(en=0)에서 전원 인가 시작
- [x] 3.3 V 신호로 서보가 도는가 → **레벨 시프터 불필요**. 3.3 V로 정상 구동
- [x] 좁은 범위 확인 → 넓은 범위 확인
- [x] **2축 동시 구현 확인** — `sw[3]`으로 축 전환. PAN/TILT 둘 다 정상
- [x] 물리 가동 범위 실측 → HANDOFF §5 기입 완료
      - PAN  최소 `32` 최대 `224`
      - TILT 최소 `32` 최대 `224`
      - 기구 간섭 없음. 서보 자체 가동 범위가 한계이며 축별 차이 없음
      - 카메라 하중이 가동 범위를 제한하지 않음 (담당 C 확인)
- [x] 각도 스케일 실측 — 좁은 범위 32 step ≈ 15° → **0.469 °/step**, 전 구간 약 120°
- [ ] 서보 수량 확인 — 2축이면 2개 + 예비 1개
- [ ] **LED** 확보 — D6 Interlock 검증에 먼저 쓴다 (SPEC §17, 계획서 §16.4)
- [ ] 레이저 포인터 + **게이팅 회로**(N-MOSFET 등) — D11
      → 포인터는 신호 입력이 없어 그대로는 `laser_enable`로 못 끈다.
        게이팅이 없으면 SPEC §17 Interlock을 연결할 방법이 없다
- [ ] Target Board 재료

> **단계별 절차 문서 2종** (개인 문서라 SPEC §1 기준 4순위다)
>
> | 문서 | 다루는 것 |
> |---|---|
> | [Vivado 브링업 순서](https://claude.ai/code/artifact/e39228b1-e454-48b3-95eb-c69fe51c12d7) | 컴퓨터 앞 — 프로젝트 열기/재생성, Hardware Manager, 클럭 통과 조건 |
> | [MG996R 브링업](https://claude.ai/code/artifact/513a36a7-db4f-43c9-8d0c-54bc4f57f609) | 벤치 — 전선 극성, Pmod JD 핀 배치, 공통 GND, 가동 범위 실측 |
>
> 순서는 Vivado → 벤치다. `led[0]` 1초 주기를 확인하기 전에는 서보를 붙이지 않는다.
>
> `board_io.v` 조작법은 파일 상단 주석에도 있다.
> 안전장치가 2단이라 `sw[2]`로 범위를 넓혀도 `servo_pwm` 출력단 clamp
> (`POS_LIMIT_LO/HI = 32/224`)를 넘지 못한다.
>
> 실측 중 확인된 것 — `board_io.v` 주석은 넓은 범위를 "약 180도"라고 적었으나
> `pos 32~224` → 펄스 `750~2250 us`이므로 `500~2500 us = 180°` 기준 환산하면
> **약 135°**다. 양 끝에 여유를 남긴 clamp이라 의도된 축소이며,
> 정확한 각도는 실측 항목이다.

---

## C. A에게 받아야 할 답

### C-1. SPEC v1.2에서 해결됨 — 다시 묻지 말 것

- [x] 8×8 Heatmap → 64×64 Coordinate Mapping (§14.1) → `target = heatmap*8 + 4`
- [x] Heatmap 인덱스 순서 → `[Y][X]`
- [x] Source → 64×64 Mapping → `min(63, floor(raw*64/frame))`
- [x] Center Dead Zone 최소값 (§15) → `abs(error) <= 4`

D1에 해결된 것 (v1.1): `target_score` = signed INT8, Event Count 포화 상한 = 127.

### C-1b. D2 오후 A의 D3 Freeze 요청으로 해결됨

`docs/D3_FREEZE_REQUEST_A_001.md` (A, 2026-08-21). C 회신은 `docs/C_TO_A_REPLY_001.md`.

- [x] **Event Tensor Physical Transfer 방식** (SPEC §7.3) → **Direct Handshake 확정**
      `ext_we` / `ext_addr[12:0]` / `ext_data` / `start` / `busy` / `done`
      **D1부터 C를 막고 있던 최우선 블로커가 해소됐다**
- [x] **Tensor Memory Order** → **CHW**, `ext_addr = (pol<<12)｜(y<<6)｜x`
- [x] **NPU Input Buffer Interface** → 위와 동일
- [x] `target_valid` 생성 조건 → `(heatmap_max_score > score_th)`, 기본 0

### C-2. 여전히 답이 필요함

**C가 할 수 있는 일은 다 했다. 전부 요청서를 올려 둔 상태이며 회신 대기다.**

- [x] **CR C-003** — C 모듈 구동 클럭 → **100 MHz 확정, 코드 반영 완료**
      → NPU와 단일 clock domain. `ext_*` 직결이라 CDC가 없어야 한다
      → 타이밍 압박은 NPU뿐이고 A가 이미 100 MHz로 닫았다. 올릴 이유가 없다
      → `board_io.v`만 125 MHz 유지 (브링업 전용, K17 직결)
      → **A 확인 필요분은 "Block Design에서 100 MHz 공급"뿐이다**
- [ ] **CR C-004** — `event_polarity` 인코딩 ★B 확인 필요
      → A는 `0 = Positive`, C는 `1 = Positive`로 서로 반대로 가정하고 있었다
      → A 안 채택하고 C 측은 반영 완료. **B의 Dataset 채널 배치 확인이 필요**
- [ ] **CR C-002** 승인 — Event Window 33.3 ms + 웹캠 Fallback ★B 영향 최대
- [ ] **CR C-001** 승인 — Servo Command Format (D2 실측으로 값 갱신함)
- [ ] PAN_CMD(0x20) / TILT_CMD(0x24) Register Bit Field
- [ ] 프레임 차분을 **어디서** 할 것인가 — PC인가 Zybo PS(PetaLinux+UVC)인가
      → CR C-002에 선택지와 위험을 정리해 뒀다. C 단독으로 정하지 않는다

---

## D. 오늘 하지 말 것

- `event_accumulator.v` 구현 → SPEC §7.3이 TBD인 채로 출력단을 만들면 재작업된다
- `tracking_controller.v` 본격 구현 → D4 항목
- `P_GAIN` / `SLEW_LIMIT` 수치 결정 → 실제 서보 봐야 정해진다
- CR C-002를 승인 전에 코드에 확정 반영 → SPEC §23-5 위반
  (`WINDOW_US` / `WINDOW_SRC`는 parameter 기본값으로만 둔다)

---

## E. 오늘 팀 공유 (SPEC §38 형식)

```text
[DAILY STATUS]

담당: C
날짜: 2026-08-21 (D2)

오늘 완료:
- event_adapter.v 구현 (SPEC §14.1 Binning + Window 경계 + 범위 밖 처리)
- tb_event_adapter.v 작성, xsim 23/23 PASS
- tools/probe_webcam.py 작성 — 웹캠 능력 실측기 (재현 가능한 근거)
- CHANGE REQUEST C-002 제출 (Event Window + 입력원 Fallback)
- SPEC v1.2 저장소 동기화 및 C 문서 전체 반영

현재 PASS Test:
- tb_event_adapter : 23/23 PASS, errors 0 (xsim)
- tb_servo_pwm     : 6/6 PASS, errors 0 (xsim, 회귀)

현재 막힌 점:
- SPEC §7.3 Event Tensor 물리 전달 방식이 v1.2 §21.2 기준 계속 TBD여서
  event_accumulator.v 출력단 설계를 시작할 수 없음 (D3 블로커)
- 서보 실물 배선 미완 (5V 전원 / 공통 GND). 비트스트림은 준비됨

공유 Interface 변경:
있음 — CHANGE REQUEST C-002 (Event Window 33,333 us + Webcam Fallback 확정 제안)
      ** B의 Dataset / Golden / Test Vector 재생성이 필요하다. B 확인 요망 **

SPEC v1.2 반영 확인:
- §14.1 Source→64×64 Mapping 확인. event_adapter.v가 이 식 그대로 구현
- §14.1 target = heatmap*8+4 확인. C는 8개 값만 받는 것으로 해석 갱신
- §15 abs(error) <= 4 확인. HANDOFF §4의 비교를 '<' 에서 '<=' 로 정정
  ('<' 로 두면 error=4 가 Hold 에 안 들어가 표적이 중앙인데도 서보가 진동한다)
- 위 항목들은 더 이상 A에게 요청하지 않음

다른 팀원에게 필요한 것:
- A: Event Tensor Physical Transfer 방식 (최우선, §21.2 계속 TBD)
- A: C 모듈 구동 클럭 — PL sysclk(125 MHz)인지 PS FCLK인지
- A: 프레임 차분 수행 위치 — PC인지 Zybo PS인지
- A: Tensor Memory Order / PAN_CMD·TILT_CMD Bit Field
- A: CR C-001, CR C-002 승인
- B: CR C-002 검토 ★ Window 10 ms -> 33.3 ms 는 Dataset 재생성이 필요하다
     재생성 시 셀당 Event Count 가 127 포화에 닿는 비율을 함께 알려주기 바람

내일 목표:
- event_accumulator.v — SPEC §7.3 답이 오면 착수, 아니면 출력단 없이 누적부만
- 서보 실물 구동 및 가동 범위 실측
```
