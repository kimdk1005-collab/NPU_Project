# [D3 FREEZE REQUEST] A → B/C  #001

> **성격:** 기존 Freeze 값 변경 아님.
> `TEAM_COMMON_AI_INTEGRATION_SPEC v1.2 §21` 체크리스트에서 **아직 빈칸인 항목**을
> A가 NPU RTL 구현 결과를 근거로 채우는 요청이다.
> v1.2에서 이미 확정된 항목(Weight Layout / Bias / Rounding / Requantize / Clamp /
> Heatmap Mapping)은 **하나도 건드리지 않는다.**
>
> 형식: 공통 스펙 §22

---

```text
[CHANGE REQUEST]

요청자: A
날짜:   2026-08-21
변경 항목:
  1. Tensor Memory Order            (§21 빈칸)
  2. Conv Padding                   (전 문서 미기재)
  3. Argmax Tie-Break Rule          (전 문서 미기재)
  4. target_valid 생성 조건         (전 문서 미기재)
  5. NPU Input Buffer Interface     (§21 빈칸)
```

---

## 1. Tensor Memory Order

```text
기존:   미확정 (§21 체크리스트 빈칸)

변경안:
  TENSOR_MEMORY_ORDER = CHW
  ADDR = (c << (2*log2(W))) + (y << log2(W)) + x
```

레이어별:

| 텐서 | Shape | 주소식 | 크기 |
|---|---|---|---:|
| Event Tensor | 2×64×64 | `(c<<12)+(y<<6)+x` | 8192 B |
| Conv1 출력 | 8×32×32 | `(c<<10)+(y<<5)+x` | 8192 B |
| Conv2 출력 | 16×16×16 | `(c<<8)+(y<<4)+x` | 4096 B |
| Conv3 출력 | 32×8×8 | `(c<<6)+(y<<3)+x` | 2048 B |
| Conv4 출력 | 1×8×8 | `(y<<3)+x` | 64 B |

```text
변경 이유:
  B의 .hex 덤프 순서와 C의 Tensor write 주소가 이 값에 직접 걸린다.
  확정 없이 각자 진행하면 Golden 비교 시 전 채널이 어긋난다.
  CHW 를 고르는 이유: PyTorch (C,H,W) 텐서의 flatten() 순서와 동일해서
  B가 transpose 없이 그대로 덤프하면 되고, RTL 주소가 전부 shift 연산으로 끝난다.

영향 담당:
- A: npu_conv_dense.v 주소생성기 (구현 완료)
- B: integer_golden.py 의 hex 덤프 순서
- C: event_accumulator.v 의 write 주소
```

---

## 2. Conv Padding

```text
기존:   전 문서 미기재
변경안:
  CONV1_PAD = 1   (zero padding, 상하좌우 대칭)
  CONV2_PAD = 1
  CONV3_PAD = 1
  CONV4_PAD = 0   (1x1 / stride 1)
  PAD_VALUE = 0
```

```text
변경 이유:
  값을 새로 정하는 게 아니라 §8 고정 출력 형상에서 유일하게 결정되는 값이다.

    out = floor((in + 2*pad - k)/stride) + 1

    pad=1 : 64->32, 32->16, 16->8   (§8과 일치)
    pad=0 : 64->31, 32->15, 16->7   (§8과 불일치)

  즉 §8을 지키는 한 pad=1 외의 선택지가 없다. 문서에만 빠져 있었다.

B 확인 요청 (1줄 회신):
  nn.Conv2d(..., padding=?) 가 Conv1~3 모두 1 인지 확인.
  다르면 §8 출력 형상이 안 나오므로 모델 재확인 대상.
  (불일치해도 A의 Conv1 Golden 전수 비교에서 즉시 검출됨)
```

---

## 3. Argmax Tie-Break Rule

```text
기존:   전 문서 미기재
        §14.1 은 좌표 Mapping 만 정하고, 최대값이 2개 이상일 때 규정이 없음

변경안:
  ARGMAX_SCAN_ORDER = raster (addr = y*8 + x, Y major / X minor)
  ARGMAX_TIE_RULE   = FIRST_MAX
  ARGMAX_COMPARE    = signed INT8, strict '>'
```

```text
변경 이유:
  이 규칙이 없으면 RTL 과 Golden 이 조용히 갈린다.
  RTL 이 '>=' 비교를 쓰면 LAST_MAX 가 되고, numpy.argmax 는 FIRST_MAX 다.
  대부분 프레임은 최대값이 유일해서 통과하다가, 동점 프레임에서만
  좌표가 8픽셀 튀는 형태로 나타난다. 디버깅이 매우 어려운 종류의 불일치다.

B 쪽 대응:
  np.argmax(heatmap.reshape(-1)) 를 그대로 쓰면 자동으로 일치한다.
  np.where(h == h.max()) 계열이나 axis 조합 변형을 쓰지 않는다.

영향 담당:
- A: argmax_decoder.v (strict '>' 로 구현 완료)
- B: integer_golden.py 의 argmax 구현
- C: 영향 없음
```

---

## 4. target_valid 생성 조건

```text
기존:   §16 은 target_valid == 0 일 때 C 의 동작만 규정.
        무엇이 0 을 만드는지는 어느 문서에도 없음.

변경안:
  target_valid = (heatmap_max_score > SCORE_TH)
  SCORE_TH     = signed INT8, NPU 입력 포트 (추후 AXI 레지스터로 노출)
  SCORE_TH_DEFAULT = 0
```

```text
변경 이유:
  C 의 Target Lost 처리(§16)와 Laser Interlock(§17)이 이 신호에 걸려 있는데
  생성 주체가 A 라서 A 가 정의해야 한다.

B 확인 요청:
  표적이 없는 프레임의 Heatmap max score 분포를 알려주면 SCORE_TH 실값을 확정한다.
  그 전까지 기본값 0 (score > 0 이면 valid) 으로 둔다.

영향 담당:
- A: argmax_decoder.v (구현 완료, 임계값 포트화)
- B: 표적 없는 프레임 score 분포 제공
- C: target_valid 의미 확정 (§39 "A→C: target_valid 의미 일치" 항목)
```

---

## 5. NPU Input Buffer Interface

```text
기존:   §21 빈칸 / §7.3 · §21.2 에서 계속 TBD

변경안 (MVP):
  input wire        ext_we;
  input wire [12:0] ext_addr;    // 1번 항목의 CHW 주소
  input wire signed [7:0] ext_data;

  규칙:
    - npu_core 의 busy == 0 일 때만 유효
    - 1 byte / cycle, 8192 cycle = 82 us @100MHz
    - C: event_window_end -> Tensor 전송 -> NPU start
```

```text
변경 이유:
  §7.3 이 나열한 5개 후보(BRAM 공유 / Ping-Pong / AXI-Stream / Memory-Mapped /
  Direct Handshake) 중 Direct Handshake 를 고른 것이다.
  AXI-Stream 이나 DMA 는 2주 일정에서 검증 비용이 크고,
  8192 byte 전송이 82 us 로 Event Window(5~10 ms) 대비 무시할 수준이라
  가장 단순한 방식으로 충분하다.

알려진 제약:
  현재 입력 Tensor 가 내부 activation ping-pong 버퍼 중 하나를 공유한다.
  -> NPU 추론 중에는 다음 Window Tensor 를 미리 쓸 수 없다.
  -> 현재 Latency 1.258 ms << Window 5~10 ms 라 MVP 에서는 문제 없음.
  -> 연속 스트리밍이 필요해지면 입력 전용 8KB 버퍼 1개(BRAM 4개) 추가.
     현재 BRAM 사용률 5.71% 라 여유 충분.

영향 담당:
- A: npu_core.v ext_* 포트 (구현 완료)
- B: 영향 없음
- C: event_accumulator.v 출력단
```

---

## 공통 영향 정리

```text
Golden Model 영향:
  B - hex 덤프 순서 CHW 확인, argmax 를 np.argmax 로 유지. 로직 변경 없음.

RTL 영향:
  A - 구현 완료 (rtl/npu/*.v)
  C - event_accumulator write 주소식만 확정

Testbench 영향:
  A - tb_npu_requant / tb_npu_pe / tb_npu_conv_dense / tb_npu_full 전부 PASS

Vivado 영향:
  없음 (Block Design 미착수)

Vitis 영향:
  없음 (미착수)

기존 Test Vector 재생성 필요 여부:
  없음. B 는 아직 A 에게 Test Vector 를 전달한 적이 없다.
  현재 A 는 tools/gen_dummy.py 의 임시 벡터로 검증 중이며,
  B 실물이 오면 파일만 교체하고 동일 TB 를 재실행한다.

예상 Merge Conflict:
  docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md  (§21 체크리스트 + §43 변경이력)
  -> 승인 후 A 가 v1.3 으로 한 번에 반영한다.
```

---

## 팀 승인

```text
A: [x] 2026-08-21
B: [ ]
C: [ ]
```

> B/C 승인 후 A 가 `TEAM_COMMON_AI_INTEGRATION_SPEC.md` 를 **v1.3** 으로 갱신한다.
> 승인 전까지 공통 스펙 파일은 v1.2 그대로 둔다 (§23).
