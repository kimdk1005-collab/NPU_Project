#!/usr/bin/env python3
"""RTL과 같은 INT8 Integer Golden 경로로 SCORE_TH 분포를 측정한다."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from dataset import (
    build_quality_distribution,
    inspect_dataset_directory,
    inspect_no_target_directory,
)
from export_b_delivery import (
    build_quantization,
    load_input_tensor,
    load_model,
    run_integer_inference,
)


def infer_max_score(input_tensor_hwc: np.ndarray, quantization) -> int:
    """전달물 Golden과 같은 Conv1~4/Requant 경로의 signed INT8 max다."""
    conv4 = run_integer_inference(input_tensor_hwc, quantization)["conv4"]
    return int(np.max(conv4.astype(np.int16)))


def summarize(scores: list[int]) -> dict[str, object]:
    if not scores:
        raise ValueError("분포를 계산할 score가 없습니다.")
    values = np.asarray(scores, dtype=np.int16)
    return {
        "sample_count": int(values.size),
        "min": int(values.min()),
        "max": int(values.max()),
        "mean": float(values.mean()),
        "std": float(values.std()),
        "median": float(np.percentile(values, 50)),
        "p90": float(np.percentile(values, 90)),
        "p95": float(np.percentile(values, 95)),
        "p99": float(np.percentile(values, 99)),
    }


def auc_probability(positive_scores: list[int], negative_scores: list[int]) -> float:
    """P(positive>negative)+0.5*P(tie)인 threshold-independent AUC다."""
    positive = np.asarray(positive_scores, dtype=np.int16)[:, None]
    negative = np.asarray(negative_scores, dtype=np.int16)[None, :]
    return float(np.mean((positive > negative) + 0.5 * (positive == negative)))


def threshold_metrics(
    target_scores: list[int],
    no_target_scores: list[int],
    score_th: int,
) -> dict[str, float | int]:
    """동결 판정식 score > SCORE_TH의 TPR/FPR을 계산한다."""
    target = np.asarray(target_scores, dtype=np.int16)
    no_target = np.asarray(no_target_scores, dtype=np.int16)
    return {
        "score_th": score_th,
        "true_positive_rate": float(np.mean(target > score_th)),
        "false_positive_rate": float(np.mean(no_target > score_th)),
    }


def choose_youden_threshold(
    target_scores: list[int],
    no_target_scores: list[int],
) -> dict[str, float | int]:
    """TPR-FPR이 최대인 signed INT8 후보를 진단값으로 반환한다."""
    candidates = [
        threshold_metrics(target_scores, no_target_scores, score_th)
        for score_th in range(-128, 128)
    ]
    return max(
        candidates,
        key=lambda metrics: (
            metrics["true_positive_rate"] - metrics["false_positive_rate"],
            metrics["true_positive_rate"],
            -abs(int(metrics["score_th"])),
        ),
    )


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    temporary_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary_path.replace(path)


def write_markdown(path: Path, payload: dict[str, object]) -> None:
    target = payload["target_summary"]
    no_target = payload["no_target_summary"]
    default_metrics = payload["threshold_metrics"]["default_0"]
    p99_metrics = payload["threshold_metrics"]["no_target_p99"]
    youden_metrics = payload["threshold_metrics"]["best_youden"]
    diagnostic = payload["diagnostic_all_accepted"]
    report = f"""# SCORE_TH INT8 Calibration Report

## 입력과 판정 경로

- Checkpoint: `{payload['checkpoint']}`
- Target Dataset: `{payload['target_dir']}`
- No-target Dataset: `{payload['no_target_dir']}`
- Evaluation Scope: **held-out `{payload['evaluation_split']}` only**
- Quantization Calibration: target `{payload['quantization_calibration_split']}` split ({payload['quantization_calibration_sample_count']} Sample)
- Score Domain: **signed INT8 Conv4 output — 전달물 Integer Golden/RTL과 동일 경로**
- Valid 식: `target_valid = (heatmap_max_score > SCORE_TH)`

## 실측 분포

| 구분 | Sample | Min | Median | P90 | P95 | P99 | Max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 표적 있음 | {target['sample_count']} | {target['min']} | {target['median']:.1f} | {target['p90']:.1f} | {target['p95']:.1f} | {target['p99']:.1f} | {target['max']} |
| 표적 없음 | {no_target['sample_count']} | {no_target['min']} | {no_target['median']:.1f} | {no_target['p90']:.1f} | {no_target['p95']:.1f} | {no_target['p99']:.1f} | {no_target['max']} |

- AUC: `{payload['auc']:.4f}` (`0.5`는 무작위 수준)
- No-target p99 후보 임계값: `{payload['no_target_p99_candidate']}`
- `SCORE_TH=0`: TPR `{default_metrics['true_positive_rate']:.4f}`, FPR `{default_metrics['false_positive_rate']:.4f}`
- `SCORE_TH={p99_metrics['score_th']}`: TPR `{p99_metrics['true_positive_rate']:.4f}`, FPR `{p99_metrics['false_positive_rate']:.4f}`
- Youden 진단 후보 `{youden_metrics['score_th']}`: TPR `{youden_metrics['true_positive_rate']:.4f}`, FPR `{youden_metrics['false_positive_rate']:.4f}`

## 전체 수집분 진단

학습에 사용한 Sample까지 포함한 값은 임계값 선택 근거로 사용하지 않고 분포 이동 확인용으로만 기록한다.

- 품질 통과 표적 / 전체 무표적: {diagnostic['target_summary']['sample_count']} / {diagnostic['no_target_summary']['sample_count']} Sample
- AUC: `{diagnostic['auc']:.4f}`
- 표적/무표적 Score 중앙값: `{diagnostic['target_summary']['median']:.1f}` / `{diagnostic['no_target_summary']['median']:.1f}`

## 판정

Held-out 분리도와 전체 수집분 진단 사이에 차이가 있어 일반화된 임계값으로 동결하기에는
근거가 부족하다. 따라서 p99와 Youden 값은 **측정 결과일 뿐 확정 SCORE_TH가 아니다.**
A가 별도 정책 또는 Change Request를 승인하기 전까지 공통 규격 기본값 `SCORE_TH=0`을
유지하고, 본 보고서를 A의 미해결 질의에 대한 실측 회신으로 전달한다.
"""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    temporary_path.write_text(report, encoding="utf-8")
    temporary_path.replace(path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="RTL INT8 SCORE_TH 분포 측정기")
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=Path("weights/tiny_cnn_fp32_model_v03.pt"),
    )
    parser.add_argument(
        "--target-dir",
        type=Path,
        default=Path("ai/dataset_samples_target_v03_strict"),
    )
    parser.add_argument(
        "--no-target-dir",
        type=Path,
        default=Path("ai/no_target_samples_v03"),
    )
    parser.add_argument(
        "--split-manifest",
        type=Path,
        default=Path("results/model_v03_split.json"),
    )
    parser.add_argument(
        "--evaluation-split",
        choices=("validation", "test"),
        default="test",
    )
    parser.add_argument(
        "--json-output",
        type=Path,
        default=Path("results/model_v03_score_th_calibration.json"),
    )
    parser.add_argument(
        "--report-output",
        type=Path,
        default=Path("results/model_v03_score_th_calibration_report.md"),
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    checkpoint, model = load_model(args.checkpoint)
    _, target_samples, target_errors, _ = inspect_dataset_directory(args.target_dir)
    _, no_target_samples, no_target_errors = inspect_no_target_directory(
        args.no_target_dir
    )
    errors = target_errors + no_target_errors
    if errors:
        summary = "; ".join(
            f"{path.name}: {message}" for path, message in errors[:10]
        )
        raise RuntimeError(f"Calibration Dataset 형식 오류: {summary}")
    if not target_samples or not no_target_samples:
        raise RuntimeError("Target/No-target Dataset이 모두 필요합니다.")

    manifest = json.loads(args.split_manifest.read_text(encoding="utf-8"))
    quality = manifest["quality_range"]
    accepted_target_samples, _, _ = build_quality_distribution(
        target_samples,
        minimum_active_pixels=int(quality["minimum_active_pixels"]),
        maximum_active_pixels=int(quality["maximum_active_pixels"]),
        minimum_target_positive_pixels=int(
            quality.get("minimum_target_positive_pixels", 0)
        ),
        require_target_positive_argmax=bool(
            quality.get("require_target_positive_argmax", False)
        ),
        minimum_target_event_pixels=int(
            quality.get("minimum_target_event_pixels", 0)
        ),
        minimum_target_event_ratio=float(
            quality.get("minimum_target_event_ratio", 0.0)
        ),
    )
    target_by_path = {sample.path: sample for sample in accepted_target_samples}
    no_target_by_path = {sample.path: sample for sample in no_target_samples}
    calibration_paths = [Path(path) for path in manifest["splits"]["train"]]
    evaluation_target_paths = [
        Path(path) for path in manifest["splits"][args.evaluation_split]
    ]
    evaluation_no_target_paths = [
        Path(path)
        for path in manifest["no_target_splits"][args.evaluation_split]
    ]
    required_paths = calibration_paths + evaluation_target_paths
    missing_target = [path for path in required_paths if path not in target_by_path]
    missing_no_target = [
        path for path in evaluation_no_target_paths if path not in no_target_by_path
    ]
    if missing_target or missing_no_target:
        missing = (missing_target + missing_no_target)[0]
        raise RuntimeError(f"Split Manifest Sample 누락 또는 품질 불일치: {missing}")

    calibration_samples = [target_by_path[path] for path in calibration_paths]
    evaluation_target_samples = [
        target_by_path[path] for path in evaluation_target_paths
    ]
    evaluation_no_target_samples = [
        no_target_by_path[path] for path in evaluation_no_target_paths
    ]
    if not evaluation_target_samples or not evaluation_no_target_samples:
        raise RuntimeError("평가 Split에 Target/No-target Sample이 모두 필요합니다.")

    quantization = build_quantization(model, calibration_samples)
    target_scores = [
        infer_max_score(load_input_tensor(sample.path), quantization)
        for sample in evaluation_target_samples
    ]
    no_target_scores = [
        infer_max_score(load_input_tensor(sample.path), quantization)
        for sample in evaluation_no_target_samples
    ]
    diagnostic_target_scores = [
        infer_max_score(load_input_tensor(sample.path), quantization)
        for sample in accepted_target_samples
    ]
    diagnostic_no_target_scores = [
        infer_max_score(load_input_tensor(sample.path), quantization)
        for sample in no_target_samples
    ]
    target_summary = summarize(target_scores)
    no_target_summary = summarize(no_target_scores)
    p99_candidate = int(np.ceil(no_target_summary["p99"]))
    payload: dict[str, object] = {
        "model_version": checkpoint.get("model_version"),
        "base_spec_version": checkpoint.get("base_spec_version"),
        "checkpoint": str(args.checkpoint),
        "target_dir": str(args.target_dir),
        "no_target_dir": str(args.no_target_dir),
        "score_domain": "RTL_INT8_INTEGER_GOLDEN_CONV4_MAX",
        "comparison": "score > SCORE_TH",
        "split_manifest": str(args.split_manifest),
        "evaluation_split": args.evaluation_split,
        "quantization_calibration_split": "train_target",
        "quantization_calibration_sample_count": len(calibration_samples),
        "target_scores": target_scores,
        "no_target_scores": no_target_scores,
        "target_summary": target_summary,
        "no_target_summary": no_target_summary,
        "auc": auc_probability(target_scores, no_target_scores),
        "no_target_p99_candidate": p99_candidate,
        "threshold_metrics": {
            "default_0": threshold_metrics(target_scores, no_target_scores, 0),
            "no_target_p99": threshold_metrics(
                target_scores,
                no_target_scores,
                p99_candidate,
            ),
            "best_youden": choose_youden_threshold(
                target_scores,
                no_target_scores,
            ),
        },
        "diagnostic_all_accepted": {
            "target_summary": summarize(diagnostic_target_scores),
            "no_target_summary": summarize(diagnostic_no_target_scores),
            "auc": auc_probability(
                diagnostic_target_scores,
                diagnostic_no_target_scores,
            ),
        },
        "recommendation": "KEEP_DEFAULT_0_PENDING_A_APPROVAL_OR_CHANGE_REQUEST",
    }
    write_json(args.json_output, payload)
    write_markdown(args.report_output, payload)
    print(f"target_samples={target_summary['sample_count']}")
    print(f"no_target_samples={no_target_summary['sample_count']}")
    print(f"auc={payload['auc']:.4f}")
    print(f"no_target_p99_candidate={p99_candidate}")
    print(f"json={args.json_output}")
    print(f"report={args.report_output}")


if __name__ == "__main__":
    main()
