# D1 체크리스트 — 담당 C  (개인 작업 메모)

> **문서 등급** — SPEC §1 기준 **4순위 (개인별 메모)**.
> 공유 규격의 근거로 쓰지 않는다. 상위 권한은
> `docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md` (이하 SPEC).
>
> **D1 목표** — Event Camera / Trace 형식 확인 + Servo 확인
> **날짜** 2026-08-20

---

## A. 완료 (저장소 반영)

- [x] SPEC §5 파일 소유권에 맞춘 디렉토리 구조 정리
- [x] `handoff/C_EVENT_CONTROL_HANDOFF.md` 작성 (SPEC §26 요구 문서)
- [x] `rtl/control/servo_pwm.v` 구현 — Safe Angle Limit Clamp 포함
- [x] `tb/control/tb_servo_pwm.v` — xsim 6/6 PASS, errors 0
- [x] `tb/control/tb_servo_pwm_sweep.v` — pos 0→255 스윕 파형 관찰용 (판정 아님)
- [x] `sim/create_vivado_project.tcl` — Vivado 프로젝트 재생성 스크립트
- [x] `sim/wave_servo_pwm.tcl` — 스윕 TB 파형 창 구성
- [x] `tools/gen_event_vector.py` — 카메라 없이 Event 자극 생성
- [x] `docs/CHANGE_REQUEST_C_001_servo_command_format.md` 작성 (SPEC §22 형식)
- [x] 개발 환경 확인 — Vivado 2024.2 / Vitis / xsim 있음. iverilog·verilator 없음, numpy 없음
- [x] Git branch `feature/c-event-control` 생성 (SPEC §24)

---

## B. 오늘 직접 해야 할 것 (물리 작업)

### B-1. 이벤트 입력 소스 확정 ★최우선

SPEC §34: Event Camera가 **D2까지** 해결되지 않으면
`1순위 저장된 Event Trace → 2순위 Webcam Frame Difference`로 전환한다.

- [ ] 이벤트 카메라 실물이 지금 있는가?
  - [ ] 있다 → 모델명 `________` / 원본 해상도 `____ x ____` / 출력 포맷
  - [ ] 없다 → 도착 예정일 `________`
- [ ] 없다면 오늘 Fallback 전환 여부를 팀에 올릴 것
- [ ] 입력 소스 최소 1개 확보
  - [ ] 공개 Event Trace 데이터셋
  - [x] PC 생성 자극 — `tools/gen_event_vector.py` **확보됨**
  - [ ] Webcam Frame Difference

> 자극 생성기가 있으므로 **카메라 없이도 D2 `event_adapter.v` 개발은 막히지 않는다.**
> 다만 B의 학습 데이터셋은 실제 데이터가 필요하므로 카메라 결정은 오늘 해야 한다.

### B-2. 서보 2축 단독 동작

- [x] 서보 모델 **MG996R** / 토크 **11 kg·cm @ 6V** (9.4 @ 4.8V) — 실물 확보됨
- [x] 틸트축이 카메라 + 레이저 무게를 버티는가 → **토크는 문제 없음** (계산 근거 아래)
- [ ] 서보 수량 확인 — 2축이면 2개 + 예비 1개 권장
- [ ] **별도 5V 전원 확보** (보드 핀에서 서보 전원 뽑으면 Zybo 리셋)
      → MG996R 스톨 2.5A/개. 1축 3A, **2축 5A** 필요
- [ ] **GND 공통 연결**
- [ ] 3.3V 신호로 서보가 도는가 → 안 되면 **74HCT125** (74HC 아님) 주문

#### MG996R 데이터시트 기준값 (실측 아님)

| 항목 | 값 |
|---|---|
| 스톨 토크 | 9.4 kg·cm @ 4.8V / **11 kg·cm @ 6V** |
| 동작 속도 | 0.17 s/60° @ 4.8V / **0.14 s/60° @ 6V** |
| 스톨 전류 | **약 2.5 A @ 6V** |
| 동작 전압 | 4.8 ~ 7.2 V |
| Dead band | 약 5 us |
| 기어 | 메탈 |

> MG996R은 클론이 많아 개체차가 크다. 위 값은 공표 사양이며 **실측이 아니다**
> (SPEC §0-12). 특히 토크는 클론에서 상당히 낮게 나온다.

#### 틸트축 토크 검토 (계산)

| 페이로드 | 축에서 거리 | 필요 토크 | 11 kg·cm 대비 |
|---|---|---|---|
| 100 g | 5 cm | 0.50 kg·cm | 22배 여유 |
| 200 g | 10 cm | 2.00 kg·cm | 6배 여유 |
| 300 g | 15 cm | 4.50 kg·cm | 2배 여유 |

**정적 토크는 병목이 아니다.** 실제 위험은 토크 부족이 아니라
(1) 하중을 계속 버티며 발생하는 헌팅·발열, (2) 브래킷 강성이다.
무게중심을 틸트축에 최대한 가깝게 두는 것이 토크 여유보다 중요하다.
- [ ] 물리 가동 범위 실측 → HANDOFF §5 `PAN/TILT_POS_MIN/MAX` 채우기
  - PAN  최소 `____` 최대 `____`
  - TILT 최소 `____` 최대 `____`

### B-3. 부품 재고 확인 → 부족분 오늘 주문

- [ ] 팬틸트 브래킷    - [ ] 서보 2개 (+예비 1개)
- [ ] 5V 어댑터 2A+    - [ ] 점퍼선 / 브레드보드
- [ ] 레이저 모듈 + LED - [ ] 카메라 마운트
- [ ] Target Board 재료 - [ ] 레벨 시프터 (필요 시)

---

## C. A에게 받아야 할 답 (SPEC이 TBD로 남긴 것)

### C-1. SPEC v1.1에서 이미 해결됨 — 다시 묻지 말 것

D1 중 SPEC이 v1.0 → v1.1로 올라가면서 아래 두 항목은 답이 나왔다.

- [x] `target_score` Data Width → **signed INT8** (SPEC §14, §21 `[x]`)
- [x] Event Count 포화 상한 127 / 255 → **127** (SPEC §9.1 `Conv1 Input Event Count = 0 ~ 127`)

`tools/gen_event_vector.py`의 `--saturate` 기본값 127은 이 규격과 일치한다.

### C-2. 여전히 답이 필요함

- [ ] **Event Tensor Physical Transfer 방식** (SPEC §7.3) ★최우선
      BRAM 공유 / Ping-Pong / AXI-Stream / Memory-Mapped / Direct Handshake
      → `event_accumulator.v` 출력단 설계가 여기서 갈린다. **D2 착수 전 필요**
      → v1.1 §21.2가 "A/C가 RTL 구조를 잡은 뒤 확정"으로 명시하여 **여전히 TBD**
- [ ] **C 모듈을 구동할 클럭** (현재 `CLK_HZ = 125 MHz` 가정 중)
      → 보드 sysclk은 **125 MHz로 확인됨**. Digilent 공식 마스터 XDC
        `constraints/digilent-xdc-master/Zybo-Z7-Master.xdc:9`가 K17 핀 sysclk을
        `-period 8.00` (= 125 MHz)로 선언한다. SPEC v1.1에는 기재가 없다.
      → **다만 C 모듈이 그 클럭으로 돈다는 뜻은 아니다.** Zynq 설계에서는
        PS의 FCLK(기본 100 MHz 등)를 PL에 공급하는 경우가 흔하다.
      → 따라서 A에게 물을 것은 "보드 sysclk이 몇이냐"가 아니라
        **"C 모듈에 어떤 클럭을 넣을 것이냐 — PL sysclk인가 PS FCLK인가"**로
        좁혀졌다. 어느 쪽이든 `servo_pwm.v`는 parameter만 바꾸면 된다.
- [ ] Tensor Memory Order (SPEC §21 `[ ]` 유지)
- [ ] PAN_CMD(0x20) / TILT_CMD(0x24) Register Bit Field — CR C-001과 정합 확인
      → SPEC §20이 Offset만 예약하고 Bit field는 D3 확정으로 미룸
- [ ] CHANGE REQUEST C-001 승인 여부 (SPEC §21 `Servo Command Format` 아직 `[ ]`)
- [ ] 8×8 Heatmap → 64×64 Coordinate Mapping (SPEC §14.1)
      → C는 변환된 좌표만 받으므로 직접 의존은 없으나, D4 `tracking_controller.v`
        검증용 자극을 만들려면 확정값이 필요하다

---

## D. 오늘 하지 말 것

- `tracking_controller.v` 본격 구현 → D4 항목
- `DEAD_ZONE` / `P_GAIN` 수치 결정 → 실제 서보 봐야 정해진다
- SPEC §7.3 물리 전달 방식을 임의 확정 → SPEC §0-10 위반

---

## E. 오늘 팀 공유 (SPEC §38 형식)

```text
[DAILY STATUS]

담당: C
날짜: 2026-08-20 (D1)

오늘 완료:
- SPEC §5 파일 소유권에 맞춰 저장소 구조 정리
- servo_pwm.v 구현 (Safe Angle Limit Clamp 포함)
- tb_servo_pwm.v 작성, xsim 검증
- Event 자극 생성기 작성 (카메라 없이 D2 개발 가능하도록)
- C Handoff 문서 초안 (SPEC §26)
- CHANGE REQUEST C-001 Servo Command Format 제안

현재 PASS Test:
- tb_servo_pwm : 6/6 PASS, errors 0 (xsim)
- tb_servo_pwm_sweep : 판정 TB 아님. pos 0~255 스윕 파형 관찰용

현재 막힌 점:
- Event Camera 실물 미확보 (해당 시 기입)
- SPEC §7.3 Event Tensor 물리 전달 방식이 TBD여서
  event_accumulator.v 출력단 설계를 시작할 수 없음

공유 Interface 변경:
있음 — CHANGE REQUEST C-001 (Servo Command Format 신규 확정 제안, 승인 대기)

SPEC v1.1 반영 확인:
- target_score = signed INT8 확인함 (§14). C 측 Handoff §7 갱신 완료
- Event Count 포화 상한 = 127 확인함 (§9.1). 자극 생성기 기본값과 일치
- 위 두 건은 더 이상 A에게 요청하지 않음

다른 팀원에게 필요한 것:
- A: Event Tensor Physical Transfer 방식 (최우선, §21.2 기준 아직 TBD)
- A: C 모듈 구동 클럭 — PL sysclk(125 MHz)인지 PS FCLK인지
     보드 sysclk이 125 MHz인 것은 Digilent 마스터 XDC로 확인함(-period 8.00).
     남은 건 Block Design 에서 C 쪽에 무엇을 물릴지다
- A: Tensor Memory Order (§21 미확정)
- A: PAN_CMD / TILT_CMD Bit Field (§20 Offset만 예약됨)
- A: CR C-001 승인
- B: numpy 미설치 환경 확인 필요

내일 목표:
- event_adapter.v 초안 (Binning + 범위 밖 폐기)
- 서보 실물 PWM 확인 및 가동 범위 실측
```
