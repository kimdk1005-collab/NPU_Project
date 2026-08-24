# CHANGE REQUEST C-001 — Servo Command Format 신규 확정 제안

> SPEC §22 형식을 따른다. SPEC §21 D3 Interface Freeze 항목 중 `Servo Command Format`은
> 현재 값이 정의되어 있지 않다. 아래는 C의 제안이며 **팀 승인 전까지 확정이 아니다** (SPEC §23-5).

```text
[CHANGE REQUEST]

요청자: C (김도근)
날짜: 2026-08-20 (D1)
변경 항목: Servo Command Format (SPEC §21 D3 Freeze 항목)

기존:
  정의 없음. SPEC §21에 항목명만 존재하고 값이 비어 있음.

변경안:
  1) Servo Position 표현
       pos = 8 bit unsigned (0 ~ 255)
       pos = 0   -> PULSE_MIN_US              = 1000    us  (최소각)
       pos = 128 -> PULSE_MIN_US + SPAN/2     = 1500    us  (중립)
       pos = 255 -> PULSE_MAX_US - SPAN/256   = 1996.09 us  (최대각 - 1 LSB)

     주의: >>8 은 255 가 아니라 256 으로 나누므로 pos=255 가
     PULSE_MAX_US(2000 us) 에 정확히 닿지 않는다. 3.91 us 모자란다.
     1 step = SPAN/256 = 3.91 us 이며 하비 서보 dead band(MG996R 약 5 us)
     보다 작아 물리적으로 구분되지 않는다. 의도된 선택이다.

  2) PWM 타이밍
       PWM 주파수    = 50 Hz (Frame 20 ms)
       PULSE_MIN_US  = 500      <- D2 실물 검증으로 확장 (제출 시 1000)
       PULSE_MAX_US  = 2500     <- D2 실물 검증으로 확장 (제출 시 2000)
       CLK_HZ        = 125,000,000   ← 보드 sysclk 값 (Digilent 마스터 XDC
                                        -period 8.00 로 확인). C 모듈 구동
                                        클럭이 이것인지는 A 확정 대기

  3) 변환식
       SPAN_CYC     = PULSE_MAX_CYC - PULSE_MIN_CYC
       pulse_cycles = PULSE_MIN_CYC + ((pos * SPAN_CYC) >> 8)

     이 식이 규격이며, 위 1) 의 수치는 이 식에서 유도된 결과다.
     식과 수치가 다르게 보이면 식이 우선한다.

  4) Safe Angle Limit
       POS_MIN / POS_MAX 파라미터로 servo_pwm.v 출력단에서 Clamp
       POS_MIN = 32   (pos 32  -> 750  us)    <- D2 실물 실측 확정
       POS_MAX = 224  (pos 224 -> 2250 us)
       PAN / TILT 동일. 실측 결과 축별 차이가 없었다

변경 이유:
  - SPEC §21이 D3까지 확정을 요구하는 항목인데 값이 비어 있어 C의 RTL을 진행할 수 없다.
  - 8 bit 해상도는 180도 기준 약 0.7도로, 하비 서보의 실사용 해상도에 충분하다.
  - >>8 시프트 스케일링은 나눗셈 없이 DSP 1개로 처리되어 자원 부담이 없다.
  - 펄스 범위를 1.0~2.0 ms로 좁게 시작하는 이유는 기구 가동 범위를 아직 모르기 때문이다.
    넓히는 방향은 나중에 안전하지만, 넓게 시작했다가 좁히는 것은 기구를 파손시킨다.

영향 파일:
  rtl/control/servo_pwm.v            (C, 구현 완료)
  tb/control/tb_servo_pwm.v          (C, 구현 완료)
  rtl/control/tracking_controller.v  (요청 당시 미착수, 현재 구현·검증 완료)
  docs/interface_contract.md         (공유 - 승인 후 기록)

영향 담당:
- A: PAN_CMD(0x20) / TILT_CMD(0x24) Register Bit Field 가 pos 8 bit 와 정합해야 함.
     C 모듈 구동 클럭 확정 필요 — PL sysclk(125 MHz)인지 PS FCLK인지.
- B: 영향 없음.
- C: 제안자. servo_pwm.v 이미 이 규격으로 구현 및 검증 완료.

Golden Model 영향: 없음
RTL 영향: C 담당 rtl/control/ 만 해당. NPU / Event 경로 영향 없음
Testbench 영향: tb/control/tb_servo_pwm.v (이미 이 규격으로 작성, 6/6 PASS)
Vivado 영향: 없음 (Block Design 미착수)
Vitis 영향: PAN_CMD / TILT_CMD 쓰기 값의 스케일이 0~255 로 고정됨

기존 Test Vector 재생성 필요 여부: 아니오
예상 Merge Conflict: 없음 (C 소유 파일만 수정)

팀 승인:
A: [ ]
B: [ ]  (영향 없음, 참고만)
C: [x]
```

---

## 승인 후 조치

1. `docs/interface_contract.md`에 Servo Command Format 절 기록 (SPEC §5.4 공유 파일이므로 A와 함께)
2. `handoff/C_EVENT_CONTROL_HANDOFF.md` §3의 "제안" 표기를 "확정"으로 변경
3. `docs/change_log.md`에 기록

## 승인 전까지

`servo_pwm.v`는 **parameter 기본값**으로만 이 규격을 갖는다.
모든 값이 parameter이므로 팀이 다른 값을 택해도 **로직 변경 없이 파라미터만 교체**하면 된다.

---

## 정정 이력 (승인 전)

**2026-08-20 (D1)** — 제출 당시 §1이 `pos = 255 -> 최대각`이라고만 적어
`pos = 255`가 `PULSE_MAX_US`에 정확히 도달하는 것처럼 읽혔다.
실제 산식 `>>8`은 256으로 나누므로 `1996.09 us`이며 `2000 us`에 3.91 us 못 미친다.

**산식은 바꾸지 않았다.** 설명 문구를 실제 동작에 맞춰 정정한 것이다.
승인 대상 규격 자체는 제출 시점과 동일하다.

`servo_pwm.v`와 `tb_servo_pwm.v`는 처음부터 `>>8`로 구현·검증되어 있었으므로
RTL / Testbench 변경 없음. 재검증 결과도 동일하다 (6/6 PASS, errors 0).

**2026-08-21 (D2)** — 펄스 범위를 `1000~2000` → **`500~2500`** 으로 확장하고
`POS_MIN/MAX` 를 **`32 / 224`** 로 확정했다.

D1 에는 기구 가동 범위를 몰라 좁게 제안했다. 제출 당시 적은 대로
**"넓히는 방향은 나중에 안전하지만 반대는 기구를 파손시킨다"** 는 원칙에 따라
좁게 시작했고, D2 에 실물을 돌려 근거가 생겼으므로 넓힌 것이다.

D2 실물 검증 내용:

```text
팬틸트 브래킷 조립 상태에서 2 축 실제 구동
  pos 32~224 전 구간 기구 간섭 없음. 어느 끝에서도 스톨하지 않음
  카메라(앱코 APC850) 하중이 가동 범위를 제한하지 않음
  좁은 범위(pos 112~144, 32 step) 실측 약 15 도
    -> 0.469 도/step,  펄스 500~2500 전 구간 약 120 도
```

**산식은 바뀌지 않았다.** `pulse = PULSE_MIN_CYC + ((pos * SPAN_CYC) >> 8)` 그대로다.
바뀐 것은 `PULSE_MIN_US` / `PULSE_MAX_US` / `POS_MIN` / `POS_MAX` **파라미터 값 네 개**이며,
전부 `servo_pwm.v` 의 parameter 라 로직 변경이 없다.

부수 정정 — D1 은 `>>8` 의 1 LSB 부족분을 "dead band 보다 작아 구분되지 않는다" 로
정당화했는데, 그것은 `1 step = 3.91 us` 이던 때의 이야기다. 범위를 넓히면서
`1 step = 7.81 us` 가 되어 dead band 약 5 us 를 넘는다. 다만 `POS_MAX = 224` 라
`pos = 255` 는 애초에 출력단 clamp 에 걸려 나가지 않으므로 실사용에 영향이 없다.
`servo_pwm.v` 주석을 이 내용으로 정정했다.

재검증: `tb_servo_pwm` 6/6 PASS (TB 는 파라미터를 명시적으로 넘기므로 영향 없음).
