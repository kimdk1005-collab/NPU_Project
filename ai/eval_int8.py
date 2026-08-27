"""FP32 대비 INT8 Integer Golden Model의 정확도를 같은 Split에서 실측한다.

공통 규격 §35가 Handoff에 요구하는
"FP32 Accuracy/MAE와 INT8 변환 후 Accuracy/MAE"를 채우기 위한 모듈이다.

INT8 경로는 전달물 Golden과 동일한 `run_integer_inference`를 그대로 쓴다.
따라서 여기서 나온 수치는 A의 RTL이 재현할 값과 같은 경로에서 나온 것이다.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import torch

from dataset import (
    HEATMAP_CELL_SIZE,
    HEATMAP_WIDTH,
    inspect_dataset_directory,
)
from export_b_delivery import (
    build_quantization,
    build_result_summary,
    load_model,
    run_integer_inference,
)
from train import INPUT_NORMALIZATION


def _target_from_cell(heatmap_x: int, heatmap_y: int) -> tuple[int, int]:
    """동결된 Mapping: target = cell*8 + 4."""
    half = HEATMAP_CELL_SIZE // 2
    return heatmap_x * HEATMAP_CELL_SIZE + half, heatmap_y * HEATMAP_CELL_SIZE + half


def evaluate(split_paths: list[Path], model, quantization) -> dict[str, float]:
    fp32_hit = int8_hit = 0
    fp32_dx: list[float] = []
    fp32_dy: list[float] = []
    int8_dx: list[float] = []
    int8_dy: list[float] = []
    agree = 0

    model.eval()
    for path in split_paths:
        with np.load(path, allow_pickle=False) as payload:
            tensor_hwc = payload["input_tensor"]
            label_x, label_y = (int(v) for v in payload["heatmap_xy"])
        true_tx, true_ty = _target_from_cell(label_x, label_y)

        # --- FP32 경로 (train.py와 동일한 정규화/축 순서) ---
        chw = np.transpose(tensor_hwc, (2, 0, 1)).astype(np.float32)
        chw /= INPUT_NORMALIZATION
        with torch.no_grad():
            logits = model(torch.from_numpy(chw).unsqueeze(0))
        flat = int(torch.argmax(logits.reshape(-1)).item())
        fy, fx = divmod(flat, HEATMAP_WIDTH)
        if (fx, fy) == (label_x, label_y):
            fp32_hit += 1
        ftx, fty = _target_from_cell(fx, fy)
        fp32_dx.append(abs(ftx - true_tx))
        fp32_dy.append(abs(fty - true_ty))

        # --- INT8 경로 (전달물 Golden과 동일 코드) ---
        outputs = run_integer_inference(tensor_hwc, quantization)
        summary = build_result_summary(outputs["conv4"])
        qx, qy = summary["heatmap_x"], summary["heatmap_y"]
        if (qx, qy) == (label_x, label_y):
            int8_hit += 1
        int8_dx.append(abs(summary["target_x"] - true_tx))
        int8_dy.append(abs(summary["target_y"] - true_ty))

        if (qx, qy) == (fx, fy):
            agree += 1

    n = len(split_paths)
    return {
        "samples": n,
        "fp32_cell_accuracy": fp32_hit / n,
        "fp32_target_x_mae_px": float(np.mean(fp32_dx)),
        "fp32_target_y_mae_px": float(np.mean(fp32_dy)),
        "fp32_target_mean_mae_px": float(np.mean(fp32_dx + fp32_dy)),
        "int8_cell_accuracy": int8_hit / n,
        "int8_target_x_mae_px": float(np.mean(int8_dx)),
        "int8_target_y_mae_px": float(np.mean(int8_dy)),
        "int8_target_mean_mae_px": float(np.mean(int8_dx + int8_dy)),
        "fp32_int8_cell_agreement": agree / n,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="FP32 vs INT8 정확도 실측")
    parser.add_argument("--checkpoint", type=Path,
                        default=Path("weights/tiny_cnn_fp32_model_v03.pt"))
    parser.add_argument("--dataset-dir", type=Path,
                        default=Path("ai/dataset_samples_target_v03_strict"))
    parser.add_argument("--split-manifest", type=Path,
                        default=Path("results/model_v03_split.json"))
    parser.add_argument(
        "--calibration-split-manifest",
        type=Path,
        default=None,
        help="생략하면 --split-manifest의 train target을 Quantization Calibration에 사용",
    )
    parser.add_argument("--split", default="test",
                        choices=("train", "validation", "test"))
    parser.add_argument("--output", type=Path,
                        default=Path("results/model_v03_int8_accuracy.json"))
    args = parser.parse_args()

    checkpoint, model = load_model(args.checkpoint)
    _, valid_samples, errors, _ = inspect_dataset_directory(args.dataset_dir)
    if errors:
        raise RuntimeError(f"Dataset 검증 오류: {errors[0]}")
    manifest = json.loads(args.split_manifest.read_text(encoding="utf-8"))
    calibration_manifest_path = (
        args.calibration_split_manifest or args.split_manifest
    )
    calibration_manifest = json.loads(
        calibration_manifest_path.read_text(encoding="utf-8")
    )
    samples_by_path = {sample.path: sample for sample in valid_samples}
    calibration_paths = [
        Path(p) for p in calibration_manifest["splits"]["train"]
    ]
    missing_calibration = [p for p in calibration_paths if p not in samples_by_path]
    if missing_calibration:
        raise RuntimeError(
            f"Quantization Calibration Sample 누락: {missing_calibration[0]}"
        )
    calibration_samples = [samples_by_path[p] for p in calibration_paths]
    quantization = build_quantization(model, calibration_samples)

    paths = [Path(p) for p in manifest["splits"][args.split]]
    metrics = evaluate(paths, model, quantization)

    print(f"Split={args.split}  Sample={metrics['samples']}")
    print(f"  FP32  Cell Accuracy {metrics['fp32_cell_accuracy']:.4f}"
          f"  Target MAE {metrics['fp32_target_mean_mae_px']:.3f} px")
    print(f"  INT8  Cell Accuracy {metrics['int8_cell_accuracy']:.4f}"
          f"  Target MAE {metrics['int8_target_mean_mae_px']:.3f} px")
    print(f"  양자화 손실  Accuracy {metrics['fp32_cell_accuracy'] - metrics['int8_cell_accuracy']:+.4f}"
          f"  MAE {metrics['int8_target_mean_mae_px'] - metrics['fp32_target_mean_mae_px']:+.3f} px")
    print(f"  FP32/INT8 예측 Cell 일치율 {metrics['fp32_int8_cell_agreement']:.4f}")

    payload = {
        "model_version": checkpoint.get("model_version"),
        "base_spec_version": checkpoint.get("base_spec_version"),
        "split": args.split,
        "quantization_calibration_split": "train_target",
        "quantization_calibration_manifest": str(calibration_manifest_path),
        "quantization_calibration_sample_count": len(calibration_samples),
        **metrics,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8")
    print(f"기록: {args.output}")


if __name__ == "__main__":
    main()
