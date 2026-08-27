# B 역할 — 공식 Test Vector v03

> 소유: B · Version: `testvec_v03` · Memory Order: CHW

각 case는 `docs/B_TO_A_DELIVERY_SPEC.md`가 요구하는 6개 파일을 포함한다.

| 파일 | 줄 수 | Tensor |
|---|---:|---|
| `input_event.hex` | 8,192 | `(2,64,64)` |
| `conv1_out.hex` | 8,192 | `(8,32,32)` |
| `conv2_out.hex` | 4,096 | `(16,16,16)` |
| `conv3_out.hex` | 2,048 | `(32,8,8)` |
| `conv4_out.hex` | 64 | `(1,8,8)` |
| `result_xy.txt` | 5 | Heatmap/Target/Score |

HEX는 한 줄에 대문자 2자리 two's-complement byte 하나이며 헤더·빈 줄이 없다.

## Case 구성과 결과

| Case | 출처·목적 | Heatmap `(x,y)` | Target `(x,y)` | Score | `score>0` |
|---|---|---:|---:|---:|:---:|
| `case00` | held-out 실제 표적 Sample | `(4,3)` | `(36,28)` | 8 | 1 |
| `case01` | 합성 모서리·Padding 검증 | `(0,0)` | `(4,4)` | 126 | 1 |
| `case02` | 합성 zero-input·무효 검증 | `(0,0)` | `(4,4)` | 0 | 0 |

Argmax는 `np.argmax(heatmap.reshape(-1))`과 같은 YX raster FIRST_MAX다. 파일별
SHA-256은 [`model_v03_manifest.json`](../golden_outputs/model_v03_manifest.json)에 있다.

```bash
python ai/verify_b_delivery.py --root .
```
