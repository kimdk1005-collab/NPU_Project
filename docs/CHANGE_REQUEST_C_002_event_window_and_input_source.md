# CHANGE REQUEST C-002 — Event Window 길이 및 Event 입력원 확정

> SPEC §22 형식을 따른다. SPEC §21 D3 Interface Freeze 항목 중 `Event Window` 는
> 현재 TBD 이며, HANDOFF §2 는 `5 ms / 10 ms` 를 후보로 두고 있었다.
> **아래는 C의 제안이며 팀 승인 전까지 확정이 아니다** (SPEC §23-5).
>
> **이 CR 은 B 에게 가장 큰 영향을 준다.** 학습 Dataset 재생성이 필요하다.

---

## 왜 지금 올리는가

SPEC **v1.2 §14.1** 이 Mapping 을 Freeze 하면서 다음 문장을 넣었다.

```text
현재 640×480 Webcam Fallback에서는:
  x64 = min(63, floor(x_raw * 64 / 640))
  y64 = min(63, floor(y_raw * 64 / 480))
```

즉 **공통 명세가 이미 입력원을 640×480 웹캠으로 전제하고 있다.**
그런데 같은 문서의 `Event Window` 는 아직 `5 ms / 10 ms` 후보 상태다.

이 두 가지는 **동시에 성립할 수 없다.** 30 fps 웹캠의 프레임 간격은 33.33 ms 이고
프레임 차분은 두 프레임 **사이의 변화**만 만들 수 있으므로,
프레임 간격보다 짧은 Event Window 는 물리적으로 존재할 수 없다.

또한 SPEC §34 는 Fallback 전환 판단 기한을 **D2** 로 지정했다. 오늘이 D2다.

---

## 실측 근거

측정 스크립트를 저장소에 넣었다. 누구나 재현할 수 있다 (SPEC §0-12).

```bash
python3 tools/probe_webcam.py            # 기본 /dev/video0
```

**대상 장치** — **앱코(APKO) APC850**
USB ID `322e:2233` (Sonix Technology) / `uvcvideo` / `usb-0000:65:00.3-4`
USB 디스크립터의 product 문자열은 제네릭 `USB2.0 HD UVC WebCam`이라 모델명이 나오지 않는다.
모델명은 사용자 확인이며, 아래 능력값은 그 장치를 실제로 조회한 결과다.

**2026-08-21 실측 결과**

| 포맷 | 해상도 | 최대 fps | 프레임 간격 |
|---|---:|---:|---:|
| MJPG | 1280×720 / 800×600 / 640×480 / 352×288 이하 | **30** | 33.33 ms |
| YUYV | **640×480** | **30** | **33.33 ms** |
| YUYV | 800×600 | 20 | 50.00 ms |
| YUYV | 1280×720 | 10 | 100.00 ms |

```text
최대 fps    : 30
프레임 간격 : 33.333 ms

Window  5.0 ms : 불가능
Window 10.0 ms : 불가능
```

**60 fps 모드는 어떤 해상도에도 없다.** 따라서 Window 를 절반으로 줄이는 선택지가 없다.

### 왜 640×480 YUYV 인가 — 720p 30 fps 가 있는데도

APC850 은 FHD 로 판매되지만 **1920×1080 모드가 장치에 없다.** 실측 최대는 1280×720 이다.
그리고 1280×720 은 MJPG 에서만 30 fps 이고 YUYV 에서는 10 fps 로 떨어진다.

즉 30 fps 선택지는 실질적으로 둘이다.

| 후보 | 장점 | 채택 여부 |
|---|---|---|
| MJPG 1280×720 @30 | 해상도가 높다 | **탈락** |
| YUYV 640×480 @30 | luma 가 바이트로 바로 나온다 | **채택** |

MJPG 를 쓰지 않는 이유는 대역폭이 아니라 **프레임 차분의 성질** 때문이다.

- JPEG 은 손실 압축이라 정지 장면에서도 블록 경계에 프레임마다 다른 양자화 오차가 남는다.
  프레임 차분은 그 오차를 **가짜 이벤트로 만들어낸다.** 8×8 블록 격자 모양의
  고정 패턴 노이즈가 Tensor 전면에 깔리므로 Argmax 에 직접 해를 준다.
- 매 프레임 JPEG 디코드가 필요하다. 차분을 PS 에서 할 경우 부담이 크다.
- YUYV 는 첫 바이트가 곧 luma 라 디코드 없이 차분이 된다.

그리고 **어느 쪽을 골라도 최대 30 fps 이므로 Window 결론은 바뀌지 않는다.**
이 CR 의 핵심 주장인 33.33 ms 는 해상도 선택과 무관하다.

640×480 은 SPEC v1.2 §14.1 이 전제한 값과도 정확히 일치한다.

---

## CHANGE REQUEST 본문

```text
[CHANGE REQUEST]

요청자: C (김도근)
날짜: 2026-08-21 (D2)
변경 항목: Event Window 길이 (SPEC §21 D3 Freeze 항목)
           Event 입력원 Fallback 전환 (SPEC §34)

기존:
  Event Window = TBD.  HANDOFF §2 후보 "5 ms 또는 10 ms"
  Event 입력원 = Event Camera 우선, Fallback 미발동
  SPEC v1.2 §14.1 은 이미 640×480 Webcam 을 전제하고 있음 (불일치 상태)

변경안:
  1) Event 입력원
       SPEC §34 Fallback 2순위 "Webcam Frame Difference" 를 발동한다.
       SPEC v1.2 §14.1 이 이미 전제하고 있는 상태를 명시적으로 확정하는 것이다.

  2) 캡처 모드
       640 x 480, YUYV, 30 fps
       SPEC §14.1 의 frame_width=640 / frame_height=480 과 일치한다.

  3) Event Window
       WINDOW_US = 33333        (= 1 프레임, 30 fps)
       5 ms / 10 ms 후보는 폐기한다. 물리적으로 불가능하다.

  4) Window 경계 생성 방식
       내부 타이머가 아니라 카메라 프레임 경계를 그대로 쓴다.
       rtl/event/event_adapter.v 의 WINDOW_SRC = 1 (외부 pulse) 로 둔다.
       자유 진행 타이머를 쓰면 Window 경계와 프레임 경계가 서서히 어긋나
       어떤 Window 는 이벤트 0 개, 다음 Window 는 2 프레임분이 된다.

변경 이유:
  - 30 fps 웹캠의 프레임 간격이 33.33 ms 이고, 프레임 차분은 프레임 간격보다
    짧은 이벤트를 만들 수 없다. 5 ms / 10 ms 는 둘 다 물리적으로 불가능하다.
    tools/probe_webcam.py 로 재현 가능한 실측이다.
  - SPEC v1.2 §14.1 이 이미 640×480 웹캠을 전제하므로, Window 만 옛 후보값으로
    남겨두면 SPEC 내부가 서로 모순된다.
  - SPEC §34 가 Fallback 판단 기한을 D2 로 지정했고 오늘이 D2다.

영향 파일:
  rtl/event/event_adapter.v          (C, 구현 완료 - parameter 만 교체)
  tb/event/tb_event_adapter.v        (C, 구현 완료)
  rtl/event/event_accumulator.v      (C, D3 착수 예정)
  tools/gen_event_vector.py          (C, --window-us 인자로 대응)
  B 소유 dataset / golden / test_vector 전체
  docs/interface_contract.md         (공유 - 승인 후 기록)

영향 담당:
- A: NPU 추론 시간 예산이 5~10 ms 에서 33.3 ms 로 **완화된다** (유리한 방향).
     별도로 결정 필요 — 프레임 차분을 어디서 수행할 것인가.
       (가) PC 에서 수행 후 이벤트 스트림만 PL 로 전달
            gen_event_vector.py 구조와 동일. 15일 일정에서 안전한 쪽.
       (나) Zybo PS 의 PetaLinux + UVC 에서 수행
            실시간이지만 PetaLinux 브링업이 일정 위험.
     이 선택은 C 단독으로 정하지 않는다.
- B: **가장 큰 영향.** 학습 Dataset 의 Event Window 가 33.3 ms 로 바뀌므로
     Dataset / Golden / Test Vector 를 재생성해야 한다.
     Window 가 3배 길어지면 셀당 Event Count 분포가 올라가므로
     SPEC §9.1 의 포화 상한 127 에 닿는 셀이 늘어날 수 있다. 재확인 필요.
- C: 제안자. event_adapter.v 는 WINDOW_US / WINDOW_SRC 가 parameter 이므로
     로직 변경 없이 값 교체만으로 대응된다.

Golden Model 영향: 있음 — Window 길이가 Tensor 값 자체를 바꾼다. B 재생성 필요
RTL 영향: C 담당 rtl/event/ 만 해당. parameter 교체. NPU 내부 영향 없음
Testbench 영향: tb/event/tb_event_adapter.v 는 parameter 화되어 있어 변경 불필요
Vivado 영향: 없음 (Block Design 미착수)
Vitis 영향: 프레임 차분 위치가 (나) 로 결정되면 PS 측 캡처 경로 구현 필요

기존 Test Vector 재생성 필요 여부: 예 — B 소유 전체
예상 Merge Conflict: 없음 (C 소유 파일과 B 소유 파일이 분리됨)

팀 승인:
A: [ ]
B: [ ]   ← 재생성 부담이 가장 크므로 B 의 동의가 핵심
C: [x]
```

---

## 함께 확인이 필요한 부수 항목

### SPEC §14.1 `min(63, ·)` 와 C 의 "범위 밖 폐기" 정책

SPEC v1.2 §14.1 은 `x64 = min(63, floor(x_raw * 64 / frame_width))` 로 **물림(clamp)** 을 명시한다.
HANDOFF §1 은 좌표 범위 밖 이벤트를 **폐기** 하는 것으로 기록되어 있다 (C 내부 결정, D1).

정상 입력에서는 `x_raw < frame_width` 이므로 **두 정책의 결과가 같다.**
차이가 나는 것은 입력이 규격을 벗어났을 때뿐이다.

C 의 판단은 **폐기가 맞다** 는 것이다. 물림을 쓰면 규격을 벗어난 이벤트가
Tensor 가장자리 열(63)에 가짜 카운트로 쌓여 Argmax 를 가장자리로 끌어당긴다.

`event_adapter.v` 는 `OOR_POLICY` parameter 로 둘 다 지원하며 기본값은 폐기다.
두 동작 모두 `tb_event_adapter.v` T3 에서 검증했다.
**팀이 물림을 원하면 parameter 하나만 바꾸면 되므로 별도 CR 로 올리지 않는다.**
다만 A 가 §14.1 을 "Event 경로에도 그대로 적용" 하는 뜻으로 썼다면 알려주기 바란다.

### Event Window 가 3배 길어지는 데 따른 포화 확인

SPEC §9.1 은 Conv1 입력 Event Count 를 `0 ~ 127` 로 확정했다.
Window 가 10 ms → 33.3 ms 로 3.3배 길어지면 셀당 카운트도 대략 그만큼 올라간다.
127 에 물리는 셀이 많아지면 Tensor 가 이진화에 가까워져 정보량이 준다.

C 가 합성 자극으로 미리 감을 볼 수는 있으나 **실제 판단 근거는 B 의 실제 데이터**다.
승인 시 B 가 재생성하면서 포화 비율을 함께 보고해 주기를 요청한다.

---

## 승인 후 조치

1. `docs/interface_contract.md` 에 Event Window / 입력원 절 기록 (SPEC §5.4 공유 파일이므로 A 와 함께)
2. `handoff/C_EVENT_CONTROL_HANDOFF.md` §2 의 TBD 를 확정으로 변경
3. `rtl/event/event_adapter.v` 기본 parameter 를 `WINDOW_US=33333`, `WINDOW_SRC=1` 로 교체
4. `docs/change_log.md` 에 기록

## 승인 전까지

`event_adapter.v` 는 `WINDOW_US=10000`, `WINDOW_SRC=0` 을 **parameter 기본값**으로만 갖는다.
확정이 아니며, 승인되면 값 교체만으로 전환된다. 로직 변경은 없다.
