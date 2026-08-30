#!/usr/bin/env python3
"""
weights/conv{1..4}_weight_int8.mem + requant_M.mem  ->  sw/int8_weights.h

PS CPU INT8 Baseline 측정용. NPU 가 BRAM 에서 읽는 것과 같은 weight 를
ARM 이 DDR 에서 읽게 C 배열로 굽는다. 순서는 B 전달 형식 그대로 OIHW (KX fastest).

사용법:  python3 tools/gen_int8_weights_c.py
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from npu_spec import LAYERS

W_DIR = os.path.join(ROOT, "weights")
OUT = os.path.join(ROOT, "sw", "int8_weights.h")


def read_mem_i8(path, n_expect):
    vals = []
    with open(path) as f:
        for line in f:
            line = line.split("//")[0].strip()
            if not line:
                continue
            v = int(line, 16)
            vals.append(v - 256 if v > 127 else v)
    if len(vals) != n_expect:
        raise SystemExit("%s: %d 기대, %d 읽음" % (path, n_expect, len(vals)))
    return vals


def main():
    sc = json.load(open(os.path.join(W_DIR, "scales.json")))
    ver = sc.get("weight_version", "?")

    Ms = []
    with open(os.path.join(W_DIR, "requant_M.mem")) as f:
        for line in f:
            line = line.split("//")[0].strip()
            if line:
                Ms.append(int(line, 16))
    if len(Ms) != 4:
        raise SystemExit("requant_M.mem 4줄 기대, %d줄" % len(Ms))

    L = [
        "/* 자동 생성 — tools/gen_int8_weights_c.py. 직접 고치지 마라.",
        " *   원본: weights/conv{1..4}_weight_int8.mem, requant_M.mem",
        " *   weight_version: %s" % ver,
        " *   순서: OIHW (KX fastest) — B 전달 형식 그대로",
        " */",
        "#ifndef INT8_WEIGHTS_H",
        "#define INT8_WEIGHTS_H",
        "",
        "#include <stdint.h>",
        "",
        "/* requant multiplier. spec 9.4: (|acc|*M + (1<<23)) >> 24 */",
        "static const int32_t requant_m[4] = { %s };" % ", ".join(str(m) for m in Ms),
        "",
    ]

    total = 0
    for (name, cin, cout, k, _s, _p, _ih, _oh, _r) in LAYERS:
        n = cout * cin * k * k
        w = read_mem_i8(os.path.join(W_DIR, "%s_weight_int8.mem" % name), n)
        total += n
        L.append("/* %s  OIHW %dx%dx%dx%d */" % (name, cout, cin, k, k))
        L.append("#define %s_W_LEN %d" % (name.upper(), n))
        L.append("static const int8_t %s_w_i8[%d] = {" % (name, n))
        for i in range(0, n, 16):
            L.append("    " + ", ".join("%4d" % v for v in w[i:i + 16])
                     + ("," if i + 16 < n else ""))
        L.append("};")
        L.append("")
        print("  %-6s %5d 값" % (name, n))

    L += ["#endif /* INT8_WEIGHTS_H */", ""]
    with open(OUT, "w") as f:
        f.write("\n".join(L))
    print("[OK] %s  (총 %d 값, M=%s)"
          % (os.path.relpath(OUT, ROOT), total, Ms))


if __name__ == "__main__":
    main()
