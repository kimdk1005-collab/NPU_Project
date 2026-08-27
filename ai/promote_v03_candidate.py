#!/usr/bin/env python3
"""Test-blind로 선택한 v03 후보를 최종 canonical 산출물으로 승격한다."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import torch


def _read_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json_atomic(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _write_text_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(path)


def _state_digest(state: dict[str, torch.Tensor]) -> str:
    digest = hashlib.sha256()
    for name in sorted(state):
        tensor = state[name].detach().cpu().contiguous()
        digest.update(name.encode("utf-8"))
        digest.update(str(tensor.dtype).encode("ascii"))
        digest.update(str(tuple(tensor.shape)).encode("ascii"))
        digest.update(tensor.numpy().tobytes())
    return digest.hexdigest()


def _target_test_metrics(int8_test: dict[str, object]) -> dict[str, object]:
    return {
        "loss": None,
        "cell_accuracy": float(int8_test["fp32_cell_accuracy"]),
        "positive_cell_accuracy": float(int8_test["fp32_cell_accuracy"]),
        "target_x_mae_px": float(int8_test["fp32_target_x_mae_px"]),
        "target_y_mae_px": float(int8_test["fp32_target_y_mae_px"]),
        "target_mean_mae_px": float(
            int8_test["fp32_target_mean_mae_px"]
        ),
        "positive_max_score_mean": None,
        "negative_max_score_mean": None,
        "score_margin": None,
        "score_auc": None,
        "true_positive_rate_at_zero": None,
        "false_positive_rate_at_zero": None,
        "positive_sample_count": int(int8_test["samples"]),
        "negative_sample_count": 0,
        "scope": "TARGET_ONLY_FINAL_TEST",
        "source": "ai/eval_int8.py",
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="선택된 v03 후보를 최종 시험 메타데이터와 함께 승격"
    )
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--history", type=Path, required=True)
    parser.add_argument("--final-split", type=Path, required=True)
    parser.add_argument("--int8-validation", type=Path, required=True)
    parser.add_argument("--int8-test", type=Path, required=True)
    parser.add_argument("--output-checkpoint", type=Path, required=True)
    parser.add_argument("--output-history", type=Path, required=True)
    parser.add_argument("--output-split", type=Path, required=True)
    parser.add_argument("--output-int8", type=Path, required=True)
    parser.add_argument("--output-validation-int8", type=Path, required=True)
    parser.add_argument("--output-report", type=Path, required=True)
    args = parser.parse_args()

    checkpoint = torch.load(args.checkpoint, map_location="cpu")
    history = _read_json(args.history)
    split = _read_json(args.final_split)
    int8_validation = _read_json(args.int8_validation)
    int8_test = _read_json(args.int8_test)

    for payload_name, payload in (
        ("checkpoint", checkpoint),
        ("history", history),
        ("split", split),
        ("INT8 validation", int8_validation),
        ("INT8 test", int8_test),
    ):
        if payload.get("model_version") != "model_v03":
            raise RuntimeError(f"{payload_name} model_version이 model_v03이 아닙니다.")
    if checkpoint.get("test_metrics") is not None:
        raise RuntimeError("입력 checkpoint는 Test-blind 후보여야 합니다.")
    if history.get("test_evaluated") is not False:
        raise RuntimeError("입력 history는 test_evaluated=false여야 합니다.")
    if split.get("test_status") != "SEALED_NOT_EVALUATED":
        raise RuntimeError("입력 Split은 SEALED_NOT_EVALUATED 상태여야 합니다.")
    if int8_test.get("split") != "test" or int(int8_test["samples"]) != 256:
        raise RuntimeError("최종 Test 실행 기록이 아닙니다.")
    if (
        int8_validation.get("split") != "validation"
        or int(int8_validation["samples"]) != 256
    ):
        raise RuntimeError("INT8 Validation 기록이 아닙니다.")
    split_counts = {
        name: len(split["splits"][name])
        for name in ("train", "validation", "test")
    }
    if split_counts != {"train": 1152, "validation": 256, "test": 256}:
        raise RuntimeError(f"최종 Split 수 불일치: {split_counts}")

    original_digest = _state_digest(checkpoint["model_state_dict"])
    test_metrics = _target_test_metrics(int8_test)
    training = checkpoint.setdefault("training", {})
    training["test_evaluated"] = True
    training["split_counts"] = split_counts
    training["no_target_split_counts"] = {
        name: len(split["no_target_splits"][name])
        for name in ("train", "validation", "test")
    }
    training["ignored_test_sample_count"] = 0
    training["ignored_no_target_test_sample_count"] = 0
    training["final_test_policy"] = "ONE_TIME_AFTER_VALIDATION_SELECTION"
    training["selected_candidate_checkpoint"] = str(args.checkpoint)
    training["final_split_manifest"] = str(args.output_split)
    training["stages"] = [
        {
            "name": "pure_localization_backbone",
            "checkpoint": "weights/strict_candidates/c5_pureloc_seed42.pt",
            "epochs": 350,
            "best_epoch": 339,
            "localization_weight": 2.0,
            "score_weight": 0.0,
            "learning_rate": 0.0002,
            "augment_train_d4": True,
        },
        {
            "name": "gentle_score_regularization",
            "checkpoint": str(args.checkpoint),
            "epochs": int(training.get("epochs_completed", 0)),
            "best_epoch": int(training.get("best_epoch", 0)),
            "localization_weight": 2.0,
            "score_weight": 0.01,
            "learning_rate": 0.00001,
            "augment_train_d4": True,
        },
    ]
    checkpoint["test_metrics"] = test_metrics
    checkpoint["final_int8_metrics"] = int8_test
    checkpoint["validation_int8_metrics"] = int8_validation
    checkpoint["promotion"] = {
        "source_checkpoint": str(args.checkpoint),
        "model_state_sha256": original_digest,
        "selection_rule": "validation FP32, then validation INT8; Test opened once",
    }

    args.output_checkpoint.parent.mkdir(parents=True, exist_ok=True)
    temporary_checkpoint = args.output_checkpoint.with_suffix(
        args.output_checkpoint.suffix + ".tmp"
    )
    torch.save(checkpoint, temporary_checkpoint)
    temporary_checkpoint.replace(args.output_checkpoint)
    reloaded = torch.load(args.output_checkpoint, map_location="cpu")
    promoted_digest = _state_digest(reloaded["model_state_dict"])
    if promoted_digest != original_digest:
        raise RuntimeError("승격 과정에서 Model State가 변경됐습니다.")

    split["test_evaluated"] = True
    split["test_status"] = "EVALUATED_ONCE_FINAL"
    split["test_evaluation_artifact"] = str(args.output_int8)
    split["selected_checkpoint"] = str(args.output_checkpoint)
    _write_json_atomic(args.output_split, split)

    history["test_evaluated"] = True
    history["split_counts"] = split_counts
    history["no_target_split_counts"] = training["no_target_split_counts"]
    history["ignored_test_sample_count"] = 0
    history["ignored_no_target_test_sample_count"] = 0
    history["test_metrics"] = test_metrics
    history["final_int8_metrics"] = int8_test
    history["validation_int8_metrics"] = int8_validation
    history["selected_candidate_checkpoint"] = str(args.checkpoint)
    history["canonical_checkpoint"] = str(args.output_checkpoint)
    history["final_split_manifest"] = str(args.output_split)
    history["final_test_policy"] = "ONE_TIME_AFTER_VALIDATION_SELECTION"
    history["stages"] = training["stages"]
    _write_json_atomic(args.output_history, history)

    canonical_int8 = dict(int8_test)
    canonical_int8["quantization_calibration_manifest"] = str(args.output_split)
    canonical_int8["checkpoint"] = str(args.output_checkpoint)
    canonical_int8["test_policy"] = "ONE_TIME_AFTER_VALIDATION_SELECTION"
    _write_json_atomic(args.output_int8, canonical_int8)
    canonical_validation_int8 = dict(int8_validation)
    canonical_validation_int8["quantization_calibration_manifest"] = str(
        args.output_split
    )
    canonical_validation_int8["checkpoint"] = str(args.output_checkpoint)
    _write_json_atomic(args.output_validation_int8, canonical_validation_int8)

    validation = checkpoint["validation_metrics"]
    report = f"""# model_v03 Final Accuracy Report

## 선택된 Model

- Canonical checkpoint: `{args.output_checkpoint}`
- Source candidate: `{args.checkpoint}`
- Model-state SHA-256: `{original_digest}`
- 선택 원칙: Validation FP32 우선, Validation INT8 안정성 확인 후 Test 1회 평가
- 구조: 동결 `2→8→16→32→1`, bias 없음, Conv1~3 `3×3/s2/p1`, Conv4 `1×1/s1/p0`

## Dataset / Split

- Target Dataset: `ai/dataset_samples_target_v03_strict`
- Train / Validation / Test: **1152 / 256 / 256**
- Session: Train 3개 / Validation 1개 / Test 1개
- 엄격 Gate: active `8~1200`, target positive `>=4`, target event `>=8`, target/active `>=0.10`, positive argmax 필수
- Test policy: **validation 선택 완료 후 1회만 평가; Test에 맞춰 재학습하지 않음**

## 학습 Recipe

1. v02 init, D4 train-only, localization weight `2`, score weight `0`, LR `2e-4`, 350 epochs (best 339)
2. 1단계 checkpoint init, D4 train-only, localization weight `2`, score weight `0.01`, LR `1e-5`, best epoch `{training.get('best_epoch')}`
3. Test loader는 두 단계 모두 생성하지 않음

## Validation

| 항목 | 결과 |
|---|---:|
| FP32 Cell Accuracy | {float(validation['cell_accuracy']):.4%} |
| FP32 Mean MAE | {float(validation['target_mean_mae_px']):.3f} px |
| INT8 Cell Accuracy | {float(int8_validation['int8_cell_accuracy']):.4%} |
| INT8 Mean MAE | {float(int8_validation['int8_target_mean_mae_px']):.3f} px |

## Final Held-out Test

| 항목 | 결과 |
|---|---:|
| FP32 Cell Accuracy | **{float(int8_test['fp32_cell_accuracy']):.4%}** |
| FP32 Mean MAE | {float(int8_test['fp32_target_mean_mae_px']):.3f} px |
| INT8 Cell Accuracy | **{float(int8_test['int8_cell_accuracy']):.4%}** |
| INT8 Mean MAE | {float(int8_test['int8_target_mean_mae_px']):.3f} px |
| FP32/INT8 Cell Agreement | {float(int8_test['fp32_int8_cell_agreement']):.4%} |

## 해석 주의

이 정확도는 표적 칸의 Event 근거를 엄격 Gate로 확인한 Dataset에서의 위치 정확도다.
CNN 입력은 색상이 아닌 2채널 명암 Event이므로, 연속 시연의 무표적 오검출률은
`SCORE_TH` calibration 보고서에 별도로 기록한다.
"""
    _write_text_atomic(args.output_report, report)

    print(f"Canonical checkpoint: {args.output_checkpoint}")
    print(f"Model state SHA-256: {original_digest}")
    print(f"Canonical split/history/report: {args.output_split}")
    print(
        f"Final Test FP32/INT8="
        f"{float(int8_test['fp32_cell_accuracy']):.4%}/"
        f"{float(int8_test['int8_cell_accuracy']):.4%}"
    )
    print("Model state bit-identical promotion: PASS")


if __name__ == "__main__":
    main()
