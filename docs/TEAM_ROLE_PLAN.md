# 이벤트 카메라 기반 FPGA NPU 팬틸트 추적 시스템
## 3인 팀 역할분담 및 개발 운영안 v1.6

> **기준 문서**  
> `NPU_DEVELOPMENT_PLAN.md`
>
> **팀 구성 전제**
> - A: 사용자 본인 / 팀 내 가장 높은 난도의 작업 담당
> - B: 보통 수준 / CNN·Python·검증 중심 담당
> - C: 제어·센서·시연 통합 중심 담당
>
> **역할분담 원칙**
> 1. 프로젝트의 핵심 성공 경로인 `CNN → INT8 → Dense NPU → 좌표 출력 → Pan/Tilt Tracking`은 A와 B가 책임진다.
> 2. C에게 NPU Core, Quantization 핵심 로직, 전체 시스템 통합 단독 책임을 맡기지 않는다.
> 3. C는 Servo/Laser/보드 I/O/데모 보조처럼 결과가 눈에 보이고 단위 검증이 쉬운 기능을 맡는다.
> 4. 최종 Vivado Block Design과 실제 보드 통합은 A가 주도하고 B/C가 각 담당 모듈을 지원한다.
> 5. Sparse/Zero-Skip은 기본 시스템 완성 후 A가 여유 있을 때만 진행한다.

---

# 1. 프로젝트 핵심 성공 기준

본 프로젝트는 아래 6개가 완료되면 기본 성공으로 판단한다.

```text
1. Event Tensor 생성
2. Tiny CNN 학습 및 INT8 변환
3. Python Integer Golden Model
4. Dense INT8 NPU RTL 구현
5. NPU Target (x, y) 출력
6. Pan/Tilt Closed-loop Tracking
```

추가로 다음을 확보한다.

```text
7. CPU vs FPGA NPU Latency 비교
8. FPGA Resource 측정
9. Laser/LED Target Lock
10. 반복 시연 안정화
```

Sparse/Zero-Skip은 선택 확장이다.

---

# 2. 전체 역할 요약

| 구분 | 담당 | 핵심 역할 | 난이도 |
|---|---|---|---|
| **A** | 사용자 본인 | NPU RTL / SoC / 전체 Architecture / 최종 통합 | **상** |
| **B** | 팀원 2 | CNN / Quantization / Integer Golden Model / 데이터 및 검증 | **중** |
| **C** | 팀원 3 | Event 입력 처리 / Tracking Controller / Pan-Tilt / Laser / 시연 통합 | **중** |

---

# 3. A 담당 — NPU RTL / SoC / 전체 통합

## 3.1 역할

A는 프로젝트의 **핵심 하드웨어 담당자 및 시스템 통합 리드**다.

### 핵심 담당

- NPU 전체 Architecture 결정
- Tensor Layout 확정
- Weight Layout 확정
- PE/MAC Array 설계
- Conv Address Generator
- Activation Buffer / Output Buffer
- INT32 Accumulator
- Requantize
- ReLU / Clamp
- Dense Conv Engine
- Layer Sequencer
- Argmax Target Decoder
- Cycle Counter
- NPU AXI-Lite Register
- Vivado Block Design 주도
- PS/PL 데이터 경로 결정
- 전체 Top-level RTL
- B가 만든 Golden Model과 RTL 결과 비교
- 전체 시스템 Timing / Utilization 확인
- 실제 보드 NPU 동작 검증
- 최종 Event → NPU → Tracking 통합 주도

### 선택 확장

기본 시스템이 완성된 경우에만:

- Conv1 Sparse / Zero-Skip
- Dense vs Sparse Cycle 비교
- PE 수 8 → 16 확장 검토

## 3.2 주요 산출물

```text
npu_pe.v
npu_conv_dense.v
npu_requant.v
npu_datapath.v
npu_controller.v
npu_axi.v
argmax_decoder.v
top_system.v

tb_npu_pe.v
tb_npu_conv_dense.v
tb_npu_requant.v
tb_npu_full.v
```

선택:

```text
npu_conv1_sparse.v
tb_npu_conv1_sparse.v
```

## 3.3 반드시 설명할 수 있어야 하는 내용

```text
INT8 × INT8
      ↓
INT32 Accumulate
      ↓
Requantize
      ↓
ReLU / Clamp
      ↓
INT8 Activation
```

발표 시 다음을 담당한다.

- 왜 INT8을 사용하는가?
- PE Array는 어떻게 병렬 MAC을 수행하는가?
- Conv 주소는 어떻게 생성하는가?
- Layer마다 Tensor 크기가 어떻게 변하는가?
- CPU보다 FPGA NPU가 왜 빠를 수 있는가?
- Cycle Count는 어떻게 측정했는가?
- Golden Model과 RTL을 어떻게 검증했는가?

## 3.4 A 난이도

**난이도: 상**

A가 막히면 프로젝트 전체가 멈출 가능성이 높기 때문에 B의 Golden Model과 C의 주변 모듈을 가능한 빨리 받아 NPU와 통합에 집중한다.

---

# 4. B 담당 — CNN / Quantization / Golden Model

## 4.1 역할

B는 **AI 모델 및 NPU 검증 기준 생성 담당자**다.

### 핵심 담당

- Event 데이터 정리
- 64×64×2 Tensor Dataset 생성
- 실제 추적 표적 중심의 자동 Label 생성
- Tiny CNN 학습
- FP32 정확도 측정
- INT8 Quantization
- Weight INT8 변환
- Activation Scale 정리
- Multiplier / Shift 계산
- Python Integer Golden Model
- Layer별 Tensor Dump
- `.hex`, `.mem` Test Vector 생성
- FP32 vs INT8 정확도 비교
- PS CPU FP32 Baseline
- PS CPU INT8 Baseline
- CPU Latency 측정 스크립트
- A와 RTL Layer-by-Layer 비교

### Dataset / Label 책임 경계 — 2026-08-22 운영 정정

```text
Dataset 입력  = 실제 추적 표적의 움직임이 포함된 Event Tensor
정답 Label    = 같은 시점의 실제 표적 중심 좌표
Laser         = NPU 추론 이후 동작하는 출력 장치
```

B는 레이저 점을 CNN의 학습 Target으로 사용하지 않는다. 기존 `ai/dataset.py`의
Red Laser 검출/Preview는 최종 자동 Label 방식이 아니며, 실제 표적용
Color/Blob/Teacher 검출기 또는 수동 보정 방식으로 교체한다.

단일 지정 표적 → 8×8 Heatmap → `target_x/y` 범위는 유지하므로 A의 NPU RTL과
C의 Tracking 인터페이스 변경은 없다.

## 4.2 주요 산출물

```text
train.py
dataset.py
quantize.py
integer_golden.py

weights/
scales.json

test_vectors/
├─ input_event.hex
├─ conv1_out.hex
├─ conv2_out.hex
├─ conv3_out.hex
├─ heatmap.hex
└─ result_xy.txt

accuracy_report.md
cpu_vs_npu.csv
```

## 4.3 핵심 기준

B의 가장 중요한 산출물은 단순 CNN Accuracy가 아니라:

```text
Python Integer Golden Model
```

이다.

A가 RTL을 구현한 뒤:

```text
Python INT8 Output
        =
RTL Output
```

을 비교할 수 있어야 한다.

검증 순서:

```text
Conv1
 ↓
Conv2
 ↓
Conv3
 ↓
Conv4
 ↓
Heatmap
 ↓
Argmax
```

## 4.4 모델 복잡도 제한

기본 구조는 다음을 유지한다.

| Layer | Output |
|---|---|
| Conv1 | 32×32×8 |
| Conv2 | 16×16×16 |
| Conv3 | 8×8×32 |
| Conv4 | 8×8×1 |
| Argmax | Target `(x, y)` |

모델 구조 변경은 반드시 A와 협의한다.

```text
모델 구조 변경
→ Weight Layout 변경
→ RTL Address 변경
→ Buffer 크기 변경
→ NPU Controller 변경
```

으로 이어지기 때문이다.

## 4.5 B 난이도

**난이도: 중**

최종적으로 A에게 다음을 정확히 전달해야 한다.

```text
Tensor Shape
Weight 순서
Scale
Multiplier
Shift
Golden Output
```

---

# 5. C 담당 — Event 입력 / Tracking Controller / Pan-Tilt / Laser

## 5.1 역할

C는 **Event 입력부부터 실제 Pan/Tilt 제어까지 연결하는 실시간 제어 파트 담당자**다.

단순 기구 조립만 하는 역할이 아니라, 센서 입력을 NPU가 사용할 수 있는 형태로 정리하고 NPU의 `(x, y)` 결과를 실제 구동으로 연결하는 한 축을 맡는다.

### 핵심 담당

- Event Source Adapter 구현
- Event Accumulator 구현
- 64×64×2 Event Tensor 생성 경로
- Event Window 제어
- 저장 Event Trace 입력 테스트
- Fallback Frame Difference 입력 연결 지원
- Pan Servo 동작
- Tilt Servo 동작
- Servo PWM
- Servo Duty Mapping
- Servo Angle Limit
- Tracking Dead Zone 적용
- Slew Rate Limit
- Laser 또는 LED ON/OFF
- Laser Emergency OFF
- Safe Zone
- Laser Offset 값 측정
- 레이저 영상검출은 구현하지 않음 (레이저는 출력 장치)
- Pan/Tilt 기구 조립
- Camera + Laser 고정
- Target Board 제작
- 보드 Switch / Button / LED 연결
- 데모용 Target 준비
- 반복 운동 Target 환경 준비
- 시연 영상 촬영 지원

## 5.2 C가 구현할 RTL

담당 RTL은 다음과 같이 구성한다.

```text
event_adapter.v
event_accumulator.v
tracking_controller.v
servo_pwm.v
laser_interlock.v
```

필요하면:

```text
board_io.v
```

## 5.3 C의 단위 테스트

### Event Input Test

NPU를 연결하기 전에 저장 Event Trace 또는 강제 입력으로 다음을 검증한다.

```text
Event x/y/polarity 입력
        ↓
64×64 좌표 Binning
        ↓
Positive / Negative Map
        ↓
Window End
        ↓
64×64×2 Tensor 생성
```

최소 확인 항목:

- 동일 좌표 Event Count 누적
- Polarity 채널 분리
- Window 종료 시 Tensor 확정
- 다음 Window 시작 시 Buffer 초기화/교체
- 범위 밖 좌표 처리

---

### Servo Test

NPU 없이 먼저 다음처럼 테스트한다.

```text
Target X = 10 → Pan Left
Target X = 32 → Hold
Target X = 50 → Pan Right
```

Tilt도 동일하게 검증한다.

### Dead Zone Test

```text
|error_x| < DEAD_ZONE
→ Pan Hold

|error_y| < DEAD_ZONE
→ Tilt Hold
```

### Laser Test

초기에는 실제 Laser 대신 LED를 사용한다.

이 테스트는 NPU의 `target_x/y`와 Lock 조건에 따라 출력이 켜지는지를 확인하는
것이며, 카메라 영상에서 레이저 점을 검출하는 테스트가 아니다.

```text
TARGET_VALID = 1
LOCK_ZONE 진입
SAFE_ZONE 내부
Emergency = 0
        ↓
LED ON
```

그 이후 실제 Laser Module로 교체한다.

## 5.4 C가 A/B와 협업하는 부분

C가 Event Tensor 형식을 임의 변경하지 않는다.

```text
Tensor Shape = 64×64×2
Coordinate = 0~63
Polarity = 2 Channel
Window End = 명시적 Pulse
```

A가 정한 NPU Input Interface에 맞춰 전달한다.

## 5.5 C에게 맡기지 않는 작업

- INT8 Quantization
- Integer Golden Model
- NPU PE 설계
- Conv Address Generator
- Requantize
- NPU Controller
- 전체 AXI Architecture
- 전체 Vivado Block Design
- Event Camera Driver의 핵심 문제 해결
- 최종 System Integration 책임
- Sparse / Zero-Skip

## 5.6 C 난이도

**난이도: 중**

Event 입력 RTL, Tracking Controller, Servo 제어, Laser Interlock까지 하나의 연속 경로를 맡기 때문에 단순 조립 수준은 아니다. 최종 시연에서 다음 흐름을 담당한다.

```text
Target 이동
→ Servo 회전
→ Target Centering
→ Lock
→ Laser/LED ON
```

---

# 6. Event Camera 담당 방식

Event Camera는 특정 한 명에게 완전히 맡기지 않는다.

이유는 카메라 SDK, USB, Linux, Driver, Event Format 등 환경 의존성이 크기 때문이다.

### B

```text
Event 데이터 확인
→ Dataset 생성
→ 학습용 Tensor/Label 구성
```

### A

```text
Event Tensor
→ NPU Input Buffer
→ PS/PL / AXI 통합
```

### C

```text
Event Camera / Trace 입력
→ Event Adapter
→ Event Accumulator
→ 64×64×2 실시간 Tensor
→ Pan/Tilt / Laser 시연 환경
```

카메라 Driver 문제가 발생하면 A와 B가 공동 대응한다.

---

# 7. Integration 담당 방식

전체 통합은 **A가 주도**한다.

```text
B
CNN / INT8 / Golden
        ↓
A에게 전달

C
Event / Tracking / Servo / Laser
        ↓
A에게 전달

A
NPU + AXI + Top
        ↓
Vivado / SoC Integration
```

A가 모든 코드를 대신 작성하는 구조는 피한다.

---

# 8. 팀 간 Interface Freeze

D3까지 다음 내용을 고정한다.

## B → A

```text
Input Tensor Shape
Weight Layout
Layer Output Shape
Quantization Scale
Multiplier / Shift
Golden Test Vector
```

## A → C

```text
TARGET_VALID
RESULT_X
RESULT_Y
RESULT_SCORE
```

Tracking Controller 입력은 가능하면 단순하게 유지한다.

```verilog
target_valid
target_x[5:0]
target_y[5:0]
target_score
```

## C → A

```text
PAN PWM
TILT PWM
LOCK
LASER ENABLE
```

---

# 9. 15일 팀별 일정

| Day | A | B | C |
|---:|---|---|---|
| **D1** | NPU 구조/Interface 설계 | 데이터/모델 환경 준비 | Event Camera/Trace 형식 확인 + Servo 확인 |
| **D2** | NPU Tensor/Weight Layout | Event Tensor Dataset | Event Adapter 초안 + Servo PWM |
| **D3** | Interface Freeze | CNN + INT8 + Golden | Event Accumulator + Pan/Tilt 단독 테스트 |
| **D4** | PE + Conv1 | Golden Conv1 제공 | Event Tensor 단위 TB + Tracking Controller |
| **D5** | Conv2/3/4 | Layer별 Golden 검증 | Dead Zone / Limit + Event Window 검증 |
| **D6** | Full Dense NPU | Full Golden 비교 지원 | Laser/LED Interlock + Event 입력 안정화 |
| **D7** | AXI + Argmax + Cycle | CPU Baseline | Event Tensor 실시간 출력 + Pan/Tilt 기구 |
| **D8** | Event → NPU 통합 | Event 입력/모델 지원 | Event Adapter→NPU 통합 지원 + Target Board |
| **D9** | NPU → Tracking 통합 | 결과 Logging | Pan/Tilt 통합 지원 |
| **D10** | Closed-loop Debug | Tracking 데이터 분석 | Servo Gain 조정 |
| **D11** | Laser/Lock 전체 통합 | Accuracy 재측정 | Laser Offset / Safety |
| **D12** | Latency / Resource | CPU vs NPU 데이터 | 반복 추적 테스트 |
| **D13** | 시스템 안정화 / 여유 시 Sparse | 그래프/결과 정리 | Demo 반복 테스트 |
| **D14** | Block Diagram/PPT | 그래프/PPT | 시연 영상/PPT |
| **D15** | 최종 통합/발표 | 발표 지원 | 시연 담당 |

---

# 10. 개발 우선순위

## A

```text
1. Dense NPU
2. Golden Match
3. NPU 좌표 출력
4. AXI / SoC
5. Pan/Tilt 통합
6. 성능 측정
7. Laser 통합
8. Sparse / Zero-Skip
```

## B

```text
1. Dataset
2. Tiny CNN
3. INT8 Quantization
4. Integer Golden
5. Test Vector
6. CPU Baseline
7. 결과 그래프
```

## C

```text
1. Event Source Adapter
2. Event Accumulator / Tensor 생성
3. Servo PWM
4. Pan/Tilt
5. Tracking Controller
6. Safety Limit
7. LED/Laser Lock
8. Demo 환경
```

---

# 11. 각 역할 완료 기준

## A

- Dense NPU Full Inference 성공
- Golden Model과 결과 일치
- Target `(x, y)` 출력
- Cycle Counter 정상
- AXI 제어 가능
- Vivado Timing 통과
- 실제 보드 동작

## B

- CNN 학습 완료
- INT8 변환 완료
- FP32/INT8 비교 완료
- Integer Golden 동작
- Layer별 Test Vector 생성
- CPU Baseline 측정

## C

- Event Adapter 입력 정상 처리
- 64×64×2 Event Tensor 생성
- Window 종료/초기화 정상
- Pan/Tilt 독립 동작
- Target Error 기반 방향 제어
- Dead Zone 정상
- Servo Angle Limit 정상
- Target Lost 시 Hold 또는 Safe 동작
- LED Lock 정상
- Laser Safe Interlock 정상

---

# 12. 팀원별 발표 담당

## A

```text
NPU Architecture
INT8
PE/MAC
Requantize
RTL
AXI
CPU vs NPU
FPGA Resource
```

## B

```text
Event Tensor
CNN
Dataset
Quantization
Golden Model
Accuracy
```

## C

```text
Event Camera Input
Event Adapter / Accumulator
Tracking Control
Pan/Tilt / Servo
Laser Lock
Safety
Demo
```

---

# 13. 문제가 생겼을 때 역할 재조정

## B가 모델 학습에서 막히는 경우

A가 모델 구조를 단순화한다.

```text
Target 단순화
Dataset 축소
CNN 구조 유지
```

NPU 구조가 바뀌는 대형 모델 변경은 하지 않는다.

## C가 Tracking RTL에서 막히는 경우

A가 최소 P-Control 식만 제공하고 C는 PWM / Servo / Laser / 기구 검증에 집중한다.

```text
error_x > DEAD_ZONE  → Right
error_x < -DEAD_ZONE → Left

error_y > DEAD_ZONE  → Down
error_y < -DEAD_ZONE → Up
```

PID는 포기해도 된다.

## Event Camera 연동이 실패하는 경우

D2까지 해결되지 않으면:

```text
저장 Event Trace
또는
Webcam Frame Difference
```

로 전환한다.

## 시간이 부족한 경우

삭제 순서:

```text
1. Sparse / Zero-Skip
2. Auto Calibration
3. RGB/Event 비교
4. Velocity Prediction
5. 실제 Laser
```

실제 Laser가 빠지면 LED Lock으로 대체한다.

절대 삭제하지 않는 것:

```text
CNN
INT8
Golden Model
Dense NPU
Target 좌표
Pan/Tilt Tracking
CPU vs NPU 비교
```

---

# 14. 팀 운영 규칙

각자 하루 종료 전 다음 3개만 공유한다.

```text
1. 오늘 완료한 것
2. 현재 막힌 것
3. 내일 필요한 입력 파일/인터페이스
```

## Git 권장 구조

```text
project/
│
├─ ai/
│   ├─ train.py
│   ├─ quantize.py
│   └─ integer_golden.py
│
├─ rtl/
│   ├─ npu/
│   ├─ event/
│   └─ control/
│
├─ tb/
├─ weights/
├─ test_vectors/
├─ vitis/
├─ docs/
└─ results/
```

---

# 15. 최종 역할 분담 결론

## A — 사용자 본인

**난이도: 상**

```text
NPU RTL
+
AXI / SoC
+
전체 Architecture
+
최종 Integration
+
여유 시 Sparse
```

프로젝트의 기술적 핵심을 담당한다.

## B — 보통 수준 팀원

**난이도: 중**

```text
CNN
+
INT8 Quantization
+
Integer Golden Model
+
Test Vector
+
CPU Baseline
```

A가 NPU를 구현할 수 있도록 정확한 기준 데이터를 제공한다.

## C — 제어·센서 담당 팀원

**난이도: 중**

```text
Event Adapter / Accumulator
+
Pan/Tilt
+
Servo PWM
+
Tracking Controller
+
Laser / LED Lock
+
기구 / 보드 I/O
+
Demo
```

단위 테스트가 쉬운 기능부터 완성하고 프로젝트의 시각적 시연 완성도를 담당한다.

---

# 16. 최종 협업 구조

```text
                B
        CNN / INT8 / Golden
                │
                ▼
Event ────────→ A ────────→ Target X/Y
              NPU
              RTL
              SoC
              │
              ▼
                C
       Pan/Tilt / Laser
                │
                ▼
        Closed-loop Demo
```

최종적으로는:

> **B가 모델과 정답 데이터를 만들고, A가 이를 실제 FPGA NPU로 구현하며, C가 Event 입력과 NPU 결과를 실제 움직임·Laser Lock으로 연결한다.**

이 구조가 현재 팀 실력 차이와 15일 개발 기간을 고려했을 때 가장 안전한 역할분담이다.

---

# 17. 진척 현황 (2026-08-22 갱신, 역할 분담 자체는 변경 없음)

역할 분담 내용은 v1.1 그대로다. 아래는 상태 기록일 뿐이다.
**v1.4 갱신: A Phase 2 (AXI / SoC / Bitstream) 완료.**
**v1.5 갱신: 기구가 Pan/Tilt 2 헤드로 변경 — C 작업량 증가. 역할 경계는 그대로.**
**v1.6 갱신: A Phase 3 (PS 소프트웨어 + C 통합 사전검증) 완료.**
**2026-08-22 운영 정정: 레이저 기반 Label을 실제 표적 중심 Label로 교체. A/C 인터페이스 변경 없음.**

## A — §3.2 산출물 진척

```text
[x] npu_pe.v            [x] npu_conv_dense.v    [x] npu_requant.v
[x] npu_datapath.v      [x] npu_controller.v    [x] argmax_decoder.v
[x] npu_axi.v           [x] top_system.v            <- Phase 2

[x] tb_npu_pe.v         [x] tb_npu_conv_dense.v
[x] tb_npu_requant.v    [x] tb_npu_full.v
[x] tb_npu_axi.v        [x] tb_top_system.v         <- Phase 2

[x] Vivado Block Design (PS7 + SmartConnect + top_system)
[x] results/npu_soc.bit   [x] results/npu_soc.xsa

Phase 3 (PS 소프트웨어 / 보드 불필요)
[x] sw/npu_regs.h  [x] sw/npu_driver.c  [x] sw/npu_test.c
[x] sw/sim/npu_mock.c + test_driver.c   -> 호스트 45 check PASS
[x] tools/gen_test_tensor_c.py          -> sw/test_tensor.h
[x] sw/build_vitis.tcl                  -> results/npu_test.elf
[x] rtl/integration/c_module_stub.v     -> C 통합 사전측정 (자리표시자)
```

§11 A 완료 기준 대비:

```text
[x] Dense NPU Full Inference 성공
[x] Golden Model과 결과 일치        (임시 weight 기준, B 실물 대기)
[x] Target (x, y) 출력
[x] Cycle Counter 정상               125,845 cycle = 1.258 ms @100MHz
[x] AXI 제어 가능                    tb_npu_axi 74 check / tb_top_system 17 check PASS
[x] Vivado Timing 통과               전체 시스템 배치배선 WNS +0.782 ns, Fmax 107.7 MHz
[x] Bitstream 생성                   results/npu_soc.bit (+ npu_soc.xsa)
[x] PS 소프트웨어                    results/npu_test.elf, 호스트 45 check PASS
[x] C 통합 타이밍 사전확인            자리표시자 포함 WNS +1.121 ns (100MHz MET)
[ ] 실제 보드 동작                    <- 보드가 있어야 함 (Phase 4)
```

A가 지금 막힌 곳은 **보드 실동작**과 **A/C 실제 전체 시스템 통합**이다.
C 모듈 전달은 완료됐고 A 소유 RTL/PS 산출물 합류가 필요하다.
상세 요약: `docs/A_NPU_HANDOFF.md`, 현재 저장소 상태: `docs/PROJECT_STATUS.md`

## B — 진척

```text
[~] Event Tensor 생성/저장 기반             ai/dataset.py (Webcam Fallback, 재사용 가능)
[ ] 실제 추적 표적 중심 자동 Label          Red Laser 의존 제거 필요
[ ] 실제 표적 Dataset 수집/분포 검증         기존 레이저 점 Sample은 최종 학습에서 제외
[x] Conv 경계 규칙 Freeze 요청 -> A 승인 완료
[ ] Tiny CNN 학습 / FP32 정확도
[ ] INT8 Quantization / Weight 변환
[ ] Python Integer Golden Model
[ ] Test Vector 생성
[ ] CPU Baseline
```

## C — 진척

```text
[x] Event Adapter + Ping-Pong Accumulator + 8192-byte Tensor 전송
[x] A Phase 3 포트용 c_event_control_top 전달

v1.5 로 늘어난 C 작업 (Pan/Tilt 2 헤드)
[x] Servo PWM 채널 2 -> 4 (PAN1/TILT1/PAN2/TILT2)
[x] PT#2 좌표 변환   theta_pan1 + k_x*(target_x-32) + LASER_OFFSET
                     (공통 지침 v1.5 §15.2 / 계획서 v1.4 §16.2)
[ ] LASER_OFFSET_PAN / TILT 실측 (고정거리 2m, 5지점)
[x] SAFE_LIMIT2 적용 (필수 — 헤드 분리로 안전 자동보장 사라짐)
[~] 서보 4채널 외부전원 단기 구동 확인, 장시간/최종 부하 검증 대기

NPU / RTL(A) 쪽 작업량 증가는 AXI Register 4개뿐. 이미 구현·검증 완료.
```

## §8 Interface Freeze 진행

```text
B -> A : Weight Layout / Quantization / Label Mapping / Conv 경계 규칙  -> 확정
A -> C : TARGET_VALID / RESULT_X / RESULT_Y / RESULT_SCORE             -> 확정 (npu_core 포트)
A -> C : AXI Register Bit Field / Base 0x4000_0000 (CR#002 rev.2)      -> C 기본 계약 수용·구현, A Phase 3 확장 회신 대기
A -> C : PT#2 좌표 변환식 (공통지침 v1.5 §15.2)                        -> C 수용·구현 완료
C -> A : Event Accumulator (evt_we/addr/data) 구동                     -> 완료, 8192 byte 전수 TB 통과
C -> A : Camera/Laser 4축 PWM / LOCK / LASER ENABLE                    -> 완료, LED 우선 실물 검증 통과
```

상세: 공통 지침 v1.5 §21.4

---

**문서 버전:** v1.6 Team Role Allocation — 상/중/중 조정본
**기준:** v1.1 Learning-Aligned Revision  
**인원:** 3명  
**진척 기록 갱신:** 2026-08-22 (§17 — A Phase 3 완료 + Dataset/Label 운영 정정. 역할 경계 변경 없음)
**역할 난이도:** A 상 / B 중 / C 중
