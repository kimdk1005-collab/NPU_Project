#!/usr/bin/env python3
"""B -> A 전달 규격 산출물 생성기.

TEAM_COMMON_AI_INTEGRATION_SPEC v1.5 를 기본으로 하고,
D3_FREEZE_APPROVAL_A_TO_B_001 / D3_FREEZE_REQUEST_A_001 을 함께 반영해
FP32 체크포인트에서 A팀이 바로 회귀할 수 있는 전달물 묶음을 만든다.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

import numpy as np
import torch
import torch.nn.functional as F

from dataset import (
    BASE_SPEC_VERSION,
    DatasetSampleInfo,
    HEATMAP_CELL_SIZE,
    HEATMAP_HEIGHT,
    HEATMAP_WIDTH,
    NEGATIVE_CHANNEL,
    POSITIVE_CHANNEL,
    SIGNED_INT8_MAX,
    TENSOR_CHANNELS,
    TENSOR_HEIGHT,
    TENSOR_WIDTH,
    build_quality_distribution,
    inspect_dataset_directory,
)
from train import INPUT_NORMALIZATION, TinyCNN


# 2026-08-25 최종 v03: 독립 촬영 Session Split, Target-Event 정렬 필터,
# 무표적 Hybrid Loss 및 Train 전용 증강을 반영한다.
# 공통 지침 §13 Version Lock — 네 가지는 반드시 함께 올린다. 혼용 금지.
DELIVERY_MODEL_VERSION = "model_v03"
DELIVERY_WEIGHT_VERSION = "weight_v03"
DELIVERY_GOLDEN_VERSION = "golden_v03"
DELIVERY_TEST_VECTOR_VERSION = "testvec_v03"
SHIFT_BITS = 24
# case01 합성 경계 텐서 파라미터.
# 변 자극 진폭을 낮게 두는 이유는 build_boundary_case_tensor() docstring 참고.
EDGE_AMPLITUDE = 12
BLOB_POSITIVE_VALUE = 127
BLOB_NEGATIVE_VALUE = 63
LAYERS = ("conv1", "conv2", "conv3", "conv4")
FREEZE_DOCUMENTS = (
    "D3_FREEZE_APPROVAL_A_TO_B_001.md",
    "D3_FREEZE_REQUEST_A_001.md",
    "B_TO_A_DELIVERY_SPEC.md",
)

RESULTS_DIR = Path("results")

# (cin, cout, in_hw, out_hw, relu) — build_scales_json 과 Handoff §2 가 함께 쓴다.
LAYER_GEOMETRY: dict[str, tuple[int, int, int, int, bool]] = {
    "conv1": (2, 8, 64, 32, True),
    "conv2": (8, 16, 32, 16, True),
    "conv3": (16, 32, 16, 8, True),
    "conv4": (32, 1, 8, 8, False),
}

@dataclass(frozen=True)
class LayerQuantization:
    weight: np.ndarray
    weight_scale: float
    output_scale: float
    multiplier: int
    stride: int
    padding: int
    relu: bool
    clamp_min: int
    clamp_max: int


def round_away_from_zero(values: np.ndarray | float) -> np.ndarray:
    array = np.asarray(values, dtype=np.float64)
    return np.where(array >= 0.0, np.floor(array + 0.5), np.ceil(array - 0.5))


def quantize_to_int8(values: np.ndarray, scale: float) -> np.ndarray:
    if scale <= 0.0:
        raise ValueError(f"scale은 0보다 커야 합니다: {scale}")
    quantized = round_away_from_zero(values / scale)
    return np.clip(quantized, -127, 127).astype(np.int8)


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    temporary_path.write_text(text, encoding="utf-8")
    temporary_path.replace(path)


def write_json(path: Path, payload: dict[str, object]) -> None:
    write_text(path, json.dumps(payload, ensure_ascii=False, indent=2) + "\n")


def write_hex_lines(path: Path, values: np.ndarray) -> None:
    flattened = values.reshape(-1)
    lines = "\n".join(f"{int(value) & 0xFF:02X}" for value in flattened) + "\n"
    write_text(path, lines)


def load_model(checkpoint_path: Path) -> tuple[dict[str, object], TinyCNN]:
    checkpoint = torch.load(checkpoint_path, map_location="cpu")
    model = TinyCNN()
    model.load_state_dict(checkpoint["model_state_dict"])
    model.eval()
    return checkpoint, model


def load_input_tensor(sample_path: Path) -> np.ndarray:
    with np.load(sample_path, allow_pickle=False) as sample:
        input_tensor = sample["input_tensor"]
    if input_tensor.shape != (64, 64, 2) or input_tensor.dtype != np.int8:
        raise ValueError(f"지원하지 않는 input_tensor 형식: {sample_path}")
    return input_tensor


def build_boundary_case_tensor() -> np.ndarray:
    """case01용 결정론적 Padding 경계 검증 Event Tensor를 만든다.

    목적은 학습 데이터 대표성이 아니라 RTL의 pad=1 경계 로직 검증이다.
    Conv1의 `iy = oy*2 + ky - 1`, `ix = ox*2 + kx - 1` 은 -1 과 64 를 짚는다.
    이때 그 이웃(y=0, y=63, x=0, x=63)이 0이면 pad=0 구현과 pad=1 구현의
    결과가 같아져 버그가 드러나지 않는다. 그래서 네 변을 전부 0이 아닌 값으로 채운다.

    설계 의도는 두 가지를 동시에 만족시키는 것이다.

    1. 경계 검출력: 네 변이 전부 0이 아니어야 한다.
    2. 표적 위치: A의 `B_TO_A_DELIVERY_SPEC.md` §5-3이 case01을 "표적이 모서리"로
       규정하므로 Heatmap argmax가 모서리 셀 (0,0)에 떨어져야 한다.

    pad 버그 검출력은 경계가 "0이 아닌지"에만 달려 있고 경계값이 "큰지"와는
    무관하다. 그래서 변 자극의 진폭을 `EDGE_AMPLITUDE`(1~12)로 낮게 잡고, 대신
    좌상단 셀의 표적 blob을 127로 강하게 준다. 이러면 경계 커버리지 512/512를
    그대로 유지하면서 (0,0)이 argmax를 단독으로(동점 아님) 이긴다.

    - 값 범위는 §9.1 Event Count saturation 규격에 맞춰 0~127 (음수 없음).
    - 난수를 쓰지 않는 순수 산술식이므로 완전히 결정론적이다.
    - 두 polarity 채널(0=Positive, 1=Negative)의 패턴을 다르게 만들어
      채널 순서가 뒤바뀐 구현 버그도 잡히게 한다.
    """
    tensor = np.zeros((TENSOR_HEIGHT, TENSOR_WIDTH, TENSOR_CHANNELS), dtype=np.int8)
    index = np.arange(TENSOR_WIDTH, dtype=np.int32)

    # 위/아래 변: 채널별로 서로 다른 산술 수열을 넣는다. 값은 항상 1 이상이다.
    tensor[0, :, POSITIVE_CHANNEL] = (
        1 + (7 * index) % EDGE_AMPLITUDE
    ).astype(np.int8)
    tensor[TENSOR_HEIGHT - 1, :, POSITIVE_CHANNEL] = (
        1 + (7 * index + 33) % EDGE_AMPLITUDE
    ).astype(np.int8)
    tensor[0, :, NEGATIVE_CHANNEL] = (
        1 + (11 * index + 23) % EDGE_AMPLITUDE
    ).astype(np.int8)
    tensor[TENSOR_HEIGHT - 1, :, NEGATIVE_CHANNEL] = (
        1 + (11 * index + 57) % EDGE_AMPLITUDE
    ).astype(np.int8)

    # 좌/우 변: 위/아래와도, 채널끼리도 겹치지 않는 별도 수열을 넣는다.
    tensor[:, 0, POSITIVE_CHANNEL] = (
        1 + (5 * index + 13) % EDGE_AMPLITUDE
    ).astype(np.int8)
    tensor[:, TENSOR_WIDTH - 1, POSITIVE_CHANNEL] = (
        1 + (5 * index + 71) % EDGE_AMPLITUDE
    ).astype(np.int8)
    tensor[:, 0, NEGATIVE_CHANNEL] = (
        1 + (13 * index + 41) % EDGE_AMPLITUDE
    ).astype(np.int8)
    tensor[:, TENSOR_WIDTH - 1, NEGATIVE_CHANNEL] = (
        1 + (13 * index + 5) % EDGE_AMPLITUDE
    ).astype(np.int8)

    # 표적 blob: Heatmap cell (0,0)에 대응하는 좌상단 8x8 영역.
    # Conv1~3이 stride 2를 세 번 거쳐 64 -> 8 이 되므로 입력 x 0..7 / y 0..7 이
    # 정확히 Heatmap 셀 (0,0)이다. 셀 경계(x<8, y<8)를 넘지 않는다.
    # 두 채널의 세기를 다르게 둬서 채널 뒤바뀜 버그도 결과에 드러나게 한다.
    tensor[0:HEATMAP_CELL_SIZE, 0:HEATMAP_CELL_SIZE, POSITIVE_CHANNEL] = (
        BLOB_POSITIVE_VALUE
    )
    tensor[0:HEATMAP_CELL_SIZE, 0:HEATMAP_CELL_SIZE, NEGATIVE_CHANNEL] = (
        BLOB_NEGATIVE_VALUE
    )

    # 네 모서리는 최대값 127. -1 과 64 를 동시에 짚는 가장 가혹한 지점이다.
    # blob 뒤에 넣어야 (0,0) 모서리가 blob 값에 덮이지 않는다.
    for corner_y in (0, TENSOR_HEIGHT - 1):
        for corner_x in (0, TENSOR_WIDTH - 1):
            tensor[corner_y, corner_x, :] = SIGNED_INT8_MAX

    return tensor


def choose_delivery_cases(
    valid_samples: list[DatasetSampleInfo],
    quantization: dict[str, LayerQuantization],
) -> dict[str, DatasetSampleInfo]:
    """실제 Dataset 샘플에서 뽑는 case만 고른다.

    case01은 합성 경계 벡터(build_boundary_case_tensor), case02는 zero-input
    합성 벡터라서 실제 샘플을 쓰지 않는다. 여기서는 case00만 고른다.
    """
    if not valid_samples:
        raise RuntimeError("전달용 case00을 만들 최소 Sample 1개가 필요합니다.")

    center_x = 32
    center_y = 32

    def center_distance(sample_info: DatasetSampleInfo) -> tuple[int, int]:
        distance = abs(sample_info.target_x - center_x) + abs(
            sample_info.target_y - center_y
        )
        return distance, sample_info.sample_index

    # 실제 held-out Test 중 중앙에 가까운 순서로 INT8 추론해,
    # 저장 Label과 Argmax가 일치하고 SCORE_TH=0을 통과하는 Sample만
    # case00으로 고른다. Handoff의 예상 표적과 Golden이 다른 상태를
    # exporter 단계에서 차단한다.
    for candidate in sorted(valid_samples, key=center_distance):
        input_tensor_hwc = load_input_tensor(candidate.path)
        outputs = run_integer_inference(input_tensor_hwc, quantization)
        summary = build_result_summary(outputs["conv4"])
        if (
            (summary["heatmap_x"], summary["heatmap_y"])
            == (candidate.heatmap_x, candidate.heatmap_y)
            and summary["target_score"] > 0
        ):
            return {"case00": candidate}
    raise RuntimeError(
        "held-out Test에서 Label·INT8 Argmax·SCORE_TH=0을 모두 만족하는 "
        "case00 Sample을 찾지 못했습니다."
    )


def collect_activation_scales(
    model: TinyCNN,
    calibration_samples: list[DatasetSampleInfo],
) -> dict[str, float]:
    maxima = {layer_name: 0.0 for layer_name in LAYERS}

    with torch.no_grad():
        for sample_info in calibration_samples:
            input_int8_hwc = load_input_tensor(sample_info.path)
            input_chw = np.transpose(input_int8_hwc, (2, 0, 1)).astype(np.float32)
            input_tensor = torch.from_numpy(input_chw[None] / INPUT_NORMALIZATION)
            outputs = model.forward_with_layers(input_tensor)

            for layer_name, output_tensor in outputs.items():
                output_np = output_tensor.detach().cpu().numpy()
                if layer_name == "conv4":
                    candidate = float(np.max(np.abs(output_np)))
                else:
                    candidate = float(np.max(output_np))
                maxima[layer_name] = max(maxima[layer_name], candidate)

    scales: dict[str, float] = {}
    for layer_name in LAYERS:
        max_value = maxima[layer_name]
        if max_value <= 0.0:
            max_value = 1.0 / SIGNED_INT8_MAX
        scales[layer_name] = max_value / SIGNED_INT8_MAX
    return scales


def build_quantization(
    model: TinyCNN,
    calibration_samples: list[DatasetSampleInfo],
) -> dict[str, LayerQuantization]:
    weight_scales: dict[str, float] = {}
    quantized_weights: dict[str, np.ndarray] = {}
    activation_scales = collect_activation_scales(model, calibration_samples)

    for layer_name in LAYERS:
        weight = getattr(model, layer_name).weight.detach().cpu().numpy()
        max_abs = float(np.max(np.abs(weight)))
        if max_abs <= 0.0:
            max_abs = 1.0 / SIGNED_INT8_MAX
        scale = max_abs / SIGNED_INT8_MAX
        weight_scales[layer_name] = scale
        quantized_weights[layer_name] = quantize_to_int8(weight, scale)

    quantization: dict[str, LayerQuantization] = {}
    input_scale = 1.0 / INPUT_NORMALIZATION
    running_input_scale = input_scale

    for layer_name in LAYERS:
        layer = getattr(model, layer_name)
        output_scale = activation_scales[layer_name]
        multiplier = int(
            round_away_from_zero(
                (running_input_scale * weight_scales[layer_name] / output_scale)
                * (1 << SHIFT_BITS)
            )
        )
        if multiplier <= 0:
            raise RuntimeError(f"{layer_name} multiplier가 0 이하입니다: {multiplier}")
        if multiplier > 0xFFFFFFFF:
            raise RuntimeError(
                f"{layer_name} multiplier가 32bit 범위를 넘습니다: {multiplier}"
            )

        quantization[layer_name] = LayerQuantization(
            weight=quantized_weights[layer_name],
            weight_scale=weight_scales[layer_name],
            output_scale=output_scale,
            multiplier=multiplier,
            stride=int(layer.stride[0]),
            padding=int(layer.padding[0]),
            relu=(layer_name != "conv4"),
            clamp_min=0 if layer_name != "conv4" else -128,
            clamp_max=127,
        )
        running_input_scale = output_scale

    return quantization


def conv2d_integer(
    input_chw: np.ndarray,
    weight_oihw: np.ndarray,
    stride: int,
    padding: int,
) -> np.ndarray:
    input_tensor = torch.from_numpy(input_chw[None].astype(np.float32))
    weight_tensor = torch.from_numpy(weight_oihw.astype(np.float32))
    output = F.conv2d(
        input_tensor,
        weight_tensor,
        bias=None,
        stride=stride,
        padding=padding,
    )
    return np.rint(output.detach().cpu().numpy()[0]).astype(np.int32)


def requantize(
    accumulator: np.ndarray,
    layer_quantization: LayerQuantization,
) -> np.ndarray:
    scaled = accumulator.astype(np.float64) * (
        layer_quantization.multiplier / float(1 << SHIFT_BITS)
    )
    quantized = round_away_from_zero(scaled).astype(np.int32)
    if layer_quantization.relu:
        quantized = np.maximum(quantized, 0)
    quantized = np.clip(
        quantized,
        layer_quantization.clamp_min,
        layer_quantization.clamp_max,
    )
    return quantized.astype(np.int8)


def run_integer_inference(
    input_tensor_hwc: np.ndarray,
    quantization: dict[str, LayerQuantization],
) -> dict[str, np.ndarray]:
    current = np.transpose(input_tensor_hwc, (2, 0, 1)).astype(np.int32, copy=False)
    outputs: dict[str, np.ndarray] = {}

    for layer_name in LAYERS:
        layer_quantization = quantization[layer_name]
        accumulator = conv2d_integer(
            current,
            layer_quantization.weight.astype(np.int32),
            stride=layer_quantization.stride,
            padding=layer_quantization.padding,
        )
        current = requantize(accumulator, layer_quantization).astype(np.int32)
        outputs[layer_name] = current.astype(np.int8)

    return outputs


def build_result_summary(conv4_output: np.ndarray) -> dict[str, int]:
    heatmap = conv4_output.reshape(HEATMAP_HEIGHT, HEATMAP_WIDTH)
    flat_index = int(np.argmax(heatmap.reshape(-1)))
    heatmap_y, heatmap_x = divmod(flat_index, HEATMAP_WIDTH)
    target_x = heatmap_x * HEATMAP_CELL_SIZE + HEATMAP_CELL_SIZE // 2
    target_y = heatmap_y * HEATMAP_CELL_SIZE + HEATMAP_CELL_SIZE // 2
    target_score = int(heatmap.reshape(-1)[flat_index])
    return {
        "heatmap_x": heatmap_x,
        "heatmap_y": heatmap_y,
        "target_x": target_x,
        "target_y": target_y,
        "target_score": target_score,
    }


def save_result_text(path: Path, result_summary: dict[str, int]) -> None:
    lines = [
        f"heatmap_x {result_summary['heatmap_x']}",
        f"heatmap_y {result_summary['heatmap_y']}",
        f"target_x {result_summary['target_x']}",
        f"target_y {result_summary['target_y']}",
        f"target_score {result_summary['target_score']}",
    ]
    write_text(path, "\n".join(lines) + "\n")


def build_scales_json(
    quantization: dict[str, LayerQuantization],
) -> dict[str, object]:
    layers_json: dict[str, object] = {}
    running_input_scale = 1.0 / INPUT_NORMALIZATION

    for layer_name in LAYERS:
        cin, cout, in_hw, out_hw, relu = LAYER_GEOMETRY[layer_name]
        layer_quantization = quantization[layer_name]
        layers_json[layer_name] = {
            "cin": cin,
            "cout": cout,
            "k": 1 if layer_name == "conv4" else 3,
            "stride": layer_quantization.stride,
            "pad": layer_quantization.padding,
            "in_hw": in_hw,
            "out_hw": out_hw,
            "relu": relu,
            "input_scale": running_input_scale,
            "weight_scale": layer_quantization.weight_scale,
            "output_scale": layer_quantization.output_scale,
            "multiplier": layer_quantization.multiplier,
            "shift": SHIFT_BITS,
            "clamp": [layer_quantization.clamp_min, layer_quantization.clamp_max],
        }
        running_input_scale = layer_quantization.output_scale

    return {
        "base_spec_version": BASE_SPEC_VERSION,
        "freeze_documents": list(FREEZE_DOCUMENTS),
        "model_version": DELIVERY_MODEL_VERSION,
        "weight_version": DELIVERY_WEIGHT_VERSION,
        "golden_version": DELIVERY_GOLDEN_VERSION,
        "test_vector_version": DELIVERY_TEST_VECTOR_VERSION,
        "tensor_order": "CHW",
        "rounding": "ties_away_from_zero",
        "shift": SHIFT_BITS,
        "layers": layers_json,
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def collect_checksums(
    workspace_root: Path,
    paths: Iterable[Path],
) -> list[tuple[str, int, str]]:
    """(저장소 상대경로, byte 크기, sha256) 목록을 만든다.

    CONTRIBUTING.md "역할별 병합 Gate / B" 가 요구하는 checksum 기록용이다.
    값을 손으로 적지 않고 실제 파일에서 읽는다.
    """
    records: list[tuple[str, int, str]] = []
    for path in paths:
        resolved = path if path.is_absolute() else workspace_root / path
        records.append(
            (
                str(resolved.relative_to(workspace_root)),
                resolved.stat().st_size,
                sha256_file(resolved),
            )
        )
    return records


def format_checksum_table(records: list[tuple[str, int, str]]) -> list[str]:
    lines = ["| 파일 | Bytes | sha256 |", "| --- | ---: | --- |"]
    for relative_path, size, digest in records:
        lines.append(f"| `{relative_path}` | {size} | `{digest}` |")
    return lines


def load_score_calibration(path: Path) -> dict[str, object]:
    """RTL INT8 경로로 생성된 SCORE_TH 실측 결과만 Handoff에 허용한다."""
    if not path.exists():
        raise RuntimeError(
            f"SCORE_TH 실측 파일이 없습니다: {path}. "
            "먼저 ai/calibrate_score_th.py를 실행하세요."
        )
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("score_domain") != "RTL_INT8_INTEGER_GOLDEN_CONV4_MAX":
        raise RuntimeError(
            "SCORE_TH 결과가 RTL INT8 Integer Golden 경로에서 생성되지 않았습니다."
        )
    if payload.get("model_version") != DELIVERY_MODEL_VERSION:
        raise RuntimeError(
            "SCORE_TH model_version이 전달물과 다릅니다: "
            f"{payload.get('model_version')} != {DELIVERY_MODEL_VERSION}"
        )
    return payload


def build_golden_manifest_markdown(
    case_sources: dict[str, str],
    case_summaries: dict[str, dict[str, int]],
    golden_checksums: list[tuple[str, int, str]],
) -> str:
    """golden_outputs/ 색인 문서.

    Layer Tensor 원본을 여기로 복사하지 않는다. 같은 파일을 두 경로에 두면
    진실의 출처가 둘이 되어 갈라지기 때문이다. 대신 test_vectors/caseNN/ 에 있는
    Golden 파일의 sha256 과 Argmax 판정을 모아 bit-exact 비교 기준을 고정한다.
    """
    lines = [
        f"# Integer Golden Manifest — `{DELIVERY_GOLDEN_VERSION}`",
        "",
        "> 소유: B · 생성: `ai/export_b_delivery.py` · 손으로 편집하지 않는다",
        "",
        "Golden Tensor 실파일은 `test_vectors/caseNN/` 에 입력 Vector 와 한 묶음으로 둔다.",
        "이 문서는 그 파일들의 checksum 과 Argmax 판정을 고정한 색인이다.",
        "사본을 만들지 않는 이유는 `README.md` 에 적었다.",
        "",
        "## 1. 버전 묶음",
        "",
        "```text",
        f"MODEL       = {DELIVERY_MODEL_VERSION}",
        f"WEIGHT      = {DELIVERY_WEIGHT_VERSION}",
        f"GOLDEN      = {DELIVERY_GOLDEN_VERSION}",
        f"TEST_VECTOR = {DELIVERY_TEST_VECTOR_VERSION}",
        "```",
        "",
        "## 2. Case 별 Heatmap Argmax·Score",
        "",
        "| Case | 출처 | Heatmap (x, y) | Target (x, y) | Score | `target_valid` (`SCORE_TH=0`) |",
        "| --- | --- | --- | --- | ---: | --- |",
    ]
    for case_name in sorted(case_summaries):
        summary = case_summaries[case_name]
        valid = "true" if summary["target_score"] > 0 else "false"
        lines.append(
            f"| `{case_name}` | `{case_sources[case_name]}` | "
            f"({summary['heatmap_x']}, {summary['heatmap_y']}) | "
            f"({summary['target_x']}, {summary['target_y']}) | "
            f"{summary['target_score']} | `{valid}` |"
        )
    lines.extend(
        [
            "",
            "판정식은 `target_valid = (heatmap_max_score > SCORE_TH)` 이고 Argmax 는",
            "Raster 주사 FIRST_MAX 다. Tie-Break·반올림·포화 규칙은",
            "저장소의 `docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md` 와 동일하게 유지한다.",
            "",
            "## 3. Golden 파일 checksum",
            "",
            *format_checksum_table(golden_checksums),
            "",
            "## 4. 재현",
            "",
            "```bash",
            "./.venv/bin/python ai/export_b_delivery.py \\",
            f"    --checkpoint weights/tiny_cnn_fp32_{DELIVERY_MODEL_VERSION}.pt \\",
            "    --dataset-dir ai/dataset_samples_target_v03",
            "```",
            "",
            "정수 추론 경로는 결정론적이라 같은 checkpoint 에서 항상 같은 byte 가 나온다.",
        ]
    )
    return "\n".join(lines) + "\n"


def build_handoff_markdown(
    checkpoint_path: Path,
    dataset_directory: Path,
    checkpoint: dict[str, object],
    quantization: dict[str, LayerQuantization],
    case_sources: dict[str, str],
    case_summaries: dict[str, dict[str, int]],
    synthetic_no_target_score: int,
    case01_heatmap: np.ndarray,
    dataset_sample_count: int,
    dataset_total_sample_count: int,
    dataset_rejected_sample_count: int,
    dataset_completed_cells: int,
    split_manifest_path: Path,
    capture_sessions: dict[str, list[str]],
    quality_range: dict[str, object],
    provenance_checksums: list[tuple[str, int, str]],
    int8_metrics: dict[str, object] | None,
    latency_metrics: dict[str, object] | None,
    compatibility_metrics: dict[str, object] | None,
    train_cell_accuracy: float | None,
    score_calibration: dict[str, object],
    weight_checksums: list[tuple[str, int, str]],
    input_checksums: list[tuple[str, int, str]],
    golden_checksums: list[tuple[str, int, str]],
) -> str:
    """handoff/README.md 가 정한 B 용 9절 구조로 Handoff 문서를 만든다.

    절 번호와 제목은 팀 TEMPLATE 을 그대로 따른다. 확인하지 않은 값은
    추정하지 않고 PENDING 으로 남긴다 (handoff/README.md 규정).
    """
    train_accuracy_text = (
        f"{train_cell_accuracy:.4f}" if train_cell_accuracy is not None else "PENDING"
    )
    # case01 경계 벡터의 Argmax 여유. 재수출마다 값이 바뀌므로 하드코딩하지 않는다.
    flat_case01 = np.asarray(case01_heatmap, dtype=np.int64).reshape(-1)
    sorted_case01 = np.sort(flat_case01)[::-1]
    case01_top = int(sorted_case01[0])
    case01_gap = int(sorted_case01[0] - sorted_case01[1])
    case01_tied = int((flat_case01 == flat_case01.max()).sum())

    validation_metrics = checkpoint["validation_metrics"]
    test_metrics = checkpoint["test_metrics"]
    training = checkpoint.get("training", {})
    split_counts = training.get("split_counts", {})
    seed = training.get("seed", "PENDING")
    best_epoch = training.get("best_epoch", "PENDING")
    source_spec = checkpoint.get("base_spec_version", "unknown")
    argmax_rule = checkpoint.get("argmax", {})
    target_score_summary = score_calibration["target_summary"]
    no_target_score_summary = score_calibration["no_target_summary"]
    default_score_metrics = score_calibration["threshold_metrics"]["default_0"]
    p99_score_metrics = score_calibration["threshold_metrics"]["no_target_p99"]
    youden_score_metrics = score_calibration["threshold_metrics"]["best_youden"]
    diagnostic_score_summary = score_calibration["diagnostic_all_accepted"]
    train_session_count = len(capture_sessions.get("train", []))
    validation_session_count = len(capture_sessions.get("validation", []))
    test_session_count = len(capture_sessions.get("test", []))

    # ---- §6 품질·성능 표 -------------------------------------------------
    if int8_metrics:
        accuracy_rows = [
            f"| FP32 Cell Accuracy | {int8_metrics['fp32_cell_accuracy']:.4f} | "
            f"`ai/eval_int8.py` · `{int8_metrics['split']}` split "
            f"{int8_metrics['samples']} Sample |",
            f"| FP32 Target Mean MAE | {int8_metrics['fp32_target_mean_mae_px']:.3f} px | "
            "같은 실행 |",
            f"| INT8 Cell Accuracy | **{int8_metrics['int8_cell_accuracy']:.4f}** | "
            "전달물 Golden 과 동일한 정수 추론 경로 |",
            f"| INT8 Target Mean MAE | **{int8_metrics['int8_target_mean_mae_px']:.3f} px** | "
            "같은 실행 |",
            f"| FP32↔INT8 Cell Accuracy 차 | "
            f"{int8_metrics['int8_cell_accuracy'] - int8_metrics['fp32_cell_accuracy']:+.4f} | "
            f"Test {int8_metrics['samples']} Sample 기준 |",
            f"| FP32↔INT8 Target MAE 차 | "
            f"{int8_metrics['int8_target_mean_mae_px'] - int8_metrics['fp32_target_mean_mae_px']:+.3f} px | "
            "MAE 는 작을수록 좋다 |",
            f"| FP32↔INT8 예측 Cell 일치율 | "
            f"{int8_metrics['fp32_int8_cell_agreement']:.4f} | 같은 Cell 을 고른 비율 |",
        ]
        int8_note = "FP32/INT8 차이는 같은 held-out Test Split에서 실측했다."
    else:
        accuracy_rows = [
            "| FP32 Cell Accuracy | PENDING | |",
            "| INT8 Cell Accuracy | PENDING | `ai/eval_int8.py` 미실행 |",
            "| FP32↔INT8 차이 | PENDING | |",
        ]
        int8_note = "INT8 실측치가 없어 PENDING 으로 남긴다."
    if compatibility_metrics:
        compatibility_rows = [
            f"| v02 기존 Test 재평가 FP32 | {compatibility_metrics['fp32_cell_accuracy']:.4f} | "
            f"기존 random Test {compatibility_metrics['samples']} Sample · v03 Weight |",
            f"| v02 기존 Test 재평가 INT8 | {compatibility_metrics['int8_cell_accuracy']:.4f} | "
            "v03 전달 Quantization 기준 |",
        ]
    else:
        compatibility_rows = []
    if latency_metrics:
        latency_rows = [
            f"| CPU FP32 Latency | {latency_metrics['fp32']['median_ms']:.3f} ms median "
            f"/ {latency_metrics['fp32']['p90_ms']:.3f} ms p90 | "
            f"PyTorch CPU eager, n={latency_metrics['iterations']} |",
            f"| CPU INT8 Golden Latency | {latency_metrics['int8']['median_ms']:.3f} ms median "
            f"/ {latency_metrics['int8']['p90_ms']:.3f} ms p90 | "
            "Python/Numpy reference; 최적화 커널이 아님 |",
        ]
        latency_note = (
            "CPU latency는 동일 입력의 warmup 후 반복 실측이며, "
            "INT8은 RTL 정확성을 위한 Python Golden 기준이지 NPU 성능이 아니다."
        )
    else:
        latency_rows = [
            "| CPU FP32 Latency | PENDING | 미측정 |",
            "| CPU INT8 Golden Latency | PENDING | 미측정 |",
        ]
        latency_note = "CPU latency 실측치가 없어 PENDING으로 남긴다."

    lines = [
        "# B Handoff — Model·Quantization·Integer Golden",
        "",
        f"> 상태: **CANDIDATE — A 회귀 승인 대기 · `{DELIVERY_MODEL_VERSION}` / `{DELIVERY_WEIGHT_VERSION}` / "
        f"`{DELIVERY_GOLDEN_VERSION}` / `{DELIVERY_TEST_VECTOR_VERSION}`**",
        ">",
        "> 소유: B · 상위 권한: `docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md`",
        ">",
        "> **이 문서는 `ai/export_b_delivery.py` 의 `build_handoff_markdown()` 이 생성한다.**",
        "> 손으로 고치면 다음 export 때 지워지므로 생성기를 고친다.",
        "> 확인하지 않은 값은 추정하지 않고 `PENDING` 으로 둔다.",
        "",
        "## 1. Version",
        "",
        "```text",
        f"MODEL          = {DELIVERY_MODEL_VERSION}",
        f"WEIGHT         = {DELIVERY_WEIGHT_VERSION}",
        f"GOLDEN         = {DELIVERY_GOLDEN_VERSION}",
        f"TEST_VECTOR    = {DELIVERY_TEST_VECTOR_VERSION}",
        f"DATASET        = {dataset_directory} (품질 사용 {dataset_sample_count} / 전체 {dataset_total_sample_count})",
        f"BASE_SPEC      = {BASE_SPEC_VERSION}",
        f"SOURCE_CKPT    = {checkpoint_path}",
        f"CKPT_BASE_SPEC = {source_spec}",
        "```",
        "",
        "공통 지침 §13 Version Lock 에 따라 네 버전을 함께 올린다. 혼용하지 않는다.",
        "A 는 `weights/scales.json` 의 네 버전 문자열이 위와 같은지 확인한 뒤 RTL 비교를 시작한다.",
        "",
        "Freeze 근거 문서:",
        "",
        f"- `docs/{FREEZE_DOCUMENTS[0]}`",
        f"- `docs/{FREEZE_DOCUMENTS[1]}`",
        f"- 저장소 참고 경로: `docs/{FREEZE_DOCUMENTS[2]}`",
        "",
        "## 2. 입력·출력 Shape",
        "",
        "| 항목 | Shape / dtype / order | 비고 |",
        "|---|---|---|",
        "| NPU Input | `64×64×2`, signed INT8, CHW | 실제값 `0~127`, FP32 변환은 `input_int8 / 127.0` |",
    ]

    for layer_name in LAYERS:
        cin, cout, in_hw, out_hw, relu = LAYER_GEOMETRY[layer_name]
        layer_quantization = quantization[layer_name]
        kernel = 1 if layer_name == "conv4" else 3
        clamp_text = (
            f"clamp `[{layer_quantization.clamp_min},{layer_quantization.clamp_max}]`"
        )
        relu_text = "ReLU" if relu else "ReLU 없음"
        lines.append(
            f"| `{layer_name}` | `{cout}×{out_hw}×{out_hw}`, signed INT8, CHW | "
            f"`{kernel}×{kernel}` / stride {layer_quantization.stride} / "
            f"pad {layer_quantization.padding} / bias 없음 / {relu_text} / {clamp_text} |"
        )

    lines.extend(
        [
            "| Heatmap | `8×8×1`, signed INT8 | `conv4` 출력 그대로. ReLU 없음 |",
            "| Target | `(valid, x, y, score)` | 아래 Argmax 규칙 |",
            "",
            "- Weight Layout: `OIHW`, Cross-Correlation, kernel flip 없음",
            f"- Argmax 주사 순서: `{argmax_rule.get('scan_order', 'YX_RASTER')}`, "
            f"동점 규칙: `{argmax_rule.get('tie_rule', 'FIRST_MAX')}` "
            "(`np.argmax(flatten)` 과 같다)",
            f"- Heatmap Cell → 픽셀 좌표 환산: `x = cell_x * {HEATMAP_CELL_SIZE} + "
            f"{HEATMAP_CELL_SIZE // 2}`, `y = cell_y * {HEATMAP_CELL_SIZE} + "
            f"{HEATMAP_CELL_SIZE // 2}`",
            "- `target_valid = (heatmap_max_score > SCORE_TH)` (공통 지침 §16.1). "
            "`SCORE_TH` 는 §8 참조 — 기본값 `0` 을 유지한다",
            "",
            "## 3. Dataset·Label",
            "",
            f"- Dataset 버전·출처: `{dataset_directory}` — 전체 {dataset_total_sample_count} Sample 중 "
            f"Target Cell Positive Event 품질 필터를 통과한 {dataset_sample_count} Sample 사용, "
            f"{dataset_rejected_sample_count} Sample 제외. "
            "파랑 단색 마커를 사용하고 카메라 제조사 기본 자동 제어를 유지했으며, "
            f"Train {train_session_count}회와 독립 Validation/Test "
            "재설치 Session으로 촬영했다",
            f"- Train/Validation/Test 분할: "
            f"{split_counts.get('train', 'PENDING')} / "
            f"{split_counts.get('validation', 'PENDING')} / "
            f"{split_counts.get('test', 'PENDING')} "
            f"(촬영 Session 역할 고정 분할, 고정 seed `{seed}`, 분할 기록은 `{split_manifest_path}`)",
            "- Label 생성 방식: **실제 표적 중심**. 색상 마커 Color/Blob 검출 "
            "(`ai/dataset.py` 의 `detect_target_marker`). 같은 순간의 표적 중심 좌표를 "
            "`8×8` One-hot Heatmap 으로 변환해 학습 Label 로 쓴다",
            f"- 실제 표적 중심 Label 확인: NPZ 의 `label_source` 가 전체 {dataset_total_sample_count} Sample "
            "전량 `TARGET_MARKER` 다. `validate_dataset_sample` 이 레이저 계열 `label_source` 를 "
            "거부하므로 금지된 Sample 의 학습 혼입은 기계적으로 차단된다",
            f"- 학습·평가 품질 기준: active Event `"
            f"{quality_range.get('minimum_active_pixels', 'PENDING')}~"
            f"{quality_range.get('maximum_active_pixels', 'PENDING')}`, 정답 Cell "
            f"Positive Event `>= {quality_range.get('minimum_target_positive_pixels', 'PENDING')}`, "
            f"정답 Cell 전체 Event `>= "
            f"{quality_range.get('minimum_target_event_pixels', 'PENDING')}`, "
            f"target/active `>= {quality_range.get('minimum_target_event_ratio', 'PENDING')}`, "
            f"Positive Energy Argmax 일치 `"
            f"{quality_range.get('require_target_positive_argmax', 'PENDING')}`. "
            "정답 위치의 Event 근거가 부족한 Sample은 저장·학습·평가에서 제외한다",
            "- Laser 점을 학습 대상으로 사용하지 않았는지: **사용하지 않았다.** 레이저는 NPU 좌표를 "
            "따라가는 출력 장치다. `ai/dataset.py` 의 레이저 검출 경로 "
            "(`detect_red_laser` / `--mode laser`) 는 좌표 Mapping 진단 전용으로만 남아 있다",
            f"- `8×8` Cell 커버리지: {dataset_completed_cells}/64 Cell 수집 완료",
            "- 상세 근거(저장소 참고 경로): `handoff/B_TO_A_DATASET_LABEL_CONFIRM_001.md` §7 · "
            "2026-08-22 규격 정정 (공통 지침 `v1.5` §4 / 개발 계획 §7.1·§7.2 / 역할 분담 `v1.6` §4.1)",
            "",
            "### 3.1 재현성 지문",
            "",
            *format_checksum_table(provenance_checksums),
            "",
            "## 4. Weight·Quantization",
            "",
            "### 4.1 Weight 파일과 checksum",
            "",
            *format_checksum_table(weight_checksums),
            "",
            "### 4.2 Layout·dtype·shape",
            "",
            "- Layout `OIHW`, dtype signed INT8, 파일은 `.mem` 1 줄 1 값 Hex",
            "- Flatten 순서는 `weight.reshape(-1)` 즉 `O → I → H → W`",
        ]
    )

    for layer_name in LAYERS:
        cin, cout, _, _, _ = LAYER_GEOMETRY[layer_name]
        kernel = 1 if layer_name == "conv4" else 3
        lines.append(
            f"- `{layer_name}_weight_int8.mem`: `{cout}×{cin}×{kernel}×{kernel}` "
            f"= {cout * cin * kernel * kernel} 값"
        )

    lines.extend(
        [
            f"- `requant_M.mem`: Layer 순서 `{' → '.join(LAYERS)}`, 32bit unsigned Hex 4 줄",
            "",
            "### 4.3 Scale / Multiplier / Shift",
            "",
            "| Layer | Weight Scale | Output Scale | Multiplier | Shift | Clamp |",
            "|---|---:|---:|---:|---:|---|",
        ]
    )

    for layer_name in LAYERS:
        layer_quantization = quantization[layer_name]
        lines.append(
            f"| `{layer_name}` | {layer_quantization.weight_scale:.9f} | "
            f"{layer_quantization.output_scale:.9f} | "
            f"{layer_quantization.multiplier} | {SHIFT_BITS} | "
            f"`[{layer_quantization.clamp_min},{layer_quantization.clamp_max}]` |"
        )

    lines.extend(
        [
            "",
            "### 4.4 Rounding / Clamp",
            "",
            "- 방식: 대칭 per-layer Weight Quantization + Calibration 기반 Activation Scale",
            "- Rounding: `ties-away-from-zero`",
            f"- Requant: `(acc * M) >> {SHIFT_BITS}` 뒤 위 표의 Clamp 적용",
            "- Conv1~3 은 ReLU 라 하한이 `0`, Conv4 는 ReLU 가 없어 하한이 `-128` 이다",
            "",
            "### 4.5 생성 명령과 random seed",
            "",
            "```bash",
            "# 1단계: 엄격 Session split + 위치 backbone 학습 (Test-blind)",
            "./.venv/bin/python ai/train.py --dataset-dir ai/dataset_samples_target_v03_strict \\",
            "    --no-target-dir ai/no_target_samples_v03 --no-freeze-backbone \\",
            "    --split-strategy session --samples-per-cell 0 \\",
            "    --min-active-pixels 8 --max-active-pixels 1200 \\",
            "    --min-target-positive-pixels 4 --min-target-event-pixels 8 \\",
            "    --min-target-event-ratio 0.10 --require-target-positive-argmax \\",
            "    --loss hybrid --localization-weight 2 --score-weight 0 \\",
            "    --learning-rate 0.0002 --epochs 350 --patience 80 \\",
            "    --augment-train-d4 --no-evaluate-test \\",
            "    --output-model weights/strict_candidates/c5_pureloc_seed42.pt",
            "# 2단계: 위치 정확도 보존 + 아주 작은 score 규제 (Test-blind)",
            "./.venv/bin/python ai/train.py --dataset-dir ai/dataset_samples_target_v03_strict \\",
            "    --no-target-dir ai/no_target_samples_v03 --no-freeze-backbone \\",
            "    --split-strategy session --samples-per-cell 0 \\",
            "    --min-active-pixels 8 --max-active-pixels 1200 \\",
            "    --min-target-positive-pixels 4 --min-target-event-pixels 8 \\",
            "    --min-target-event-ratio 0.10 --require-target-positive-argmax \\",
            "    --init-checkpoint weights/strict_candidates/c5_pureloc_seed42.pt \\",
            "    --loss hybrid --localization-weight 2 --score-weight 0.01 \\",
            "    --learning-rate 0.00001 --epochs 200 --patience 80 \\",
            "    --augment-train-d4 --no-evaluate-test \\",
            "    --output-model weights/strict_candidates/c5_score_gentle.pt",
            "# 후보 선택 후 strict_test를 1회만 열어 FP32/INT8 평가",
            "./.venv/bin/python ai/eval_int8.py \\",
            "    --checkpoint weights/tiny_cnn_fp32_model_v03.pt \\",
            "    --dataset-dir ai/dataset_samples_target_v03_strict \\",
            "    --split-manifest results/model_v03_split.json --split test",
            "./.venv/bin/python ai/calibrate_score_th.py --evaluation-split validation",
            "./.venv/bin/python ai/export_b_delivery.py \\",
            "    --dataset-dir ai/dataset_samples_target_v03_strict",
            "./.venv/bin/python ai/verify_b_delivery.py --archive results/b_deliver_v03.zip",
            "```",
            f"FP32 학습 seed는 `{seed}`, 선택 checkpoint의 best epoch는 `{best_epoch}`다. "
            f"현재 전달물은 고정된 {DELIVERY_MODEL_VERSION} checkpoint에서 재생성한다.",
            "",
            "## 5. Test Vector·Integer Golden",
            "",
            "### 5.1 입력 Vector 파일과 checksum",
            "",
            *format_checksum_table(input_checksums),
            "",
            "### 5.2 Layer별 Golden 파일과 checksum",
            "",
            *format_checksum_table(golden_checksums),
            "",
            "Golden Tensor 는 입력 Vector 와 같은 `test_vectors/caseNN/` 에 둔다. "
            "중복 사본은 만들지 않고 이 checksum 표를 bit-exact 기준으로 사용한다.",
            "",
            "### 5.3 재현 명령",
            "",
            "```bash",
            "./.venv/bin/python ai/export_b_delivery.py \\",
            f"    --checkpoint {checkpoint_path} \\",
            f"    --dataset-dir {dataset_directory} \\",
            f"    --split-manifest {split_manifest_path}",
            "```",
            "",
            "정수 추론 경로 `run_integer_inference()` 는 결정론적이라 같은 checkpoint 에서 "
            "항상 같은 byte 가 나온다. 위 checksum 이 재현 판정 기준이다.",
            "",
            "### 5.4 Argmax / `target_valid` 판정 결과",
            "",
            "| Case | 출처 | Heatmap (x, y) | Target (x, y) | Score | `target_valid` (`SCORE_TH=0`) |",
            "| --- | --- | --- | --- | ---: | --- |",
        ]
    )

    for case_name in sorted(case_summaries):
        summary = case_summaries[case_name]
        valid = "true" if summary["target_score"] > 0 else "false"
        lines.append(
            f"| `{case_name}` | `{case_sources[case_name]}` | "
            f"({summary['heatmap_x']}, {summary['heatmap_y']}) | "
            f"({summary['target_x']}, {summary['target_y']}) | "
            f"{summary['target_score']} | `{valid}` |"
        )

    lines.extend(
        [
            "",
            f"- `case00`: 실제 Dataset Sample. 출처 `{case_sources['case00']}`",
            f"- `case01`: `{case_sources['case01']}` — 결정론적 합성 경계 텐서다. "
            "실제 Dataset Sample 이 아니다. y=0 / y=63 / x=0 / x=63 네 변 512 픽셀이 전부 0 이 "
            "아니고 네 모서리는 127 이라서, pad=1 경계 처리가 틀리면 이 벡터에서 결과가 어긋난다",
            f"- `case01` 의 표적은 Heatmap 모서리 셀 `(0,0)` 이다 "
            f"(최대값 {case01_top}, 동점 {case01_tied}개, 2등과 격차 {case01_gap}). "
            "`docs/B_TO_A_DELIVERY_SPEC.md` §5-3 의 \"표적이 모서리\" 규정과 일치한다",
            f"- `case02`: `{case_sources['case02']}` — 전 0 입력. max score "
            f"`{synthetic_no_target_score}` 라 `SCORE_TH=0` 에서 `target_valid=false` 다",
            "",
            "## 6. 품질·성능",
            "",
            "| 항목 | 결과 | 환경·명령 |",
            "|---|---:|---|",
            f"| Validation Cell Accuracy | {validation_metrics['cell_accuracy']:.4f} | "
            f"`ai/train.py` best epoch {best_epoch} |",
            f"| Validation Target Mean MAE | {validation_metrics['target_mean_mae_px']:.3f} px | "
            "같은 실행 |",
            f"| Test Cell Accuracy | {test_metrics['cell_accuracy']:.4f} | 같은 실행 |",
            f"| Test Target Mean MAE | {test_metrics['target_mean_mae_px']:.3f} px | 같은 실행 |",
            *accuracy_rows,
            *compatibility_rows,
            *latency_rows,
            "",
            f"- {int8_note}",
            f"- {latency_note}",
            "- 원본 수치(저장소 참고 경로): "
            f"`{RESULTS_DIR.as_posix()}/{DELIVERY_MODEL_VERSION}_int8_accuracy.json` · "
            f"`{RESULTS_DIR.as_posix()}/{DELIVERY_MODEL_VERSION}_fp32_accuracy_report.md`",
            "",
            "## 7. A/C 영향과 승인 요청",
            "",
            "### A 가 적용해야 할 파일·Parameter",
            "",
            "- `weights/*.mem` 4 개와 `weights/requant_M.mem`, `weights/scales.json` 을 "
            f"`{DELIVERY_WEIGHT_VERSION}` 로 교체한다",
            f"- Requant Shift `{SHIFT_BITS}` 와 §4.3 Multiplier 를 RTL Parameter 에 반영한다",
            "- `test_vectors/case00~case02` 로 `tb/npu/` 회귀를 재실행하고 §5.2 checksum 과 "
            "bit-exact 비교 결과를 기록한다",
            "- **이 전달물은 v02의 실제 표적 Label을 유지하면서 Target-Event 정렬 필터와 "
            "무표적 fine-tuning을 추가한 v03 후보이다.** A 회귀가 통과한 뒤에만 v02를 대체한다",
            "",
            "### C Event Window/Polarity 영향",
            "",
            "- 입력 계약(`64×64×2`, signed INT8, CHW, 실제값 `0~127`)은 바뀌지 않았다. "
            "C 의 Event Tensor 생성 경로는 수정할 것이 없다",
            "- §8 실측상 heatmap score만으로 표적 유무를 가르기 어렵다. `INPUT_STAT` Event "
            "Count를 보조 조건으로 쓰는 방안은 **Change Request 후보**이며, A/C 승인 전에는 "
            "구현하지 않는다",
            "",
            "### 공유 Interface 변경 요청",
            "",
            f"- 본 {DELIVERY_MODEL_VERSION} 전달물에는 없다. `target_valid = (score > SCORE_TH)` 계약과 포트·비트폭은 "
            "그대로다. Event Count 보조 판정은 필요 시 별도 Change Request로 올린다",
            "",
            "### 필요한 승인",
            "",
            "1. A: §5.2 checksum 기준 bit-exact 비교 PASS 여부 회신",
            "2. A/C: §8 SCORE_TH 실측 접수 및 별도 Change Request 필요 여부 회신",
            f"3. 통합: `docs/integration_manifest.md` 의 B 버전을 `{DELIVERY_MODEL_VERSION}` / "
            f"`{DELIVERY_WEIGHT_VERSION}` / `{DELIVERY_GOLDEN_VERSION}` / "
            f"`{DELIVERY_TEST_VECTOR_VERSION}` 로 갱신 (B 소유 경로가 아니라 직접 고치지 않았다)",
            "",
            "## 8. Known Limitation·남은 작업",
            "",
            "### 8.1 Dataset 품질 필터와 비교 범위",
            "",
            f"- 전체 {dataset_total_sample_count} Sample에 active "
            f"{quality_range.get('minimum_active_pixels')}~"
            f"{quality_range.get('maximum_active_pixels')}, target positive >="
            f"{quality_range.get('minimum_target_positive_pixels')}, target event >="
            f"{quality_range.get('minimum_target_event_pixels')}, target/active >="
            f"{quality_range.get('minimum_target_event_ratio')}, positive argmax 필수를 "
            f"적용해 {dataset_sample_count} Sample을 사용했다.",
            f"- Train/Validation/Test는 {split_counts.get('train', 'PENDING')} / "
            f"{split_counts.get('validation', 'PENDING')} / {split_counts.get('test', 'PENDING')}이며, "
            "촬영 Session metadata의 역할에 따라 Train/Validation/Test를 격리했다.",
            f"- 엄격 필터 Test Cell Accuracy는 {test_metrics['cell_accuracy']:.4f}다. "
            "v02의 전체 1280 Sample random split 수치와 모집단이 달라 직접적인 절대 비교에는 제한이 있다.",
            "",
            "### 8.2 `SCORE_TH` 실측 — held-out 분리 한계 확인",
            "",
            f"학습에 사용하지 않은 `{score_calibration['evaluation_split']}` Split의 표적 "
            f"{target_score_summary['sample_count']} Sample과 무표적 "
            f"{no_target_score_summary['sample_count']} Sample을 전달물과 같은 INT8 정수 추론 경로로 측정했다.",
            "",
            "| 구분 | Sample | Score 중앙값 | Score p90 | Score p99 |",
            "| --- | ---: | ---: | ---: | ---: |",
            f"| 표적 있음 | {target_score_summary['sample_count']} | "
            f"{target_score_summary['median']:.1f} | {target_score_summary['p90']:.1f} | "
            f"{target_score_summary['p99']:.1f} |",
            f"| 표적 없음 | {no_target_score_summary['sample_count']} | "
            f"{no_target_score_summary['median']:.1f} | {no_target_score_summary['p90']:.1f} | "
            f"{no_target_score_summary['p99']:.1f} |",
            "",
            f"- Held-out AUC는 `{score_calibration['auc']:.4f}`로 0.5 무작위 수준보다도 "
            "낮다. 위치 정확도와 별개로, heatmap max score만으로는 "
            "현재 무표적 움직임을 안정적으로 분리하지 못한다.",
            f"- 무표적 p99 후보는 `{score_calibration['no_target_p99_candidate']}`지만, "
            f"strict `>` 판정에서 이 값을 쓰면 TPR `{p99_score_metrics['true_positive_rate']:.4f}`, "
            f"FPR `{p99_score_metrics['false_positive_rate']:.4f}`다. 기본값 0도 TPR "
            f"`{default_score_metrics['true_positive_rate']:.4f}`, FPR "
            f"`{default_score_metrics['false_positive_rate']:.4f}`다. Youden 진단 후보 "
            f"`{youden_score_metrics['score_th']}`에서는 TPR "
            f"`{youden_score_metrics['true_positive_rate']:.4f}`, FPR "
            f"`{youden_score_metrics['false_positive_rate']:.4f}`다.",
            f"- 학습에 사용한 Sample까지 포함한 전체 수집분 진단 AUC는 "
            f"`{diagnostic_score_summary['auc']:.4f}`다. Held-out과 차이가 커 촬영 구간별 "
            "Event 에너지 분포 이동이 있음을 보여준다.",
            "- **가능성이 큰 요인.** v02는 무표적을 학습하지 않았고, 현재 데이터는 독립 촬영 "
            "Session 사이의 Event 에너지 분포 차이가 크다. 또한 bias 없는 ReLU CNN의 양의 동차성은 "
            "절대 score를 입력 크기에 민감하게 만든다. 어느 하나를 단일 원인으로 단정하지 않는다.",
            "- **v03 보완.** Target Cell Event 품질 Gate와 촬영 Session Split을 "
            "적용했다. 1단계에서 전체 Conv1~4를 위치 Cross-Entropy 중심으로 "
            "학습하고, 2단계에서 위치 정확도를 보존하는 작은 score 규제 "
            "가중치 0.01을 적용했다. Train에만 D4를 사용했고 극성 교환은 "
            "사용하지 않았다.",
            "- **결론과 제안.** `SCORE_TH` 는 기본값 `0` 을 유지한다. Event Count 보조 판정은 "
            "A/C가 별도 Change Request로 승인할 경우에만 적용한다. `SCORE_TH` 는 런타임 AXI "
            "레지스터 값이므로 나중에 정책이 바뀌어도 Weight/Golden 재생성은 필요 없다.",
            f"- 실측 원본(저장소 참고 경로)은 `results/{DELIVERY_MODEL_VERSION}_score_th_calibration_report.md`와 "
            f"`results/{DELIVERY_MODEL_VERSION}_score_th_calibration.json`이며, 본 ZIP에는 위 요약을 포함했다.",
            "- 추가 개선 우선순위는 더 다양한 조도·배경의 독립 Session과 파란색이 아닌 Hard Negative 확충이다. 그 뒤에도 분리가 "
            "부족하면 `bias=False` 동결 해제나 표적 유무 분류 Head를 검토해야 하며, 이 구조 변경은 "
            "SPEC Change Request 없이 B 단독으로 적용하지 않는다.",
            "",
            "### 8.3 Dataset 환경 의존",
            "",
            f"- Train {train_session_count}개, Validation {validation_session_count}개, "
            f"Test {test_session_count}개의 독립 표적 Session과 quiet/motion으로 나눈 "
            "무표적 6개 Session에서 수집했다. 제조사 기본 자동 노출·화이트밸런스를 유지했으며, "
            "새 조명·배경·마커로 바뀌면 정확도를 다시 측정해야 한다.",
            "",
            "### 8.4 단일 표적 전제",
            "",
            "- 공통 지침 §4 대로 단일 실연 표적 한 종류만 다룬다. 다중 표적·다중 클래스는 "
            "현재 인터페이스 범위가 아니다.",
            "",
            "### 8.5 남은 작업",
            "",
            "- A 의 `tb/npu/` bit-exact 비교 결과 회신 수령",
            "- `docs/integration_manifest.md` B 버전 갱신 (소유자 경유)",
            "",
            "## 9. 전달 체크리스트",
            "",
            "- [x] `weights/` 실제 산출물과 checksum — §4.1",
            "- [x] `test_vectors/` 공식 입력 — §5.1",
            "- [x] Layer별 Golden bit-exact checksum — §5.2",
            f"- [x] `{RESULTS_DIR.as_posix()}/` Accuracy·Quantization 보고서 — §6",
            "- [x] 재현 명령·환경·seed — §4.5 · §5.3",
            "- [ ] `docs/integration_manifest.md` 버전 갱신 — B 소유 경로가 아니라 대기 중",
            "- [ ] A NPU TB 비교 결과 또는 전달 요청 — §7 승인 1번 대기 중",
        ]
    )
    return "\n".join(lines) + "\n"


def build_delivery_manifest(
    checkpoint_path: Path,
    checkpoint: dict[str, object],
    case_summaries: dict[str, dict[str, int]],
    case_sources: dict[str, str],
    delivery_checksums: list[tuple[str, int, str]],
) -> dict[str, object]:
    return {
        "base_spec_version": BASE_SPEC_VERSION,
        "freeze_documents": list(FREEZE_DOCUMENTS),
        "checkpoint_path": str(checkpoint_path),
        "checkpoint_base_spec_version": checkpoint.get("base_spec_version"),
        "model_version": DELIVERY_MODEL_VERSION,
        "weight_version": DELIVERY_WEIGHT_VERSION,
        "golden_version": DELIVERY_GOLDEN_VERSION,
        "test_vector_version": DELIVERY_TEST_VECTOR_VERSION,
        "case_sources": case_sources,
        "case_results": case_summaries,
        "files": [
            {"path": path, "bytes": size, "sha256": digest}
            for path, size, digest in delivery_checksums
        ],
    }


def create_archive(
    archive_path: Path,
    workspace_root: Path,
    members: list[Path],
) -> None:
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = archive_path.with_suffix(archive_path.suffix + ".tmp")
    with ZipFile(temporary_path, "w", compression=ZIP_DEFLATED) as zip_file:
        for member in members:
            zip_file.write(member, arcname=str(member.relative_to(workspace_root)))
    temporary_path.replace(archive_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="B -> A 전달 규격 산출물 생성기"
    )
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
    parser.add_argument(
        "--workspace-root",
        type=Path,
        default=Path("."),
    )
    parser.add_argument(
        "--archive-output",
        type=Path,
        default=Path("results/b_deliver_v03.zip"),
    )
    parser.add_argument(
        "--score-calibration",
        type=Path,
        default=Path("results/model_v03_score_th_calibration.json"),
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    checkpoint_path = args.checkpoint
    workspace_root = args.workspace_root.resolve()
    score_calibration = load_score_calibration(args.score_calibration)

    checkpoint, model = load_model(checkpoint_path)
    _, valid_samples, errors, _ = inspect_dataset_directory(args.dataset_dir)
    if errors:
        error_summary = "; ".join(
            f"{path.name}: {message}" for path, message in errors
        )
        raise RuntimeError(f"Dataset 검증 오류가 있어 전달물을 만들 수 없습니다: {error_summary}")
    if not valid_samples:
        raise RuntimeError(f"전달용 Sample이 없습니다: {args.dataset_dir}")
    if checkpoint.get("model_version") != DELIVERY_MODEL_VERSION:
        raise RuntimeError(
            f"Checkpoint Version 불일치: {checkpoint.get('model_version')} != "
            f"{DELIVERY_MODEL_VERSION}"
        )
    if score_calibration.get("checkpoint") != str(checkpoint_path):
        raise RuntimeError(
            "SCORE_TH Calibration checkpoint가 현재 전달 checkpoint와 다릅니다."
        )
    if score_calibration.get("split_manifest") != str(args.split_manifest):
        raise RuntimeError(
            "SCORE_TH Calibration Split Manifest가 현재 전달 Split과 다릅니다."
        )

    split_manifest = json.loads(args.split_manifest.read_text(encoding="utf-8"))
    if split_manifest.get("model_version") != DELIVERY_MODEL_VERSION:
        raise RuntimeError("Split Manifest Version이 전달물과 다릅니다.")
    if split_manifest.get("test_status") != "EVALUATED_ONCE_FINAL":
        raise RuntimeError("Split Manifest의 최종 Test 평가 상태가 확정되지 않았습니다.")
    quality = split_manifest["quality_range"]
    accepted_samples, rejected_samples, _ = build_quality_distribution(
        valid_samples,
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
    accepted_by_path = {sample.path: sample for sample in accepted_samples}
    calibration_paths = [Path(path) for path in split_manifest["splits"]["train"]]
    missing_calibration = [
        path for path in calibration_paths if path not in accepted_by_path
    ]
    if missing_calibration:
        raise RuntimeError(
            f"Quantization Calibration Sample 누락: {missing_calibration[0]}"
        )
    calibration_samples = [accepted_by_path[path] for path in calibration_paths]
    quantization = build_quantization(model, calibration_samples)

    # INT8 실측치와 Train Accuracy는 있으면 읽고, 없으면 추정하지 않고 미측정으로 남긴다.
    int8_metrics: dict[str, object] | None = None
    int8_path = Path("results") / f"{DELIVERY_MODEL_VERSION}_int8_accuracy.json"
    if int8_path.exists():
        int8_metrics = json.loads(int8_path.read_text(encoding="utf-8"))
        if int8_metrics.get("model_version") != DELIVERY_MODEL_VERSION:
            raise RuntimeError("INT8 Accuracy Version이 전달물과 다릅니다.")
        if int8_metrics.get("checkpoint") != str(checkpoint_path):
            raise RuntimeError("INT8 Accuracy checkpoint가 전달 checkpoint와 다릅니다.")
        if int8_metrics.get("split") != "test":
            raise RuntimeError("INT8 Accuracy는 최종 Test Split 결과여야 합니다.")
        if int(int8_metrics.get("samples", 0)) != len(
            split_manifest["splits"]["test"]
        ):
            raise RuntimeError("INT8 Accuracy Sample 수가 Split Manifest와 다릅니다.")
        checkpoint_test = checkpoint.get("test_metrics") or {}
        if not np.isclose(
            float(int8_metrics["fp32_cell_accuracy"]),
            float(checkpoint_test.get("cell_accuracy", -1.0)),
        ):
            raise RuntimeError("INT8 Accuracy의 FP32 Test 수치가 checkpoint와 다릅니다.")
        print(f"INT8 실측치 반영: {int8_path}")
    else:
        print(f"INT8 실측치 없음 (미측정으로 기재): {int8_path}")

    latency_metrics: dict[str, object] | None = None
    latency_path = Path("results") / f"{DELIVERY_MODEL_VERSION}_latency.json"
    if latency_path.exists():
        latency_metrics = json.loads(latency_path.read_text(encoding="utf-8"))
        if latency_metrics.get("model_version") != DELIVERY_MODEL_VERSION:
            raise RuntimeError("Latency model_version이 전달물과 다릅니다.")
        if latency_metrics.get("checkpoint") != str(checkpoint_path):
            raise RuntimeError("Latency checkpoint가 전달 checkpoint와 다릅니다.")
        if latency_metrics.get("split_manifest") != str(args.split_manifest):
            raise RuntimeError("Latency Split Manifest가 전달 Split과 다릅니다.")
        print(f"CPU Latency 실측치 반영: {latency_path}")
    else:
        print(f"CPU Latency 실측치 없음 (PENDING): {latency_path}")

    compatibility_metrics: dict[str, object] | None = None
    compatibility_path = (
        Path("results") / f"{DELIVERY_MODEL_VERSION}_on_v02_test_accuracy.json"
    )
    if compatibility_path.exists():
        compatibility_metrics = json.loads(
            compatibility_path.read_text(encoding="utf-8")
        )
        if compatibility_metrics.get("model_version") != DELIVERY_MODEL_VERSION:
            raise RuntimeError("v02 Test 재평가 Version이 전달물과 다릅니다.")

    train_cell_accuracy: float | None = None
    history_path = Path("results") / f"{DELIVERY_MODEL_VERSION}_train_history.json"
    if history_path.exists():
        history = json.loads(history_path.read_text(encoding="utf-8"))
        if history.get("canonical_checkpoint") != str(checkpoint_path):
            raise RuntimeError("Train History checkpoint provenance가 일치하지 않습니다.")
        if history.get("final_split_manifest") != str(args.split_manifest):
            raise RuntimeError("Train History Split provenance가 일치하지 않습니다.")
        if history.get("test_evaluated") is not True:
            raise RuntimeError("Train History에 최종 Test 평가가 반영되지 않았습니다.")
        best_epoch = checkpoint.get("training", {}).get("best_epoch")
        for entry in history.get("history", []):
            if entry.get("epoch") == best_epoch:
                train_cell_accuracy = float(entry["train"]["cell_accuracy"])
                break

    # 8x8 Cell 커버리지는 Handoff 문서에 실측값으로 기재한다 (하드코딩 금지).
    cell_hit = np.zeros((8, 8), dtype=np.int64)
    for sample in accepted_samples:
        cell_hit[sample.heatmap_y, sample.heatmap_x] += 1
    completed_cells = int(np.count_nonzero(cell_hit))

    weights_dir = workspace_root / "weights"
    test_vectors_dir = workspace_root / "test_vectors"
    handoff_dir = workspace_root / "handoff"
    results_dir = workspace_root / "results"

    for layer_name in LAYERS:
        write_hex_lines(
            weights_dir / f"{layer_name}_weight_int8.mem",
            quantization[layer_name].weight.reshape(-1),
        )
    requant_m = np.array(
        [quantization[layer_name].multiplier for layer_name in LAYERS],
        dtype=np.uint32,
    )
    write_text(
        weights_dir / "requant_M.mem",
        "\n".join(f"{int(value):08X}" for value in requant_m) + "\n",
    )
    write_json(weights_dir / "scales.json", build_scales_json(quantization))

    delivery_test_paths = [
        Path(path) for path in split_manifest["splits"]["test"]
    ]
    missing_delivery_test = [
        path for path in delivery_test_paths if path not in accepted_by_path
    ]
    if missing_delivery_test:
        raise RuntimeError(
            f"case00 후보 Test Sample 누락: {missing_delivery_test[0]}"
        )
    delivery_test_samples = [
        accepted_by_path[path] for path in delivery_test_paths
    ]
    selected_cases = choose_delivery_cases(
        delivery_test_samples,
        quantization,
    )
    case_sources = {
        "case00": str(selected_cases["case00"].path),
        "case01": "synthetic_boundary_corner",
        "case02": "synthetic_zero_input",
    }
    case_summaries: dict[str, dict[str, int]] = {}

    for case_name, sample_info in selected_cases.items():
        input_tensor_hwc = load_input_tensor(sample_info.path)
        outputs = run_integer_inference(input_tensor_hwc, quantization)
        case_dir = test_vectors_dir / case_name
        write_hex_lines(case_dir / "input_event.hex", np.transpose(input_tensor_hwc, (2, 0, 1)))
        write_hex_lines(case_dir / "conv1_out.hex", outputs["conv1"])
        write_hex_lines(case_dir / "conv2_out.hex", outputs["conv2"])
        write_hex_lines(case_dir / "conv3_out.hex", outputs["conv3"])
        write_hex_lines(case_dir / "conv4_out.hex", outputs["conv4"])
        result_summary = build_result_summary(outputs["conv4"])
        if (
            (result_summary["heatmap_x"], result_summary["heatmap_y"])
            != (sample_info.heatmap_x, sample_info.heatmap_y)
            or result_summary["target_score"] <= 0
        ):
            raise RuntimeError(
                f"{case_name} Label/INT8 Argmax/SCORE_TH 의미 검증 실패"
            )
        save_result_text(case_dir / "result_xy.txt", result_summary)
        case_summaries[case_name] = result_summary

    # case01: pad=1 경계 로직 검증용 결정론적 합성 텐서 (실제 Dataset 샘플 아님)
    boundary_input = build_boundary_case_tensor()
    boundary_outputs = run_integer_inference(boundary_input, quantization)
    case01_dir = test_vectors_dir / "case01"
    write_hex_lines(
        case01_dir / "input_event.hex", np.transpose(boundary_input, (2, 0, 1))
    )
    write_hex_lines(case01_dir / "conv1_out.hex", boundary_outputs["conv1"])
    write_hex_lines(case01_dir / "conv2_out.hex", boundary_outputs["conv2"])
    write_hex_lines(case01_dir / "conv3_out.hex", boundary_outputs["conv3"])
    write_hex_lines(case01_dir / "conv4_out.hex", boundary_outputs["conv4"])
    case01_summary = build_result_summary(boundary_outputs["conv4"])
    case01_flat = boundary_outputs["conv4"].reshape(-1)
    if (
        (case01_summary["heatmap_x"], case01_summary["heatmap_y"]) != (0, 0)
        or case01_summary["target_score"] <= 0
        or int(np.count_nonzero(case01_flat == case01_flat.max())) != 1
    ):
        raise RuntimeError(
            "case01은 단독 (0,0) Argmax이고 SCORE_TH=0을 통과해야 합니다."
        )
    save_result_text(case01_dir / "result_xy.txt", case01_summary)
    case_summaries["case01"] = case01_summary

    zero_input = np.zeros((64, 64, 2), dtype=np.int8)
    zero_outputs = run_integer_inference(zero_input, quantization)
    case02_dir = test_vectors_dir / "case02"
    write_hex_lines(case02_dir / "input_event.hex", np.transpose(zero_input, (2, 0, 1)))
    write_hex_lines(case02_dir / "conv1_out.hex", zero_outputs["conv1"])
    write_hex_lines(case02_dir / "conv2_out.hex", zero_outputs["conv2"])
    write_hex_lines(case02_dir / "conv3_out.hex", zero_outputs["conv3"])
    write_hex_lines(case02_dir / "conv4_out.hex", zero_outputs["conv4"])
    case02_summary = build_result_summary(zero_outputs["conv4"])
    if case02_summary["target_score"] != 0:
        raise RuntimeError(
            "case02 zero-input은 SCORE_TH=0에서 target_valid=false여야 합니다."
        )
    save_result_text(case02_dir / "result_xy.txt", case02_summary)
    case_summaries["case02"] = case02_summary

    weight_paths = [
        weights_dir / "conv1_weight_int8.mem",
        weights_dir / "conv2_weight_int8.mem",
        weights_dir / "conv3_weight_int8.mem",
        weights_dir / "conv4_weight_int8.mem",
        weights_dir / "requant_M.mem",
        weights_dir / "scales.json",
    ]
    input_paths = [
        test_vectors_dir / case_name / "input_event.hex"
        for case_name in ("case00", "case01", "case02")
    ]
    golden_paths = [
        test_vectors_dir / case_name / file_name
        for case_name in ("case00", "case01", "case02")
        for file_name in (
            "conv1_out.hex",
            "conv2_out.hex",
            "conv3_out.hex",
            "conv4_out.hex",
            "result_xy.txt",
        )
    ]
    weight_checksums = collect_checksums(workspace_root, weight_paths)
    input_checksums = collect_checksums(workspace_root, input_paths)
    golden_checksums = collect_checksums(workspace_root, golden_paths)
    provenance_paths = [
        checkpoint_path,
        args.split_manifest,
        args.score_calibration,
    ]
    provenance_paths.extend(
        path
        for path in (int8_path, history_path, latency_path)
        if path.exists()
    )
    provenance_checksums = collect_checksums(
        workspace_root,
        provenance_paths,
    )

    handoff_text = build_handoff_markdown(
        checkpoint_path=checkpoint_path,
        dataset_directory=args.dataset_dir,
        checkpoint=checkpoint,
        quantization=quantization,
        case_sources=case_sources,
        case_summaries=case_summaries,
        synthetic_no_target_score=case02_summary["target_score"],
        case01_heatmap=boundary_outputs["conv4"],
        dataset_sample_count=len(accepted_samples),
        dataset_total_sample_count=len(valid_samples),
        dataset_rejected_sample_count=len(rejected_samples),
        dataset_completed_cells=completed_cells,
        split_manifest_path=args.split_manifest,
        capture_sessions=split_manifest["capture_sessions"],
        quality_range=split_manifest["quality_range"],
        provenance_checksums=provenance_checksums,
        int8_metrics=int8_metrics,
        latency_metrics=latency_metrics,
        compatibility_metrics=compatibility_metrics,
        train_cell_accuracy=train_cell_accuracy,
        score_calibration=score_calibration,
        weight_checksums=weight_checksums,
        input_checksums=input_checksums,
        golden_checksums=golden_checksums,
    )
    write_text(handoff_dir / "B_MODEL_HANDOFF.md", handoff_text)

    archive_members = [
        *weight_paths,
        *[
            test_vectors_dir / case_name / file_name
            for case_name in ("case00", "case01", "case02")
            for file_name in (
                "input_event.hex",
                "conv1_out.hex",
                "conv2_out.hex",
                "conv3_out.hex",
                "conv4_out.hex",
                "result_xy.txt",
            )
        ],
        handoff_dir / "B_MODEL_HANDOFF.md",
    ]
    delivery_checksums = collect_checksums(workspace_root, archive_members)

    manifest = build_delivery_manifest(
        checkpoint_path=checkpoint_path,
        checkpoint=checkpoint,
        case_summaries=case_summaries,
        case_sources=case_sources,
        delivery_checksums=delivery_checksums,
    )
    write_json(results_dir / "b_delivery_manifest.json", manifest)
    create_archive(args.archive_output, workspace_root, archive_members)

    print(f"전달용 체크포인트: {checkpoint_path}")
    for layer_name in LAYERS:
        layer_quantization = quantization[layer_name]
        print(
            f"{layer_name}: weight_scale={layer_quantization.weight_scale:.9f} "
            f"output_scale={layer_quantization.output_scale:.9f} "
            f"multiplier={layer_quantization.multiplier}"
        )
    print(f"case00 source: {case_sources['case00']}")
    print(f"case01 source: {case_sources['case01']}")
    print(f"case01 result: {case01_summary}")
    print(f"case02 synthetic score: {case02_summary['target_score']}")
    print(f"handoff: {handoff_dir / 'B_MODEL_HANDOFF.md'}")
    print(f"archive: {args.archive_output}")


if __name__ == "__main__":
    main()
