#!/usr/bin/env python3
"""
weights/tiny_cnn_fp32_model_v04_demo_masked_radius1_x1.pt  ->  sw/fp32_weights.h
(+ 콘솔 요약)

PS CPU FP32 Baseline 측정용. B 가 준 checkpoint 에서 conv1~4 FP32 weight 를 꺼내
ARM 에서 그대로 쓸 C 헤더로 굽는다.

torch 를 설치하지 않는다. .pt 는 zip + pickle 이고 tensor 는
torch._utils._rebuild_tensor_v2(storage, offset, size, stride, ...) 로 저장돼 있어서
그 호출만 가로채면 numpy 로 복원된다.

사용법:
    python3 tools/dump_fp32_weights.py
    python3 tools/dump_fp32_weights.py <다른.pt> <다른출력.h>
"""
import io
import os
import pickle
import sys
import zipfile

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from npu_spec import LAYERS

DTYPE = {"FloatStorage": np.float32, "HalfStorage": np.float16,
         "DoubleStorage": np.float64, "LongStorage": np.int64,
         "IntStorage": np.int32}


class _Stub:
    """pickle 이 부르는 torch 심볼 자리표시자."""
    def __init__(self, name):
        self.name = name

    def __call__(self, *a, **kw):
        return (self.name, a, kw)


def _load_state_dict(path):
    zf = zipfile.ZipFile(path)
    root = zf.namelist()[0].split("/")[0]

    class U(pickle.Unpickler):
        def find_class(self, mod, name):
            if mod.startswith("torch"):
                return _Stub(name)
            return super().find_class(mod, name)

        def persistent_load(self, pid):
            # ('storage', <FloatStorage stub>, key, location, numel)
            _tag, stype, key, _loc, numel = pid
            return ("storage", stype.name, key, numel)

    obj = U(io.BytesIO(zf.read(f"{root}/data.pkl"))).load()

    # B checkpoint 는 state_dict 를 한 겹 감싸고 있다 (meta 키가 같이 들어있음)
    meta = {}
    if isinstance(obj, dict) and "model_state_dict" in obj:
        meta = {k: v for k, v in obj.items() if k != "model_state_dict"}
        obj = obj["model_state_dict"]

    out = {}
    for k, v in obj.items():
        if not (isinstance(v, tuple) and v and v[0] == "_rebuild_tensor_v2"):
            continue
        storage, offset, size, stride = v[1][0], v[1][1], v[1][2], v[1][3]
        _s, sname, key, numel = storage
        dt = DTYPE[sname]
        raw = zf.read(f"{root}/data/{key}")
        flat = np.frombuffer(raw, dtype=dt, count=numel)
        arr = np.lib.stride_tricks.as_strided(
            flat[offset:], shape=tuple(size),
            strides=tuple(s * dt().itemsize for s in stride))
        out[k] = np.ascontiguousarray(arr)
    return out, meta


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(ROOT, "weights",
                     "tiny_cnn_fp32_model_v04_demo_masked_radius1_x1.pt")
    dst = sys.argv[2] if len(sys.argv) > 2 else \
        os.path.join(ROOT, "sw", "fp32_weights.h")

    sd, meta = _load_state_dict(src)
    for k in ("model_version", "base_spec_version"):
        if k in meta:
            print("  %-18s %s" % (k, meta[k]))
    conv = {k: v for k, v in sd.items() if v.ndim == 4}
    if len(conv) != 4:
        raise SystemExit("conv weight 4개를 못 찾았다: %s"
                         % {k: v.shape for k, v in sd.items()})

    # OIHW shape 로 LAYERS 와 대조해 순서를 정한다 (키 이름에 의존하지 않는다)
    want = [(l[2], l[1], l[3], l[3]) for l in LAYERS]      # (cout, cin, k, k)
    ordered = []
    for li, shape in enumerate(want):
        hit = [k for k, v in conv.items() if v.shape == shape]
        if len(hit) != 1:
            raise SystemExit("layer %s shape %s 매칭 실패: %s"
                             % (LAYERS[li][0], shape, hit))
        ordered.append((LAYERS[li][0], hit[0], conv[hit[0]]))

    lines = [
        "/* 자동 생성 — tools/dump_fp32_weights.py. 직접 고치지 마라.",
        " *   원본: %s" % os.path.relpath(src, ROOT),
        " *   용도: PS CPU FP32 Baseline (Cortex-A9). 순서 = OIHW, KX fastest",
        " */",
        "#ifndef FP32_WEIGHTS_H",
        "#define FP32_WEIGHTS_H",
        "",
    ]
    for name, key, w in ordered:
        n = w.size
        flat = w.reshape(-1).astype(np.float32)
        lines.append("/* %s  <- state_dict[\"%s\"]  OIHW %s */" %
                     (name, key, "x".join(str(d) for d in w.shape)))
        lines.append("#define %s_W_LEN %d" % (name.upper(), n))
        lines.append("static const float %s_w[%d] = {" % (name, n))
        for i in range(0, n, 8):
            chunk = ", ".join("%.9gf" % v for v in flat[i:i + 8])
            lines.append("    " + chunk + ("," if i + 8 < n else ""))
        lines.append("};")
        lines.append("")
        print("  %-6s %-28s %-14s min %+.6f max %+.6f" %
              (name, key, "x".join(str(d) for d in w.shape),
               float(flat.min()), float(flat.max())))
    lines += ["#endif /* FP32_WEIGHTS_H */", ""]

    with open(dst, "w") as f:
        f.write("\n".join(lines))
    print("[OK] %s  (conv weight %d개, 총 %d 값)" %
          (os.path.relpath(dst, ROOT), len(ordered),
           sum(w.size for _n, _k, w in ordered)))

    bias = {k: v for k, v in sd.items() if v.ndim == 1}
    if bias:
        print("  [주의] 1-D 텐서 발견(bias 로 추정): %s" %
              {k: v.shape for k, v in bias.items()})
    else:
        print("  bias 없음 — INT8 경로와 동일 (spec 9.x)")


if __name__ == "__main__":
    main()
