#!/usr/bin/env python3
"""npu_requant 단위 검증용 벡터 생성 (경계값 + 랜덤)."""
import os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from npu_spec import SHIFT, ROUND_ADD

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "test_vectors", "case00", "requant_tv.txt")


def requant(acc, M, relu):
    neg = acc < 0
    sh = (abs(acc) * M + ROUND_ADD) >> SHIFT
    val = -sh if neg else sh
    if relu:
        val = max(val, 0)
    return max(-128, min(127, val))


def main():
    rng = np.random.default_rng(7)
    cases = []
    # 경계 / 반올림 tie 케이스
    edge_M = [1 << SHIFT, 1, 0xFFFFFFFF, 41125, 125005]
    edge_acc = [0, 1, -1, 127, -128, 128, -129, 1 << 20, -(1 << 20),
                (1 << 31) - 1, -(1 << 31), 8388608, -8388608,   # 2^23 (tie)
                25165824, -25165824]                            # 1.5*2^24 (tie)
    for a in edge_acc:
        for M in edge_M:
            for r in (0, 1):
                if abs(a) * M >= (1 << 63):
                    continue
                cases.append((a, M, r))
    for _ in range(3000):
        a = int(rng.integers(-(1 << 22), 1 << 22))
        M = int(rng.integers(1, 1 << 22))
        r = int(rng.integers(0, 2))
        cases.append((a, M, r))

    with open(OUT, "w") as f:
        for a, M, r in cases:
            q = requant(a, M, r)
            f.write("%08X %08X %d %02X\n" % (a & 0xFFFFFFFF, M, r, q & 0xFF))
    print("[gen_requant_tv] %d cases -> %s" % (len(cases), OUT))


if __name__ == "__main__":
    main()
