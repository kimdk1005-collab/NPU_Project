#!/usr/bin/env python3
"""Canonical v03의 CPU FP32와 Python INT8 Golden 지연을 실측한다."""

from __future__ import annotations

import argparse
import json
import platform
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import torch

from dataset import inspect_dataset_directory
from export_b_delivery import (
    build_quantization,
    load_input_tensor,
    load_model,
    run_integer_inference,
)
from train import INPUT_NORMALIZATION


def _summary(samples_ms: list[float]) -> dict[str, float]:
    values = np.asarray(samples_ms, dtype=np.float64)
    return {
        "mean_ms": float(values.mean()),
        "median_ms": float(np.median(values)),
        "p90_ms": float(np.percentile(values, 90)),
        "p99_ms": float(np.percentile(values, 99)),
        "min_ms": float(values.min()),
        "max_ms": float(values.max()),
    }


def _write_json_atomic(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def main() -> None:
    parser = argparse.ArgumentParser(description="model_v03 CPU latency 실측")
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=Path("weights/tiny_cnn_fp32_model_v03.pt"),
    )
    parser.add_argument(
        "--dataset-dir",
        type=Path,
        default=Path("ai/dataset_samples_target_v03_strict"),
    )
    parser.add_argument(
        "--split-manifest",
        type=Path,
        default=Path("results/model_v03_split.json"),
    )
    parser.add_argument("--warmup", type=int, default=10)
    parser.add_argument("--iterations", type=int, default=100)
    parser.add_argument("--torch-threads", type=int, default=1)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("results/model_v03_latency.json"),
    )
    args = parser.parse_args()
    if args.warmup < 1 or args.iterations < 1 or args.torch_threads < 1:
        parser.error("warmup/iterations/torch-threads는 1 이상이어야 합니다.")

    torch.set_num_threads(args.torch_threads)
    checkpoint, model = load_model(args.checkpoint)
    manifest = json.loads(args.split_manifest.read_text(encoding="utf-8"))
    _, samples, errors, _ = inspect_dataset_directory(args.dataset_dir)
    if errors:
        path, message = errors[0]
        raise RuntimeError(f"Dataset 오류: {path}: {message}")
    samples_by_path = {sample.path: sample for sample in samples}
    train_paths = [Path(path) for path in manifest["splits"]["train"]]
    test_paths = [Path(path) for path in manifest["splits"]["test"]]
    if not train_paths or not test_paths:
        raise RuntimeError("Train/Test Split이 비어 있습니다.")
    missing = [
        path
        for path in train_paths + test_paths[:1]
        if path not in samples_by_path
    ]
    if missing:
        raise RuntimeError(f"Split Sample 누락: {missing[0]}")

    calibration_samples = [samples_by_path[path] for path in train_paths]
    quantization = build_quantization(model, calibration_samples)
    input_path = test_paths[0]
    input_hwc = load_input_tensor(input_path)
    input_chw = np.transpose(input_hwc, (2, 0, 1)).astype(np.float32)
    input_fp32 = torch.from_numpy(input_chw / INPUT_NORMALIZATION).unsqueeze(0)

    with torch.inference_mode():
        for _ in range(args.warmup):
            model(input_fp32)
        fp32_ms: list[float] = []
        for _ in range(args.iterations):
            start = time.perf_counter_ns()
            model(input_fp32)
            fp32_ms.append((time.perf_counter_ns() - start) / 1_000_000.0)

    for _ in range(args.warmup):
        run_integer_inference(input_hwc, quantization)
    int8_ms: list[float] = []
    for _ in range(args.iterations):
        start = time.perf_counter_ns()
        run_integer_inference(input_hwc, quantization)
        int8_ms.append((time.perf_counter_ns() - start) / 1_000_000.0)

    payload: dict[str, object] = {
        "model_version": checkpoint.get("model_version"),
        "base_spec_version": checkpoint.get("base_spec_version"),
        "checkpoint": str(args.checkpoint),
        "split_manifest": str(args.split_manifest),
        "input_sample": str(input_path),
        "measured_at_utc": datetime.now(timezone.utc).isoformat(
            timespec="milliseconds"
        ),
        "environment": {
            "platform": platform.platform(),
            "processor": platform.processor() or "UNKNOWN",
            "python": platform.python_version(),
            "torch": torch.__version__,
            "torch_threads": args.torch_threads,
        },
        "warmup": args.warmup,
        "iterations": args.iterations,
        "fp32": {
            "implementation": "PyTorch CPU eager inference_mode",
            **_summary(fp32_ms),
        },
        "int8": {
            "implementation": "Python/Numpy Integer Golden reference; not optimized kernel",
            **_summary(int8_ms),
        },
    }
    _write_json_atomic(args.output, payload)
    print(
        f"FP32 median/p90={payload['fp32']['median_ms']:.3f}/"
        f"{payload['fp32']['p90_ms']:.3f} ms"
    )
    print(
        f"INT8 Golden median/p90={payload['int8']['median_ms']:.3f}/"
        f"{payload['int8']['p90_ms']:.3f} ms"
    )
    print(f"Latency report: {args.output}")


if __name__ == "__main__":
    main()
