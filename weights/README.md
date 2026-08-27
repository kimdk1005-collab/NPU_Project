# B 역할 — Weight·Quantization Parameter

> 소유: B · 전달 규격: `../docs/B_TO_A_DELIVERY_SPEC.md`
> Version Lock: `model_v03 / weight_v03 / golden_v03 / testvec_v03`

## 파일과 checksum

| 파일 | 형식·줄 수 | SHA-256 |
|---|---|---|
| `tiny_cnn_fp32_model_v03.pt` | canonical FP32 checkpoint | `7592abb6ee06a3b41650e8013aefc4f4dcfbb556d1fc3cc66e7e185ab627ff53` |
| `conv1_weight_int8.mem` | OIHW, 144줄 | `7030b1ac3644dde0f9a13a7ac9eab94579d2895bda89c49c6e4e297b397630d6` |
| `conv2_weight_int8.mem` | OIHW, 1,152줄 | `498edfa238409527ebcca9dfaac542a97dfb729fa9bcd837225b8b22eb96b32f` |
| `conv3_weight_int8.mem` | OIHW, 4,608줄 | `d7028aab3d526d79eb657f447f2dd5158905c36e74f56080252d0ddd2b0b8c41` |
| `conv4_weight_int8.mem` | OIHW, 32줄 | `bf29e64426f9348dae5f7ee5a4c6926b7c11e830a00de946d3c6d38fb5aff740` |
| `requant_M.mem` | Conv1→4, 32-bit HEX 4줄 | `b7c15e95402511405ad23315f9893fcf199022400af5ec1a950e7c6c4ce39fbe` |
| `scales.json` | Scale·Multiplier·Clamp 메타 | `7b8c809decd6d36cadf17bd6b28c9c6d682740e8c79f693f3d2460de3e1d33a7` |

## 수치 계약

- Weight: symmetric per-layer INT8, zero-point 0, clamp `[-127,127]`
- Layout: OIHW `[O][I][KY][KX]`, KX fastest
- Bias: 없음
- Requant: `M = RoundAwayFromZero((in_scale×weight_scale/out_scale)×2^24)`
- SHIFT: 24
- Conv1~3 clamp: `[0,127]`; Conv4 clamp: `[-128,127]`
- `requant_M.mem`: `00009552 / 0000E5C2 / 00006DC6 / 000059C9`

전체 파일 checksum과 case 연결은
[`model_v03_manifest.json`](../golden_outputs/model_v03_manifest.json)을 정본으로 사용한다.
