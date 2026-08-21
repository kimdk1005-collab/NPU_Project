# 이벤트 카메라 기반 FPGA NPU 팬틸트 추적 시스템

**상세 개발 계획서 v1.1 — 학습 진도 반영본**

> **문서 목적**  
> 기존 v1.1의 핵심 구조인 `CNN 모델 → INT8 → RTL NPU 검증 → SoC 통합 → 팬틸트/레이저 추적`, `합성 Gate`, `폴백 전략`은 유지한다.  
> 다만 현재 교육 진도가 **CNN 진행 중**, **RTL/SoC 학습 및 프로젝트 경험 완료**, **NPU 학습 예정**, **Sparse/Zero-Skip은 미학습**인 점을 반영하여,  
> **Dense INT8 NPU와 Closed-loop Tracking을 본 프로젝트의 필수 본선**으로 두고 **Sparse/Zero-Skip은 시간이 남고 NPU 기본 구조를 충분히 이해한 경우에만 수행하는 선택 확장**으로 내린다.

---

## 0. v1.1에서 변경된 핵심

| 항목 | v1.0 초안 | v1.1 통합본 |
|---|---|---|
| 센서 기본안 | 고속 USB 웹캠 + 프레임 차분 | **실제 Event Camera 우선** |
| 대체 입력 | 없음 | 웹캠 Frame Difference를 **Fallback**으로 명시 |
| 이벤트 입력 | 프레임 차분 2채널 | `(x, y, polarity, timestamp)` 기반 Event Stream |
| NPU | 전 레이어 Zero-Skip 지향 | **Dense INT8 NPU 필수, Sparse/Zero-Skip은 선택 확장** |
| 좌표 추출 | Soft-argmax | **Argmax 필수**, 3×3 weighted centroid는 확장 |
| 모델 검증 | 정수 골든 모델 | 그대로 유지, **D3 필수 Gate** |
| Weight 로딩 | AXI Weight Port | MVP는 **BRAM/ROM 사전 초기화** |
| 캘리브레이션 | 7×7 자동 자기 캘리브레이션 | MVP는 **고정 Offset 보정**, 자동 방식은 확장 |
| 레이저 | 단순 ON/OFF | **Target Lock + Safe Zone + Emergency OFF** |
| 지연 목표 | 특정 절대값 제시 | **구간별 실측**, 과장된 절대값 금지 |
| 소프트웨어 | PYNQ 고정 | **D1 환경 확인 후 Vitis/Linux/PYNQ 중 선택** |
| 성공 기준 | Zero-Skip 중심 | **CNN + Dense NPU + SoC + Closed-loop Tracking 완성**이 필수, Sparse는 여유 시 확장 |

---

# 0.5 현재 학습 진도 반영 원칙

현재 팀의 교육 진도와 이미 수행한 실습을 기준으로 구현 우선순위를 다음처럼 고정한다.

| 구분 | 현재 상태 | 프로젝트 반영 |
|---|---|---|
| RTL | 학습 및 프로젝트 경험 있음 | **즉시 활용** — NPU Datapath, Controller, PWM, AXI 주변 RTL |
| SoC | 학습 및 프로젝트 경험 있음 | **즉시 활용** — PS/PL 제어, AXI-Lite, Vitis/통합 |
| CNN | 현재 학습 중 | **필수** — Tiny CNN 학습 및 Heatmap 추론 |
| NPU | 곧 학습 예정 | **필수** — 수업 내용에 맞춰 Dense INT8 NPU 구현 |
| Sparse / Zero-Skip | 아직 배우지 않음 | **선택 확장** — 기본 NPU와 추적 완성 후 여유가 있을 때만 |
| SNN | 미학습/고난도 | **후순위 연구 항목** |

### 구현 원칙

```text
배운 RTL/SoC를 활용
        ↓
현재 배우는 CNN 완성
        ↓
NPU 수업 내용으로 Dense NPU 구현
        ↓
Event Camera + Pan/Tilt + Laser 통합
        ↓
정량 측정 및 시연 안정화
        ↓
시간이 남을 때만 Sparse/Zero-Skip
```

Sparse/Zero-Skip을 구현하지 못해도 **프로젝트 실패로 보지 않는다.**  
본 프로젝트의 평가 중심은 `CNN 모델`, `INT8 Dense NPU RTL`, `SoC 통합`, `실시간 Closed-loop 추적`, `정량 비교`다.

---

# 1. 프로젝트 개요

## 1.1 프로젝트명

### 권장 공식명

**이벤트 카메라 기반 FPGA NPU 저지연 팬틸트 추적 시스템**

영문:

**Event-Camera-Based FPGA NPU for Low-Latency Pan-Tilt Tracking**

### 발표용 짧은 이름

**Event NPU Tracking Turret**

---

## 1.2 한 줄 정의

이벤트 카메라의 비동기·희소 데이터를 짧은 시간 창으로 누적하고, FPGA에 직접 구현한 INT8 Tiny CNN NPU가 이동 표적의 위치를 추론한 뒤 팬틸트와 레이저 포인터가 표적을 따라가도록 하는 저지연 Edge AI 시스템을 구현한다.

---

## 1.3 개발 조건

| 항목 | 기준 |
|---|---|
| 개발 기간 | 15일 내외 |
| 인원 | 3명 |
| 기준 FPGA 플랫폼 | Digilent Zybo Z7-20 / XC7Z020 계열 |
| AI 형식 | Tiny CNN, INT8 |
| NPU | RTL 직접 구현 |
| 입력 | 실제 Event Camera 우선 |
| 출력 | Target `(x, y)`, Confidence/Score, Pan/Tilt |
| 시연 | 이동 표적을 팬틸트가 추적하고 Laser Lock 표시 |
| 핵심 정량 지표 | CNN 정확도, CPU/NPU Latency, Cycle Count, Tracking Error, FPGA Resource |

> 보드 또는 이벤트 카메라 모델이 달라질 경우 **인터페이스 Adapter만 수정**하고 NPU Core 인터페이스는 유지한다.

---

# 2. 문제 정의

## 2.1 해결하려는 문제

고속으로 이동하는 표적을 카메라로 추적하는 시스템에서는 인식 정확도뿐 아니라 **센서 입력부터 제어 명령이 나오기까지의 지연**이 중요하다.

일반 프레임 기반 영상에서는 다음 문제가 발생할 수 있다.

- 일정 FPS 단위로만 새로운 영상을 획득
- 빠른 움직임에서 모션 블러 발생 가능
- 변화하지 않은 픽셀까지 매 프레임 처리
- CPU에서 영상 전처리와 추론을 순차 처리할 경우 Latency 증가
- 추론이 빨라도 Servo 기계 응답이 느리면 전체 시스템이 병목됨

본 프로젝트는 이를 다음 두 축으로 접근한다.

1. **Event Camera**  
   변화가 발생한 픽셀 중심의 희소한 이벤트 데이터를 사용한다.

2. **FPGA NPU**  
   CNN 연산을 INT8로 양자화하고 FPGA에서 병렬 처리한다. 기본 NPU가 안정화된 뒤 시간이 남는 경우에만 이벤트 입력의 희소성을 이용한 Sparse/Zero-Skip 구조를 추가 실험한다.

---

## 2.2 실제 활용처

- 고속 컨베이어 물체 추적
- 산업 설비의 이동 부품 감시
- 스포츠 움직임 추적 장비
- 저전력 상시 감시 카메라
- 로봇 Active Vision
- 고속 Human-Machine Interaction
- Edge Robotics Vision Front-End

> 레이저 포인터는 **추적 결과를 눈으로 보여주기 위한 데모 장치**로 사용한다. 사람·동물 추적을 목적으로 하지 않는다.

---

# 3. 왜 Edge NPU인가

발표에서 다음 질문을 방어할 수 있어야 한다.

## Q1. 왜 클라우드가 아닌가?

추적 제어는 센서 입력 이후 즉시 제어 명령이 필요하므로 네트워크 왕복 지연과 네트워크 상태 변화가 들어가는 구조는 적합하지 않다.

**핵심 답변**

> 본 시스템은 영상 분석 결과를 나중에 확인하는 시스템이 아니라 현재 위치를 기준으로 즉시 Pan/Tilt를 갱신해야 하는 Closed-loop 제어 시스템이므로 Edge 처리 구조가 필요하다.

---

## Q2. 왜 CPU만 사용하지 않는가?

CPU에서도 추론은 가능하다. 하지만 본 프로젝트에서는 같은 보드의 PS CPU와 PL NPU를 실제 측정하여 다음을 비교한다.

- FP32 CPU inference
- INT8 CPU inference
- FPGA Dense NPU inference
- (선택 확장) FPGA Sparse/Zero-Skip Front-End + NPU inference

**과장 금지**

`CPU는 이벤트 데이터를 처리할 수 없다`고 주장하지 않는다.

대신:

> CPU에서도 처리는 가능하지만, 본 프로젝트에서는 CNN의 반복적인 MAC 연산을 FPGA 데이터패스로 병렬화한 Dense INT8 NPU를 직접 구현하고 CPU와 지연을 비교한다. Sparse/Zero-Skip은 기본 NPU가 완성된 뒤 선택적으로 추가 측정한다.

---

## Q3. 왜 GPU가 아닌가?

GPU가 이벤트 데이터를 처리하지 못하는 것은 아니다.

본 프로젝트의 명분은:

- 소형 Edge 환경
- 낮은 Batch Size
- 고정된 Tiny CNN
- INT8 연산
- 센서 → NPU → 제어가 가까운 데이터 경로
- RTL로 직접 구성한 전용 CNN 데이터패스
- (선택) 희소 입력에 맞춘 Zero-Skip 데이터패스 실험

이다.

즉 **GPU를 못 쓰기 때문이 아니라, 특정 워크로드에 맞춘 전용 NPU 아키텍처가 얼마나 효율적인지 검증하는 프로젝트**다.

---

## Q4. NPU에서 직접 한 것이 무엇인가?

최종 발표에서 아래가 핵심 답변이다.

> Tiny CNN을 단순 실행한 것이 아니라, FP32 모델을 INT8 정수 연산으로 변환하고 Conv/MAC/Requantize/Activation/Layer Sequencing을 RTL NPU로 직접 구현한 뒤, SoC에서 실제 추적 제어까지 연결한다.  
> Sparse/Zero-Skip은 수업 및 기본 NPU 구현이 안정화된 뒤 시간이 남으면 Conv1에 한해 추가하고 Dense Mode와 Cycle Count를 비교하는 **선택 확장 성과**로 둔다.

---

# 4. 최종 시스템 구조

## 4.1 Primary 구조 — 실제 Event Camera

```text
┌──────────────────────────────┐
│         Event Camera         │
│ x, y, polarity, timestamp    │
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│ Event Source Adapter         │
│ - Sensor interface normalize │
│ - Coordinate resize/binning  │
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│ Event Accumulator RTL        │
│ - Positive Map               │
│ - Negative Map               │
│ - 5~10 ms Window             │
│ - Event Count / Window       │
└──────────────┬───────────────┘
               │
               ▼
      64 × 64 × 2 INT8 Tensor
               │
               │
               ▼
┌──────────────────────────────┐
│ Dense INT8 NPU Input Path    │
│ (MVP / 필수 구현)            │
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│ INT8 Tiny CNN NPU            │
│ Conv / Acc / Requant / ReLU  │
│ Layer Sequencer              │
└──────────────┬───────────────┘
               │
               ▼
        8 × 8 Heatmap
               │
               ▼
┌──────────────────────────────┐
│ Argmax Target Decoder        │
│ x, y, score                  │
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│ Tracking Controller          │
│ P Control + Dead Zone        │
│ Safe Zone / Target Lost      │
└───────┬──────────────┬───────┘
        │              │
        ▼              ▼
    PAN Servo       TILT Servo
        │              │
        └──────┬───────┘
               ▼
        Camera + Laser
```

---

## 4.2 Event Source Adapter 표준 인터페이스

카메라 모델과 NPU 개발을 분리하기 위해 내부 이벤트 형식은 조기에 고정한다.

```verilog
event_valid
event_x[5:0]        // 0~63
event_y[5:0]        // 0~63
event_polarity
event_window_end
```

실제 카메라 해상도가 더 큰 경우 Adapter에서 64×64 좌표로 Binning한다.

이 규격을 사용하면 다음 입력을 모두 동일한 NPU로 연결할 수 있다.

1. 실제 Event Camera
2. 저장된 Event Trace
3. PC에서 생성한 Event Test Vector
4. Fallback Frame Difference Source

---

# 5. 센서 확보 실패에 대한 Fallback

## 5.1 Fallback 구조

실제 이벤트 카메라의 드라이버·배송·인터페이스가 D2까지 해결되지 않을 경우 다음으로 전환한다.

```text
High-FPS RGB Camera
        ↓
Frame Difference
        ↓
Positive / Negative Map
        ↓
동일 Event Source Adapter
        ↓
동일 NPU 이하 구조
```

## 5.2 발표 시 표현 규칙

Fallback 사용 시 프로젝트를 실제 Event Camera 시스템이라고 표현하지 않는다.

권장 제목:

**프레임 차분 기반 FPGA NPU 고속 추적 시스템**

그리고 다음 주장은 제외한다.

- 마이크로초 Event Sensor 응답
- Event Camera 자체의 모션블러 우위
- 비동기 센서의 초고속 시간 해상도

대신 **CNN → INT8 → FPGA NPU → Tracking**의 전체 구현과 CPU/NPU 지연 비교를 중심으로 발표한다. Sparse/Zero-Skip은 구현한 경우에만 확장 결과로 언급한다.

---

# 6. 모델 설계

## 6.1 입력 Tensor

```text
Shape: 64 × 64 × 2

Channel 0 = Positive Event Count
Channel 1 = Negative Event Count
```

Event Count는 Window 안에서 Saturation하여 INT8 범위에 맞춘다.

권장 초기 Window:

```text
5 ms 또는 10 ms
```

최종값은 실제 Event Rate를 보고 D2~D3에 확정한다.

---

## 6.2 Tiny CNN

초안 모델:

| Layer | Output | Kernel / Stride | 예상 파라미터 |
|---|---|---|---:|
| Conv1 | 32×32×8 | 3×3 / 2 | 144 |
| ReLU | 32×32×8 | - | - |
| Conv2 | 16×16×16 | 3×3 / 2 | 1,152 |
| ReLU | 16×16×16 | - | - |
| Conv3 | 8×8×32 | 3×3 / 2 | 4,608 |
| ReLU | 8×8×32 | - | - |
| Conv4 | 8×8×1 | 1×1 / 1 | 32 |
| Argmax | `(x, y)` | - | - |

총 파라미터는 약 **5.9K** 수준이다.

> 정확한 MAC 수와 BRAM 사용량은 D3 모델 동결 후 스크립트로 다시 산출한다.

---

## 6.3 왜 Heatmap인가

단순 Class 분류가 아니라 표적 위치를 출력해야 한다.

```text
Event Tensor
    ↓
CNN
    ↓
8×8 Heatmap
    ↓
MAX 위치
    ↓
Target x, y
```

장점:

- 구조가 간단함
- 하드웨어 후처리가 쉬움
- Bounding Box Regression보다 구현 부담이 작음
- 단일 표적 Tracking에 충분함

---

## 6.4 좌표 추출

### MVP

**Argmax**

```text
Heatmap 64개 값
   ↓
Comparator Tree / Sequential Max
   ↓
Max Index
   ↓
(x, y)
```

### 확장

Argmax 주변 3×3의 Weighted Centroid를 사용하여 Sub-cell 보정.

Soft-argmax는 MVP 범위에서 제외한다.

---

# 7. 데이터 수집과 학습

## 7.1 학습 목표

표적의 종류를 분류하는 것이 아니라:

```text
입력: Event Tensor
출력: Target Heatmap
```

을 학습한다.

---

## 7.2 Label 생성

사람이 모든 프레임을 직접 라벨링하지 않는다.

가능한 방법:

### 방법 A — Teacher Model

동기 RGB 영상이 있으면 PC에서 YOLO/MediaPipe/간단 Color Tracker 등으로 Target Center를 얻는다.

### 방법 B — 표적 디자인 이용

배경과 대비가 큰 원형/LED Target을 사용해 OpenCV Color/Blob Detection으로 자동 좌표를 생성한다.

### 방법 C — 수동 일부 라벨

Teacher가 불안정한 구간만 보정한다.

> 모델 학습 자체가 프로젝트 핵심이 아니므로 **자동 라벨 + 소형 데이터셋**을 우선한다.

---

# 8. INT8 양자화

## 8.1 기본 정책

- Weight: INT8
- Activation: INT8
- Accumulator: INT32
- Requantize: Integer Multiplier + Shift
- Activation: ReLU 또는 Clamp

```text
INT8 × INT8
      ↓
INT32 Accumulate
      ↓
Multiplier
      ↓
Shift
      ↓
Clamp
      ↓
INT8
```

---

## 8.2 양자화 목표

FP32 모델과 INT8 모델을 비교한다.

| 모델 | 측정 |
|---|---|
| FP32 | Heatmap/좌표 정확도 |
| INT8 Golden | Heatmap/좌표 정확도 |
| RTL NPU | INT8 Golden과 bit-exact 또는 허용 오차 비교 |

---

# 9. Python Integer Golden Model

## 9.1 D3 필수 산출물

이 프로젝트에서 가장 먼저 동결해야 할 검증 기준이다.

```text
PyTorch FP32
     ↓
Quantization
     ↓
Python Integer Inference
     ↓
Layer-by-layer Tensor Dump
     ↓
.hex / .mem
     ↓
RTL Testbench
```

---

## 9.2 Golden Model 출력

각 테스트 벡터에 대해:

```text
input_event.hex
conv1_acc.hex
conv1_out.hex
conv2_out.hex
conv3_out.hex
heatmap.hex
result_xy.txt
```

를 생성한다.

---

## 9.3 검증 원칙

RTL 오류와 학습/양자화 오류를 분리하기 위해:

```text
Layer 1 검증
   ↓ PASS
Layer 2 검증
   ↓ PASS
Layer 3 검증
   ↓ PASS
Full NPU 검증
```

순서로 진행한다.

---

# 10. NPU RTL 구조

## 10.1 MVP 데이터패스

```text
Activation Buffer
      ↓
Window / Address Generator
      ↓
PE Array
      ↓
INT32 Accumulator
      ↓
Requantize
      ↓
ReLU / Clamp
      ↓
Output BRAM
```

---

## 10.2 PE Array 규모

처음부터 128~256 MAC을 목표로 하지 않는다.

### 권장 시작점

```text
8 PE
```

D4 합성 이후:

```text
Timing / DSP / LUT 여유
        ↓
16 PE 또는 그 이상 검토
```

### 이유

- 모델 전체 크기가 작음
- 2주 프로젝트에서 검증 가능한 구조가 중요
- PE 수나 Sparse 최적화보다 **Dense NPU의 완전한 추론 경로와 실제 추적 통합**이 발표 가치가 큼

---

# 11. Sparse / Zero-Skip — 선택 확장

## 11.1 현재 범위

Sparse/Zero-Skip은 **MVP 필수 범위가 아니다.**

현재 교육과정에서 아직 배우지 않았으므로 다음 순서를 지킨다.

```text
Dense INT8 NPU 완성
→ Golden Model 검증
→ Event Camera 통합
→ Pan/Tilt Closed-loop Tracking
→ CPU vs NPU 측정
→ 여유가 있으면 Sparse/Zero-Skip 학습 및 실험
```

따라서 일정표에서 Sparse를 먼저 구현하기 위해 기본 Tracking 통합을 늦추지 않는다.

---

## 11.2 선택 구현 범위

실제로 추가한다면 **Conv1 한 레이어만** 대상으로 한다.

이유:

- Event Tensor의 입력 희소성이 가장 직접적으로 나타나는 구간
- 전체 NPU 구조를 다시 설계하지 않아도 됨
- Dense NPU와 Cycle Count를 비교하기 쉬움
- 15일 프로젝트에서 학습과 구현 범위를 제한할 수 있음

확장 개념:

```text
Event Tensor
   ↓
Zero / Non-Zero 판정
   ↓
Non-Zero 위치만 연산 요청
   ↓
Conv1 MAC 일부 Skip
   ↓
Dense Conv2~4는 그대로 사용
```

---

## 11.3 착수 조건

아래 조건이 모두 만족될 때만 시작한다.

- Dense NPU Full Inference PASS
- RTL 결과가 Integer Golden Model과 일치
- 실제 또는 Fallback Event 입력이 연결됨
- Pan/Tilt Tracking이 반복 동작함
- Laser/LED Lock 로직이 동작함
- CPU vs NPU 기본 Latency가 측정됨
- Sparse/Zero-Skip의 동작 원리를 팀이 설명할 수 있음

하나라도 만족하지 못하면 Sparse는 생략한다.

---

## 11.4 구현 시 주의

단순히 `activation == 0`에서 MAC enable만 끄고 전체 Cycle 수가 그대로라면, 이를 **Zero-Skip으로 인한 Latency 개선**이라고 주장하지 않는다.

실제 Cycle 감소를 주장하려면:

```text
Dense Cycle > Sparse Cycle
```

이 실제 Counter 측정으로 확인되어야 한다.

이 부분은 **배운 범위를 넘어서는 추가 연구 성과**로 취급한다.

---

# 12. NPU Weight/Scale 저장

## 12.1 MVP

Weight와 Requantize Parameter는 `.mem` 또는 BRAM Initialization으로 합성 시 넣는다.

장점:

- AXI Weight Loader 구현 시간 절약
- Weight 전송 오류 제거
- Testbench와 실제 보드가 동일한 값을 사용

## 12.2 확장

시간이 남으면 AXI를 통한 Runtime Weight Upload를 추가한다.

---

# 13. Control / AXI Register Map

초기 제안이며 D3 Interface Freeze에서 확정한다.

| Offset | Name | R/W | 내용 |
|---:|---|---|---|
| `0x00` | `CTRL` | RW/W1P | bit0 START, bit1 SOFT_RESET, bit2 RESERVED/OPTION_SPARSE_EN |
| `0x04` | `STATUS` | R | DONE, BUSY, ERROR, TARGET_VALID |
| `0x08` | `EVENT_CFG` | RW | Event Window / Accumulation 설정 |
| `0x0C` | `INPUT_STAT` | R | MVP: Event Count / 선택 확장: NNZ |
| `0x10` | `CYCLE_CNT` | R | NPU 처리 Cycle |
| `0x14` | `RESULT_X` | R | Target X |
| `0x18` | `RESULT_Y` | R | Target Y |
| `0x1C` | `RESULT_SCORE` | R | Heatmap Max Score |
| `0x20` | `PAN_CMD` | RW | Pan Target |
| `0x24` | `TILT_CMD` | RW | Tilt Target |
| `0x28` | `LASER_CTRL` | RW | Laser Enable / Interlock |
| `0x2C` | `SAFE_LIMIT` | RW | Pan/Tilt Safe Limit |
| `0x30` | `TRACK_ERR_X` | R | Current X Error |
| `0x34` | `TRACK_ERR_Y` | R | Current Y Error |

Weight/Scale 전용 Runtime Window는 MVP에서 만들지 않는다.

---

# 14. Tracking Controller

## 14.1 목표

NPU 출력:

```text
Target X, Target Y
```

Camera Center:

```text
Center X = 32
Center Y = 32
```

오차:

```text
error_x = Target X - Center X
error_y = Target Y - Center Y
```

---

## 14.2 MVP 제어

PID 전체를 처음부터 구현하지 않는다.

```text
P Control + Dead Zone
```

예:

```text
|error| < DEAD_ZONE
→ Servo Hold

error > 0
→ 해당 방향 이동

error < 0
→ 반대 방향 이동
```

필요하면 마지막에 D항 또는 Velocity Feed-Forward를 추가한다.

---

# 15. Pan/Tilt 및 기존 RTL 재사용

기존 로봇팔 RTL 프로젝트의 PWM 생성기는 재사용 가능하다.

단, 이번 프로젝트의 핵심 성과로 계산하지 않는다.

재사용:

- PWM Generator
- Servo Duty Mapping
- Enable Logic

신규:

- NPU Result → Servo Command
- Tracking Dead Zone
- Slew Rate Limit
- Safe Angle Limit
- Target Lost 처리
- Laser Interlock

---

# 16. 레이저 포인터 설계

## 16.1 기구 구조

카메라와 레이저를 같은 Pan/Tilt Head에 고정한다.

```text
Pan/Tilt Head
├─ Event Camera
└─ Laser Module
```

레이저를 별도의 축으로 조준하지 않는다.

---

## 16.2 MVP 보정

자동 7×7 캘리브레이션 대신 고정 실험 거리에서:

```text
LASER_OFFSET_X
LASER_OFFSET_Y
```

를 측정한다.

최종 Lock 목표:

```text
Target X + Offset X
Target Y + Offset Y
```

---

## 16.3 Laser ON 조건

다음 조건을 모두 만족할 때만 ON한다.

```text
TARGET_VALID == 1
RESULT_SCORE >= threshold
Target inside Safe Zone
Servo command inside Safe Limit
|error_x| <= LOCK_ZONE_X
|error_y| <= LOCK_ZONE_Y
Emergency Stop == 0
```

하나라도 만족하지 못하면:

```text
LASER = OFF
```

---

## 16.4 안전 원칙

- 사람·동물 추적 금지
- 관객 방향 조준 금지
- 테이블 또는 별도 Target Board 영역만 사용
- 제조사 안전등급과 사용 지침을 준수한 저출력 가시광 모듈 사용
- Pan/Tilt 하드웨어/소프트 리밋 적용
- 보드 버튼 또는 별도 스위치에 **Laser Emergency OFF**
- 개발 중에는 Laser 대신 LED로 먼저 검증

---

# 17. 소프트웨어 구조

## 17.1 PS 역할

PS는 다음 작업을 담당한다.

- Sensor Driver 또는 Event Packet 수신
- NPU 초기 설정
- Start/Status Register 제어
- 결과 Logging
- CPU Baseline 측정
- UART/Ethernet/HDMI/PC Dashboard 출력
- 필요 시 Event Trace 저장

**최종 Tracking 제어 루프는 가능하면 PL 안에서 닫는다.**

---

## 17.2 개발 환경 선택

D1에 실제 보드에서 가능한 환경을 확인하고 하나로 고정한다.

우선순위 예:

```text
1. 기존 사용 가능한 Linux/PYNQ 환경
2. Vitis Bare-Metal + 외부 PC Event Stream
3. 경량 Linux + Vendor Event Camera SDK
```

특정 PYNQ 이미지가 반드시 존재한다고 전제하지 않는다.

---

# 18. 정량 평가 항목

## 18.1 반드시 측정

### 모델

- FP32 Target MAE
- INT8 Target MAE
- Quantization accuracy loss

### NPU

- NPU Cycle Count
- NPU Latency
- CPU vs Dense NPU Latency
- Dense NPU Cycle Count
- Layer별 또는 전체 처리 시간
- (선택 확장) Input NNZ / Sparsity / Dense-Sparse Speedup

### FPGA

- LUT
- FF
- DSP
- BRAM
- Fmax / Timing Slack

### Tracking

- Target Position MAE
- RMS Pixel Tracking Error
- Lock Ratio
- Target Lost Count
- 최대 안정 추적 속도 또는 동일 궤적에서의 상대 비교

---

## 18.2 Latency는 분리해서 보고

하나의 `End-to-End Latency` 숫자로 숨기지 않는다.

```text
Sensor / Accumulation
        ↓
Transfer / Adapter
        ↓
NPU Inference
        ↓
Target Decode
        ↓
Control Command
        ↓
Servo Mechanical Response
```

각 구간을 가능하면 별도로 측정한다.

발표 예:

```text
Event Window        : XX ms
NPU Inference       : XX us/ms
Control Generation  : XX us
Servo Response      : XX ms
```

서보가 가장 느리면 그것을 그대로 병목으로 보고한다.

---

## 18.3 비교 기준선

가능하면 동일 보드/동일 모델에서:

1. PS CPU FP32
2. PS CPU INT8
3. PL Dense NPU
4. (선택 확장) PL Sparse/Zero-Skip Front-End + NPU

를 비교한다.

추가 비교:

```text
Simple Event Centroid
vs
CNN NPU Tracking
```

이를 통해:

> 왜 단순 Centroid가 아니라 NPU가 필요한가?

에 대한 답도 준비한다.

---

# 19. 성공 기준

## 19.1 필수 성공 조건 — MVP

아래가 모두 동작해야 프로젝트를 완성으로 판단한다.

- [ ] Event Tensor 생성
- [ ] Python Integer Golden Model
- [ ] RTL Dense INT8 NPU
- [ ] Golden Model과 RTL 결과 검증
- [ ] NPU가 Target `(x, y)` 출력
- [ ] Pan/Tilt Closed-loop Tracking
- [ ] Target Lock 상태 표시
- [ ] CPU vs NPU Latency 비교
- [ ] FPGA Resource Report
- [ ] 보드 시연

---

## 19.2 우선 확장 기능

Dense NPU와 Tracking이 안정화된 뒤 우선한다.

- [ ] Laser Lock
- [ ] 고정 Offset Calibration
- [ ] 반복 궤적 Tracking Test
- [ ] Latency Breakdown 측정
- [ ] CPU FP32/INT8 vs FPGA Dense NPU 비교

이 단계까지 완료되면 발표 완성도는 충분히 높다.

---

## 19.3 여유가 있을 때만 하는 확장

- [ ] Conv1 Sparse / Zero-Skip Prototype
- [ ] Dense/Sparse Mode 비교
- [ ] NNZ vs Cycle Count 그래프
- [ ] RGB vs Event 추적 비교
- [ ] Weighted Centroid Subpixel
- [ ] Auto Calibration
- [ ] Target Velocity Prediction
- [ ] Power Measurement
- [ ] SNN 실험

Sparse/Zero-Skip은 여기서 **필수가 아니라 최상위 선택 확장**이다.

---

# 20. 팀 역할 분담

## 팀원 1 — 모델 / Quantization / Golden Model

담당:

- 데이터 수집
- 자동 라벨 생성
- Tiny CNN 학습
- FP32 성능 측정
- INT8 Quantization
- Scale / Multiplier / Shift 생성
- Python Integer Golden Model
- Layer별 `.hex/.mem` 생성
- CPU FP32/INT8 Baseline 측정

### D3 책임 산출물

```text
model_int8.py
weights/*.mem
scales.json
test_vectors/
golden_outputs/
accuracy_report.md
```

---

## 팀원 2 — NPU Datapath RTL

담당:

- PE/MAC
- Address Generator
- Accumulator
- Requantize
- ReLU/Clamp
- Dense Conv Engine
- Layer별 Testbench
- Cycle Counter
- (선택 확장) Sparse Conv1 Front-End / NNZ 검증

### 산출물

```text
npu_pe.v
npu_conv_dense.v
# 선택 확장 시: npu_conv1_sparse.v
npu_requant.v
npu_datapath.v
tb_*.v
```

---

## 팀원 3 — Event / Control / Integration

담당:

- Event Source Adapter
- Event Accumulator
- Tensor Buffer
- Layer Sequencer
- AXI-Lite
- Pan/Tilt Controller
- Servo PWM
- Laser Interlock
- Board I/O
- System Integration
- Logging / Demo UI

### 산출물

```text
event_adapter.v
event_accumulator.v
npu_controller.v
npu_axi.v
tracking_controller.v
servo_pwm.v
laser_interlock.v
top_system.v
```

---

## 공통

- D3 Interface Freeze 전원 리뷰
- D4 첫 합성 전원 확인
- D12 이후 기본 시스템이 안정화된 경우에만 Sparse/Zero-Skip 착수 여부 결정
- D10 Closed-loop Tracking 통합 완료 목표
- D12 이후 인터페이스 변경 금지

---

# 21. 15일 개발 일정

| Day | 핵심 작업 | 통과 기준 |
|---:|---|---|
| **D1** | 보드/Toolchain/Event Camera 환경 확인, 내부 Event Interface Freeze 초안, Servo 단독 동작 확인 | 개발 환경 실행 |
| **D2** | Event 데이터 수집, 64×64×2 Tensor 생성, Label 자동 생성 | Dataset Pipeline |
| **D3** | Tiny CNN 학습, INT8, **Integer Golden Model**, Weight/Scale Dump, Interface Freeze | **GATE A** |
| **D4** | PE Array + Dense Conv1 RTL, 첫 합성, PE 수 확정 | Conv1 Golden PASS |
| **D5** | Dense Conv2/3/4 + Buffer/Address | Layer별 PASS |
| **D6** | Requantize + Full Dense NPU | Full Golden PASS |
| **D7** | Layer Sequencer + AXI + Cycle Counter + Argmax | 보드 NPU 좌표 출력 |
| **D8** | 실제 Event Source와 Dense NPU 통합 / Fallback 결정 | 실시간 Event Tensor → NPU |
| **D9** | Tracking Controller + Pan/Tilt | Target Centering |
| **D10** | Closed-loop Tracking 안정화 + SoC 제어/로그 | 반복 추적 성공 |
| **D11** | Laser Offset + Interlock 통합 | **GATE B** |
| **D12** | CPU vs Dense NPU Latency, Cycle, Resource 측정 | 정량 데이터 확보 |
| **D13** | 반복 궤적 Tracking Test / 병목 수정 / **여유 시 Sparse Conv1 실험** | Demo 안정화 우선 |
| **D14** | PPT/보고서/그래프/Block Diagram | 발표 자료 |
| **D15** | 최종 리허설, 영상 촬영, Backup Demo 준비 | 제출/발표 |

---

# 22. 개발 Gate

## GATE A — D3

다음이 없으면 RTL 범위를 확대하지 않는다.

- [ ] 모델 구조 확정
- [ ] Weight INT8 확정
- [ ] Quantization Parameter 확정
- [ ] Integer Golden Model 동작
- [ ] 최소 3개 Test Vector 준비
- [ ] NPU Tensor Layout 확정

---

## GATE B — D6~D7

- [ ] Dense NPU Full Inference PASS
- [ ] Result Heatmap/Argmax PASS
- [ ] Cycle Counter 정상
- [ ] 보드 합성/Timing 가능

이 시점부터는 Sparse 여부와 무관하게 전체 Tracking 통합을 우선한다.

---

## GATE C — D12~D13 선택 확장 판단

다음 조건을 **모두 만족할 때만** Sparse/Zero-Skip을 시작한다.

- [ ] Dense NPU Full Inference PASS
- [ ] 실제 Event 입력과 NPU 통합 완료
- [ ] Pan/Tilt Closed-loop Tracking 반복 동작
- [ ] Laser 또는 LED Lock 로직 동작
- [ ] CPU vs NPU 기본 측정값 확보
- [ ] 팀원이 Sparse/Zero-Skip 동작 원리를 설명할 수 있음

조건을 만족하지 못하면:

```text
Sparse/Zero-Skip 미구현
→ 실패가 아니라 계획된 범위 관리
→ Dense NPU + SoC + Tracking 완성도를 높임
```

조건을 만족하고 시간이 남으면 Conv1에 한해 Prototype을 추가한다.

---

# 23. 리스크 관리

| 리스크 | 조기 판단 | 대응 |
|---|---|---|
| Event Camera 배송/Driver 실패 | D1~D2 | 저장 Event Trace → Fallback Frame Difference |
| Event Rate 너무 높음 | D2 | 64×64 Spatial Binning / Window 조정 |
| 모델 학습 불안정 | D3 | Target 단순화, Color/LED Target 사용 |
| INT8 정확도 급락 | D3 | QAT 또는 Activation Range 조정 |
| RTL/Golden 불일치 | D4~D6 | Layer별 bit-exact 검증 |
| DSP/LUT 초과 | D4 | PE 16→8 또는 Time Multiplex |
| Sparse/Zero-Skip 미학습·구조 복잡 | D12~D13 | 기본 일정에서 제외, Dense NPU 완성 후 선택 실험 |
| Servo 진동/Overshoot | D10 | Dead Zone, P Gain 감소, Slew Limit |
| Servo 전원 노이즈 | 즉시 | 외부 5V Servo 전원, GND 공통 |
| Laser Offset 변화 | D11 | 고정 거리 시연, Offset 재측정 |
| Laser 안전 문제 | 전 과정 | LED 선검증, Safe Zone, Emergency OFF |
| 실시간 화면 UI 지연 | D12 | UI는 제어 루프와 분리 |

---

# 24. 시연 대상 선정

## 권장

- 검은 배경에서 밝은 원형 표적
- 테이블 위에서 좌우 이동하는 Target
- Pendulum 형태의 반복 운동 Target
- 레일 위를 왕복하는 작은 표적

## 이유

반복 가능한 운동을 사용해야:

```text
CPU
Dense NPU
(선택) Sparse NPU
```

를 같은 조건에서 비교할 수 있다.

### 비추천

- 사람이 공을 임의로 던지는 방식만 사용
- 관객을 레이저로 추적
- 드론 등 기구 위험성이 높은 대상

---

# 25. 권장 시연 시나리오

## Demo 1 — NPU Tracking

1. Target 정지
2. Target 좌우 이동
3. Event Map 표시
4. NPU Target `(x,y)` 표시
5. Pan/Tilt가 화면 중심으로 Target 유지

---

## Demo 2 — CPU vs FPGA NPU

동일한 입력 샘플 또는 동일한 Event Tensor를 사용하여:

```text
CPU Inference
vs
FPGA Dense NPU Inference
```

를 비교한다.

화면에:

```text
CPU Latency = XX ms
NPU Latency = XX us/ms
NPU Cycle   = XXXX
Target X/Y  = XX / XX
```

를 표시한다.

**수업에서 배운 CNN/NPU가 실제 RTL/SoC 시스템으로 연결되었다는 점**이 핵심이다.

### Demo 2-B — Sparse/Zero-Skip (선택)

D13까지 기본 시스템이 안정화되고 Sparse 확장을 구현한 경우에만 Dense/Sparse Cycle 차이를 추가 시연한다.

---

## Demo 3 — Laser Lock

1. Target 탐지
2. Target Error 감소
3. Lock Zone 진입
4. Laser ON
5. Target Lost 또는 Safe Zone 이탈
6. 즉시 Laser OFF

> 개발 초반에는 Laser 대신 LED로 동일 로직을 검증한다.

---

# 26. 발표용 핵심 그래프

기본 발표에서 준비할 그래프:

### Graph 1

```text
CPU FP32
CPU INT8
PL Dense NPU
      ↓
Inference Latency
```

### Graph 2

```text
Event Accumulation
NPU Inference
Target Decode
Control Command
Servo Response
      ↓
Latency Breakdown
```

### Graph 3

```text
Target Speed / Motion Condition
        vs
Tracking RMS Error
```

### Graph 4

```text
FP32
INT8
RTL
   ↓
Target MAE
```

### Graph 5

```text
LUT / FF / DSP / BRAM
```

### Graph 6 — 선택 확장

Sparse/Zero-Skip을 실제 구현했을 때만 추가한다.

```text
Input Sparsity (%)
        vs
Dense / Sparse Cycle Count
```

---

# 27. 발표에서 하지 말아야 할 주장

실측하기 전 다음 표현을 사용하지 않는다.

- `항상 1 ms 이내`
- `GPU보다 80% 전력 절감`
- `이벤트 데이터의 90% 이상이 항상 0`
- `CPU/GPU에서는 처리가 불가능`
- `Zero-Skip으로 N배 빨라진다` (실제 구현·측정하지 않았다면 발표에서 언급하지 않음)

발표에서는 기본적으로:

```text
CPU Latency = XXXX
Dense NPU Cycle = XXXX
Dense NPU Latency = XXXX
Tracking RMS Error = XXXX
```

처럼 실제 결과만 사용한다. Sparse/Zero-Skip을 실제 구현한 경우에만 NNZ, Sparsity, Dense/Sparse Speedup 수치를 추가한다.

---

# 28. 최종 산출물

## 28.1 필수 산출물

### 모델

```text
train.py
quantize.py
integer_golden.py
weights/
test_vectors/
accuracy_report.md
```

### RTL

```text
event_adapter.v
event_accumulator.v
npu_pe.v
npu_conv_dense.v
npu_requant.v
npu_datapath.v
npu_controller.v
npu_axi.v
tracking_controller.v
servo_pwm.v
laser_interlock.v
top_system.v
```

### Testbench

```text
tb_event_accumulator.v
tb_npu_pe.v
tb_npu_conv_dense.v
tb_npu_requant.v
tb_npu_full.v
tb_tracking_controller.v
```

### 결과 자료

```text
cpu_vs_npu.csv
tracking_error.csv
utilization.rpt
timing_summary.rpt
waveforms/
demo_video/
```

## 28.2 Sparse/Zero-Skip 선택 확장 산출물

실제 구현했을 때만 추가한다.

```text
npu_conv1_sparse.v
tb_npu_conv1_sparse.v
dense_vs_sparse.csv
```

---

# 29. D1 확정해야 할 사항

아래 6가지는 첫날 반드시 확정한다.

- [ ] 실제 사용할 Event Camera 모델
- [ ] Event Camera → Zynq 데이터 경로
- [ ] Zybo Z7-20 사용 여부 최종 확정
- [ ] Toolchain / OS / Runtime 환경
- [ ] 추적 Target 종류
- [ ] Laser 사용 여부와 안전 시연 영역

그리고 다음 내부 인터페이스는 D1~D3 안에 동결한다.

```text
Event Interface
Tensor Layout
NPU Weight Layout
Requantize Format
Register Map
Servo Command Format
```

---

# 30. 최종 프로젝트 성공 시 한 문장

> **기본 성공 문장:** “이벤트 카메라의 변화 데이터를 Tiny CNN으로 처리하고, 이를 INT8 FPGA NPU로 직접 구현하여 CPU 대비 추론 지연을 측정한 뒤, 추론 결과를 Pan/Tilt와 Laser Lock까지 연결한 Closed-loop Edge AI 추적 시스템을 구현하였다.”  
> **Sparse 확장 성공 시 추가:** “추가로 Conv1 Zero-Skip/Sparse Front-End를 구현해 Dense NPU와 Cycle Count 차이를 실측하였다.”

---

# 31. 최종 범위 우선순위

개발 중 시간이 부족해지면 반드시 아래 순서로 지킨다.

```text
1. Integer Golden Model
2. Dense INT8 NPU
3. Event Tensor 입력
4. Target 좌표 출력
5. Pan/Tilt Tracking
6. CPU vs NPU 정량 비교
7. Laser Lock
8. 반복 추적 안정화 / 정량 측정 강화
9. RGB/Event 비교
10. Auto Calibration
11. Sparse Conv1 / Zero-Skip 실험
12. Velocity Prediction / SNN
```

**1~6은 절대 포기하지 않는다.**  
레이저는 기본 시스템 안정화 후 우선 확장하고, Sparse/Zero-Skip은 그보다 뒤에 둔다.  
Sparse/Zero-Skip이나 SNN을 위해 Dense NPU와 Closed-loop Tracking 완성도를 희생하지 않는다.

---

**문서 버전:** v1.1 Learning-Aligned Revision  
**상태:** 현재 학습 진도 반영 / Sparse·Zero-Skip 선택 확장화 / D1~D3 Interface Freeze 전  
