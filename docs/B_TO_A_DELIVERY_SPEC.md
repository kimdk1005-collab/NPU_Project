# B → A 전달 규격 (A가 요청하는 최종 형식)

> **작성:** A
> **대상:** B
> **기준:** `TEAM_COMMON_AI_INTEGRATION_SPEC.md` v1.2 §10 / §11.1 / §12 / §39
> **목적:** B의 산출물을 A가 **파일만 덮어쓰고 바로 회귀 테스트**할 수 있는 형식으로 고정

A쪽 NPU RTL과 Testbench는 이미 완성·검증되어 있다.
아래 형식만 지켜 주면 **A는 TB를 수정하지 않고** 그대로 돌려서 layer별 bit-exact를 확인한다.

---

## 1. 전달 위치

```text
NPU_Project/
├─ weights/
│   ├─ conv1_weight_int8.mem
│   ├─ conv2_weight_int8.mem
│   ├─ conv3_weight_int8.mem
│   ├─ conv4_weight_int8.mem
│   ├─ requant_M.mem
│   └─ scales.json
│
└─ test_vectors/
    ├─ case00/          <- Test Vector 1번
    ├─ case01/          <- 2번
    └─ case02/          <- 3번  (spec §39: 최소 3개)
```

`w_bank0..7.mem`은 **B가 만들 필요 없다.** A가 `tools/pack_weights.py`로 변환한다.

---

## 2. Weight 파일 — `weights/`

| 파일 | 줄 수 | 순서 |
|---|---:|---|
| `conv1_weight_int8.mem` | 144 | OIHW `[O][I][KY][KX]`, KX fastest |
| `conv2_weight_int8.mem` | 1152 | 동일 |
| `conv3_weight_int8.mem` | 4608 | 동일 |
| `conv4_weight_int8.mem` | 32 | 동일 |

형식 (spec §11.1):

```text
1 line = 1 weight
8-bit two's complement, 대문자 HEX 2자리
헤더/주석/빈 줄 없음
```

예 (`conv1_weight_int8.mem` 앞부분):

```text
1A
FF
80
7F
```

주소식 확인:

```text
addr = ((((oc * CIN) + ic) * KH + ky) * KW + kx)
```

Python 덤프 1줄:

```python
w = state_dict["conv1.weight"]          # (O, I, KY, KX) INT8
open("weights/conv1_weight_int8.mem","w").write(
    "\n".join("%02X" % (int(v) & 0xFF) for v in w.reshape(-1)) + "\n")
```

---

## 3. Requantize 파라미터 — `weights/requant_M.mem`

```text
4 line, 각 32bit 대문자 HEX 8자리
Conv1 -> Conv2 -> Conv3 -> Conv4 순서
```

예:

```text
0000A0A5
0001E84D
0000655F
00014C2A
```

```text
M = RoundAwayFromZero( (input_scale * weight_scale / output_scale) * 2^24 )
SHIFT = 24 고정  (spec §9.4)
M > 0xFFFFFFFF 이면 Saturation 하지 말고 A에게 알릴 것
```

---

## 4. Scale 메타 — `weights/scales.json`

A가 자동 검사에 쓴다. 최소 아래 키를 포함한다 (spec §10 Handoff 항목).

```json
{
  "model_version": "model_v01",
  "weight_version": "weight_v01",
  "golden_version": "golden_v01",
  "test_vector_version": "testvec_v01",
  "tensor_order": "CHW",
  "shift": 24,
  "layers": {
    "conv1": {"cin":2,"cout":8,"k":3,"stride":2,"pad":1,
              "in_hw":64,"out_hw":32,"relu":true,
              "input_scale":0.0,"weight_scale":0.0,"output_scale":0.0,
              "multiplier":0,"shift":24,"clamp":[0,127]},
    "conv2": {"...": "..."},
    "conv3": {"...": "..."},
    "conv4": {"...": "...", "relu": false, "clamp": [-128,127]}
  }
}
```

---

## 5. Test Vector — `test_vectors/caseNN/`

case 하나당 아래 6개 파일. **전부 CHW 순서.**

| 파일 | 줄 수 | 내용 | 텐서 |
|---|---:|---|---|
| `input_event.hex` | 8192 | Conv1 입력 Event Tensor | `(2,64,64)` |
| `conv1_out.hex` | 8192 | Conv1 requant 후 INT8 | `(8,32,32)` |
| `conv2_out.hex` | 4096 | Conv2 출력 | `(16,16,16)` |
| `conv3_out.hex` | 2048 | Conv3 출력 | `(32,8,8)` |
| `conv4_out.hex` | 64 | Heatmap (ReLU 없음, signed) | `(1,8,8)` |
| `result_xy.txt` | 5 | Argmax 결과 | — |

형식: weight와 동일 (1 line = 1 byte, two's complement HEX 2자리).

### 5-1. CHW 변환 (중요)

`dataset.py`는 HWC `(64,64,2)`로 저장한다. **덤프할 때 CHW로 바꿔야 한다.**

```python
tensor_chw = np.transpose(tensor_hwc, (2, 0, 1))     # (2, 64, 64)
flat = tensor_chw.reshape(-1)
```

PyTorch 중간 출력은 이미 `(C,H,W)`라 `tensor.reshape(-1)` 그대로면 된다.

주소식:

```text
addr = (c << 2*log2(W)) + (y << log2(W)) + x

input_event : (c<<12) + (y<<6) + x     c=0 Positive, c=1 Negative
conv1_out   : (c<<10) + (y<<5) + x
conv2_out   : (c<<8)  + (y<<4) + x
conv3_out   : (c<<6)  + (y<<3) + x
conv4_out   :           (y<<3) + x
```

### 5-2. `result_xy.txt` 형식

**정확히 5줄, `키 공백 정수`.** A의 TB가 이 순서로 파싱한다.

```text
heatmap_x 5
heatmap_y 2
target_x 44
target_y 20
target_score 118
```

```text
heatmap_x/y  = 0~7
target_x/y   = heatmap * 8 + 4   (4,12,20,28,36,44,52,60 중 하나)
target_score = signed INT8, Conv4 Heatmap 최대값
argmax       = np.argmax(heatmap.reshape(-1))   <- raster FIRST_MAX
```

> **동점 주의:** `np.argmax`를 그대로 쓸 것.
> `np.where(h == h.max())` 계열이나 axis 조합을 쓰면 동점 프레임에서 RTL과 갈린다.

### 5-3. case 3개 구성 권장

```text
case00 : 표적이 화면 중앙 근처
case01 : 표적이 모서리 (padding 경계 검증용)
case02 : 표적 없음 또는 score 낮은 프레임 (target_valid 검증용)
```

`case01`이 중요하다. Padding=1 경계 처리가 틀리면 여기서만 깨진다.

---

## 6. Handoff 문서 — `handoff/B_MODEL_HANDOFF.md`

spec §26 필수 항목:

```text
Model Version / Input Shape / Layer Shape / Weight Layout
Quantization Parameter / Rounding / Clamp
Weight Files / Golden Files / Accuracy / CPU Baseline
```

`docs/A_NPU_HANDOFF.md`를 형식 참고용으로 쓰면 된다.

---

## 7. 전달 방법

### 방법 1 — Git (권장, spec §24)

```bash
git checkout -b feature/b-model
git add weights/ test_vectors/ ai/ handoff/B_MODEL_HANDOFF.md
git commit -m "[B][GOLDEN] Export weight_v01 / golden_v01 / testvec_v01"
git push origin feature/b-model
```

A가 `integration` 브랜치에서 받아 회귀한다.

### 방법 2 — 압축 전달

```text
b_deliver_v01.zip
├─ weights/            (6 파일)
├─ test_vectors/case00/ case01/ case02/
└─ handoff/B_MODEL_HANDOFF.md
```

어느 쪽이든 **`weights/`와 `test_vectors/` 폴더 구조를 그대로 유지**한다.

---

## 8. A가 받고 하는 일 (B는 안 해도 됨)

```bash
python3 tools/pack_weights.py                        # OIHW -> 8 bank
TV_DIR=../test_vectors/case00/ ./sim/run_sim.sh      # 회귀
TV_DIR=../test_vectors/case01/ ./sim/run_sim.sh
TV_DIR=../test_vectors/case02/ ./sim/run_sim.sh
```

결과는 layer별 전수 비교로 나온다:

```text
[PASS] Conv1  8192 bytes 전부 일치
[PASS] Conv2  4096 bytes 전부 일치
[PASS] Conv3  2048 bytes 전부 일치
[PASS] Conv4    64 bytes 전부 일치
[PASS] tb_npu_full : Golden Model 완전 일치
```

불일치가 나면 A가 **어느 레이어 몇 번째 byte**인지까지 알려준다.

---

## 9. B 체크리스트

- [ ] `conv{1..4}_weight_int8.mem` 4개, OIHW, 줄 수 144/1152/4608/32
- [ ] `requant_M.mem` 4줄, 32bit hex
- [ ] `scales.json`
- [ ] `test_vectors/case00,01,02/` 각 6파일
- [ ] 모든 `.hex`가 **CHW** 순서
- [ ] `result_xy.txt` 5줄 형식
- [ ] argmax = `np.argmax(flatten)` (FIRST_MAX)
- [ ] Padding = 1, Cross-Correlation, flip 없음, bias 없음
- [ ] `handoff/B_MODEL_HANDOFF.md`
- [ ] 버전 문자열 통일 (`model_v01` / `weight_v01` / `golden_v01` / `testvec_v01`)

---

## 10. A가 B에게 물어본 것 (회신 필요)

| # | 질문 | 상태 |
|---|---|---|
| 1 | `nn.Conv2d(padding=?)` = 1 | **해결됨** — `D3_B_to_A_CNN_Convolution_Freeze_Request` 로 확정, A 승인 완료 |
| 2 | 표적 없는 프레임의 Heatmap max score 분포 | **회신 대기** — `score_th` 실값 확정용 |
| 3 | `docs/D3_FREEZE_REQUEST_A_001.md` 승인 (CHW / Argmax tie / target_valid / ext 포트) | **B 회신 대기** — C는 `C_TO_A_REPLY_001.md`에서 수용 완료 |
