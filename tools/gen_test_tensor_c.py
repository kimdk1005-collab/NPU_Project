#!/usr/bin/env python3
"""
test_vectors/caseNN/*.hex + result_xy.txt  ->  sw/test_tensor.h

PS 소프트웨어가 보드에서 쓸 Event Tensor 와 기대값을 C 헤더로 굽는다.
시뮬레이션(tb_top_system)과 보드가 똑같은 입력/기대값을 쓰게 하는 게 목적이다.

사용법:
    python3 tools/gen_test_tensor_c.py                      # 기본 test_vectors/case00/
    python3 tools/gen_test_tensor_c.py test_vectors/case01  # 다른 벡터 셋
"""
import sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TV   = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "test_vectors", "case00")
OUT  = os.path.join(ROOT, "sw", "test_tensor.h")

N = 8192


def read_hex_i8(path, n):
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            v = int(line, 16) & 0xFF
            vals.append(v - 256 if v >= 128 else v)   # two's complement -> signed
    if len(vals) != n:
        sys.exit(f"[FAIL] {path}: {len(vals)} 개, {n} 개 기대")
    return vals


def read_result(path):
    d = {}
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) == 2:
                d[p[0]] = int(p[1])
    return d


tensor = read_hex_i8(os.path.join(TV, "input_event.hex"), N)
res    = read_result(os.path.join(TV, "result_xy.txt"))

for k in ("target_x", "target_y", "target_score"):
    if k not in res:
        sys.exit(f"[FAIL] result_xy.txt 에 {k} 없음")

lines = []
lines.append("/*=====================================================================")
lines.append(" * test_tensor.h : 보드 자체시험용 Event Tensor + 기대값")
lines.append(" *")
lines.append(" * !! 자동 생성 파일이다. 손으로 고치지 마라. !!")
lines.append(" *   생성: tools/gen_test_tensor_c.py")
lines.append(f" *   원본: {os.path.relpath(TV, ROOT)}/input_event.hex , result_xy.txt")
lines.append(" *")
lines.append(" * 이 벡터는 tb_top_system 이 시뮬레이션에서 쓴 것과 동일하다.")
lines.append(" * 보드에서 같은 결과가 나오면 RTL <-> 실물이 일치한다는 뜻이다.")
lines.append(" * Tensor 순서 = CHW,  addr = (polarity<<12) | (y<<6) | x   (spec 7.4)")
lines.append(" *=====================================================================*/")
lines.append("#ifndef TEST_TENSOR_H")
lines.append("#define TEST_TENSOR_H")
lines.append("")
lines.append("#include <stdint.h>")
lines.append("")
lines.append(f"#define TEST_TENSOR_BYTES   {N}")
lines.append(f"#define TEST_EXPECT_X       {res['target_x']}")
lines.append(f"#define TEST_EXPECT_Y       {res['target_y']}")
lines.append(f"#define TEST_EXPECT_SCORE   {res['target_score']}")
lines.append(f"#define TEST_EXPECT_VALID   1")
if "heatmap_x" in res:
    lines.append(f"#define TEST_EXPECT_HEATMAP_X {res['heatmap_x']}")
    lines.append(f"#define TEST_EXPECT_HEATMAP_Y {res['heatmap_y']}")
lines.append("")
lines.append("static const int8_t test_tensor[TEST_TENSOR_BYTES] = {")
for i in range(0, N, 16):
    chunk = ", ".join(f"{v:4d}" for v in tensor[i:i + 16])
    lines.append(f"    {chunk},")
lines.append("};")
lines.append("")
lines.append("#endif /* TEST_TENSOR_H */")

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    f.write("\n".join(lines) + "\n")

nz = sum(1 for v in tensor if v != 0)
print(f"[OK] {os.path.relpath(OUT, ROOT)}")
print(f"     tensor {N} byte (nonzero {nz}, {100.0*nz/N:.1f}%)")
print(f"     expect x={res['target_x']} y={res['target_y']} score={res['target_score']}")
