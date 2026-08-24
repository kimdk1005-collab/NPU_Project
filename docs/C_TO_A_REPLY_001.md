# [회신] C → A  #001

> **대상 문서**
> - `docs/D3_FREEZE_REQUEST_A_001.md` (A, 2026-08-21)
> - `docs/C_TO_A_DELIVERY_SPEC.md` (A, 2026-08-21)
>
> **회신자** C (김도근) / **날짜** 2026-08-21 (D2)
> **기준 SPEC** v1.2

---

## 0. 요약

A의 Freeze 요청 5건은 **전부 수용한다.** 특히 5번(Direct Handshake)이
D1부터 C를 막고 있던 SPEC §7.3이라 이걸로 `event_accumulator.v` 착수가 가능해졌다.

다만 **A의 문서를 그대로 구현하면 조용히 깨지는 항목 두 개**를 발견했다.
둘 다 SPEC이 값을 정하지 않은 빈칸이고, A와 C가 서로 다르게 가정하고 있었다.
아래 CR C-003 / C-004로 함께 Freeze를 요청한다.

| 항목 | C 판정 |
|---|---|
| 1. Tensor Memory Order = CHW | **수용** |
| 2. Conv Padding | C 영향 없음, 이의 없음 |
| 3. Argmax Tie-Break | C 영향 없음, 이의 없음 |
| 4. `target_valid` 생성 조건 | **수용** |
| 5. NPU Input Buffer Interface | **수용** |
| ★ CR C-003 C 모듈 구동 클럭 | **A 확정 필요 — Freeze 목록에 빠져 있음** |
| ★ CR C-004 `event_polarity` 인코딩 | **A/C 가정이 정반대 — 채널이 뒤바뀜** |

---

## 1. A의 Freeze 요청 항목별 회신

### 1번 Tensor Memory Order = CHW — 수용

`ext_addr = (polarity << 12) | (event_y << 6) | event_x`를 그대로 쓴다.

C의 참조 모델 `tools/gen_event_vector.py`의 기본 출력 순서를 이 주소식에 맞췄고,
실제 생성물 8192 byte를 주소식으로 전수 대조해 **불일치 0**을 확인했다.
`event_accumulator.v`의 write 주소도 이 식을 쓴다.

### 2번 Conv Padding — C 영향 없음

`out = floor((in + 2*pad - k)/stride) + 1`에서 §8 출력 형상을 지키려면
`pad=1` 외의 선택지가 없다는 A의 논증에 동의한다. C는 관여하지 않는다.

### 3번 Argmax Tie-Break — C 영향 없음

A가 "C 영향 없음"으로 적은 것이 맞다. C는 변환된 좌표만 받는다.

다만 C 입장에서 하나 확인해 둔다 — `FIRST_MAX` + raster 순서면 동점 시
**Y가 작은 쪽(위쪽)이 이긴다.** Tracking이 위쪽으로 치우치는 편향이 생길 수 있으나,
동점은 드물고 Dead Zone ±4 안에서 흡수되는 크기라 C는 문제 삼지 않는다.

### 4번 `target_valid` 생성 조건 — 수용

```text
target_valid = (heatmap_max_score > score_th),  score_th 기본 0, signed 비교
```

C 측 해석을 명시해 둔다 (SPEC §39 "A→C: target_valid 의미 일치" 항목).

| `target_valid` | C 동작 | 근거 |
|---|---|---|
| `1` | 정상 Tracking, 조건 만족 시 Laser ON | SPEC §16 |
| `0` | **현재 위치 Hold** (중립 복귀 안 함) + **Laser OFF** | SPEC §16, HANDOFF §6 |

`score_th`가 AXI 레지스터로 노출되면 C는 읽지 않는다. C는 `target_valid` 결과만 쓴다.
`target_score`를 Laser Interlock의 `SCORE_TH`와 비교할 때는 **signed 비교**로 한다
(Conv4는 ReLU가 없어 음수 score가 실제로 나온다 — SPEC §9.1).

### 5번 NPU Input Buffer Interface — 수용

`ext_we` / `ext_addr[12:0]` / `ext_data` / `start` / `busy` / `done` 직접 write 방식을 수용한다.
5개 후보 중 Direct Handshake가 2주 일정에서 가장 합리적이라는 판단에 동의한다.

`busy == 1`인 동안 `ext_we`를 올리지 않는다는 제약도 수용한다.
**다만 이 제약 때문에 C 쪽에 Ping-Pong 버퍼가 필요해진다** — 아래 3절 참조.
이건 C 내부 구현이라 A에게 요구하는 것은 없다.

---

## 2. C가 추가 Freeze를 요청하는 항목

### ★ CR C-003 — C 모듈 구동 클럭

```text
[CHANGE REQUEST]

요청자: C (김도근)
날짜: 2026-08-21 (D2)
변경 항목: C 모듈 구동 클럭 (SPEC §21 빈칸, 전 문서 미기재)

기존:
  어느 문서에도 값이 없다. D1부터 C가 A에게 요청해 온 항목이며
  D3_FREEZE_REQUEST_A_001 의 5개 항목에도 포함되지 않았다.

  그런데 A 문서 본문은 100 MHz 를 전제하고 있다.
      8192 cycle    = 82 us    @100MHz
      125,845 cycle = 1.258 ms @100MHz
  역산하면 정확히 100 MHz 다.

  반면 C 모듈은 전부 CLK_HZ = 125_000_000 이다.
      rtl/control/servo_pwm.v
      rtl/event/event_adapter.v
      rtl/control/board_io.v      (브링업 전용)

변경안:
  C_CLK_HZ = 100,000,000  (A 의 npu_core 와 동일 클럭, 단일 clock domain)

  ** C 의 권고는 100 MHz 다. ** 근거는 아래 "왜 100 MHz 인가" 참조.
  최종 확정 권한은 Block Design 을 가진 A 에게 있다.

변경 이유:
  1) event_accumulator 가 npu_core 의 ext_* 포트에 직접 붙으므로
     두 모듈은 반드시 같은 clock domain 이어야 한다. 다르면 CDC 가 필요하고
     2주 일정에서 불필요한 위험이다.

  2) 클럭이 틀리면 조용히 깨진다. 실제 100 MHz 인데 CLK_HZ=125 MHz 로 두면
     모든 시간이 1.25 배로 늘어난다.
         Servo Frame  20 ms  -> 25 ms
         중립 펄스   1500 us -> 1875 us
     서보가 엉뚱한 각도에 서지만 RTL 은 아무 오류도 내지 않는다.

  3) 참고 — 오늘 브링업에서 led[0] 1 초 주기를 실측 확인했다.
     board_io 는 PL sysclk K17 을 직결하므로 이것은 K17 = 125 MHz 의 확인이다.
     top_system 에서 C 모듈에 무엇을 물릴지는 별개이고, 그것이 이 CR 의 대상이다.

왜 100 MHz 인가 (C 의 권고 근거):

  1) 타이밍 압박을 받는 블록은 NPU 뿐이고, A 는 이미 100 MHz 로 닫았다.
     C 모듈은 PWM 카운터 / 이진 Binning(DSP 1~2 개) / BRAM 누적이라
     어느 쪽이든 여유롭게 닫힌다. 즉 클럭은 NPU 사정으로 정해야 한다.
     125 MHz 는 25 % 인상이라 NPU 재클로징 위험만 새로 만든다.

  2) 속도를 올릴 이유가 없다. A 계산으로 전송+추론이 1.34 ms 인데
     Event Window 는 33.3 ms 다 (CR C-002). 여유가 25 배다.
     125 MHz 로 올려도 1.07 ms 가 될 뿐 시스템에 아무 차이가 없다.

  3) 단일 clock domain 이면 CDC 가 없다. event_accumulator 가 npu_core 의
     ext_* 에 직접 붙으므로 클럭이 다르면 13 bit addr + 8 bit data + handshake
     전체에 CDC 가 필요하다. 2 주 일정에서 불필요한 위험이다.

  4) SPEC §20 이 AXI 레지스터 맵을 예약하고 있어 PS 는 어차피 인스턴스된다.
     그러면 FCLK_CLK0 = 100 MHz 가 Zynq 기본값으로 그냥 나온다.

  5) C 측 비용이 0 이다. 100 MHz 로 실제 elaborate 를 확인했다.
       servo_pwm    @100MHz : PERIOD_CYC = 2,000,000, CNT_W = 21
                              중립 pulse = 150,000 cycle = 1500 us  (정확)
       event_adapter@100MHz : WINDOW_CYC = 3,333,300 (33.333 ms), WCNT_W = 22
                              Binning 상수는 클럭과 무관하므로 불변
     $error 없음. 로직 변경 없음.

  참고 - board_io.v 는 이 결정의 영향을 받지 않는다. 브링업 전용 top 이고
  PL sysclk K17 을 직결하므로 125 MHz 를 유지한다. top_system 에 들어가지 않는다.

영향 파일:
  rtl/control/servo_pwm.v         parameter 만 교체
  rtl/event/event_adapter.v       parameter 만 교체
  rtl/control/tracking_controller.v / laser_interlock.v   (미착수, 착수 전 확정 필요)
  rtl/control/board_io.v          영향 없음 (브링업 전용, K17 직결 유지)

영향 담당:
- A: Block Design 에서 C 쪽에 공급할 클럭 확정 및 회신
- B: 영향 없음
- C: parameter 교체만. 로직 변경 없음

Golden Model 영향: 없음
RTL 영향: C 담당 parameter 만
Testbench 영향: 없음 (TB 는 CLK_HZ 를 축소값으로 덮어쓴다)
기존 Test Vector 재생성 필요 여부: 아니오
예상 Merge Conflict: 없음

팀 승인:
A: [ ]   <- Block Design 에서 100 MHz 공급 확인 필요
B: [ ]   (영향 없음, 참고만)
C: [x]   2026-08-21 100 MHz 로 확정, 코드 반영 완료
```

> **C 측 반영 완료 (2026-08-21).**
> `servo_pwm.v` / `event_adapter.v` 의 `CLK_HZ` 기본값을 `100_000_000` 으로 교체했다.
> 로직 변경 없음. `tb_servo_pwm` 6/6, `tb_event_adapter` 23/23 PASS 유지.
>
> `board_io.v` 는 **125 MHz 를 유지한다.** 브링업 전용 top 이고 PL sysclk K17 을
> 직결하며 `top_system` 에 들어가지 않는다.
>
> **A 에게 남은 것은 Block Design 에서 C 모듈에 100 MHz 를 공급하는 것뿐이다.**
> PS `FCLK_CLK0` 기본값이 100 MHz 이므로 그대로 쓰면 된다.
> 다른 값을 주려면 회신 바란다 — parameter 교체로 대응한다.

---

### ★ CR C-004 — `event_polarity` 인코딩 (**채널이 뒤바뀌는 문제**)

```text
[CHANGE REQUEST]

요청자: C (김도근)
날짜: 2026-08-21 (D2)
변경 항목: event_polarity 비트 인코딩 (SPEC §6.1 / §7.1 미기재)

기존:
  SPEC §6.1 은 event_polarity 를 "Positive / Negative Channel 선택" 이라고만
  적고 어느 값이 어느 채널인지 정하지 않았다.
  그 결과 A 와 C 가 정반대로 가정하고 있었다.

      A (C_TO_A_DELIVERY_SPEC §2-2) : polarity 0 = Positive (Channel 0)
      C (gen_event_vector.py, HANDOFF): polarity 1 = Positive (Channel 0)

변경안:
  A 안을 채택한다.

      event_polarity = 0  ->  Positive  ->  Channel 0  ->  addr 0    ~ 4095
      event_polarity = 1  ->  Negative  ->  Channel 1  ->  addr 4096 ~ 8191

  이렇게 하면 polarity 값이 곧 Channel 번호가 되어
  ext_addr = (polarity << 12) | (y << 6) | x 가 문자 그대로 성립한다.

변경 이유:
  이 항목이 어긋나면 Positive 와 Negative 채널이 통째로 뒤바뀐 Tensor 가
  NPU 에 들어간다. RTL 도 Golden 도 오류를 내지 않고, "모델 정확도가 왜 낮지"
  로만 보인다. 원인을 찾기 매우 어려운 종류의 불일치다.

  A 안을 채택하는 이유는 A 의 주소식이 자연스럽게 읽히고,
  C 측 비용이 사실상 0 이기 때문이다. event_adapter.v 는 polarity 비트를
  해석하지 않고 통과만 시키므로 주석만 바뀌었고, 실제 해석이 들어가는
  event_accumulator.v 는 아직 착수 전이다.

C 측 반영 (완료):
  tools/gen_event_vector.py   Positive=0 / Negative=1 로 교체
                              생성물 8192 byte 를 A 주소식으로 전수 대조 -> 불일치 0
  rtl/event/event_adapter.v   포트 주석 정정 (로직 변경 없음)
                              tb_event_adapter 23/23 PASS 유지

영향 파일:
  tools/gen_event_vector.py       (C, 반영 완료)
  rtl/event/event_adapter.v       (C, 주석만)
  rtl/event/event_accumulator.v   (회신 당시 미착수, 현재 구현·검증 완료)
  B 소유 dataset / integer_golden / test_vector

영향 담당:
- A: SPEC §6.1 에 인코딩을 명시해 주기 바란다. A 측 RTL 변경은 없을 것으로 본다
     (npu_core 는 Tensor 를 읽기만 하고 polarity 를 해석하지 않는다)
- B: **확인 필요.** Dataset 생성 시 Positive 이벤트가 Channel 0 에 들어가는지.
     반대로 되어 있으면 학습된 모델과 실입력의 채널이 뒤바뀐다
- C: 반영 완료

Golden Model 영향: 있음 - B 의 채널 배치 확인 필요
RTL 영향: C 주석만. A 영향 없음
Testbench 영향: 없음 (tb_event_adapter 는 통과 여부만 검사)
기존 Test Vector 재생성 필요 여부: B 가 반대로 되어 있다면 예
예상 Merge Conflict: 없음

팀 승인:
A: [ ]
B: [ ]   <- 채널 배치 확인 필요
C: [x]
```

---

## 3. C 쪽 설계 결과 — Ping-Pong 버퍼

A의 제약(`busy==1`이면 write 금지)을 지키려면 **C의 누적기에 Ping-Pong이 필요하다.**

```text
Window 종료
   -> 버퍼 A 를 8192 cycle 동안 읽어 NPU 로 전송   (82 us @100MHz)
   -> 이 82 us 동안에도 다음 Window 이벤트는 계속 들어온다
   -> 단일 버퍼면 그만큼 유실되어 Golden 과 어긋난다
```

따라서 `event_accumulator.v`는 8 KB 버퍼 2개(총 16 KB)를 번갈아 쓴다.
BRAM 4개이며 A가 밝힌 현재 사용률 5.71%를 감안하면 부담 없다.

**A에게 요구하는 것은 없다.** C 내부 구현이며 SPEC §5.3 C 소유 범위다.
`ext_*` 인터페이스는 A 규격 그대로 유지된다.

---

## 4. A의 질문 4개에 대한 답

| # | A의 질문 | C 회신 |
|---|---|---|
| 1 | `ext_we`/`ext_addr`/`ext_data` 직접 write 수용? | **수용.** 단 CR C-003 클럭 확정이 선행되어야 한다 |
| 2 | `D3_FREEZE_REQUEST_A_001` 승인? | **5건 전부 수용.** 추가로 CR C-003 / C-004 확정 요청 |
| 3 | Event Window 5 ms / 10 ms 결정됐는지? | **둘 다 불가능.** 아래 참조 |
| 4 | Servo Command Format? | **CR C-001로 이미 제출됨.** A 승인 대기 중 |

### 질문 3 상세 — Event Window

`docs/CHANGE_REQUEST_C_002_event_window_and_input_source.md`로 D2에 제출했다.

SPEC **v1.2 §14.1이 스스로 "현재 640×480 Webcam Fallback"을 명시**하는데,
그 웹캠(앱코 APC850, USB `322e:2233`)을 실측한 결과 **전 해상도 30 fps 상한**이다.
프레임 차분은 프레임 간격보다 짧은 이벤트를 만들 수 없으므로
**5 ms / 10 ms 는 둘 다 물리적으로 불가능하고 33,333 us 가 강제된다.**

재현 가능한 실측이다.

```bash
python3 tools/probe_webcam.py
```

**A 설계에는 유리한 방향이다.** 예산이 5~10 ms에서 33.3 ms로 늘어나므로
A가 계산한 `1.34 ms`의 여유가 오히려 커진다.
다만 A 문서 곳곳이 "Window 5~10 ms"를 전제로 적혀 있으니 갱신이 필요하다.

**B 영향이 가장 크다** — Window가 3.3배 길어지므로 Dataset / Golden / Test Vector
재생성이 필요하고, 셀당 Event Count가 SPEC §9.1 포화 상한 127에 닿는 비율도 올라간다.

### 질문 4 상세 — Servo Command Format

`docs/CHANGE_REQUEST_C_001_servo_command_format.md`로 D1에 제출했다.

```text
pos = 8 bit unsigned (0~255)
pulse_cycles = PULSE_MIN_CYC + ((pos * SPAN_CYC) >> 8)
PWM 50 Hz, PULSE_MIN/MAX_US 는 기구 실측으로 확정 중
```

`servo_pwm.v`는 이 규격으로 구현·검증 완료(`tb_servo_pwm` 6/6 PASS)이며
**D2에 실물 2축 구동까지 확인했다.** A 승인만 남았다.

---

## 5. C 진행 상태 (A 참고용)

| 파일 | 상태 | 검증 |
|---|---|---|
| `rtl/event/event_adapter.v` | **완료** | `tb_event_adapter` 23/23 PASS |
| `rtl/event/event_accumulator.v` | **D3 착수 가능** (본 회신으로 블로커 해소) | — |
| `rtl/control/servo_pwm.v` | **완료** | `tb_servo_pwm` 6/6 PASS + 실물 2축 구동 확인 |
| `rtl/control/board_io.v` | 완료 (브링업 전용) | 실물 동작 확인, 가동 범위 실측 중 |
| `rtl/control/tracking_controller.v` | 미착수 (D4) | — |
| `rtl/control/laser_interlock.v` | 미착수 (D6) | — |

`top_system.v` / `constraints/` / Block Design은 건드리지 않았다 (SPEC §5.4).

---

## 6. A에게 요청하는 것 (우선순위 순)

1. **CR C-003 클럭 확정** — `event_accumulator.v` 착수 전에 필요하다. 100 MHz인가?
2. **CR C-004 polarity 인코딩을 SPEC §6.1에 명시** — B에게도 전달 필요
3. **CR C-002 검토** — Event Window 33.3 ms. B 회신이 핵심이다
4. **CR C-001 승인** — Servo Command Format
5. A 문서의 "Window 5~10 ms" 표현을 CR C-002 확정값으로 갱신
