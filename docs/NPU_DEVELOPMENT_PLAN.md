# 이벤트 카메라 기반 FPGA NPU 팬틸트 추적 시스템

**상세 개발 계획서 v1.4 — Pan/Tilt 2 헤드 구성 반영본**

> **2026-08-30 구현 상태 주의:** 이 문서는 계획과 Gate 정의의 정본이다. 본문에 남은
> `A 실제 RTL 합류 대기`, `model_v03`, 과거 타이밍 수치는 당시 계획 이력이며 현재 상태가
> 아니다. A RTL/SoC/PS와 B v04 데모 후보의 최신 상태는 `PROJECT_STATUS.md`, 현재 Version
> Lock과 측정값은 `integration_manifest.md`를 우선한다.

> **문서 목적**  
> 기존 v1.1의 핵심 구조인 `CNN 모델 → INT8 → RTL NPU 검증 → SoC 통합 → 팬틸트/레이저 추적`, `합성 Gate`, `폴백 전략`은 유지한다.  
> 다만 현재 교육 진도가 **CNN 진행 중**, **RTL/SoC 학습 및 프로젝트 경험 완료**, **NPU 학습 예정**, **Sparse/Zero-Skip은 미학습**인 점을 반영하여,  
> **Dense INT8 NPU와 Closed-loop Tracking을 본 프로젝트의 필수 본선**으로 두고 **Sparse/Zero-Skip은 시간이 남고 NPU 기본 구조를 충분히 이해한 경우에만 수행하는 선택 확장**으로 내린다.

> **2026-08-22 Dataset/Label 운영 정정**
> 레이저 포인터는 추론 결과를 보여주는 **출력 장치**이며 CNN의 학습·검출 대상이 아니다.
> B는 실제 추적 표적이 움직이는 Event Tensor와 그 표적 중심 좌표를 짝지어 Dataset을 만든다.
> 이 정정은 NPU 입출력, 8×8 Heatmap, 좌표 Mapping, A/C 인터페이스를 변경하지 않는다.

---

## 0.0 v1.2 / v1.3 에서 변경된 핵심 (2026-08-21)

v1.1의 구조와 우선순위는 **그대로 유지**한다.
v1.2는 A의 Phase 1(Dense NPU Core 구현 + Golden 검증) 완료로 확정된 **실측값과 결정을 반영**한 것이다.

| 항목 | v1.1 | v1.2 |
|---|---|---|
| PE Array 규모 | "D4 합성 후 16 PE 검토" (근거 없음) | **8 PE 실측 확보** — LUT 2.65%, 16 PE 시 1.53x. §10.2 |
| NPU Latency | 미측정 | **125,845 cycle = 1.258 ms @100MHz**. §18.1 |
| FPGA Resource | 미측정 | **npu_core LUT 573 / FF 279 / BRAM 8 / DSP 12, 전체 시스템 LUT 1441** (배치배선 후). §18.1 |
| Timing | 미측정 | **100MHz MET. 전체 시스템 배치배선 후 WNS +0.782 ns, Fmax 108.5 MHz**. §18.1 |
| Conv 경계 규칙 | 미기재 | **Padding=1 / Cross-Correlation Freeze 완료** (공통스펙 v1.3 §8.1) |
| Tensor Memory Order | 미기재 | **CHW — C 승인 완료, B 확인 대기** (공통스펙 §7.4) |
| Golden 검증 | D3 Gate 예정 | **Conv1~4 + Argmax 전수 bit-exact PASS** (임시 weight 기준) |
| 신규 위험 | — | ~~Zybo board file 미설치~~ → **오기록. 이미 설치돼 있음, 해소.** §17.3 |
| AXI / SoC | 미착수 | **v1.3: Bitstream + XSA 생성 완료.** Register 기본 계약은 C 수용·구현 완료, Phase 3 확장은 A 회신 대기. 상세 요약은 `docs/A_NPU_HANDOFF.md` |

| 기구 구성 | Pan/Tilt 1개 (카메라+레이저 한 몸) | **v1.4: Pan/Tilt 2개로 분리.** PT#1 카메라 / PT#2 레이저. §16.1, §16.2 |

A Phase 1~3 상세 요약: `docs/A_NPU_HANDOFF.md`

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
└───────┬──────────────────────┬───────┘
        │                      │
        ▼                      ▼
┌───────────────┐      ┌──────────────────────┐
│ PT#1 제어      │      │ PT#2 제어             │
│ 화면중앙 유지   │──θ1─▶│ θ_target = θ1 + k·err │
│ (closed-loop) │      │ + LASER_OFFSET       │
└───┬───────┬───┘      └────┬────────────┬────┘
    ▼       ▼               ▼            ▼
  PAN1    TILT1           PAN2         TILT2
  Servo   Servo           Servo        Servo
    └───┬───┘               └─────┬──────┘
        ▼                         ▼
  ┌───────────┐            ┌───────────┐
  │Event Camera│  <=10cm   │  Laser    │
  └───────────┘            └───────────┘
```

> **v1.4 변경:** Pan/Tilt 가 2개다. PT#1 은 카메라를 표적에 겨누고,
> PT#2 는 레이저를 표적에 겨눈다. PT#2 각도는 PT#1 각도를 **더해서** 구한다.
> 상세: 공통 지침 v1.5 §15.2.

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

MVP는 여러 종류를 분류하거나 여러 표적을 동시에 추적하지 않는다.
팀이 미리 정한 **단일 시연 표적 한 종류의 위치**를 추론한다.

```text
입력: 실제 추적 표적의 움직임이 포함된 Event Tensor
출력: Target Heatmap
```

을 학습한다.

레이저 포인터는 CNN 입력의 의미상 Target이 아니며, 런타임에도 카메라 영상에서
레이저 점을 검출해 좌표를 만드는 경로를 사용하지 않는다.

---

## 7.2 Label 생성

사람이 모든 프레임을 직접 라벨링하지 않는다.

Label은 반드시 **실제 추적 표적의 중심 좌표**다. Dataset의 Event Tensor에도
같은 시점의 실제 표적 움직임이 들어 있어야 한다.

가능한 방법:

### 방법 A — Teacher Model

동기 RGB 영상이 있으면 PC에서 YOLO/MediaPipe/간단 Color Tracker 등으로 Target Center를 얻는다.

### 방법 B — 표적 디자인 이용

배경과 대비가 큰 원형/LED/색상 마커 Target을 사용해 OpenCV Color/Blob Detection으로
실제 표적 중심의 자동 좌표를 생성한다.

### 방법 C — 수동 일부 라벨

Teacher가 불안정한 구간만 보정한다.

> 모델 학습 자체가 프로젝트 핵심이 아니므로 **자동 라벨 + 소형 데이터셋**을 우선한다.

### 금지 — 레이저 점을 학습 Target으로 대체

```text
레이저 점만 화면에서 움직임
→ 같은 영상의 Frame Difference를 CNN 입력으로 사용
→ 검출한 레이저 좌표를 정답 Label로 사용
```

위 방식은 CNN이 실제 물체가 아니라 레이저 점의 움직임을 학습하게 만들 수 있으므로
최종 Dataset에 사용하지 않는다. `ai/dataset.py`의 기존 Red Laser 검출/Preview는
Dataset 규격과 좌표 Mapping을 확인했던 진단용 코드로만 취급하고, B가 실제 표적
검출기 또는 별도 Label 공급 방식으로 교체한다.

레이저 포인터에 필요한 작업은 학습이 아니라 §16.2의 좌표 변환과
`LASER_OFFSET_PAN/TILT` 실측 보정이다.

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

### v1.3 실측 결과 — 8 PE + AXI + Bitstream (전부 배치배선 후)

xc7z020clg400-1, 100 MHz 제약:

| 항목 | `npu_core` | `top_system` (+AXI) | **전체 시스템 (bitstream)** | 전체 | 비율 |
|---|---:|---:|---:|---:|---:|
| Slice LUT | 573 | 1060 | **1441** | 53200 | 2.71% |
| Slice Register | 279 | 849 | **1392** | 106400 | 1.31% |
| Block RAM Tile | 8 | 8 | **8** | 140 | 5.71% |
| DSP48E1 | 12 | 12 | **12** | 220 | 5.45% |

```text
Timing @100MHz : MET  (전부 배치배선 후 실측)
  npu_core 단독 (OOC)         WNS = +0.994 ns , WHS = +0.054 ns , Fmax 111.0 MHz
  top_system (+AXI, OOC)      WNS = +0.302 ns , WHS = +0.100 ns  (OOC 리셋트리 부재 인공물)
  전체 시스템 (bitstream)     WNS = +0.782 ns , WHS = +0.043 ns , Fmax 108.5 MHz
```

> **v1.2 의 LUT 1373 / WNS +0.266 ns / Fmax 102.7 MHz 는 무효다.**
> Vivado 가 PE 8개의 8×8 곱셈기를 LUT/CARRY4 로 합성하고 있었고
> (`DSP = 4` 는 전부 requantize 용이었다), `npu_pe` 에
> `(* use_dsp = "yes" *)` 한 줄을 넣어 전부 DSP48 로 옮긴 뒤 재측정했다.
> 그 결과 LUT 는 절반 이하로, 타이밍 여유는 2.7% → 7.8% 로 늘었다.
> v1.2 가 걱정한 "Phase 2 에서 100 MHz 를 놓칠 위험"은 해소됐다.

### 16 PE 확대 시 예상 (판단 근거 확보)

| Layer | 8 PE | 16 PE | 비고 |
|---|---:|---:|---|
| Conv1 | 35,843 | 35,843 | cout=8 이라 이득 없음 |
| Conv2 | 45,572 | 22,786 | 출력채널 블록 2→1 |
| Conv3 | 41,220 | 20,610 | 출력채널 블록 4→2 |
| Conv4 | 3,140 | 3,140 | cout=1 |
| 합계 | ~125.8k | ~82.4k | **1.53x** |

**결정: 8 PE 유지.** 리소스는 여유가 크지만 현재 Latency 1.258 ms가
Event Window 5~10 ms 대비 이미 4~8배 여유이므로 성능상 필요가 없다.
Dense NPU + Closed-loop Tracking 완성 후에도 시간이 남으면 그때 검토한다.

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
| `0x20` | `PAN_CMD` | RW | Pan Target — **PT#1 카메라 헤드** |
| `0x24` | `TILT_CMD` | RW | Tilt Target — **PT#1 카메라 헤드** |
| `0x28` | `LASER_CTRL` | RW | Laser Enable / Interlock |
| `0x2C` | `SAFE_LIMIT` | RW | **PT#1** Safe Limit |
| `0x48` | `PAN2_CMD` | RW | Pan Target — **PT#2 레이저 헤드** (v1.4) |
| `0x4C` | `TILT2_CMD` | RW | Tilt Target — **PT#2 레이저 헤드** (v1.4) |
| `0x50` | `SAFE_LIMIT2` | RW | **PT#2** Safe Limit (v1.4) |
| `0x54` | `LASER_CAL` | RW | 레이저 조준 보정 계수 (v1.4) |
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
- **PT#2 좌표 변환** (`theta_pan1 + k_x*(target_x-32) + LASER_OFFSET`)  ← v1.4
- **Servo 채널 4개** (PAN1/TILT1/PAN2/TILT2). PWM 생성기 인스턴스 2배  ← v1.4
- **PT#2 Safe Limit** — 헤드가 분리되면서 필수가 됨  ← v1.4

> Servo 4채널이면 **전류가 2배**다. §23 "Servo 전원 노이즈" 리스크가 커진다.
> 외부 5V 전원 용량을 다시 확인한다.

---

# 16. 레이저 포인터 설계

## 16.1 기구 구조 — **v1.4 변경: Pan/Tilt 2 헤드**

v1.3 까지는 카메라와 레이저를 **같은 Head** 에 고정하고
"레이저를 별도의 축으로 조준하지 않는다"고 못박았다. **v1.4 에서 이걸 바꾼다.**

```text
   PT#1                                 PT#2
 ┌──────────────┐                     ┌──────────────┐
 │ Event Camera │   baseline <=10cm   │ Laser Module │
 └──────────────┘                     └──────────────┘
 화면 중앙에 표적 유지                    표적 절대방향 조준
 closed-loop (P + Dead Zone)           open-loop + 상수 보정
```

바뀐 것과 안 바뀐 것:

| | v1.3 | **v1.4** |
|---|---|---|
| Pan/Tilt Head | 1개 (카메라+레이저) | **2개 (분리)** |
| Servo 채널 | 2 | **4** |
| 레이저 조준 | 카메라와 한 몸이라 자동 | **좌표 변환 필요 (§16.2)** |
| NPU / RTL (A) | — | **변경 없음.** `target_x/y` 그대로 |
| AXI Register | 0x20~0x34 | **+ 0x48~0x54** (기존 Offset 무변경) |

**왜 2개로 갔나:** 레이저가 독립 축을 가지면 카메라 정렬이 끝나기 전에도
표적을 조준할 수 있다 (§16.2 식이 잔차를 그대로 더하므로).
단일 헤드는 카메라가 다 돌아야 레이저도 맞았다.

---

## 16.2 좌표 변환 — **v1.4 신규, 이 절이 이번 변경의 핵심**

정본: 공통 지침 v1.5 §15.2 / `docs/D3_FREEZE_REQUEST_A_002.md` rev.2 §2.13.

**카메라가 움직인다.** 그래서 `error_x = target_x - 32` 는
카메라 각도에 **상대적인** 값이지 표적의 절대 방향이 아니다.

```text
k_x = FOV_X / 64   [deg/pixel]
k_y = FOV_Y / 64   [deg/pixel]

표적 절대 방향
  theta_pan_target  = theta_pan1  + k_x * (target_x - 32)
  theta_tilt_target = theta_tilt1 + k_y * (target_y - 32)

레이저 헤드 명령
  PAN2_CMD  = theta_pan_target  + LASER_OFFSET_PAN
  TILT2_CMD = theta_tilt_target + LASER_OFFSET_TILT
```

`theta_pan1` 은 Tracking Controller 가 방금 자기가 낸 `PAN_CMD` 값이다.
**센서 필요 없다. 그냥 더한다.**

```text
[절대 금지]  PAN2_CMD = f(error_x)
  -> 레이저가 표적이 아니라 "오차"를 따라간다.
     표적이 화면 중앙에 오면 레이저가 0도를 가리킨다.
```

`k_x` 의 **부호는 실측으로 정한다.** 서보 회전 방향 × 카메라 장착 방향에 따라 뒤집힌다.

### Parallax 와 MVP 보정

자동 7×7 캘리브레이션은 여전히 하지 않는다. baseline 이 10 cm 이하이고
시연 거리가 고정이면 시차가 **상수 오프셋으로 흡수**되기 때문이다.

| 시연 거리 | 시차각 `atan(0.1/D)` | 2 m 지점 환산 |
|---:|---:|---|
| 1.0 m | 5.7° | — |
| **2.0 m** | **2.9°** | **권장 시연 거리** |
| 3.0 m | 1.9° | — |

거리가 2.0 m ± 0.5 m 흔들리면 잔차 ±0.7° ≈ **±2.5 cm**.
표적판을 그보다 크게 만들면 된다.

보정 절차:

```text
1. 고정 거리 D(권장 2 m)에 표적을 둔다
2. PT#1 이 표적을 화면 중앙에 잡게 한다
3. 레이저가 표적에 맞을 때까지 PAN2_CMD / TILT2_CMD 를 손으로 조정한다
4. (PAN2_CMD - theta_pan_target) = LASER_OFFSET_PAN
5. 중앙 + 네 모서리 5 지점에서 측정해 평균  (LASER_CAL 0x54 에 저장 가능)
```

---

## 16.3 Laser ON 조건

다음 조건을 모두 만족할 때만 ON한다.

```text
TARGET_VALID == 1
RESULT_SCORE >= threshold
Target inside Safe Zone
PT#1 servo command inside SAFE_LIMIT   (0x2C)
PT#2 servo command inside SAFE_LIMIT2  (0x50)   <- v1.4 신규, 필수
|error_x| <= LOCK_ZONE_X
|error_y| <= LOCK_ZONE_Y
Emergency Stop == 0
```

> **헤드 2개가 되면서 새로 생긴 위험:**
> v1.3 은 카메라와 레이저가 한 몸이라 "화면에 보이는 것만 쏜다"가
> **기구적으로 자동 보장**됐다. 헤드를 분리하면 그 보장이 사라진다.
> §16.2 좌표 변환의 부호가 뒤집히거나 계수가 틀리면
> **레이저 헤드가 카메라 시야 밖을 조준한다.**
> `SAFE_LIMIT2` 는 선택이 아니라 필수이고, 좌표 변환 첫 검증은 **반드시 LED 로** 한다.

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
- Pan/Tilt 하드웨어/소프트 리밋 적용 — **두 헤드 다** (v1.4)
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

## 17.3 Toolchain 확보 상태 (v1.2 신규)

| 항목 | 상태 | 비고 |
|---|---|---|
| Vivado 2024.2 | **확보** | `/media/user7/data/tools/Vivado/2024.2` |
| Vitis 2024.2 | **확보** | 동일 경로 |
| xsim (시뮬레이터) | **확보** | RTL 회귀 검증에 사용 중 |
| xc7z020 device 파일 | **확보** | 합성 확인 완료 |
| **Zybo Z7-20 board file** | **확보 (v1.3 정정)** | `~/.Xilinx/Vivado/2024.2/xhub/board_store/...` — 다운로드 불필요 |

### Zybo Z7-20 board file — v1.2 의 "미설치" 는 오기록이었다 (v1.3 정정)

v1.2 는 board file 이 없다고 적고 다운로드 방법까지 안내했다.
**틀린 기록이다.** Vivado **설치 폴더**(`<Vivado>/data/boards/`)에 없었을 뿐,
Vivado 가 실제로 읽는 **사용자 홈의 xhub 캐시**에 이미 들어 있다.

```text
실제 위치
  ~/.Xilinx/Vivado/2024.2/xhub/board_store/xilinx_board_store
      /XilinxBoardStore/Vivado/2024.2/boards/Digilent/zybo-z7-20/
          1.1/1.1/{board.xml, part0_pins.xml, preset.xml, xitem.json}
          A.0/1.0/...

확인 방법
  set_param board.repoPaths [list "$::env(HOME)/.Xilinx/Vivado/2024.2/xhub/board_store/xilinx_board_store"]
  get_board_parts *zybo*
  -> digilentinc.com:zybo-z7-10:part0:1.0 / 1.1
     digilentinc.com:zybo-z7-20:part0:1.0 / 1.1
```

`sim/run_bd.tcl` 이 이 경로를 자동으로 지정한다. **다운로드할 것 없다.**
실제로 이 board file 로 Block Design 을 만들고 Bitstream 까지 뽑았다
(`docs/A_NPU_HANDOFF.md` 요약 기준, 해당 A 산출물은 현재 저장소 미병합).

참고: board file 은 XDC 가 아니다. XDC 는 "내가 만든 포트를 어느 핀에 붙일지"를
쓰는 텍스트 제약이고, board file 은 "이 보드에 뭐가 달려 있는지"를 Vivado 에게
알려주는 메타데이터(board.xml / part0_pins.xml / preset.xml)다.
Zynq PS 의 DDR3 타이밍·MIO·클럭 preset 이 여기서 자동으로 채워진다.

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

### v1.3 실측 완료분 — A NPU Core + SoC (a_npu_v01 / a_soc_v01)

아래는 **실측값**이다. 발표/보고 시 이 값을 그대로 쓴다.

```text
대상    : xc7z020clg400-1 (Zybo Z7-20)
제약    : 100 MHz
측정    : 전부 place & route 후 (합성 추정치 아님, §35)

                        LUT    FF     BRAM   DSP    WNS        Fmax
npu_core 단독 (OOC)      573    279    8      12     +0.994 ns  111.0 MHz
top_system (+AXI, OOC)  1060    849    8      12     +0.302 ns  (OOC 인공물)
전체 시스템 (bitstream) 1441   1392    8      12     +0.782 ns  108.5 MHz

전체 대비 : LUT 2.71% / FF 1.31% / BRAM 5.71% / DSP 5.45%
산출물    : results/npu_soc.bit , results/npu_soc.xsa
```

**Fmax 는 배치배선 후 실측값이다.** 합성 추정치를 보고하지 않는다 (§35).

NPU Cycle Count (레이어별):

| Layer | 누적 cycle | 구간 cycle |
|---|---:|---:|
| Conv1 | 35,843 | 35,843 |
| Conv2 | 81,415 | 45,572 |
| Conv3 | 122,635 | 41,220 |
| Conv4 | 125,775 | 3,140 |
| Argmax + 종료 | **125,845** | 70 |

```text
NPU Inference = 125,845 cycle = 1.258 ms @ 100 MHz
Event Tensor 전송 = 8,192 cycle = 82 us
```

데이터 의존성이 없는 고정 구조라 실제 weight로 바꿔도 cycle 수는 동일하다.

**아직 미측정:** CPU FP32/INT8 Baseline(B 담당), Tracking MAE(C 담당),
Servo 응답시간(C 담당), 최종 Fmax(Implementation 후).

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
Event Window        : XX ms          <- C 측정 예정
Tensor Transfer     : 0.082 ms       <- 실측 (8,192 cycle @100MHz)
NPU Inference       : 1.258 ms       <- 실측 (125,845 cycle @100MHz)
Target Decode       : 0.0007 ms      <- 실측 (Argmax 70 cycle, NPU Inference에 포함)
Control Generation  : XX us          <- C 측정 예정
Servo Response      : XX ms          <- C 측정 예정
```

현재 A 담당 구간은 전송 + 추론 합계 **약 1.34 ms**로 확정되었다.
Event Window(5~10 ms) 대비 4~8배 여유이므로 병목은 A 구간이 아니다.

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

- 실제 추적 표적의 움직임이 포함된 데이터 수집
- 실제 표적 중심 자동 라벨 생성 (레이저 점 Label 사용 금지)
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
| **D4** | PE Array + Dense Conv1 RTL, 첫 합성, PE 수 확정 | Conv1 Golden PASS ✅ **A 완료** |
| **D5** | Dense Conv2/3/4 + Buffer/Address | Layer별 PASS ✅ **A 완료** |
| **D6** | Requantize + Full Dense NPU | Full Golden PASS ✅ **A 완료** |
| **D7** | Layer Sequencer + AXI + Cycle Counter + Argmax | Sequencer/Argmax/Cycle ✅ **완료** / AXI·BD **진행 중** |
| **D8** | 실제 Event Source와 Dense NPU 통합 / Fallback 결정 | 실시간 Event Tensor → NPU |
| **D9** | Tracking Controller + **PT#1(카메라 헤드)** Centering | Target Centering |
| **D10** | Closed-loop 안정화 + **PT#2 좌표 변환(§16.2) LED 검증** | 반복 추적 성공 |
| **D11** | **LASER_OFFSET 실측** + Interlock + SAFE_LIMIT2 통합 | **GATE B** |
| **D12** | CPU vs Dense NPU Latency, Cycle, Resource 측정 | 정량 데이터 확보 |
| **D13** | 반복 궤적 Tracking Test / 병목 수정 / **여유 시 Sparse Conv1 실험** | Demo 안정화 우선 |
| **D14** | PPT/보고서/그래프/Block Diagram | 발표 자료 |
| **D15** | 최종 리허설, 영상 촬영, Backup Demo 준비 | 제출/발표 |

## 21.1 v1.2 시점 진척 (2026-08-21)

```text
A : NPU Core + AXI-Lite + Block Design + PS 소프트웨어 완료.
    임시 weight/golden으로 Conv1~4 + Argmax 전수 bit-exact PASS, 100MHz Timing MET.
    A 제공 기록 기준 2026-08-24 Zybo Z7-20 A-only 기능 판정 16/16 PASS.
    남은 작업은 B 실제 weight/golden 재검증과 C 실제 모듈 전체 통합.

B : Dataset 파이프라인(ai/dataset.py) 작성, Webcam Frame Difference 경로.
    Conv 경계 규칙 Freeze 요청 -> A 승인 완료.
    남은 작업 = CNN 학습 / INT8 / Integer Golden / Test Vector 3종.

C : Event Adapter/Accumulator, 4축 Servo, PT#2 좌표 변환, Fail-Closed Interlock,
    A Phase 3 연동 래퍼와 KY-008 수동 재무장/100 ms Gate 준비 완료.
    C 자동판정 12종 287 PASS. 기존 D6 C 래퍼 100 MHz OOC 타이밍 확인.
    남은 작업은 A 실제 RTL 통합, KY-008 소비전류/default-OFF/물리 E-stop 승인, 카메라 Closed-loop,
    실제 광출력 확인과 2 m Offset 실측.
```

**GATE A(D3)는 B의 Integer Golden Model 제출로만 최종 통과된다.**
A쪽 RTL은 임시 Golden으로 선행 검증되어 있어, B 실물 도착 시
파일 교체 후 동일 Testbench 재실행만으로 GATE A 판정이 가능하다.

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
| RTL/Golden 불일치 | D4~D6 | Layer별 bit-exact 검증 — **A쪽 선행 검증 완료, 해소** |
| DSP/LUT 초과 | D4 | PE 16→8 또는 Time Multiplex — **LUT 2.58% 실측, 해소** |
| **Timing 미달** | D4 | **발생함 → 해소.** 조합 Requantize 20.6ns → 4단 파이프라인, MAC 곱셈/누산 분리, `npu_pe` DSP 강제. 전체 시스템 배치배선 후 WNS **+0.782ns** |
| **Timing 여유 부족 (재발 위험)** | **D7** | **v1.2 의 2.7% → 현재 7.8% 로 해소.** 다만 C 모듈 추가 시 재발 가능하므로 모듈을 붙일 때마다 `sim/run_bd.tcl` 로 재측정. Fallback 유지: PS FCLK 50MHz (Latency 2.52ms, Window 대비 여전히 여유) |
| ~~Zybo board file 미설치~~ | — | **오기록이었다. 해소.** `~/.Xilinx/.../xhub/board_store` 에 이미 존재하며 이 파일로 Bitstream 생성 완료 (§17.3) |
| **A/C 전체 시스템 통합 지연** | **D7~D9** | C 래퍼는 완료됐다. A 실제 `top_system/npu_axi` 합류 후 `INPUT_SRC`, START MUX, 신규 RO 상태와 전체 타이밍을 검증한다. |
| **Argmax 동점 처리 규칙 부재** | D6 | **발견·해소.** FIRST_MAX 규칙 명문화 (공통스펙 v1.3 §14.2). 동점 프레임에서만 좌표가 어긋나는 은닉형 불일치였음 |
| Sparse/Zero-Skip 미학습·구조 복잡 | D12~D13 | 기본 일정에서 제외, Dense NPU 완성 후 선택 실험 |
| Servo 진동/Overshoot | D10 | Dead Zone, P Gain 감소, Slew Limit |
| **PT#2 좌표 변환 부호 반대** | **D10** | **레이저가 표적 반대쪽으로 간다.** LED 로 먼저 검증하고 `k_x` 부호를 실측으로 정한다 (§16.2). 이번 변경에서 제일 잘 틀리는 곳 |
| **PT#2 를 error 기준으로 오구현** | **D10** | `PAN2_CMD = f(error_x)` 로 짜면 레이저가 표적이 아니라 오차를 따라간다. §16.2 식 강제 |
| **Servo 4채널 전류 초과** | **D9** | 채널이 2→4로 늘어 전류 2배. 외부 5V 전원 용량 재확인, 보드 5V 에서 뽑지 말 것 |
| **레이저가 카메라 시야 밖 조준** | **D10~D11** | 헤드 분리로 기구적 보장이 사라짐. `SAFE_LIMIT2`(0x50) 필수 적용 + LED 선검증 (§16.3) |
| Servo 전원 노이즈 | 즉시 | 외부 5V Servo 전원, GND 공통 |
| Laser Offset 변화 / Parallax | D11 | 고정 거리(권장 2 m) 시연, 5지점 Offset 실측. baseline<=10cm 이면 잔차 ±2.5cm (§16.2) |
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

**문서 버전:** v1.4 — Pan/Tilt 2 헤드 구성 반영본 (2026-08-22 Dataset/Label 운영 정정 포함)
**이전 버전:** v1.3 A Phase 1 + Phase 2 실측 반영본
**상태:** Sparse·Zero-Skip 선택 확장 유지 / A Phase 1~4 기록 반영 / **Pan/Tilt 2 헤드·KY-008 C 독립 단발 완료, 물리 안전 승인·A 전체 통합 대기**
**갱신일:** 2026-08-26
**동반 문서:** 공통 지침 v1.5, 역할분담 v1.6, `docs/A_NPU_HANDOFF.md`, `docs/D3_FREEZE_REQUEST_A_002.md`, `docs/integration_manifest.md`
