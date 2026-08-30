# B 역할 — 현재 Weight·Quantization Parameter

> 소유: B · Version Lock: `model_v04_demo_masked_radius1_x1 / weight_v04 / golden_v04 / testvec_v04`
>
> 판정: `DEMO-MASKED-PASS`, 프로필 `DEMO_BLUE_01`, 범위 **`DEMO_ONLY`**

## 파일

| 파일 | 형식 | SHA-256 |
|---|---|---|
| `tiny_cnn_fp32_model_v04_demo_masked_radius1_x1.pt` | 승인 FP32 checkpoint | `578d3aaa8ce20ff038c45d290e4b6d8cf6c2ab6ddfcfaed28a5f448754436a96` |
| `conv1_weight_int8.mem` | OIHW, 144줄 | `dc607e93a9a96093cfb0b45717359ea49aa515c1060ba3b487947eab666f5976` |
| `conv2_weight_int8.mem` | OIHW, 1,152줄 | `08972082cde8cde65126139e77ba161202e0262f5810807a24ffbba852c32bd5` |
| `conv3_weight_int8.mem` | OIHW, 4,608줄 | `ecd55cc27bc3a65ab702aea7ea869996d8f059792fb90f7f74a419c9bb60b1f8` |
| `conv4_weight_int8.mem` | OIHW, 32줄 | `80175a34fcecea5989d5b99bfd9ac79b58ff61dd3556473f936a8483c13c056f` |
| `requant_M.mem` | Conv1→4, Q24 HEX | `3a1917a90cbc73002a6ba1484d5a74f8513cb0fa45f27355b95352c7fb69b600` |
| `scales.json` | Version/Scale/Clamp/프로필 | `d895ac5b22e1ac13f7e02e9fd7af32de8459d91c4ee678f4d28770a39becb45c` |

`w_bank0.mem`~`w_bank7.mem`은 RTL이 읽는 packed bank이며
`python3 tools/pack_weights.py`로 재생성한다. 기존 v03 checkpoint는 계보와 B 재현 도구를
위해 보존하지만 현재 Bitstream의 Weight가 아니다.

수치 계약은 symmetric per-layer INT8, zero-point 0, OIHW, bias 없음, Q24
ties-away-from-zero다. Conv1~3은 `[0,127]`, Conv4는 `[-128,127]`로 Clamp한다.

이 모델은 PS의 `color_masked_event_v02_radius1` 전처리가 필수이며 범용 환경 또는 외부
Test에서 최종 검증됐다고 해석하지 않는다.
