# B 역할 — 공식 Test Vector v04

> 소유: B · Version: `testvec_v04` · Memory Order: CHW · 범위: `DEMO_ONLY`

각 `caseNN/`은 입력, Conv1~4 Golden, Argmax 결과와 A Requant 단위시험 벡터를 포함한다.
HEX는 헤더 없는 대문자 2자리 two's-complement byte다.

| Case | 목적 | Heatmap `(x,y)` | Target `(x,y)` | Score | `score>0` |
|---|---|---:|---:|---:|:---:|
| `case00` | B 전달 held-out 표적 | `(4,3)` | `(36,28)` | 43 | 1 |
| `case01` | 합성 모서리·Padding | `(0,0)` | `(4,4)` | 101 | 1 |
| `case02` | 합성 zero-input | `(0,0)` | `(4,4)` | 0 | 0 |

```bash
./sim/run_sim.sh
TV_DIR=../test_vectors/case01/ ./sim/run_sim.sh
TV_DIR=../test_vectors/case02/ ./sim/run_sim.sh
```

파일별 SHA-256은 `../golden_outputs/model_v04_demo_manifest.json`에 기록한다.
