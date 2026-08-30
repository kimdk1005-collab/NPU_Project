#!/usr/bin/env python3
"""
B가 준 OIHW .mem  ->  RTL용 8-bank .mem 변환.

B 전달 형식 (spec 11.1):
    weights/conv{N}_weight_int8.mem
    1 line = 1 weight, 8bit two's complement HEX
    순서 = O -> I -> KY -> KX  (KX fastest)

RTL 형식:
    weights/w_bank{0..7}.mem  (각 BANK_DEPTH 라인)
    bank j = out_ch % 8 == j 인 weight만 모음
    bank 내부 주소 = BANK_BASE[L] + oc_blk*(CIN*K*K) + (ic*K*K + ky*K + kx)
    -> PE 8개가 같은 주소를 동시에 읽으면 됨

B 실제 weight가 오면 이 스크립트만 다시 돌리면 된다.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from npu_spec import LAYERS, NPE, BANK_BASE, BANK_DEPTH, to_hex8

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_oihw_mem(path, n_expect):
    vals = []
    with open(path) as f:
        for line in f:
            line = line.split("//")[0].strip()
            if not line:
                continue
            v = int(line, 16)
            vals.append(v - 256 if v > 127 else v)   # two's complement -> signed
    if len(vals) != n_expect:
        raise ValueError("%s: %d개 기대, %d개 읽음" % (path, n_expect, len(vals)))
    return vals


def pack(w_dir=None):
    w_dir = w_dir or os.path.join(ROOT, "weights")
    banks = [[0] * BANK_DEPTH for _ in range(NPE)]

    for li, (name, cin, cout, k, _s, _p, _ih, _oh, _r) in enumerate(LAYERS):
        n = cout * cin * k * k
        flat = read_oihw_mem(os.path.join(w_dir, "%s_weight_int8.mem" % name), n)
        nblk = (cout + NPE - 1) // NPE
        tap = cin * k * k
        for blk in range(nblk):
            for j in range(NPE):
                oc = blk * NPE + j
                for ic in range(cin):
                    for ky in range(k):
                        for kx in range(k):
                            t = (ic * k + ky) * k + kx
                            dst = BANK_BASE[li] + blk * tap + t
                            if oc < cout:
                                # OIHW addr = ((((oc*CIN)+ic)*KH+ky)*KW+kx)   spec 11
                                src = (((oc * cin) + ic) * k + ky) * k + kx
                                banks[j][dst] = flat[src]
                            else:
                                banks[j][dst] = 0   # cout<8 인 conv4 padding

    for j in range(NPE):
        p = os.path.join(w_dir, "w_bank%d.mem" % j)
        with open(p, "w") as f:
            f.write("\n".join(to_hex8(v) for v in banks[j]) + "\n")
    print("[pack_weights] w_bank0..7.mem 생성 (각 %d 라인)" % BANK_DEPTH)
    return banks


if __name__ == "__main__":
    pack()
