#!/usr/bin/env python3
"""Generate the canonical checksum manifest for the active B delivery."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def delivery_paths(root: Path) -> list[Path]:
    paths = [
        root / "weights/conv1_weight_int8.mem",
        root / "weights/conv2_weight_int8.mem",
        root / "weights/conv3_weight_int8.mem",
        root / "weights/conv4_weight_int8.mem",
        root / "weights/requant_M.mem",
        root / "weights/scales.json",
    ]
    for case_name in ("case00", "case01", "case02"):
        paths.extend(
            root / "test_vectors" / case_name / name
            for name in (
                "input_event.hex",
                "conv1_out.hex",
                "conv2_out.hex",
                "conv3_out.hex",
                "conv4_out.hex",
                "result_xy.txt",
            )
        )
    paths.append(root / "handoff/B_MODEL_HANDOFF.md")
    return paths


def parse_result(path: Path) -> dict[str, int]:
    lines = path.read_text(encoding="ascii").splitlines()
    if len(lines) != 5:
        raise ValueError(f"{path}: result_xy.txt must contain exactly 5 lines")
    result: dict[str, int] = {}
    for line in lines:
        key, value = line.split()
        result[key] = int(value)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()
    root = args.root.resolve()
    scales = json.loads((root / "weights/scales.json").read_text(encoding="utf-8"))
    model_version = scales["model_version"]
    if args.output is None:
        manifest_name = (
            "model_v03_manifest.json"
            if model_version == "model_v03"
            else "model_v04_demo_manifest.json"
        )
        output = root / "golden_outputs" / manifest_name
    else:
        output = (root / args.output).resolve() if not args.output.is_absolute() else args.output

    paths = delivery_paths(root)
    missing = [str(path.relative_to(root)) for path in paths if not path.is_file()]
    if missing:
        raise FileNotFoundError(f"missing delivery files: {missing}")

    files = [
        {
            "path": path.relative_to(root).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
        }
        for path in paths
    ]
    checkpoint_names = {
        "model_v03": "tiny_cnn_fp32_model_v03.pt",
        "model_v04_demo_masked_radius1_x1":
            "tiny_cnn_fp32_model_v04_demo_masked_radius1_x1.pt",
    }
    try:
        checkpoint = root / "weights" / checkpoint_names[model_version]
    except KeyError as exc:
        raise ValueError(f"unsupported model_version: {model_version}") from exc
    manifest = {
        "base_spec_version": scales["base_spec_version"],
        "model_version": model_version,
        "weight_version": scales["weight_version"],
        "golden_version": scales["golden_version"],
        "test_vector_version": scales["test_vector_version"],
        "profile_id": scales.get("profile_id"),
        "demo_only": bool(scales.get("demo_only", False)),
        "input_preprocess": scales.get("input_preprocess"),
        "external_test_used_for_selection": bool(
            scales.get("external_test_used_for_selection", False)
        ),
        "checkpoint": {
            "path": checkpoint.relative_to(root).as_posix(),
            "bytes": checkpoint.stat().st_size,
            "sha256": sha256(checkpoint),
        },
        "case_sources": {
            "case00": (
                "ai/dataset_samples_target_v03_strict/sample_001438.npz"
                if model_version == "model_v03"
                else "B final delivery: E4_E2_RADIUS1_X1 held-out target"
            ),
            "case01": "synthetic_boundary_corner",
            "case02": "synthetic_zero_input",
        },
        "case_results": {
            case_name: parse_result(
                root / "test_vectors" / case_name / "result_xy.txt"
            )
            for case_name in ("case00", "case01", "case02")
        },
        "files": files,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"[PASS] wrote {output.relative_to(root)} ({len(files)} delivery files)")


if __name__ == "__main__":
    main()
