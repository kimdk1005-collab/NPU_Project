#!/usr/bin/env python3
"""공유 저장소의 활성 B 산출물을 독립된 정수 연산으로 검증한다."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from pathlib import Path
from zipfile import ZipFile

import numpy as np
import torch


LAYERS = ("conv1", "conv2", "conv3", "conv4")
WEIGHT_SHAPES = {
    "conv1": (8, 2, 3, 3),
    "conv2": (16, 8, 3, 3),
    "conv3": (32, 16, 3, 3),
    "conv4": (1, 32, 1, 1),
}
TENSOR_COUNTS = {
    "input_event.hex": 8192,
    "conv1_out.hex": 8192,
    "conv2_out.hex": 4096,
    "conv3_out.hex": 2048,
    "conv4_out.hex": 64,
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_hex_bytes(path: Path, expected_count: int) -> np.ndarray:
    raw = path.read_text(encoding="ascii")
    if not raw.endswith("\n"):
        raise AssertionError(f"마지막 newline 누락: {path}")
    lines = raw.splitlines()
    if len(lines) != expected_count:
        raise AssertionError(f"줄 수 불일치: {path} {len(lines)} != {expected_count}")
    if any(re.fullmatch(r"[0-9A-F]{2}", line) is None for line in lines):
        raise AssertionError(f"2자리 대문자 HEX 형식 오류: {path}")
    unsigned = np.asarray([int(line, 16) for line in lines], dtype=np.int16)
    return np.where(unsigned >= 128, unsigned - 256, unsigned).astype(np.int32)


def conv2d_exact(
    input_chw: np.ndarray,
    weight_oihw: np.ndarray,
    stride: int,
    padding: int,
) -> np.ndarray:
    padded = np.pad(
        input_chw,
        ((0, 0), (padding, padding), (padding, padding)),
        constant_values=0,
    )
    kernel = weight_oihw.shape[2]
    windows = np.lib.stride_tricks.sliding_window_view(
        padded,
        (kernel, kernel),
        axis=(1, 2),
    )[:, ::stride, ::stride, :, :]
    return np.einsum(
        "iyxkl,oikl->oyx",
        windows.astype(np.int64),
        weight_oihw.astype(np.int64),
        dtype=np.int64,
        optimize=True,
    )


def requantize_exact(accumulator: np.ndarray, multiplier: int, relu: bool) -> np.ndarray:
    product = accumulator * np.int64(multiplier)
    magnitude = np.abs(product)
    rounded = (magnitude + (1 << 23)) // (1 << 24)
    rounded = np.where(product < 0, -rounded, rounded)
    if relu:
        rounded = np.maximum(rounded, 0)
    return np.clip(rounded, 0 if relu else -128, 127).astype(np.int32)


def expected_members(root: Path) -> list[Path]:
    members = [
        *(root / "weights").glob("conv*_weight_int8.mem"),
        root / "weights/requant_M.mem",
        root / "weights/scales.json",
    ]
    members = sorted(members, key=lambda path: str(path.relative_to(root)))
    for case_name in ("case00", "case01", "case02"):
        for file_name in (
            "input_event.hex",
            "conv1_out.hex",
            "conv2_out.hex",
            "conv3_out.hex",
            "conv4_out.hex",
            "result_xy.txt",
        ):
            members.append(root / "test_vectors" / case_name / file_name)
    members.append(root / "handoff/B_MODEL_HANDOFF.md")
    return members


def verify(root: Path, archive: Path | None = None) -> None:
    scales = json.loads((root / "weights/scales.json").read_text(encoding="utf-8"))
    versions = (
        scales["model_version"],
        scales["weight_version"],
        scales["golden_version"],
        scales["test_vector_version"],
    )
    supported_versions = {
        ("model_v03", "weight_v03", "golden_v03", "testvec_v03"),
        (
            "model_v04_demo_masked_radius1_x1",
            "weight_v04",
            "golden_v04",
            "testvec_v04",
        ),
    }
    if versions not in supported_versions:
        raise AssertionError(f"Version Lock 불일치: {versions}")

    model_version = versions[0]
    checkpoint_names = {
        "model_v03": "tiny_cnn_fp32_model_v03.pt",
        "model_v04_demo_masked_radius1_x1":
            "tiny_cnn_fp32_model_v04_demo_masked_radius1_x1.pt",
    }
    manifest_names = {
        "model_v03": "model_v03_manifest.json",
        "model_v04_demo_masked_radius1_x1": "model_v04_demo_manifest.json",
    }

    requant_lines = (root / "weights/requant_M.mem").read_text(encoding="ascii").splitlines()
    if len(requant_lines) != 4 or any(
        re.fullmatch(r"[0-9A-F]{8}", line) is None for line in requant_lines
    ):
        raise AssertionError("requant_M.mem 형식 오류")
    multipliers = dict(zip(LAYERS, (int(line, 16) for line in requant_lines)))

    checkpoint = torch.load(
        root / "weights" / checkpoint_names[model_version],
        map_location="cpu",
        weights_only=False,
    )
    checkpoint_model_version = checkpoint.get("model_version")
    expected_checkpoint_version = (
        "model_v04" if model_version.startswith("model_v04_demo_") else model_version
    )
    if checkpoint_model_version != expected_checkpoint_version:
        raise AssertionError("checkpoint model_version 불일치")

    weights: dict[str, np.ndarray] = {}
    for layer_name in LAYERS:
        shape = WEIGHT_SHAPES[layer_name]
        count = math.prod(shape)
        delivered = read_hex_bytes(
            root / f"weights/{layer_name}_weight_int8.mem",
            count,
        )
        weights[layer_name] = delivered.reshape(shape)

        fp32 = checkpoint["model_state_dict"][f"{layer_name}.weight"].numpy()
        weight_scale = float(np.max(np.abs(fp32))) / 127.0
        quantized = np.where(
            fp32 / weight_scale >= 0,
            np.floor(fp32 / weight_scale + 0.5),
            np.ceil(fp32 / weight_scale - 0.5),
        )
        quantized = np.clip(quantized, -127, 127).astype(np.int8).reshape(-1)
        if not np.array_equal(quantized.astype(np.int32), delivered):
            raise AssertionError(f"checkpoint→Weight 불일치: {layer_name}")

        layer = scales["layers"][layer_name]
        calculated_m = math.floor(
            (
                layer["input_scale"]
                * layer["weight_scale"]
                / layer["output_scale"]
            )
            * (1 << 24)
            + 0.5
        )
        if calculated_m != layer["multiplier"] or calculated_m != multipliers[layer_name]:
            raise AssertionError(f"Multiplier 불일치: {layer_name}")

    case_results: dict[str, dict[str, int]] = {}
    for case_name in ("case00", "case01", "case02"):
        case_dir = root / "test_vectors" / case_name
        current = read_hex_bytes(
            case_dir / "input_event.hex",
            TENSOR_COUNTS["input_event.hex"],
        ).reshape(2, 64, 64)
        for layer_name in LAYERS:
            layer = scales["layers"][layer_name]
            accumulator = conv2d_exact(
                current,
                weights[layer_name],
                int(layer["stride"]),
                int(layer["pad"]),
            )
            current = requantize_exact(
                accumulator,
                multipliers[layer_name],
                bool(layer["relu"]),
            )
            expected = read_hex_bytes(
                case_dir / f"{layer_name}_out.hex",
                TENSOR_COUNTS[f"{layer_name}_out.hex"],
            ).reshape(current.shape)
            if not np.array_equal(current, expected):
                first = tuple(np.argwhere(current != expected)[0])
                raise AssertionError(
                    f"Golden 불일치: {case_name}/{layer_name}/{first}"
                )

        flat_index = int(np.argmax(current.reshape(-1)))
        heatmap_y, heatmap_x = divmod(flat_index, 8)
        result = {
            "heatmap_x": heatmap_x,
            "heatmap_y": heatmap_y,
            "target_x": heatmap_x * 8 + 4,
            "target_y": heatmap_y * 8 + 4,
            "target_score": int(current.reshape(-1)[flat_index]),
        }
        result_lines = (case_dir / "result_xy.txt").read_text(encoding="ascii").splitlines()
        parsed = {line.split()[0]: int(line.split()[1]) for line in result_lines}
        if len(result_lines) != 5 or parsed != result:
            raise AssertionError(f"result_xy 불일치: {case_name}")
        case_results[case_name] = result

    manifest = json.loads(
        (root / "golden_outputs" / manifest_names[model_version]).read_text()
    )
    manifest_versions = (
        manifest["model_version"],
        manifest["weight_version"],
        manifest["golden_version"],
        manifest["test_vector_version"],
    )
    if manifest_versions != versions:
        raise AssertionError(f"Manifest Version Lock 불일치: {manifest_versions}")

    checkpoint_path = root / manifest["checkpoint"]["path"]
    if manifest["checkpoint"]["sha256"] != sha256(checkpoint_path):
        raise AssertionError("Manifest checkpoint checksum 불일치")

    if manifest["case_results"] != case_results:
        raise AssertionError("Manifest case_results 불일치")
    manifest_hashes = {item["path"]: item["sha256"] for item in manifest["files"]}

    members = expected_members(root)
    member_names = [str(path.relative_to(root)) for path in members]
    for path, name in zip(members, member_names):
        if manifest_hashes.get(name) != sha256(path):
            raise AssertionError(f"Manifest checksum 불일치: {name}")

    if archive is not None:
        with ZipFile(archive) as zip_file:
            if sorted(zip_file.namelist()) != sorted(member_names):
                raise AssertionError("ZIP 파일 목록 불일치")
            for path, name in zip(members, member_names):
                if zip_file.read(name) != path.read_bytes():
                    raise AssertionError(f"ZIP과 작업 파일 불일치: {name}")

    source = root / Path(manifest["case_sources"]["case00"])
    if source.exists():
        with np.load(source, allow_pickle=False) as sample:
            source_chw = np.transpose(sample["input_tensor"], (2, 0, 1)).reshape(-1)
        delivered_input = read_hex_bytes(
            root / "test_vectors/case00/input_event.hex",
            TENSOR_COUNTS["input_event.hex"],
        )
        if not np.array_equal(source_chw.astype(np.int32), delivered_input):
            raise AssertionError("case00 CHW 변환/source provenance 불일치")
    else:
        print("[SKIP] case00 원본 NPZ는 공개 저장소 제외 — 전달 HEX checksum 검증 사용")

    print(f"[PASS] B repository format / Version Lock / checksum ({model_version})")
    print("[PASS] checkpoint -> OIHW INT8 Weight / Q24 Multiplier")
    print("[PASS] case00~02 Conv1~4 Integer Golden bit-exact")
    print(f"[PASS] Argmax results: {case_results}")
    if archive is not None:
        print(f"[PASS] ZIP {archive} ({len(member_names)} files)")


def main() -> None:
    parser = argparse.ArgumentParser(description="공유 저장소 활성 B 산출물 독립 검증")
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument(
        "--archive",
        type=Path,
        default=None,
        help="선택: 별도 전달 ZIP까지 함께 검증",
    )
    args = parser.parse_args()
    archive = args.archive.resolve() if args.archive is not None else None
    verify(args.root.resolve(), archive)


if __name__ == "__main__":
    main()
