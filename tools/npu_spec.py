#!/usr/bin/env python3
"""
NPU 공통 상수 / 레이어 테이블.
기준: docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md v1.2
"""

# name, cin, cout, k, stride, pad, in_hw, out_hw, relu
LAYERS = [
    ("conv1",  2,  8, 3, 2, 1, 64, 32, True),
    ("conv2",  8, 16, 3, 2, 1, 32, 16, True),
    ("conv3", 16, 32, 3, 2, 1, 16,  8, True),
    ("conv4", 32,  1, 1, 1, 0,  8,  8, False),
]

NPE = 8           # PE 개수 = 병렬 출력 채널 수
SHIFT = 24        # requantize right shift (spec 9.4)
ROUND_ADD = 1 << (SHIFT - 1)

# 뱅크당 레이어 길이 = ceil(cout/NPE) * cin * k * k
def bank_len(l):
    _, cin, cout, k, *_ = l
    nblk = (cout + NPE - 1) // NPE
    return nblk * cin * k * k

BANK_LEN = [bank_len(l) for l in LAYERS]              # [18, 144, 576, 32]
BANK_BASE = [sum(BANK_LEN[:i]) for i in range(4)]     # [0, 18, 162, 738]
BANK_DEPTH = sum(BANK_LEN)                            # 770


def round_away(x):
    """round-to-nearest, ties away from zero (spec 9.3)"""
    import numpy as np
    return np.sign(x) * np.floor(np.abs(x) + 0.5)


def to_hex8(v):
    """signed int -> 8bit two's complement hex string"""
    return "%02X" % (int(v) & 0xFF)


if __name__ == "__main__":
    print("BANK_LEN ", BANK_LEN)
    print("BANK_BASE", BANK_BASE)
    print("BANK_DEPTH", BANK_DEPTH)
