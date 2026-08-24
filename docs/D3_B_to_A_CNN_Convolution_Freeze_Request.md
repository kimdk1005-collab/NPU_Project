# D3 B → A CNN Convolution 경계 규칙 Freeze 요청서

## 1. 문서 상태

- 작성 담당: B
- 요청 대상: A
- 상태: **승인 대기 / TBD**
- 적용 우선순위: 요청 당시 공통 지침 v1.2 준수. 현재 정본은 `TEAM_COMMON_AI_INTEGRATION_SPEC.md`
- 원칙: 승인 전에는 `train.py`, `quantize.py`, `integer_golden.py`와 RTL Address Generator에 본 제안을 확정값으로 반영하지 않는다.

## 2. 요청 사유

공통 지침 v1.2에는 다음 CNN 출력 형상이 고정돼 있다.

```text
Conv1: 64×64×2  → 32×32×8   / Kernel 3×3 / Stride 2
Conv2: 32×32×8  → 16×16×16  / Kernel 3×3 / Stride 2
Conv3: 16×16×16 →  8×8×32   / Kernel 3×3 / Stride 2
Conv4:  8×8×32  →  8×8×1    / Kernel 1×1 / Stride 1
```

하지만 아래 항목은 명시돼 있지 않다.

```text
Conv1~3의 경계 Padding 값과 방식
Kernel 180도 반전 여부
경계 밖 Input의 처리값
Output 좌표와 Input 좌표의 정확한 대응식
```

이 규칙이 다르면 같은 OIHW Weight를 사용해도 PyTorch FP32, Python Integer Golden, A의 RTL NPU 결과가 일치하지 않는다.

## 3. B 권장 Freeze안

### 3-1. Conv1~Conv3

```text
KERNEL          = 3×3
STRIDE          = 2
PADDING         = 1
PADDING_MODE    = 대칭 Zero Padding
PADDING_TOP     = 1
PADDING_BOTTOM  = 1
PADDING_LEFT    = 1
PADDING_RIGHT   = 1
OUT_OF_RANGE    = 0
KERNEL_FLIP     = 없음
OPERATION       = PyTorch Conv2d 방식의 Cross-Correlation
BIAS            = 없음
```

출력 `(oy, ox)`의 누산식은 다음과 같이 제안한다.

```text
acc[o, oy, ox]
  = Σ input[i, oy×2 + ky - 1, ox×2 + kx - 1]
      × weight[o, i, ky, kx]

i  = 0 ... CIN-1
ky = 0 ... 2
kx = 0 ... 2
```

`input_y` 또는 `input_x`가 유효 범위를 벗어나면 해당 Input 값은 `0`으로 처리한다. Weight는 `[O][I][KY][KX]`를 그대로 사용하며 `KY/KX`를 뒤집지 않는다.

### 3-2. Conv4

```text
KERNEL          = 1×1
STRIDE          = 1
PADDING         = 0
KERNEL_FLIP     = 없음
BIAS            = 없음
```

```text
acc[0, y, x] = Σ input[i, y, x] × weight[0, i, 0, 0]
```

### 3-3. 출력 형상 확인

제안값을 적용하면 다음 고정 형상을 만족한다.

```text
Conv1: 32×32×8
Conv2: 16×16×16
Conv3:  8×8×32
Conv4:  8×8×1
```

## 4. 기존 Label Mapping의 `Padding 없음`과 구분

공통 지침 v1.2의 Label Mapping에 적힌 `Crop 없음 / Padding 없음`은 원본 좌표를 64×64 좌표로 변환할 때 영상 외곽을 추가하거나 좌표를 이동하지 않는다는 의미다.

본 요청의 `Conv Padding=1`은 CNN 내부의 3×3 MAC 경계 처리 규칙이다. 두 Padding은 적용 단계와 목적이 다르며 서로 충돌하지 않는다.

## 5. 승인 요청 항목

A는 다음 항목을 검토해 달라.

- [ ] Conv1 Padding = 대칭 Zero Padding 1
- [ ] Conv2 Padding = 대칭 Zero Padding 1
- [ ] Conv3 Padding = 대칭 Zero Padding 1
- [ ] Conv4 Padding = 0
- [ ] 경계 밖 Input = 0
- [ ] PyTorch Conv2d Cross-Correlation 사용
- [ ] Kernel 180도 반전 없음
- [ ] 출력 `(oy, ox)`의 Input 시작 좌표 = `(oy×stride-padding, ox×stride-padding)`
- [ ] OIHW Weight `[O][I][KY][KX]`를 그대로 MAC에 사용

## 6. 역할 및 영향 범위

| 담당 | 수행할 일 | 수행하지 않을 일 |
|---|---|---|
| B | 규칙 제안, 승인 후 FP32/INT8/Golden/Test Vector에 동일 적용 | NPU RTL 수정 |
| A | 규칙 검토·승인, Conv Address Generator와 RTL Testbench에 반영 | B의 학습 코드 구현 |
| C | 영향 없음 | CNN/RTL 규칙 결정 |

본 요청은 B가 Golden 기준을 제안하고 A가 RTL 영향까지 검토해 Freeze하는 절차이므로 역할 침해가 아니다.

## 7. 변경 영향

- B 영향 파일: `train.py`, `quantize.py`, `integer_golden.py`, Layer Dump
- A 영향 파일: Dense Conv RTL, Address Generator, 관련 Testbench
- Weight Layout: 기존 OIHW 유지
- Bias: 기존 `bias=False` 유지
- Quantization 규칙: 변경 없음
- Tensor Physical Transfer/Memory Order: 계속 TBD, 본 요청에서 확정하지 않음
- 기존 Dataset/Label Mapping: 변경 없음

## 8. 승인 기록

```text
A 승인: [ ] 승인  [ ] 수정 요청
B 확인: [ ] 확인

확정 Padding:
확정 Kernel 연산 방식:
확정 날짜:
적용 문서/Version:
비고:
```

승인 완료 전까지 본 문서의 값은 **권장 제안이며 Freeze 값이 아니다.**
