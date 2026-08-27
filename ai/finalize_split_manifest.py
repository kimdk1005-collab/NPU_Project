#!/usr/bin/env python3
"""Test-blind 후보 Manifest에 봉인된 Session Test 경로를 연결한다."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from dataset import (
    HEATMAP_HEIGHT,
    HEATMAP_WIDTH,
    inspect_dataset_directory,
    inspect_no_target_directory,
)


def _path_set(values: list[str]) -> set[Path]:
    return {Path(value) for value in values}


def _write_json_atomic(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Test-blind 후보 Split에 봉인된 Test Session 연결"
    )
    parser.add_argument("--candidate-manifest", type=Path, required=True)
    parser.add_argument("--dataset-dir", type=Path, required=True)
    parser.add_argument("--no-target-dir", type=Path, required=True)
    parser.add_argument("--test-session-id", default="strict_test")
    parser.add_argument("--expected-target-count", type=int, default=256)
    parser.add_argument("--expected-no-target-count", type=int, default=100)
    parser.add_argument("--expected-per-cell", type=int, default=4)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    manifest = json.loads(
        args.candidate_manifest.read_text(encoding="utf-8")
    )
    if manifest.get("test_evaluated") is not False:
        raise RuntimeError("입력은 test_evaluated=false인 후보여야 합니다.")
    if manifest["splits"].get("test"):
        raise RuntimeError("입력 후보의 Test Split이 이미 열려 있습니다.")

    _, target_samples, target_errors, _ = inspect_dataset_directory(
        args.dataset_dir
    )
    if target_errors:
        path, message = target_errors[0]
        raise RuntimeError(f"Target Dataset 오류: {path}: {message}")

    train_paths = _path_set(manifest["splits"]["train"])
    validation_paths = _path_set(manifest["splits"]["validation"])
    if train_paths & validation_paths:
        raise RuntimeError("Train/Validation 경로가 겹칩니다.")

    target_by_path = {sample.path: sample for sample in target_samples}
    missing_known = (train_paths | validation_paths) - set(target_by_path)
    if missing_known:
        raise RuntimeError(f"기존 Split Sample 누락: {min(missing_known)}")
    if any(target_by_path[path].capture_split != "train" for path in train_paths):
        raise RuntimeError("Train Split에 train Session이 아닌 Sample이 있습니다.")
    if any(
        target_by_path[path].capture_split != "validation"
        for path in validation_paths
    ):
        raise RuntimeError(
            "Validation Split에 validation Session이 아닌 Sample이 있습니다."
        )

    target_test = sorted(
        (
            sample
            for sample in target_samples
            if sample.capture_split == "test"
            and sample.capture_session_id == args.test_session_id
        ),
        key=lambda sample: sample.path,
    )
    if len(target_test) != args.expected_target_count:
        raise RuntimeError(
            f"Target Test 수 불일치: {len(target_test)} != "
            f"{args.expected_target_count}"
        )
    target_test_paths = {sample.path for sample in target_test}
    if target_test_paths & (train_paths | validation_paths):
        raise RuntimeError("Test와 Train/Validation 경로가 겹칩니다.")

    distribution = np.zeros(
        (HEATMAP_HEIGHT, HEATMAP_WIDTH), dtype=np.int32
    )
    for sample in target_test:
        distribution[sample.heatmap_y, sample.heatmap_x] += 1
    if not bool(np.all(distribution == args.expected_per_cell)):
        raise RuntimeError(
            "Target Test 8×8 분포가 기대값과 다릅니다: "
            f"min={int(distribution.min())}, max={int(distribution.max())}"
        )

    _, no_target_samples, no_target_errors = inspect_no_target_directory(
        args.no_target_dir
    )
    if no_target_errors:
        path, message = no_target_errors[0]
        raise RuntimeError(f"No-target Dataset 오류: {path}: {message}")
    no_target_train = _path_set(manifest["no_target_splits"]["train"])
    no_target_validation = _path_set(
        manifest["no_target_splits"]["validation"]
    )
    no_target_test = sorted(
        (
            sample
            for sample in no_target_samples
            if sample.capture_split == "test"
        ),
        key=lambda sample: sample.path,
    )
    if len(no_target_test) != args.expected_no_target_count:
        raise RuntimeError(
            f"No-target Test 수 불일치: {len(no_target_test)} != "
            f"{args.expected_no_target_count}"
        )
    no_target_test_paths = {sample.path for sample in no_target_test}
    if no_target_test_paths & (no_target_train | no_target_validation):
        raise RuntimeError("No-target Test와 Train/Validation이 겹칩니다.")

    manifest["splits"]["test"] = [str(sample.path) for sample in target_test]
    manifest["capture_sessions"]["test"] = sorted(
        {sample.capture_session_id for sample in target_test}
    )
    manifest["no_target_splits"]["test"] = [
        str(sample.path) for sample in no_target_test
    ]
    manifest["no_target_capture_sessions"]["test"] = sorted(
        {sample.capture_session_id for sample in no_target_test}
    )
    manifest["no_target_split_counts"]["test"] = len(no_target_test)
    manifest["test_evaluated"] = False
    manifest["test_status"] = "SEALED_NOT_EVALUATED"
    manifest["ignored_test_sample_count"] = 0
    manifest["ignored_no_target_test_sample_count"] = 0
    manifest["finalized_from_candidate_manifest"] = str(
        args.candidate_manifest
    )
    _write_json_atomic(args.output, manifest)

    print(f"Final Split Manifest: {args.output}")
    print(
        f"Target Train/Validation/Test="
        f"{len(train_paths)}/{len(validation_paths)}/{len(target_test)}"
    )
    print(
        f"No-target Train/Validation/Test="
        f"{len(no_target_train)}/{len(no_target_validation)}/{len(no_target_test)}"
    )
    print(
        f"Target Test Session={args.test_session_id}, "
        f"Cell={HEATMAP_WIDTH}×{HEATMAP_HEIGHT}×{args.expected_per_cell}"
    )
    print("Test 추론은 수행하지 않음: SEALED_NOT_EVALUATED")


if __name__ == "__main__":
    main()
