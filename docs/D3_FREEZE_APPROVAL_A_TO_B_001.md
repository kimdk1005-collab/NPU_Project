# [D3 FREEZE APPROVAL] A → B  #001

> **대상 요청서:** `docs/freeze/D3_B_to_A_CNN_Convolution_Freeze_Request.md`
> **판정:** **전 항목 승인 (수정 없음)**
> **승인자:** A
> **날짜:** 2026-08-21

---

## 1. 판정 요약

B가 제안한 9개 항목 **전부 승인**한다. 수정 요청 없음.

추가로 알린다: **A의 NPU RTL은 이미 이 규칙 그대로 구현되어 있고,
Python 정수 Golden과 bit-exact 일치가 검증된 상태다.**
따라서 이 승인으로 인한 A측 재작업은 없다.

---

## 2. 항목별 판정

| # | B 제안 | 판정 | A RTL 구현 위치 / 근거 |
|---|---|---|---|
| 1 | Conv1 Padding = 대칭 Zero Padding 1 | **승인** | `npu_conv_dense.v` `pad = cfg_s2 ? 1 : 0` |
| 2 | Conv2 Padding = 대칭 Zero Padding 1 | **승인** | 동일 |
| 3 | Conv3 Padding = 대칭 Zero Padding 1 | **승인** | 동일 |
| 4 | Conv4 Padding = 0 | **승인** | `cfg_s2=0` → `pad=0`, `cfg_k=1` |
| 5 | 경계 밖 Input = 0 | **승인** | `oob` 판정 후 `mac_a = oob_d ? 8'sd0 : act_rdata` |
| 6 | PyTorch Conv2d Cross-Correlation | **승인** | weight를 `[O][I][KY][KX]` 그대로 곱함 |
| 7 | Kernel 180도 반전 없음 | **승인** | 반전 로직 없음 |
| 8 | Input 시작 좌표 = `(oy*stride - pad, ox*stride - pad)` | **승인** | 아래 3절 식 대조 |
| 9 | OIHW `[O][I][KY][KX]` 그대로 MAC 사용 | **승인** | `tools/pack_weights.py`가 순서 보존 변환 |

---

## 3. 누산식 대조

**B 요청서 §3-1**

```text
acc[o, oy, ox] = Σ input[i, oy*2 + ky - 1, ox*2 + kx - 1] × weight[o, i, ky, kx]
```

**A RTL — `rtl/npu/npu_conv_dense.v`**

```verilog
wire [7:0] oy_str = cfg_s2 ? {oy, 1'b0} : {2'b0, oy};   // oy * 2
wire signed [8:0] pad = cfg_s2 ? 9'sd1 : 9'sd0;
wire signed [8:0] iy  = $signed({1'b0, oy_str}) + $signed({7'b0, ky}) - pad;
wire signed [8:0] ix  = $signed({1'b0, ox_str}) + $signed({7'b0, kx}) - pad;

wire oob = iy[8] | ix[8] | (iy >= cfg_iw) | (ix >= cfg_iw);
wire signed [7:0] mac_a = oob_d ? 8'sd0 : act_rdata;
```

전개하면 `iy = oy*2 + ky - 1`, `ix = ox*2 + kx - 1`. **B 제안식과 동일.**

**Conv4** — `cfg_s2 = 0` 이므로 `pad = 0`, `stride = 1`, `cfg_k = 1`:

```text
iy = y + 0 - 0 = y ,  ix = x
acc[0, y, x] = Σ input[i, y, x] × weight[0, i, 0, 0]
```

**B 요청서 §3-2와 동일.**

**Weight 인덱싱** — `tools/pack_weights.py`

```python
src = (((oc * cin) + ic) * k + ky) * k + kx      # OIHW, 순서 보존
```

`ky/kx` 반전 없음. Cross-Correlation.

---

## 4. B 요청서 §4에 대한 A 확인

> "Label Mapping의 `Padding 없음`과 Conv Padding=1은 서로 다른 층위다"

**동의한다.** 두 개는 충돌하지 않는다.

```text
Label Mapping "Padding 없음"  = 원본 영상 좌표 -> 64x64 좌표 변환 단계
Conv Padding = 1              = CNN 내부 3x3 MAC 경계 처리
```

A의 `argmax_decoder.v`는 v1.2 §14.1 Label Mapping을 그대로 따르고
(`target = cell*8 + 4`), `npu_conv_dense.v`는 Conv Padding=1을 따른다. 별개 모듈이다.

---

## 5. 검증 근거

Padding=1이 아니면 v1.2 §8의 고정 출력 형상이 나오지 않는다.

```text
out = floor((in + 2*pad - k)/stride) + 1

pad=1 : 64->32 , 32->16 , 16->8    (§8 일치)
pad=0 : 64->31 , 32->15 , 16->7    (§8 불일치)
```

즉 이 값은 새로 정하는 값이 아니라 §8을 지키면 **유도되는 유일한 값**이다.

실제 검증 결과 (`tools/gen_dummy.py`의 Python 정수 Golden vs A RTL):

| Testbench | 비교 대상 | 결과 |
|---|---|---|
| `tb_npu_conv_dense` | Conv1 8192 byte 전수 | PASS |
| `tb_npu_full` | Conv1/2/3/4 + Argmax 전수 | PASS |

Golden 쪽 Conv 구현 (`tools/gen_dummy.py`):

```python
xp = np.pad(x, ((0,0),(pad,pad),(pad,pad)))        # 대칭 zero pad
patch = xp[:, oy*stride:oy*stride+k, ox*stride:ox*stride+k]
out[:, oy, ox] = (w * patch[None]).sum(axis=(1,2,3))   # flip 없음
```

B의 `integer_golden.py`도 동일하게 만들면 자동으로 일치한다.

---

## 6. B 요청서 §8 승인 기록 (기입본)

```text
A 승인: [x] 승인   [ ] 수정 요청
B 확인: [ ] 확인

확정 Padding:
  Conv1 = 1 (대칭 zero)
  Conv2 = 1 (대칭 zero)
  Conv3 = 1 (대칭 zero)
  Conv4 = 0
  경계 밖 Input = 0

확정 Kernel 연산 방식:
  Cross-Correlation (PyTorch Conv2d 방식)
  Kernel 180도 반전 없음
  Weight = OIHW [O][I][KY][KX] 그대로 사용
  Bias 없음

확정 날짜: 2026-08-21
적용 문서/Version:
  TEAM_COMMON_AI_INTEGRATION_SPEC v1.3 (예정)
  docs/interface_contract.md
  a_npu_v01 (구현 및 검증 완료)
비고:
  A RTL은 승인 이전에 이미 동일 규칙으로 구현·검증 완료.
  본 승인으로 A측 재작업 없음.
  본 항목은 A가 별도로 올린 D3_FREEZE_REQUEST_A_001 의 2번 항목과 동일 건이며,
  B 요청서가 더 상세하므로 B 요청서를 정본으로 채택한다.
```

---

## 7. B에게 추가로 알리는 사항 (승인과 별개)

### 7-1. `dataset.py` 검토 결과 — 문제 없음

| 확인 항목 | 결과 |
|---|---|
| Tensor 64×64×2, 0~127, signed INT8 | 규격 일치 (v1.2 §7.1, §9.1) |
| Channel 0 = Positive, 1 = Negative | 규격 일치 |
| Source → 64×64 floor 변환 | v1.2 §14.1 일치 |
| 64×64 → 8×8 `floor(coord/8)` | 일치 |
| Heatmap `[Y][X]` One-hot | 일치 |
| `target = cell*8 + 4` | 일치 |
| `tensor_layout = "HWC_LOGICAL_ONLY"` 명시 | **적절.** 물리 순서를 확정하지 않은 것이 맞다 |

특히 NPZ에 `spec_version`, `tensor_layout`, `channel_order`, `heatmap_layout`을
같이 저장한 부분은 v1.2 §27 Version 표 관리에 그대로 쓸 수 있다.

### 7-2. `.hex` 만들 때 필요한 변환 1줄

`dataset.py`가 저장하는 배열은 HWC `(64,64,2)`다.
A의 NPU는 **CHW** 순서를 쓴다 (`docs/freeze/D3_FREEZE_REQUEST_A_001` 1번 항목).

`integer_golden.py`에서 `.hex`를 만들 때:

```python
tensor_chw = np.transpose(tensor_hwc, (2, 0, 1))     # (2, 64, 64)
flat = tensor_chw.reshape(-1)                        # 8192
open("input_event.hex","w").write(
    "\n".join("%02X" % (int(v) & 0xFF) for v in flat) + "\n")
```

레이어별 출력도 동일하게 `(C, H, W)` 기준 `flatten()` 순서로 덤프한다.
PyTorch 텐서는 이미 `(C,H,W)`라 별도 transpose가 필요 없다.
`dataset.py`의 HWC만 위 한 줄로 바꾸면 된다.

### 7-3. Webcam Fallback 사용 확인

`dataset.py`가 Webcam Frame Difference 경로다 (v1.2 §34 2순위).
실제 Event Camera를 포기한 것인지 팀 공유가 필요하다.
**A 입장에서는 어느 쪽이든 NPU 인터페이스가 동일하므로 영향 없다.**
발표 시 표현은 개발계획 §5.2 규칙을 따른다.
