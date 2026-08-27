#!/usr/bin/env python3
"""B 역할 Tiny CNN FP32 학습 및 정확도 측정 모듈.

최상위 기준은 TEAM_COMMON_AI_INTEGRATION_SPEC v1.2이며, 2026-08-21
A/B 승인 완료 CNN Convolution Freeze와 A의 Freeze Request #001을 함께 적용한다.

고정 구조:

    Input  64×64×2
    Conv1  3×3 / stride 2 / padding 1 / 2→8 / bias 없음 / ReLU
    Conv2  3×3 / stride 2 / padding 1 / 8→16 / bias 없음 / ReLU
    Conv3  3×3 / stride 2 / padding 1 / 16→32 / bias 없음 / ReLU
    Conv4  1×1 / stride 1 / padding 0 / 32→1 / bias 없음 / ReLU 없음
    Output 8×8 Heatmap

NPZ Dataset의 HWC 논리 배열은 PyTorch 학습 경계에서 CHW로 변환한다.
FP32 입력은 Event Count를 127로 나눈 0.0~1.0 값이다. 이후 INT8
Quantization에서는 이 전처리를 기준으로 Conv1 Input Scale을 Calibration한다.
"""

from __future__ import annotations

import argparse
import copy
import json
import random
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
from torch.utils.data import DataLoader, Dataset

from dataset import (
    DatasetSampleInfo,
    HEATMAP_HEIGHT,
    HEATMAP_WIDTH,
    NoTargetSampleInfo,
    SIGNED_INT8_MAX,
    TENSOR_CHANNELS,
    TENSOR_HEIGHT,
    TENSOR_WIDTH,
    build_quality_distribution,
    inspect_dataset_directory,
    inspect_no_target_directory,
)


# 2026-08-25: 무표적(negative) Sample을 학습에 포함해 §16.1 SCORE_TH가 의미를
# 갖도록 손실을 BCEWithLogitsLoss로 전환한 재학습분이다. 공통 지침 §13 Version
# Lock에 따라 weight/golden/testvec과 함께 v03이다. 산출물 파일명과 체크포인트
# provenance가 이 값을 따르므로 v03 결과를 model_v02_* 이름으로 내보내지 않는다.
# CNN 구조·출력 형상(8×8×1)·좌표 Mapping·Argmax 규칙은 A/B Freeze 그대로다.
MODEL_VERSION = "model_v03"
BASE_SPEC_VERSION = "common_v1.5"
INPUT_NORMALIZATION = float(SIGNED_INT8_MAX)
EXPECTED_PARAMETER_COUNT = 5_936
# 2026-08-22 규격 정정: 실제 표적 중심 Label로 수집한 Dataset만 학습에 사용한다.
DEFAULT_DATASET_CANDIDATES = (Path("ai/dataset_samples_target_v03"),)
# SCORE_TH 보정 및 v03 score margin 학습용 무표적 Sample.
DEFAULT_NO_TARGET_DIR = Path("ai/no_target_samples_v03")
# 최종 v03은 위치 분류와 절대 score 분리를 별도 항으로 학습한다. 기존 v03의
# BCEWithLogitsLoss 단일 손실은 Test score margin이 0.0016으로 붕괴했으므로
# 재현 비교용 선택지로만 남긴다.
DEFAULT_LOSS = "hybrid"
DEFAULT_POS_WEIGHT = 63.0
DEFAULT_LOCALIZATION_WEIGHT = 1.0
DEFAULT_SCORE_WEIGHT = 1.0
DEFAULT_POSITIVE_MARGIN = 1.0
DEFAULT_NEGATIVE_MARGIN = 0.25
DEFAULT_SELECTION_AUC_WEIGHT = 0.5
DEFAULT_MINIMUM_TARGET_POSITIVE_PIXELS = 3
DEFAULT_MAXIMUM_ACTIVE_PIXELS = 1_800
DEFAULT_REQUIRE_TARGET_POSITIVE_ARGMAX = False
DEFAULT_SPLIT_STRATEGY = "session"
DEFAULT_INIT_CHECKPOINT = Path("weights/tiny_cnn_fp32_model_v02.pt")
DEFAULT_FREEZE_BACKBONE = True
DEFAULT_LEARNING_RATE = 2e-4
DEFAULT_EPOCHS = 200
DEFAULT_PATIENCE = 50
# 무표적 Sample도 양성과 같은 6:2:2로 나눈다.
NO_TARGET_VALIDATION_RATIO = 0.2
NO_TARGET_TEST_RATIO = 0.2
HEATMAP_CELL_COUNT = HEATMAP_HEIGHT * HEATMAP_WIDTH


@dataclass(frozen=True)
class Metrics:
    """한 Dataset Split에서 측정한 FP32 지표.

    `cell_accuracy`, `target_*_mae_px`는 하위 호환을 위해 이름을 유지하며
    모두 **양성(표적 있음) Sample만** 집계한 값이다. 무표적 Sample은 정답
    Cell이 없으므로 정확도/MAE 집계에서 제외하고 점수 수준만 따로 기록한다.
    """

    loss: float
    cell_accuracy: float
    positive_cell_accuracy: float
    target_x_mae_px: float
    target_y_mae_px: float
    target_mean_mae_px: float
    positive_max_score_mean: float
    negative_max_score_mean: float
    score_margin: float
    score_auc: float
    true_positive_rate_at_zero: float
    false_positive_rate_at_zero: float
    positive_sample_count: int
    negative_sample_count: int


class HybridDetectionLoss(nn.Module):
    """동결된 8×8 출력에서 위치와 표적 유무를 함께 학습한다.

    표적 Sample에는 Cross Entropy로 Raster Cell 위치를 학습하고 정답 Cell
    logit이 양의 margin보다 커지게 한다. 무표적 Sample에는 Heatmap 최대
    logit이 음의 margin보다 작아지게 한다. 별도 Class/Head/Bias를 추가하지
    않으므로 A/B가 동결한 CNN 구조와 `score > SCORE_TH` 계약은 그대로다.
    """

    def __init__(
        self,
        localization_weight: float,
        score_weight: float,
        positive_margin: float,
        negative_margin: float,
        localization_label_smoothing: float = 0.0,
    ) -> None:
        super().__init__()
        self.localization_weight = localization_weight
        self.score_weight = score_weight
        self.positive_margin = positive_margin
        self.negative_margin = negative_margin
        self.localization_label_smoothing = localization_label_smoothing

    def forward(
        self,
        flat_heatmap: torch.Tensor,
        target_vector: torch.Tensor,
    ) -> torch.Tensor:
        positive_mask = target_vector.sum(dim=1) > 0.5
        negative_mask = ~positive_mask
        zero = flat_heatmap.sum() * 0.0

        localization_loss = zero
        positive_score_loss = zero
        if bool(positive_mask.any()):
            positive_logits = flat_heatmap[positive_mask]
            positive_targets = torch.argmax(target_vector[positive_mask], dim=1)
            localization_loss = F.cross_entropy(
                positive_logits,
                positive_targets,
                label_smoothing=self.localization_label_smoothing,
            )
            target_scores = positive_logits.gather(
                1,
                positive_targets.unsqueeze(1),
            ).squeeze(1)
            positive_score_loss = F.softplus(
                self.positive_margin - target_scores
            ).mean()

        negative_score_loss = zero
        if bool(negative_mask.any()):
            negative_max_score = flat_heatmap[negative_mask].max(dim=1).values
            negative_score_loss = F.softplus(
                negative_max_score + self.negative_margin
            ).mean()

        return (
            self.localization_weight * localization_loss
            + self.score_weight * (positive_score_loss + negative_score_loss)
        )


class TinyCNN(nn.Module):
    """공통 지침과 A/B Freeze에 고정된 4-Layer Tiny CNN."""

    def __init__(self) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(
            in_channels=2,
            out_channels=8,
            kernel_size=3,
            stride=2,
            padding=1,
            bias=False,
        )
        self.conv2 = nn.Conv2d(
            in_channels=8,
            out_channels=16,
            kernel_size=3,
            stride=2,
            padding=1,
            bias=False,
        )
        self.conv3 = nn.Conv2d(
            in_channels=16,
            out_channels=32,
            kernel_size=3,
            stride=2,
            padding=1,
            bias=False,
        )
        self.conv4 = nn.Conv2d(
            in_channels=32,
            out_channels=1,
            kernel_size=1,
            stride=1,
            padding=0,
            bias=False,
        )
        self.relu = nn.ReLU(inplace=False)

    def forward_with_layers(
        self,
        input_tensor: torch.Tensor,
    ) -> dict[str, torch.Tensor]:
        """Quantization/Golden 단계에서 재사용할 Layer별 FP32 출력을 반환한다."""
        conv1 = self.relu(self.conv1(input_tensor))
        conv2 = self.relu(self.conv2(conv1))
        conv3 = self.relu(self.conv3(conv2))
        conv4 = self.conv4(conv3)
        return {
            "conv1": conv1,
            "conv2": conv2,
            "conv3": conv3,
            "conv4": conv4,
        }

    def forward(self, input_tensor: torch.Tensor) -> torch.Tensor:
        return self.forward_with_layers(input_tensor)["conv4"]


def apply_train_augmentation(
    input_tensor: torch.Tensor,
    target_vector: torch.Tensor,
    transform_index: int,
    swap_polarity: bool,
) -> tuple[torch.Tensor, torch.Tensor]:
    """같은 변환을 64×64 입력과 8×8 정답에 적용한다.

    회전/반전은 Train 전용이며 Validation/Test에는 적용하지 않는다. 극성 교환은
    물체 이동 방향이 반대일 때 POSITIVE/NEGATIVE Event가 뒤바뀌는 경우를 모사한다.
    """
    if not 0 <= transform_index < 8:
        raise ValueError("transform_index는 0~7이어야 합니다.")

    target_heatmap = target_vector.reshape(HEATMAP_HEIGHT, HEATMAP_WIDTH)
    quarter_turns = transform_index % 4
    if quarter_turns:
        input_tensor = torch.rot90(
            input_tensor,
            quarter_turns,
            dims=(1, 2),
        )
        target_heatmap = torch.rot90(
            target_heatmap,
            quarter_turns,
            dims=(0, 1),
        )
    if transform_index >= 4:
        input_tensor = torch.flip(input_tensor, dims=(2,))
        target_heatmap = torch.flip(target_heatmap, dims=(1,))
    if swap_polarity:
        input_tensor = torch.flip(input_tensor, dims=(0,))

    return input_tensor.contiguous(), target_heatmap.reshape(-1).contiguous()


def compose_synthetic_target(
    donor_input: torch.Tensor,
    donor_xy: tuple[int, int],
    background_input: torch.Tensor,
    target_index: int,
    patch_size: int,
    amplitude_scale: float,
) -> tuple[torch.Tensor, torch.Tensor]:
    """실제 Train 표적 Event 패치를 실제 Train 무표적 배경에 합성한다."""
    if donor_input.shape != (TENSOR_CHANNELS, TENSOR_HEIGHT, TENSOR_WIDTH):
        raise ValueError("donor_input 형상이 2×64×64가 아닙니다.")
    if background_input.shape != donor_input.shape:
        raise ValueError("background_input 형상이 donor_input과 다릅니다.")
    if patch_size < 8 or patch_size > 32 or patch_size % 2:
        raise ValueError("synthetic patch size는 8~32의 짝수여야 합니다.")
    if not 0 <= target_index < HEATMAP_CELL_COUNT:
        raise ValueError("target_index는 0~63이어야 합니다.")
    if amplitude_scale <= 0:
        raise ValueError("amplitude_scale은 0보다 커야 합니다.")

    donor_x, donor_y = donor_xy
    target_y, target_x = divmod(target_index, HEATMAP_WIDTH)
    destination_x = target_x * 8 + 4
    destination_y = target_y * 8 + 4
    half = patch_size // 2

    offset_x0 = max(-half, -donor_x, -destination_x)
    offset_x1 = min(
        half,
        TENSOR_WIDTH - donor_x,
        TENSOR_WIDTH - destination_x,
    )
    offset_y0 = max(-half, -donor_y, -destination_y)
    offset_y1 = min(
        half,
        TENSOR_HEIGHT - donor_y,
        TENSOR_HEIGHT - destination_y,
    )
    if offset_x0 >= offset_x1 or offset_y0 >= offset_y1:
        raise ValueError("합성 표적 패치의 유효 영역이 없습니다.")

    source_patch = donor_input[
        :,
        donor_y + offset_y0 : donor_y + offset_y1,
        donor_x + offset_x0 : donor_x + offset_x1,
    ]
    source_patch = torch.clamp(source_patch * amplitude_scale, 0.0, 1.0)
    destination_slice = (
        slice(None),
        slice(destination_y + offset_y0, destination_y + offset_y1),
        slice(destination_x + offset_x0, destination_x + offset_x1),
    )
    synthetic = background_input.clone()
    synthetic[destination_slice] = torch.maximum(
        synthetic[destination_slice],
        source_patch,
    )

    target_vector = torch.zeros(HEATMAP_CELL_COUNT, dtype=torch.float32)
    target_vector[target_index] = 1.0
    return synthetic.contiguous(), target_vector


class EventHeatmapDataset(Dataset[tuple[torch.Tensor, torch.Tensor]]):
    """검증을 통과한 NPZ Sample을 PyTorch CHW Tensor와 8×8 정답으로 읽는다.

    표적 있음(positive) Sample은 정답 Cell만 1.0인 One-hot 8×8을, 무표적
    (negative) Sample은 전부 0.0인 8×8을 낸다. 두 경우 모두 Flatten한
    `(64,)` FP32 Vector로 돌려주며 BCEWithLogitsLoss가 그대로 받는다.
    무표적 NPZ에는 `heatmap_xy`가 없으므로 `input_tensor`만 읽는다.

    양성/음성 구분은 별도 Flag 없이 `target_vector.sum() > 0`으로 복원한다.
    """

    def __init__(
        self,
        samples: list[DatasetSampleInfo],
        no_target_samples: list[NoTargetSampleInfo] | None = None,
        augment_d4: bool = False,
        augment_polarity_swap: bool = False,
        synthetic_target_count: int = 0,
        synthetic_min_target_event_ratio: float = 0.1,
        synthetic_patch_size: int = 16,
        synthetic_amplitude_jitter: float = 0.25,
    ) -> None:
        # (NPZ 경로, Raster Class Index 또는 무표적을 뜻하는 None)
        self.entries: list[tuple[Path, int | None]] = [
            (
                sample_info.path,
                sample_info.heatmap_y * HEATMAP_WIDTH + sample_info.heatmap_x,
            )
            for sample_info in samples
        ]
        negative_samples = no_target_samples or []
        self.entries.extend((sample_info.path, None) for sample_info in negative_samples)
        self.augment_d4 = augment_d4
        self.augment_polarity_swap = augment_polarity_swap
        self.synthetic_target_count = synthetic_target_count
        self.synthetic_patch_size = synthetic_patch_size
        self.synthetic_amplitude_jitter = synthetic_amplitude_jitter
        self.synthetic_donors = [
            sample_info.path
            for sample_info in samples
            if sample_info.target_event_pixel_count
            / max(1, sample_info.active_pixel_count)
            >= synthetic_min_target_event_ratio
        ]
        self.synthetic_backgrounds = [sample_info.path for sample_info in negative_samples]
        if synthetic_target_count < 0:
            raise ValueError("synthetic_target_count는 0 이상이어야 합니다.")
        if synthetic_target_count and not self.synthetic_donors:
            raise ValueError("합성 표적 donor Sample이 없습니다.")
        if synthetic_target_count and not self.synthetic_backgrounds:
            raise ValueError("합성 표적용 무표적 배경 Sample이 없습니다.")
        if not 0.0 <= synthetic_amplitude_jitter <= 0.75:
            raise ValueError("synthetic_amplitude_jitter는 0~0.75여야 합니다.")

        # 이 Dataset은 수천 개의 작은 NPZ로 구성된다. Epoch마다
        # 각 NPZ를 다시 열면 작은 CNN 계산보다 파일 열기/해제가
        # 지배적인 병목이 된다. 입력을 한 번만 읽어 기존과 동일한
        # CHW FP32/정규화 Tensor로 보관한다. 2×64×64×4 byte라서
        # 현재 엄격 Dataset 전체도 수십 MB 수준이다.
        self.cached_inputs: list[torch.Tensor] = []
        for sample_path, _ in self.entries:
            with np.load(sample_path, allow_pickle=False) as sample:
                input_hwc = sample["input_tensor"]
            input_chw = np.ascontiguousarray(
                np.transpose(input_hwc, (2, 0, 1))
            )
            input_fp32 = torch.from_numpy(input_chw).to(torch.float32)
            self.cached_inputs.append(input_fp32 / INPUT_NORMALIZATION)

    def __len__(self) -> int:
        return len(self.entries) + self.synthetic_target_count

    def __getitem__(self, index: int) -> tuple[torch.Tensor, torch.Tensor]:
        if index >= len(self.entries):
            donor_path = self.synthetic_donors[
                int(torch.randint(0, len(self.synthetic_donors), (1,)).item())
            ]
            background_path = self.synthetic_backgrounds[
                int(torch.randint(0, len(self.synthetic_backgrounds), (1,)).item())
            ]
            with np.load(donor_path, allow_pickle=False) as donor_sample:
                donor_hwc = donor_sample["input_tensor"]
                donor_x, donor_y = (
                    int(value) for value in donor_sample["tensor_xy"]
                )
            with np.load(background_path, allow_pickle=False) as background_sample:
                background_hwc = background_sample["input_tensor"]
            donor_input = torch.from_numpy(
                np.ascontiguousarray(np.transpose(donor_hwc, (2, 0, 1)))
            ).to(torch.float32) / INPUT_NORMALIZATION
            input_fp32 = torch.from_numpy(
                np.ascontiguousarray(np.transpose(background_hwc, (2, 0, 1)))
            ).to(torch.float32) / INPUT_NORMALIZATION
            target_index = int(torch.randint(0, HEATMAP_CELL_COUNT, (1,)).item())
            jitter = self.synthetic_amplitude_jitter
            amplitude_scale = 1.0 + (float(torch.rand(1).item()) * 2.0 - 1.0) * jitter
            input_fp32, target_vector = compose_synthetic_target(
                donor_input,
                (donor_x, donor_y),
                input_fp32,
                target_index,
                self.synthetic_patch_size,
                amplitude_scale,
            )
            if self.augment_d4 or self.augment_polarity_swap:
                transform_index = (
                    int(torch.randint(0, 8, (1,)).item())
                    if self.augment_d4
                    else 0
                )
                swap_polarity = bool(
                    self.augment_polarity_swap
                    and int(torch.randint(0, 2, (1,)).item())
                )
                input_fp32, target_vector = apply_train_augmentation(
                    input_fp32,
                    target_vector,
                    transform_index,
                    swap_polarity,
                )
            return input_fp32, target_vector

        _, target_index = self.entries[index]
        # Train 증강이 cache 원본을 절대 바꾸지 않도록 독립 Tensor를 준다.
        # Dataset의 HWC→CHW와 FP32 정규화는 __init__에서 한 번만 수행된다.
        input_fp32 = self.cached_inputs[index].clone()

        # [Y][X] Raster 순서 One-hot. 출력 형상 8×8×1은 그대로이며
        # "no-target Class"를 65번째 칸으로 추가하지 않는다.
        target_vector = torch.zeros(HEATMAP_CELL_COUNT, dtype=torch.float32)
        if target_index is not None:
            target_vector[target_index] = 1.0
        if self.augment_d4 or self.augment_polarity_swap:
            transform_index = (
                int(torch.randint(0, 8, (1,)).item())
                if self.augment_d4
                else 0
            )
            swap_polarity = bool(
                self.augment_polarity_swap
                and int(torch.randint(0, 2, (1,)).item())
            )
            input_fp32, target_vector = apply_train_augmentation(
                input_fp32,
                target_vector,
                transform_index,
                swap_polarity,
            )
        return input_fp32, target_vector


def set_reproducibility(seed: int) -> None:
    """Dataset 분할과 CPU 학습 결과의 재현성을 고정한다."""
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.use_deterministic_algorithms(True)


def build_balanced_split(
    accepted_samples: list[DatasetSampleInfo],
    samples_per_cell: int,
    seed: int,
    strategy: str = "random",
    require_test: bool = True,
) -> tuple[
    list[DatasetSampleInfo],
    list[DatasetSampleInfo],
    list[DatasetSampleInfo],
]:
    """각 Heatmap Cell을 Train/Validation/Test로 나눈다.

    ``samples_per_cell=0``이면 품질 필터를 통과한 Sample을 전부 사용한다.
    ``chronological``은 같은 Cell 안에서 sample_index 순서를 유지해 뒤쪽
    Sample을 Validation/Test로 격리한다. 기존 random 분할도 재현 비교용으로
    지원한다. Session 후보 학습에서 ``require_test=False``이면 Train과
    Validation의 64개 Cell만 검사해 아직 없거나 격리한 Test를 허용한다.
    """
    if samples_per_cell not in (0,) and samples_per_cell < 3:
        raise ValueError(
            "samples_per_cell은 0(전부 사용) 또는 Train/Validation/Test용 3 이상이어야 합니다."
        )
    if strategy not in {"random", "chronological", "session"}:
        raise ValueError(f"지원하지 않는 Split 전략입니다: {strategy}")

    if strategy == "session":
        if samples_per_cell != 0:
            raise ValueError(
                "session Split은 촬영 Session의 Sample을 전부 사용하므로 "
                "samples_per_cell=0이어야 합니다."
            )
        split_samples: dict[str, list[DatasetSampleInfo]] = {
            "train": [],
            "validation": [],
            "test": [],
        }
        session_roles: dict[str, str] = {}
        for sample_info in accepted_samples:
            if sample_info.capture_split not in split_samples:
                raise RuntimeError(
                    "session Split에 legacy/미지정 Sample을 사용할 수 없습니다: "
                    f"{sample_info.path}"
                )
            previous_role = session_roles.setdefault(
                sample_info.capture_session_id,
                sample_info.capture_split,
            )
            if previous_role != sample_info.capture_split:
                raise RuntimeError(
                    "하나의 capture_session_id가 여러 Split에 포함되었습니다: "
                    f"{sample_info.capture_session_id}"
                )
            split_samples[sample_info.capture_split].append(sample_info)

        required_split_names = (
            ("train", "validation", "test")
            if require_test
            else ("train", "validation")
        )
        for split_name in required_split_names:
            samples = split_samples[split_name]
            split_distribution = np.zeros(
                (HEATMAP_HEIGHT, HEATMAP_WIDTH),
                dtype=np.int32,
            )
            for sample_info in samples:
                split_distribution[
                    sample_info.heatmap_y,
                    sample_info.heatmap_x,
                ] += 1
            missing_cells = np.argwhere(split_distribution == 0)
            if missing_cells.size:
                first_y, first_x = (int(value) for value in missing_cells[0])
                raise RuntimeError(
                    f"{split_name} 촬영 Session의 Heatmap Cell "
                    f"({first_x}, {first_y})에 품질 Sample이 없습니다."
                )

        def ordered(split_name: str) -> list[DatasetSampleInfo]:
            return sorted(
                split_samples[split_name],
                key=lambda sample_info: (
                    sample_info.capture_session_id,
                    sample_info.sample_index,
                ),
            )

        return ordered("train"), ordered("validation"), ordered("test")

    by_cell: dict[tuple[int, int], list[DatasetSampleInfo]] = {
        (heatmap_x, heatmap_y): []
        for heatmap_y in range(HEATMAP_HEIGHT)
        for heatmap_x in range(HEATMAP_WIDTH)
    }
    for sample_info in accepted_samples:
        by_cell[(sample_info.heatmap_x, sample_info.heatmap_y)].append(sample_info)

    train_samples: list[DatasetSampleInfo] = []
    validation_samples: list[DatasetSampleInfo] = []
    test_samples: list[DatasetSampleInfo] = []

    for heatmap_y in range(HEATMAP_HEIGHT):
        for heatmap_x in range(HEATMAP_WIDTH):
            cell = (heatmap_x, heatmap_y)
            cell_samples = sorted(
                by_cell[cell],
                key=lambda sample_info: sample_info.sample_index,
            )
            if samples_per_cell and len(cell_samples) < samples_per_cell:
                raise RuntimeError(
                    f"Heatmap Cell {cell}의 품질 Sample이 부족합니다: "
                    f"현재={len(cell_samples)}, 필요={samples_per_cell}"
                )

            if strategy == "random":
                cell_random = random.Random(
                    seed + heatmap_y * HEATMAP_WIDTH + heatmap_x
                )
                cell_random.shuffle(cell_samples)
            selected = (
                cell_samples[:samples_per_cell]
                if samples_per_cell
                else cell_samples
            )
            selected_count = len(selected)
            validation_count = max(1, selected_count // 5)
            test_count = max(1, selected_count // 5)
            train_count = selected_count - validation_count - test_count
            if train_count < 1:
                raise RuntimeError(f"Heatmap Cell {cell}의 Train Sample이 없습니다.")

            train_samples.extend(selected[:train_count])
            validation_samples.extend(
                selected[train_count : train_count + validation_count]
            )
            test_samples.extend(selected[train_count + validation_count :])

    return train_samples, validation_samples, test_samples


def build_no_target_split(
    no_target_samples: list[NoTargetSampleInfo],
    seed: int,
    strategy: str = "random",
    require_test: bool = True,
) -> tuple[
    list[NoTargetSampleInfo],
    list[NoTargetSampleInfo],
    list[NoTargetSampleInfo],
]:
    """무표적 Sample을 양성과 같은 6:2:2로 결정론적으로 나눈다.

    `sample_index` 정렬 후 `random.Random(seed)`로만 섞으므로 파일 나열
    순서나 전역 난수 상태와 무관하게 같은 seed면 같은 분할이 나온다.
    Sample이 3개 미만이면 Validation/Test를 비우고 Train에만 넣는다.
    Session 후보 학습의 ``require_test=False``는 Train/Validation Session만
    필수로 하고 Test Session은 없어도 허용한다.
    """
    ordered_samples = sorted(
        no_target_samples,
        key=lambda sample_info: sample_info.sample_index,
    )
    if not ordered_samples:
        return [], [], []

    if strategy not in {"random", "chronological", "session"}:
        raise ValueError(f"지원하지 않는 Split 전략입니다: {strategy}")
    if strategy == "session":
        split_samples: dict[str, list[NoTargetSampleInfo]] = {
            "train": [],
            "validation": [],
            "test": [],
        }
        session_roles: dict[str, str] = {}
        for sample_info in ordered_samples:
            if sample_info.capture_split not in split_samples:
                raise RuntimeError(
                    "session Split에 legacy/미지정 무표적 Sample을 사용할 수 없습니다: "
                    f"{sample_info.path}"
                )
            previous_role = session_roles.setdefault(
                sample_info.capture_session_id,
                sample_info.capture_split,
            )
            if previous_role != sample_info.capture_split:
                raise RuntimeError(
                    "하나의 무표적 capture_session_id가 여러 Split에 포함되었습니다: "
                    f"{sample_info.capture_session_id}"
                )
            split_samples[sample_info.capture_split].append(sample_info)
        required_split_names = (
            ("train", "validation", "test")
            if require_test
            else ("train", "validation")
        )
        empty_splits = [
            name for name in required_split_names if not split_samples[name]
        ]
        if empty_splits:
            raise RuntimeError(
                "무표적 촬영 Session이 없는 Split: " + ", ".join(empty_splits)
            )

        def ordered(split_name: str) -> list[NoTargetSampleInfo]:
            return sorted(
                split_samples[split_name],
                key=lambda sample_info: (
                    sample_info.capture_session_id,
                    sample_info.sample_index,
                ),
            )

        return ordered("train"), ordered("validation"), ordered("test")
    shuffled = list(ordered_samples)
    if strategy == "random":
        random.Random(seed).shuffle(shuffled)

    total_count = len(shuffled)
    validation_count = int(total_count * NO_TARGET_VALIDATION_RATIO)
    test_count = int(total_count * NO_TARGET_TEST_RATIO)
    if total_count - validation_count - test_count < 1:
        validation_count = 0
        test_count = 0

    train_samples = shuffled[: total_count - validation_count - test_count]
    validation_samples = shuffled[
        total_count - validation_count - test_count : total_count - test_count
    ]
    test_samples = shuffled[total_count - test_count :] if test_count else []
    return train_samples, validation_samples, test_samples


def make_loader(
    samples: list[DatasetSampleInfo],
    batch_size: int,
    shuffle: bool,
    seed: int,
    no_target_samples: list[NoTargetSampleInfo] | None = None,
    augment_d4: bool = False,
    augment_polarity_swap: bool = False,
    synthetic_target_count: int = 0,
    synthetic_min_target_event_ratio: float = 0.1,
    synthetic_patch_size: int = 16,
    synthetic_amplitude_jitter: float = 0.25,
) -> DataLoader[tuple[torch.Tensor, torch.Tensor]]:
    generator = torch.Generator()
    generator.manual_seed(seed)
    return DataLoader(
        EventHeatmapDataset(
            samples,
            no_target_samples,
            augment_d4=augment_d4,
            augment_polarity_swap=augment_polarity_swap,
            synthetic_target_count=synthetic_target_count,
            synthetic_min_target_event_ratio=synthetic_min_target_event_ratio,
            synthetic_patch_size=synthetic_patch_size,
            synthetic_amplitude_jitter=synthetic_amplitude_jitter,
        ),
        batch_size=batch_size,
        shuffle=shuffle,
        num_workers=0,
        pin_memory=False,
        generator=generator,
    )


def resolve_dataset_directory(dataset_dir: Path) -> Path:
    """기본 경로가 비어 있으면 저장소 안의 알려진 Dataset 폴더로 보정한다."""
    if dataset_dir.exists():
        return dataset_dir

    for candidate in DEFAULT_DATASET_CANDIDATES:
        if candidate == dataset_dir:
            continue
        if candidate.exists():
            print(
                f"기본 Dataset 경로 {dataset_dir} 가 없어 "
                f"{candidate} 를 사용합니다."
            )
            return candidate
    return dataset_dir


def load_no_target_samples(no_target_dir: Path) -> list[NoTargetSampleInfo]:
    """무표적 Sample을 읽는다. 최종 필요 여부는 학습 설정에서 판정한다."""
    if not no_target_dir.exists():
        print(
            f"경고: 무표적 Dataset 경로 {no_target_dir} 가 없습니다. "
            "양성 Sample만으로 학습하며 무표적 점수 지표는 측정하지 않습니다."
        )
        return []

    _, valid_samples, errors = inspect_no_target_directory(no_target_dir)
    if errors:
        error_summary = "; ".join(
            f"{path.name}: {message}" for path, message in errors[:5]
        )
        print(
            f"경고: 무표적 Sample {len(errors)}개를 형식 오류로 제외합니다: "
            f"{error_summary}"
        )
    if not valid_samples:
        print(
            f"경고: 무표적 Dataset {no_target_dir} 에 사용할 Sample이 없습니다. "
            "양성 Sample만으로 학습하며 무표적 점수 지표는 측정하지 않습니다."
        )
    return valid_samples


def summarize_distribution_gap(
    distribution: np.ndarray,
    samples_per_cell: int,
) -> str:
    """분포 부족 상황을 짧게 요약해 학습 실패 원인을 바로 알린다."""
    completed_cells = int(np.count_nonzero(distribution >= samples_per_cell))
    partial_cells = int(
        np.count_nonzero((distribution > 0) & (distribution < samples_per_cell))
    )
    empty_cells = int(np.count_nonzero(distribution == 0))

    lacking_cells: list[str] = []
    for heatmap_y, row in enumerate(distribution):
        for heatmap_x, count in enumerate(row):
            if int(count) < samples_per_cell:
                lacking_cells.append(f"({heatmap_x},{heatmap_y})={int(count)}")
            if len(lacking_cells) == 8:
                break
        if len(lacking_cells) == 8:
            break

    return (
        f"완료 Cell={completed_cells}/64, 부분 Cell={partial_cells}/64, "
        f"미수집 Cell={empty_cells}/64, 부족 예시={', '.join(lacking_cells)}"
    )


def calculate_batch_errors(
    predicted_index: torch.Tensor,
    target_index: torch.Tensor,
) -> tuple[float, float]:
    predicted_x = predicted_index.remainder(HEATMAP_WIDTH) * 8 + 4
    predicted_y = torch.div(
        predicted_index,
        HEATMAP_WIDTH,
        rounding_mode="floor",
    ) * 8 + 4
    target_x = target_index.remainder(HEATMAP_WIDTH) * 8 + 4
    target_y = torch.div(
        target_index,
        HEATMAP_WIDTH,
        rounding_mode="floor",
    ) * 8 + 4

    x_error_sum = torch.abs(predicted_x - target_x).sum().item()
    y_error_sum = torch.abs(predicted_y - target_y).sum().item()
    return float(x_error_sum), float(y_error_sum)


class MetricAccumulator:
    """양성/음성 Sample을 분리 집계해 Metrics 한 개를 만든다.

    정확도와 Target MAE는 정답 Cell이 있는 양성 Sample만 대상으로 한다.
    무표적 Sample은 Heatmap max logit 평균만 따로 모아 SCORE_TH 분리도를
    본다. 양성/음성 구분은 One-hot 정답 Vector의 합으로 판정한다.
    """

    def __init__(self) -> None:
        self.sample_count = 0
        self.loss_sum = 0.0
        self.positive_count = 0
        self.negative_count = 0
        self.correct_count = 0
        self.x_error_sum = 0.0
        self.y_error_sum = 0.0
        self.positive_score_sum = 0.0
        self.negative_score_sum = 0.0
        self.positive_scores: list[float] = []
        self.negative_scores: list[float] = []

    def update(
        self,
        flat_heatmap: torch.Tensor,
        target_vector: torch.Tensor,
        loss_value: float,
    ) -> None:
        scores = flat_heatmap.detach()
        batch_count = int(target_vector.shape[0])
        self.sample_count += batch_count
        self.loss_sum += float(loss_value) * batch_count

        positive_mask = target_vector.sum(dim=1) > 0.5
        negative_mask = ~positive_mask
        max_score = scores.max(dim=1).values
        self.positive_count += int(positive_mask.sum().item())
        self.negative_count += int(negative_mask.sum().item())
        self.positive_score_sum += float(max_score[positive_mask].sum().item())
        self.negative_score_sum += float(max_score[negative_mask].sum().item())
        self.positive_scores.extend(
            float(value) for value in max_score[positive_mask].cpu().tolist()
        )
        self.negative_scores.extend(
            float(value) for value in max_score[negative_mask].cpu().tolist()
        )

        if not bool(positive_mask.any()):
            return

        # [Y][X] Raster One-hot이므로 argmax가 그대로 정답 Class Index다.
        target_index = torch.argmax(target_vector[positive_mask], dim=1)
        predicted_index = torch.argmax(scores[positive_mask], dim=1)
        self.correct_count += int((predicted_index == target_index).sum().item())
        x_error, y_error = calculate_batch_errors(predicted_index, target_index)
        self.x_error_sum += x_error
        self.y_error_sum += y_error

    def finalize(self, stage: str) -> Metrics:
        if self.sample_count == 0:
            raise RuntimeError(f"{stage}할 Sample이 없습니다.")

        if self.positive_count:
            cell_accuracy = self.correct_count / self.positive_count
            x_mae = self.x_error_sum / self.positive_count
            y_mae = self.y_error_sum / self.positive_count
            positive_max_score_mean = (
                self.positive_score_sum / self.positive_count
            )
        else:
            cell_accuracy = float("nan")
            x_mae = float("nan")
            y_mae = float("nan")
            positive_max_score_mean = float("nan")

        if self.negative_count:
            negative_max_score_mean = (
                self.negative_score_sum / self.negative_count
            )
        else:
            negative_max_score_mean = float("nan")

        if self.positive_scores and self.negative_scores:
            positive_scores = np.asarray(self.positive_scores, dtype=np.float64)[:, None]
            negative_scores = np.asarray(self.negative_scores, dtype=np.float64)[None, :]
            score_auc = float(
                np.mean(
                    (positive_scores > negative_scores)
                    + 0.5 * (positive_scores == negative_scores)
                )
            )
            true_positive_rate_at_zero = float(
                np.mean(positive_scores.reshape(-1) > 0.0)
            )
            false_positive_rate_at_zero = float(
                np.mean(negative_scores.reshape(-1) > 0.0)
            )
        else:
            score_auc = float("nan")
            true_positive_rate_at_zero = float("nan")
            false_positive_rate_at_zero = float("nan")

        return Metrics(
            loss=self.loss_sum / self.sample_count,
            cell_accuracy=cell_accuracy,
            positive_cell_accuracy=cell_accuracy,
            target_x_mae_px=x_mae,
            target_y_mae_px=y_mae,
            target_mean_mae_px=(x_mae + y_mae) / 2.0,
            positive_max_score_mean=positive_max_score_mean,
            negative_max_score_mean=negative_max_score_mean,
            score_margin=positive_max_score_mean - negative_max_score_mean,
            score_auc=score_auc,
            true_positive_rate_at_zero=true_positive_rate_at_zero,
            false_positive_rate_at_zero=false_positive_rate_at_zero,
            positive_sample_count=self.positive_count,
            negative_sample_count=self.negative_count,
        )


def evaluate(
    model: TinyCNN,
    loader: DataLoader[tuple[torch.Tensor, torch.Tensor]],
    criterion: nn.Module,
) -> Metrics:
    model.eval()
    accumulator = MetricAccumulator()

    with torch.no_grad():
        for input_tensor, target_vector in loader:
            heatmap = model(input_tensor)
            flat_heatmap = heatmap.flatten(start_dim=1)
            loss = criterion(flat_heatmap, target_vector)
            accumulator.update(flat_heatmap, target_vector, float(loss.item()))

    return accumulator.finalize("평가")


def train_one_epoch(
    model: TinyCNN,
    loader: DataLoader[tuple[torch.Tensor, torch.Tensor]],
    criterion: nn.Module,
    optimizer: torch.optim.Optimizer,
) -> Metrics:
    model.train()
    accumulator = MetricAccumulator()

    for input_tensor, target_vector in loader:
        optimizer.zero_grad(set_to_none=True)
        heatmap = model(input_tensor)
        flat_heatmap = heatmap.flatten(start_dim=1)
        loss = criterion(flat_heatmap, target_vector)
        loss.backward()
        optimizer.step()

        accumulator.update(flat_heatmap, target_vector, float(loss.item()))

    return accumulator.finalize("학습")


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    temporary_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary_path.replace(path)


def write_accuracy_report(
    path: Path,
    dataset_directory: Path,
    accepted_count: int,
    rejected_count: int,
    split_counts: dict[str, int],
    best_epoch: int,
    validation_metrics: Metrics,
    test_metrics: Metrics | None,
    no_target_directory: Path | None = None,
    no_target_split_counts: dict[str, int] | None = None,
    loss_description: str = DEFAULT_LOSS,
    minimum_target_positive_pixels: int = DEFAULT_MINIMUM_TARGET_POSITIVE_PIXELS,
    require_target_positive_argmax: bool = False,
    split_strategy: str = DEFAULT_SPLIT_STRATEGY,
    initialization_checkpoint: Path | None = None,
    freeze_backbone: bool = False,
    learning_rate: float = 0.0,
    augment_train_d4: bool = False,
    augment_train_polarity_swap: bool = False,
    synthetic_target_count: int = 0,
    synthetic_min_target_event_ratio: float = 0.1,
    synthetic_patch_size: int = 16,
    minimum_train_target_event_ratio: float = 0.0,
    minimum_target_event_pixels: int = 0,
    minimum_target_event_ratio: float = 0.0,
    test_evaluated: bool = True,
    ignored_test_sample_count: int = 0,
    ignored_no_target_test_sample_count: int = 0,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    no_target_text = (
        str(no_target_directory) if no_target_directory is not None else "없음"
    )
    split_description = (
        "촬영 Session 역할 고정(누수 방지)"
        if split_strategy == "session"
        else "Cell별 6:2:2"
    )
    if no_target_split_counts:
        negative_counts_text = (
            f"{no_target_split_counts['train']} / "
            f"{no_target_split_counts['validation']} / "
            f"{no_target_split_counts['test']}"
        )
    else:
        negative_counts_text = "0 / 0 / 0 (무표적 Sample 없음)"
    if test_metrics is None:
        test_metrics_text = (
            "- Test Evaluation: `NOT_EVALUATED` (`--no-evaluate-test`)\n"
            "- Test Cell Accuracy: `NOT_EVALUATED`\n"
            "- Test Target X/Y/Mean MAE: `NOT_EVALUATED`"
        )
        test_score_text = (
            "- Test Positive/Negative Max Score 평균: `NOT_EVALUATED`\n"
            "- Test Score Margin/AUC: `NOT_EVALUATED`\n"
            "- Test `score > 0` TPR/FPR: `NOT_EVALUATED`"
        )
    else:
        test_metrics_text = (
            "- Test Evaluation: `EVALUATED`\n"
            f"- Test Cell Accuracy: {test_metrics.cell_accuracy:.6f}\n"
            f"- Test Target X MAE: {test_metrics.target_x_mae_px:.6f} px\n"
            f"- Test Target Y MAE: {test_metrics.target_y_mae_px:.6f} px\n"
            f"- Test Target Mean MAE: {test_metrics.target_mean_mae_px:.6f} px"
        )
        test_score_text = (
            f"- Test Positive Max Score 평균: "
            f"{test_metrics.positive_max_score_mean:.6f}\n"
            f"- Test Negative Max Score 평균: "
            f"{test_metrics.negative_max_score_mean:.6f}\n"
            f"- Test Score Margin: {test_metrics.score_margin:.6f}\n"
            f"- Test Score AUC: {test_metrics.score_auc:.6f}\n"
            f"- Test `score > 0` TPR/FPR: "
            f"{test_metrics.true_positive_rate_at_zero:.6f} / "
            f"{test_metrics.false_positive_rate_at_zero:.6f}"
        )
    report = f"""# FP32 Tiny CNN Accuracy Report

## 규격

- Base Spec: `{BASE_SPEC_VERSION}`
- Model Version: `{MODEL_VERSION}`
- Dataset: `{dataset_directory}`
- Input: `64×64×2`, signed INT8 저장, 실제값 `0~127`
- FP32 입력 변환: `input_int8 / 127.0`
- CNN: `2→8→16→32→1`, Conv1~3 `3×3/s2/p1`, Conv4 `1×1/s1/p0`
- Bias: 없음
- Conv1~3: ReLU
- Conv4: ReLU 없음
- Argmax: Raster FIRST_MAX
- Loss: `{loss_description}`
- Initialization: `{initialization_checkpoint if initialization_checkpoint is not None else 'random'}`
- Trainable Range: `{'Conv4 only' if freeze_backbone else 'Conv1~4'}`
- Learning Rate: `{learning_rate:g}`
- Train D4 Augmentation: `{augment_train_d4}`
- Train Polarity Swap Augmentation: `{augment_train_polarity_swap}`
- Train Synthetic Target Samples/Epoch: `{synthetic_target_count}`
- Synthetic Donor Target Event Ratio Minimum: `{synthetic_min_target_event_ratio:g}`
- Synthetic Target Patch: `{synthetic_patch_size}×{synthetic_patch_size}`
- Train Target/Active Event Ratio Minimum: `{minimum_train_target_event_ratio:g}`

## Dataset

- 품질 사용 Sample: {accepted_count}
- 품질 제외 Sample: {rejected_count}
- Target Cell Positive Event 최소: {minimum_target_positive_pixels} pixel
- Target Cell 전체 Event 최소: {minimum_target_event_pixels} pixel
- Target/Active Event 비율 최소: {minimum_target_event_ratio:g}
- Target Cell Positive Energy Argmax 필수: {require_target_positive_argmax}
- Split 전략: `{split_strategy}` ({split_description})
- Train: {split_counts['train']}
- Validation: {split_counts['validation']}
- Test: {split_counts['test']}
- Test Evaluation Enabled: {test_evaluated}
- Test-blind 제외 표적/무표적 Sample: {ignored_test_sample_count} / {ignored_no_target_test_sample_count}
- 무표적 Dataset: `{no_target_text}`
- 무표적 Train / Validation / Test: {negative_counts_text}

## 실측 결과

- Best Epoch: {best_epoch}
- Validation Cell Accuracy: {validation_metrics.cell_accuracy:.6f}
- Validation Target Mean MAE: {validation_metrics.target_mean_mae_px:.6f} px
{test_metrics_text}

## SCORE_TH 분리도 (FP32 Heatmap max logit)

- Validation Positive Max Score 평균: {validation_metrics.positive_max_score_mean:.6f}
- Validation Negative Max Score 평균: {validation_metrics.negative_max_score_mean:.6f}
- Validation Score Margin: {validation_metrics.score_margin:.6f}
- Validation Score AUC: {validation_metrics.score_auc:.6f}
{test_score_text}

## 후속 정수 경로 측정

- `SCORE_TH`: 이 보고서는 FP32 학습 단계 결과다. 최종 RTL INT8 실측은
  `results/{MODEL_VERSION}_score_th_calibration_report.md`를 기준으로 한다
- CPU FP32 Latency: 별도 Baseline 측정 전까지 TBD
- INT8 Accuracy: `results/{MODEL_VERSION}_int8_accuracy.json`에서 별도 기록한다
"""
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    temporary_path.write_text(report, encoding="utf-8")
    temporary_path.replace(path)


def run_self_test() -> None:
    """고정 Layer 형상, 파라미터 수, Bias, FIRST_MAX를 자체 검증한다."""
    set_reproducibility(42)
    model = TinyCNN()
    input_tensor = torch.zeros(
        (2, TENSOR_CHANNELS, TENSOR_HEIGHT, TENSOR_WIDTH),
        dtype=torch.float32,
    )
    layers = model.forward_with_layers(input_tensor)

    assert layers["conv1"].shape == (2, 8, 32, 32)
    assert layers["conv2"].shape == (2, 16, 16, 16)
    assert layers["conv3"].shape == (2, 32, 8, 8)
    assert layers["conv4"].shape == (2, 1, 8, 8)

    parameter_count = sum(parameter.numel() for parameter in model.parameters())
    assert parameter_count == EXPECTED_PARAMETER_COUNT
    assert model.conv1.bias is None
    assert model.conv2.bias is None
    assert model.conv3.bias is None
    assert model.conv4.bias is None

    tied_heatmap = torch.zeros((1, 64), dtype=torch.float32)
    tied_heatmap[0, 5] = 1.0
    tied_heatmap[0, 17] = 1.0
    assert int(torch.argmax(tied_heatmap, dim=1).item()) == 5

    # BCE 정답 Vector: 양성은 8×8 One-hot, 음성은 전부 0이며 Class 수는 64다.
    positive_target = torch.zeros(HEATMAP_CELL_COUNT, dtype=torch.float32)
    positive_target[3 * HEATMAP_WIDTH + 6] = 1.0
    negative_target = torch.zeros(HEATMAP_CELL_COUNT, dtype=torch.float32)
    assert positive_target.shape == (64,)
    assert float(positive_target.sum().item()) == 1.0
    assert float(negative_target.sum().item()) == 0.0
    assert int(torch.argmax(positive_target).item()) == 3 * HEATMAP_WIDTH + 6

    bce_criterion = nn.BCEWithLogitsLoss(
        pos_weight=torch.tensor(DEFAULT_POS_WEIGHT)
    )
    stacked_target = torch.stack([positive_target, negative_target])
    stacked_logits = torch.zeros((2, HEATMAP_CELL_COUNT), dtype=torch.float32)
    assert float(bce_criterion(stacked_logits, stacked_target).item()) > 0.0
    hybrid_criterion = HybridDetectionLoss(
        localization_weight=DEFAULT_LOCALIZATION_WEIGHT,
        score_weight=DEFAULT_SCORE_WEIGHT,
        positive_margin=DEFAULT_POSITIVE_MARGIN,
        negative_margin=DEFAULT_NEGATIVE_MARGIN,
    )
    hybrid_loss = hybrid_criterion(stacked_logits, stacked_target)
    assert bool(torch.isfinite(hybrid_loss)) and float(hybrid_loss.item()) > 0.0

    # Train 증강은 입력과 정답에 같은 공간 변환을 적용하고 극성만 교환한다.
    augmentation_input = torch.zeros((2, 64, 64), dtype=torch.float32)
    augmentation_input[0, 12, 20] = 1.0
    augmentation_target = torch.zeros(HEATMAP_CELL_COUNT, dtype=torch.float32)
    augmentation_target[1 * HEATMAP_WIDTH + 2] = 1.0
    augmented_input, augmented_target = apply_train_augmentation(
        augmentation_input,
        augmentation_target,
        transform_index=1,
        swap_polarity=True,
    )
    assert tuple(augmented_input.shape) == (2, 64, 64)
    assert int(torch.argmax(augmented_target).item()) == 5 * HEATMAP_WIDTH + 1
    assert float(augmented_input[1].sum().item()) == 1.0
    assert float(augmented_input[0].sum().item()) == 0.0

    # 실제 Event donor의 중심을 임의 Cell 중심으로 옮겨도 두 채널과 One-hot
    # 계약을 유지해야 한다. Validation/Test에는 이 경로를 사용하지 않는다.
    donor_input = torch.zeros((2, 64, 64), dtype=torch.float32)
    donor_input[0, 20, 20] = 1.0
    background_input = torch.zeros((2, 64, 64), dtype=torch.float32)
    synthetic_index = 3 * HEATMAP_WIDTH + 4
    synthetic_input, synthetic_target = compose_synthetic_target(
        donor_input,
        (20, 20),
        background_input,
        synthetic_index,
        patch_size=16,
        amplitude_scale=1.0,
    )
    assert tuple(synthetic_input.shape) == (2, 64, 64)
    assert float(synthetic_input[0, 28, 36].item()) == 1.0
    assert float(synthetic_input[1].sum().item()) == 0.0
    assert int(torch.argmax(synthetic_target).item()) == synthetic_index
    assert float(synthetic_target.sum().item()) == 1.0

    # 무표적 Split은 seed가 같으면 항상 같은 6:2:2 분할이어야 한다.
    dummy_no_target = [
        NoTargetSampleInfo(
            path=Path(f"sample_{index:06d}.npz"),
            sample_index=index,
            active_pixel_count=10 + index,
        )
        for index in range(1, 11)
    ]
    first_split = build_no_target_split(dummy_no_target, seed=42)
    second_split = build_no_target_split(list(reversed(dummy_no_target)), seed=42)
    assert [len(part) for part in first_split] == [6, 2, 2]
    assert first_split == second_split
    chronological_split = build_no_target_split(
        dummy_no_target,
        seed=42,
        strategy="chronological",
    )
    assert [[sample.sample_index for sample in part] for part in chronological_split] == [
        [1, 2, 3, 4, 5, 6],
        [7, 8],
        [9, 10],
    ]

    # v03 최종 분할은 촬영 Session에 기록한 역할을 그대로 따라야 한다.
    session_target_samples: list[DatasetSampleInfo] = []
    sample_index = 1
    for split_name in ("train", "validation", "test"):
        for heatmap_y in range(HEATMAP_HEIGHT):
            for heatmap_x in range(HEATMAP_WIDTH):
                session_target_samples.append(
                    DatasetSampleInfo(
                        path=Path(f"target_{sample_index:06d}.npz"),
                        sample_index=sample_index,
                        heatmap_x=heatmap_x,
                        heatmap_y=heatmap_y,
                        target_x=heatmap_x * 8 + 4,
                        target_y=heatmap_y * 8 + 4,
                        active_pixel_count=10,
                        target_positive_pixel_count=3,
                        target_event_pixel_count=3,
                        positive_energy_argmax_match=True,
                        total_energy_argmax_match=True,
                        capture_session_id=f"target_{split_name}",
                        capture_split=split_name,
                    )
                )
                sample_index += 1
    session_target_split = build_balanced_split(
        session_target_samples,
        samples_per_cell=0,
        seed=42,
        strategy="session",
    )
    assert [len(part) for part in session_target_split] == [64, 64, 64]
    test_blind_target_split = build_balanced_split(
        [
            sample
            for sample in session_target_samples
            if sample.capture_split != "test"
        ],
        samples_per_cell=0,
        seed=42,
        strategy="session",
        require_test=False,
    )
    assert [len(part) for part in test_blind_target_split] == [64, 64, 0]

    session_no_target = [
        NoTargetSampleInfo(
            path=Path(f"no_target_{index:06d}.npz"),
            sample_index=index,
            active_pixel_count=10,
            capture_session_id=f"no_target_{split_name}",
            capture_split=split_name,
        )
        for index, split_name in enumerate(
            ("train", "train", "validation", "validation", "test", "test"),
            start=1,
        )
    ]
    session_negative_split = build_no_target_split(
        session_no_target,
        seed=42,
        strategy="session",
    )
    assert [len(part) for part in session_negative_split] == [2, 2, 2]
    test_blind_negative_split = build_no_target_split(
        [
            sample
            for sample in session_no_target
            if sample.capture_split != "test"
        ],
        seed=42,
        strategy="session",
        require_test=False,
    )
    assert [len(part) for part in test_blind_negative_split] == [2, 2, 0]

    print("Tiny CNN 자체 검증 통과")
    print("Layer 형상: 32×32×8 → 16×16×16 → 8×8×32 → 8×8×1")
    print(f"전체 Weight 수: {parameter_count}개, Bias 없음")
    print("Conv1~3 Padding=1, Conv4 Padding=0")
    print("Raster FIRST_MAX Argmax 자체 검증 통과")
    print("8×8 One-hot / 무표적 0 Vector 및 Hybrid Loss 자체 검증 통과")
    print("Train D4·극성 교환 증강 정렬 자체 검증 통과")
    print("무표적 6:2:2 결정론적 Split 자체 검증 통과")
    print("v03 촬영 Session 기반 Train/Validation/Test 분리 자체 검증 통과")
    print("Test-blind 후보 학습용 Train/Validation 분리 자체 검증 통과")


def run_training(args: argparse.Namespace) -> None:
    set_reproducibility(args.seed)
    args.dataset_dir = resolve_dataset_directory(args.dataset_dir)

    sample_paths, valid_samples, errors, _ = inspect_dataset_directory(
        args.dataset_dir
    )
    if not sample_paths:
        raise RuntimeError(f"학습할 NPZ Sample이 없습니다: {args.dataset_dir}")
    if errors:
        error_summary = "; ".join(
            f"{path.name}: {message}" for path, message in errors
        )
        raise RuntimeError(f"Dataset 형식 오류가 있습니다: {error_summary}")
    if args.split_strategy == "session":
        legacy_samples = [
            sample
            for sample in valid_samples
            if sample.capture_split not in {"train", "validation", "test"}
        ]
        if legacy_samples:
            raise RuntimeError(
                "session Split에는 v03 촬영 메타데이터가 필요합니다. "
                f"legacy/미지정 Sample={len(legacy_samples)}"
            )

    accepted_samples, rejected_samples, distribution = build_quality_distribution(
        valid_samples,
        minimum_active_pixels=args.min_active_pixels,
        maximum_active_pixels=args.max_active_pixels,
        minimum_target_positive_pixels=args.min_target_positive_pixels,
        require_target_positive_argmax=args.require_target_positive_argmax,
        minimum_target_event_pixels=args.min_target_event_pixels,
        minimum_target_event_ratio=args.min_target_event_ratio,
    )
    required_per_cell = args.samples_per_cell if args.samples_per_cell else 3
    if not bool(np.all(distribution >= required_per_cell)):
        distribution_summary = summarize_distribution_gap(
            distribution,
            samples_per_cell=required_per_cell,
        )
        raise RuntimeError(
            "8×8 전체 Cell에 품질 Sample이 충분하지 않습니다. "
            f"{distribution_summary}. "
            "dataset.py --mode dataset-check 결과를 확인하세요."
        )

    train_samples, validation_samples, test_samples = build_balanced_split(
        accepted_samples,
        samples_per_cell=args.samples_per_cell,
        seed=args.seed,
        strategy=args.split_strategy,
        require_test=args.evaluate_test,
    )
    ignored_test_sample_count = 0
    if not args.evaluate_test:
        ignored_test_sample_count = len(test_samples)
        test_samples = []
    train_count_before_signal_filter = len(train_samples)
    if args.min_train_target_event_ratio > 0.0:
        train_samples = [
            sample
            for sample in train_samples
            if sample.target_event_pixel_count
            / max(1, sample.active_pixel_count)
            >= args.min_train_target_event_ratio
        ]
        retained_cells = {
            (sample.heatmap_x, sample.heatmap_y) for sample in train_samples
        }
        if len(retained_cells) != HEATMAP_CELL_COUNT:
            raise RuntimeError(
                "Train target/active Event 비율 필터 후 64개 Cell이 모두 "
                f"남지 않았습니다: {len(retained_cells)}/64"
            )
    split_counts = {
        "train": len(train_samples),
        "validation": len(validation_samples),
        "test": len(test_samples),
    }

    no_target_samples = load_no_target_samples(args.no_target_dir)
    if args.loss == "hybrid" and args.score_weight > 0 and not no_target_samples:
        raise RuntimeError(
            "Hybrid score 학습에는 실제 무표적 Dataset이 필요합니다: "
            f"{args.no_target_dir}"
        )
    (
        no_target_train,
        no_target_validation,
        no_target_test,
    ) = build_no_target_split(
        no_target_samples,
        seed=args.seed,
        strategy=args.split_strategy,
        require_test=args.evaluate_test,
    )
    ignored_no_target_test_sample_count = 0
    if not args.evaluate_test:
        ignored_no_target_test_sample_count = len(no_target_test)
        no_target_test = []
    no_target_split_counts = {
        "train": len(no_target_train),
        "validation": len(no_target_validation),
        "test": len(no_target_test),
    }

    train_loader = make_loader(
        train_samples,
        batch_size=args.batch_size,
        shuffle=True,
        seed=args.seed,
        no_target_samples=no_target_train,
        augment_d4=args.augment_train_d4,
        augment_polarity_swap=args.augment_train_polarity_swap,
        synthetic_target_count=args.synthetic_target_count,
        synthetic_min_target_event_ratio=args.synthetic_min_target_event_ratio,
        synthetic_patch_size=args.synthetic_patch_size,
        synthetic_amplitude_jitter=args.synthetic_amplitude_jitter,
    )
    validation_loader = make_loader(
        validation_samples,
        batch_size=args.batch_size,
        shuffle=False,
        seed=args.seed,
        no_target_samples=no_target_validation,
    )
    test_loader = (
        make_loader(
            test_samples,
            batch_size=args.batch_size,
            shuffle=False,
            seed=args.seed,
            no_target_samples=no_target_test,
        )
        if args.evaluate_test
        else None
    )

    model = TinyCNN()
    initialization_checkpoint = None if args.random_init else args.init_checkpoint
    if initialization_checkpoint is not None:
        initialization = torch.load(initialization_checkpoint, map_location="cpu")
        model.load_state_dict(initialization["model_state_dict"])
        print(
            f"초기 가중치: {initialization_checkpoint} "
            f"({initialization.get('model_version', 'UNKNOWN')})"
        )
    else:
        print("초기 가중치: random (seed 고정)")
    if args.freeze_backbone:
        for layer in (model.conv1, model.conv2, model.conv3):
            for parameter in layer.parameters():
                parameter.requires_grad = False
        print("Fine-tuning 범위: Conv4 only (Conv1~3 frozen)")
    if args.loss == "hybrid":
        criterion: nn.Module = HybridDetectionLoss(
            localization_weight=args.localization_weight,
            score_weight=args.score_weight,
            positive_margin=args.positive_margin,
            negative_margin=args.negative_margin,
            localization_label_smoothing=args.localization_label_smoothing,
        )
        loss_description = (
            "HybridDetectionLoss("
            f"localization_weight={args.localization_weight:g}, "
            f"score_weight={args.score_weight:g}, "
            f"positive_margin={args.positive_margin:g}, "
            f"negative_margin={args.negative_margin:g}, "
            f"label_smoothing={args.localization_label_smoothing:g})"
        )
    else:
        criterion = nn.BCEWithLogitsLoss(
            pos_weight=torch.tensor(args.pos_weight, dtype=torch.float32)
        )
        loss_description = f"BCEWithLogitsLoss(pos_weight={args.pos_weight:g})"
    optimizer = torch.optim.Adam(
        (parameter for parameter in model.parameters() if parameter.requires_grad),
        lr=args.learning_rate,
        weight_decay=args.weight_decay,
    )

    print(f"Dataset: 전체={len(sample_paths)} 품질사용={len(accepted_samples)} 품질제외={len(rejected_samples)}")
    print(
        f"분할: Train={split_counts['train']} "
        f"Validation={split_counts['validation']} Test={split_counts['test']}"
    )
    if not args.evaluate_test:
        print(
            "Test-blind 후보 모드: Test loader/추론을 생성하지 않음 "
            f"(표적 {ignored_test_sample_count}개, "
            f"무표적 {ignored_no_target_test_sample_count}개 제외)"
        )
    if args.min_train_target_event_ratio > 0.0:
        print(
            "Train 신호 필터: "
            f"target/active>={args.min_train_target_event_ratio:g}, "
            f"{train_count_before_signal_filter}->{len(train_samples)}"
        )
    print(
        f"무표적 Dataset: 경로={args.no_target_dir} 사용={len(no_target_samples)} "
        f"Train={no_target_split_counts['train']} "
        f"Validation={no_target_split_counts['validation']} "
        f"Test={no_target_split_counts['test']}"
    )
    print(
        f"품질 필터: target_positive>={args.min_target_positive_pixels}, "
        f"target_event>={args.min_target_event_pixels}, "
        f"target/active>={args.min_target_event_ratio:g}, "
        f"positive_argmax_required={args.require_target_positive_argmax}"
    )
    print(f"Split 전략: {args.split_strategy}")
    print(
        "Train 증강: "
        f"D4={args.augment_train_d4}, "
        f"polarity_swap={args.augment_train_polarity_swap}, "
        f"synthetic_target={args.synthetic_target_count}, "
        f"synthetic_ratio>={args.synthetic_min_target_event_ratio:g}, "
        f"synthetic_patch={args.synthetic_patch_size}"
    )
    print(f"Loss: {loss_description}")
    print(f"Model: {MODEL_VERSION}, Parameters={EXPECTED_PARAMETER_COUNT}, Device=CPU")

    history: list[dict[str, object]] = []
    best_state: dict[str, torch.Tensor] | None = None
    best_validation_metrics: Metrics | None = None
    best_epoch = 0
    epochs_without_improvement = 0

    for epoch in range(1, args.epochs + 1):
        train_metrics = train_one_epoch(
            model,
            train_loader,
            criterion,
            optimizer,
        )
        validation_metrics = evaluate(model, validation_loader, criterion)
        history.append(
            {
                "epoch": epoch,
                "train": asdict(train_metrics),
                "validation": asdict(validation_metrics),
            }
        )

        validation_auc = (
            validation_metrics.score_auc
            if np.isfinite(validation_metrics.score_auc)
            else 0.5
        )
        selection_score = (
            validation_metrics.cell_accuracy
            + args.selection_auc_weight * validation_auc
        )
        if best_validation_metrics is None:
            best_selection_score = float("-inf")
        else:
            best_auc = (
                best_validation_metrics.score_auc
                if np.isfinite(best_validation_metrics.score_auc)
                else 0.5
            )
            best_selection_score = (
                best_validation_metrics.cell_accuracy
                + args.selection_auc_weight * best_auc
            )
        is_better = (
            selection_score > best_selection_score
            or (
                selection_score == best_selection_score
                and best_validation_metrics is not None
                and validation_metrics.loss < best_validation_metrics.loss
            )
        )
        if is_better:
            best_state = copy.deepcopy(model.state_dict())
            best_validation_metrics = validation_metrics
            best_epoch = epoch
            epochs_without_improvement = 0
        else:
            epochs_without_improvement += 1

        if epoch == 1 or epoch % args.log_every == 0 or epoch == args.epochs:
            print(
                f"Epoch={epoch:03d} "
                f"TrainLoss={train_metrics.loss:.6f} "
                f"TrainAcc={train_metrics.cell_accuracy:.4f} "
                f"ValLoss={validation_metrics.loss:.6f} "
                f"ValAcc={validation_metrics.positive_cell_accuracy:.4f} "
                f"ValMAE={validation_metrics.target_mean_mae_px:.3f}px "
                f"ValPosScore={validation_metrics.positive_max_score_mean:.4f} "
                f"ValNegScore={validation_metrics.negative_max_score_mean:.4f} "
                f"ValMargin={validation_metrics.score_margin:.4f} "
                f"ValAUC={validation_metrics.score_auc:.4f} "
                f"Select={selection_score:.4f}"
            )

        if epochs_without_improvement >= args.patience:
            print(f"Early Stop: {args.patience} Epoch 동안 Validation 개선 없음")
            break

    if best_state is None or best_validation_metrics is None:
        raise RuntimeError("최적 Model을 선택하지 못했습니다.")

    model.load_state_dict(best_state)
    final_validation_metrics = evaluate(model, validation_loader, criterion)
    test_metrics = (
        evaluate(model, test_loader, criterion)
        if test_loader is not None
        else None
    )

    split_manifest = {
        "model_version": MODEL_VERSION,
        "base_spec_version": BASE_SPEC_VERSION,
        "seed": args.seed,
        "quality_range": {
            "minimum_active_pixels": args.min_active_pixels,
            "maximum_active_pixels": args.max_active_pixels,
            "minimum_target_positive_pixels": args.min_target_positive_pixels,
            "minimum_target_event_pixels": args.min_target_event_pixels,
            "minimum_target_event_ratio": args.min_target_event_ratio,
            "require_target_positive_argmax": args.require_target_positive_argmax,
        },
        "samples_per_cell": args.samples_per_cell,
        "split_strategy": args.split_strategy,
        "test_evaluated": args.evaluate_test,
        "ignored_test_sample_count": ignored_test_sample_count,
        "ignored_no_target_test_sample_count": (
            ignored_no_target_test_sample_count
        ),
        "train_count_before_signal_filter": train_count_before_signal_filter,
        "minimum_train_target_event_ratio": args.min_train_target_event_ratio,
        "train_augmentation": {
            "d4": args.augment_train_d4,
            "polarity_swap": args.augment_train_polarity_swap,
            "synthetic_target_count_per_epoch": args.synthetic_target_count,
            "synthetic_min_target_event_ratio": (
                args.synthetic_min_target_event_ratio
            ),
            "synthetic_patch_size": args.synthetic_patch_size,
            "synthetic_amplitude_jitter": args.synthetic_amplitude_jitter,
            "validation_test_augmentation": False,
        },
        "loss": {
            "type": args.loss,
            "pos_weight": args.pos_weight,
            "localization_weight": args.localization_weight,
            "score_weight": args.score_weight,
            "positive_margin": args.positive_margin,
            "negative_margin": args.negative_margin,
            "localization_label_smoothing": (
                args.localization_label_smoothing
            ),
            "selection_auc_weight": args.selection_auc_weight,
            "target_encoding": "8x8_ONEHOT_POSITIVE_ZEROS_NEGATIVE",
        },
        "splits": {
            "train": [str(sample.path) for sample in train_samples],
            "validation": [str(sample.path) for sample in validation_samples],
            "test": [str(sample.path) for sample in test_samples],
        },
        "capture_sessions": {
            "train": sorted({sample.capture_session_id for sample in train_samples}),
            "validation": sorted(
                {sample.capture_session_id for sample in validation_samples}
            ),
            "test": sorted({sample.capture_session_id for sample in test_samples}),
        },
        "no_target_directory": str(args.no_target_dir),
        "no_target_split_counts": no_target_split_counts,
        "no_target_splits": {
            "train": [str(sample.path) for sample in no_target_train],
            "validation": [str(sample.path) for sample in no_target_validation],
            "test": [str(sample.path) for sample in no_target_test],
        },
        "no_target_capture_sessions": {
            "train": sorted(
                {sample.capture_session_id for sample in no_target_train}
            ),
            "validation": sorted(
                {sample.capture_session_id for sample in no_target_validation}
            ),
            "test": sorted(
                {sample.capture_session_id for sample in no_target_test}
            ),
        },
    }
    write_json(args.split_manifest, split_manifest)

    checkpoint = {
        "model_state_dict": model.state_dict(),
        "model_version": MODEL_VERSION,
        "base_spec_version": BASE_SPEC_VERSION,
        "freeze_documents": [
            "D3_FREEZE_APPROVAL_A_TO_B_001.md",
            "D3_B_to_A_CNN_Convolution_Freeze_Request.md",
            "D3_FREEZE_REQUEST_A_001.md",
        ],
        "architecture": {
            "input_shape_chw": [2, 64, 64],
            "conv1": {"cin": 2, "cout": 8, "k": 3, "stride": 2, "pad": 1, "relu": True, "bias": False},
            "conv2": {"cin": 8, "cout": 16, "k": 3, "stride": 2, "pad": 1, "relu": True, "bias": False},
            "conv3": {"cin": 16, "cout": 32, "k": 3, "stride": 2, "pad": 1, "relu": True, "bias": False},
            "conv4": {"cin": 32, "cout": 1, "k": 1, "stride": 1, "pad": 0, "relu": False, "bias": False},
            "operation": "cross_correlation_no_kernel_flip",
            "weight_layout": "OIHW",
        },
        "input_preprocessing": {
            "dataset_layout": "HWC_LOGICAL_ONLY",
            "model_layout": "CHW",
            "normalization": "input_int8 / 127.0",
        },
        "argmax": {
            "scan_order": "YX_RASTER",
            "tie_rule": "FIRST_MAX",
        },
        "training": {
            "seed": args.seed,
            "epochs_requested": args.epochs,
            "epochs_completed": len(history),
            "best_epoch": best_epoch,
            "batch_size": args.batch_size,
            "learning_rate": args.learning_rate,
            "weight_decay": args.weight_decay,
            "init_checkpoint": (
                str(initialization_checkpoint)
                if initialization_checkpoint is not None
                else None
            ),
            "random_init": args.random_init,
            "freeze_backbone": args.freeze_backbone,
            "minimum_target_positive_pixels": args.min_target_positive_pixels,
            "minimum_target_event_pixels": args.min_target_event_pixels,
            "minimum_target_event_ratio": args.min_target_event_ratio,
            "minimum_train_target_event_ratio": (
                args.min_train_target_event_ratio
            ),
            "require_target_positive_argmax": args.require_target_positive_argmax,
            "split_strategy": args.split_strategy,
            "test_evaluated": args.evaluate_test,
            "ignored_test_sample_count": ignored_test_sample_count,
            "ignored_no_target_test_sample_count": (
                ignored_no_target_test_sample_count
            ),
            "split_counts": split_counts,
            "no_target_split_counts": no_target_split_counts,
            "loss": args.loss,
            "pos_weight": args.pos_weight,
            "localization_weight": args.localization_weight,
            "score_weight": args.score_weight,
            "positive_margin": args.positive_margin,
            "negative_margin": args.negative_margin,
            "localization_label_smoothing": (
                args.localization_label_smoothing
            ),
            "selection_auc_weight": args.selection_auc_weight,
            "augment_train_d4": args.augment_train_d4,
            "augment_train_polarity_swap": args.augment_train_polarity_swap,
            "synthetic_target_count": args.synthetic_target_count,
            "synthetic_min_target_event_ratio": (
                args.synthetic_min_target_event_ratio
            ),
            "synthetic_patch_size": args.synthetic_patch_size,
            "synthetic_amplitude_jitter": args.synthetic_amplitude_jitter,
        },
        "validation_metrics": asdict(final_validation_metrics),
        "test_metrics": asdict(test_metrics) if test_metrics is not None else None,
    }
    args.output_model.parent.mkdir(parents=True, exist_ok=True)
    temporary_model_path = args.output_model.with_suffix(
        args.output_model.suffix + ".tmp"
    )
    torch.save(checkpoint, temporary_model_path)
    temporary_model_path.replace(args.output_model)

    write_json(
        args.history_output,
        {
            "model_version": MODEL_VERSION,
            "base_spec_version": BASE_SPEC_VERSION,
            "dataset_directory": str(args.dataset_dir),
            "no_target_directory": str(args.no_target_dir),
            "accepted_sample_count": len(accepted_samples),
            "rejected_sample_count": len(rejected_samples),
            "no_target_sample_count": len(no_target_samples),
            "split_counts": split_counts,
            "no_target_split_counts": no_target_split_counts,
            "minimum_target_positive_pixels": args.min_target_positive_pixels,
            "minimum_target_event_pixels": args.min_target_event_pixels,
            "minimum_target_event_ratio": args.min_target_event_ratio,
            "minimum_train_target_event_ratio": (
                args.min_train_target_event_ratio
            ),
            "require_target_positive_argmax": args.require_target_positive_argmax,
            "split_strategy": args.split_strategy,
            "test_evaluated": args.evaluate_test,
            "ignored_test_sample_count": ignored_test_sample_count,
            "ignored_no_target_test_sample_count": (
                ignored_no_target_test_sample_count
            ),
            "loss": args.loss,
            "loss_description": loss_description,
            "pos_weight": args.pos_weight,
            "localization_weight": args.localization_weight,
            "score_weight": args.score_weight,
            "positive_margin": args.positive_margin,
            "negative_margin": args.negative_margin,
            "localization_label_smoothing": (
                args.localization_label_smoothing
            ),
            "selection_auc_weight": args.selection_auc_weight,
            "augment_train_d4": args.augment_train_d4,
            "augment_train_polarity_swap": args.augment_train_polarity_swap,
            "synthetic_target_count": args.synthetic_target_count,
            "synthetic_min_target_event_ratio": (
                args.synthetic_min_target_event_ratio
            ),
            "synthetic_patch_size": args.synthetic_patch_size,
            "synthetic_amplitude_jitter": args.synthetic_amplitude_jitter,
            "init_checkpoint": (
                str(initialization_checkpoint)
                if initialization_checkpoint is not None
                else None
            ),
            "random_init": args.random_init,
            "freeze_backbone": args.freeze_backbone,
            "best_epoch": best_epoch,
            "validation_metrics": asdict(final_validation_metrics),
            "test_metrics": (
                asdict(test_metrics) if test_metrics is not None else None
            ),
            "history": history,
        },
    )
    write_accuracy_report(
        args.report_output,
        dataset_directory=args.dataset_dir,
        accepted_count=len(accepted_samples),
        rejected_count=len(rejected_samples),
        split_counts=split_counts,
        best_epoch=best_epoch,
        validation_metrics=final_validation_metrics,
        test_metrics=test_metrics,
        no_target_directory=args.no_target_dir if no_target_samples else None,
        no_target_split_counts=(
            no_target_split_counts if no_target_samples else None
        ),
        loss_description=loss_description,
        minimum_target_positive_pixels=args.min_target_positive_pixels,
        require_target_positive_argmax=args.require_target_positive_argmax,
        split_strategy=args.split_strategy,
        initialization_checkpoint=initialization_checkpoint,
        freeze_backbone=args.freeze_backbone,
        learning_rate=args.learning_rate,
        augment_train_d4=args.augment_train_d4,
        augment_train_polarity_swap=args.augment_train_polarity_swap,
        synthetic_target_count=args.synthetic_target_count,
        synthetic_min_target_event_ratio=args.synthetic_min_target_event_ratio,
        synthetic_patch_size=args.synthetic_patch_size,
        minimum_train_target_event_ratio=args.min_train_target_event_ratio,
        minimum_target_event_pixels=args.min_target_event_pixels,
        minimum_target_event_ratio=args.min_target_event_ratio,
        test_evaluated=args.evaluate_test,
        ignored_test_sample_count=ignored_test_sample_count,
        ignored_no_target_test_sample_count=(
            ignored_no_target_test_sample_count
        ),
    )

    print("FP32 Tiny CNN 학습 완료")
    print(f"Best Epoch={best_epoch}")
    print(
        f"Validation: Accuracy={final_validation_metrics.positive_cell_accuracy:.4f}, "
        f"Target MAE={final_validation_metrics.target_mean_mae_px:.3f}px"
    )
    if test_metrics is None:
        print("Test: NOT_EVALUATED (--no-evaluate-test)")
    else:
        print(
            f"Test: Accuracy={test_metrics.positive_cell_accuracy:.4f}, "
            f"Target MAE={test_metrics.target_mean_mae_px:.3f}px"
        )
    print(
        "Validation SCORE_TH 분리도: "
        f"positive_max_score_mean={final_validation_metrics.positive_max_score_mean:.6f}, "
        f"negative_max_score_mean={final_validation_metrics.negative_max_score_mean:.6f}, "
        f"score_margin={final_validation_metrics.score_margin:.6f}"
        f", auc={final_validation_metrics.score_auc:.6f}"
    )
    if test_metrics is None:
        print("Test SCORE_TH 분리도: NOT_EVALUATED (--no-evaluate-test)")
    else:
        print(
            "Test SCORE_TH 분리도: "
            f"positive_max_score_mean={test_metrics.positive_max_score_mean:.6f}, "
            f"negative_max_score_mean={test_metrics.negative_max_score_mean:.6f}, "
            f"score_margin={test_metrics.score_margin:.6f}"
            f", auc={test_metrics.score_auc:.6f}"
        )
    print(f"Model 저장: {args.output_model}")
    print(f"분할 기록: {args.split_manifest}")
    print(f"학습 기록: {args.history_output}")
    print(f"Accuracy Report: {args.report_output}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="B 역할 고정 Tiny CNN FP32 학습 모듈"
    )
    parser.add_argument(
        "--mode",
        choices=("train", "self-test"),
        default="train",
    )
    parser.add_argument(
        "--dataset-dir",
        type=Path,
        default=DEFAULT_DATASET_CANDIDATES[0],
    )
    parser.add_argument(
        "--no-target-dir",
        type=Path,
        default=DEFAULT_NO_TARGET_DIR,
        help=(
            "SCORE_TH 보정용 무표적 NPZ 폴더. 없거나 비어 있으면 경고만 남기고 "
            "score_weight가 0보다 큰 Hybrid 학습은 실패한다."
        ),
    )
    parser.add_argument(
        "--init-checkpoint",
        type=Path,
        default=DEFAULT_INIT_CHECKPOINT,
        help="동결 구조가 같은 checkpoint에서 fine-tuning 시작",
    )
    parser.add_argument(
        "--random-init",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="init-checkpoint를 무시하고 고정 seed의 무작위 가중치로 시작",
    )
    parser.add_argument(
        "--freeze-backbone",
        action=argparse.BooleanOptionalAction,
        default=DEFAULT_FREEZE_BACKBONE,
        help="Conv1~3을 고정하고 Conv4만 fine-tuning",
    )
    parser.add_argument(
        "--pos-weight",
        type=float,
        default=DEFAULT_POS_WEIGHT,
        help=(
            "BCEWithLogitsLoss 양성 항 가중치. 8×8 Cell 중 양성은 1칸뿐이라 "
            f"기본값은 {DEFAULT_POS_WEIGHT:g}이다."
        ),
    )
    parser.add_argument(
        "--loss",
        choices=("hybrid", "bce"),
        default=DEFAULT_LOSS,
    )
    parser.add_argument(
        "--localization-weight",
        type=float,
        default=DEFAULT_LOCALIZATION_WEIGHT,
    )
    parser.add_argument(
        "--score-weight",
        type=float,
        default=DEFAULT_SCORE_WEIGHT,
    )
    parser.add_argument(
        "--positive-margin",
        type=float,
        default=DEFAULT_POSITIVE_MARGIN,
    )
    parser.add_argument(
        "--negative-margin",
        type=float,
        default=DEFAULT_NEGATIVE_MARGIN,
    )
    parser.add_argument(
        "--localization-label-smoothing",
        type=float,
        default=0.0,
        help="Train 위치 Cross Entropy의 label smoothing (Validation/Test 불변)",
    )
    parser.add_argument(
        "--selection-auc-weight",
        type=float,
        default=DEFAULT_SELECTION_AUC_WEIGHT,
        help="Validation checkpoint 선택에서 score AUC에 주는 가중치",
    )
    parser.add_argument("--min-active-pixels", type=int, default=5)
    parser.add_argument(
        "--max-active-pixels",
        type=int,
        default=DEFAULT_MAXIMUM_ACTIVE_PIXELS,
    )
    parser.add_argument(
        "--min-target-positive-pixels",
        type=int,
        default=DEFAULT_MINIMUM_TARGET_POSITIVE_PIXELS,
    )
    parser.add_argument("--min-target-event-pixels", type=int, default=0)
    parser.add_argument("--min-target-event-ratio", type=float, default=0.0)
    parser.add_argument(
        "--min-train-target-event-ratio",
        type=float,
        default=0.0,
        help=(
            "Session 분할 후 Train에만 적용할 target-cell/전체 active Event "
            "최소 비율. Validation/Test는 필터하지 않는다."
        ),
    )
    parser.add_argument(
        "--require-target-positive-argmax",
        action=argparse.BooleanOptionalAction,
        default=DEFAULT_REQUIRE_TARGET_POSITIVE_ARGMAX,
    )
    parser.add_argument(
        "--split-strategy",
        choices=("session", "chronological", "random"),
        default=DEFAULT_SPLIT_STRATEGY,
    )
    parser.add_argument(
        "--evaluate-test",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "최종 선택 후 Test를 평가한다. 후보 탐색에는 "
            "--no-evaluate-test를 사용해 Test loader와 추론을 건너뛴다."
        ),
    )
    parser.add_argument(
        "--samples-per-cell",
        type=int,
        default=0,
        help="0이면 품질 필터 통과 Sample 전부 사용",
    )
    parser.add_argument("--epochs", type=int, default=DEFAULT_EPOCHS)
    parser.add_argument("--patience", type=int, default=DEFAULT_PATIENCE)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--learning-rate", type=float, default=DEFAULT_LEARNING_RATE)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--log-every", type=int, default=5)
    parser.add_argument(
        "--augment-train-d4",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Train에만 90도 회전과 반전으로 구성된 D4 공간 증강 적용",
    )
    parser.add_argument(
        "--augment-train-polarity-swap",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Train에만 POSITIVE/NEGATIVE Event 채널 무작위 교환 적용",
    )
    parser.add_argument(
        "--synthetic-target-count",
        type=int,
        default=0,
        help=(
            "Epoch마다 실제 Train 표적 패치와 실제 Train 무표적 배경으로 만드는 "
            "학습 전용 합성 Sample 수"
        ),
    )
    parser.add_argument(
        "--synthetic-min-target-event-ratio",
        type=float,
        default=0.1,
        help="합성 donor로 쓸 Train Sample의 target/active Event 최소 비율",
    )
    parser.add_argument(
        "--synthetic-patch-size",
        type=int,
        default=16,
        help="임의 8×8 Heatmap Cell 중심으로 옮길 Event patch 한 변 크기",
    )
    parser.add_argument(
        "--synthetic-amplitude-jitter",
        type=float,
        default=0.25,
        help="합성 donor Event 세기 배율의 ±무작위 범위",
    )
    parser.add_argument(
        "--output-model",
        type=Path,
        default=Path(f"weights/tiny_cnn_fp32_{MODEL_VERSION}.pt"),
    )
    parser.add_argument(
        "--split-manifest",
        type=Path,
        default=Path(f"results/{MODEL_VERSION}_split.json"),
    )
    parser.add_argument(
        "--history-output",
        type=Path,
        default=Path(f"results/{MODEL_VERSION}_train_history.json"),
    )
    parser.add_argument(
        "--report-output",
        type=Path,
        default=Path(f"results/{MODEL_VERSION}_fp32_accuracy_report.md"),
    )
    args = parser.parse_args()

    if args.epochs < 1:
        parser.error("--epochs는 1 이상이어야 합니다.")
    if args.patience < 1:
        parser.error("--patience는 1 이상이어야 합니다.")
    if args.batch_size < 1:
        parser.error("--batch-size는 1 이상이어야 합니다.")
    if args.learning_rate <= 0:
        parser.error("--learning-rate는 0보다 커야 합니다.")
    if args.weight_decay < 0:
        parser.error("--weight-decay는 0 이상이어야 합니다.")
    if args.log_every < 1:
        parser.error("--log-every는 1 이상이어야 합니다.")
    if args.pos_weight <= 0:
        parser.error("--pos-weight는 0보다 커야 합니다.")
    if args.localization_weight < 0 or args.score_weight < 0:
        parser.error("Loss 가중치는 0 이상이어야 합니다.")
    if args.localization_weight == 0 and args.score_weight == 0:
        parser.error("Loss 가중치 중 하나 이상은 0보다 커야 합니다.")
    if args.positive_margin < 0 or args.negative_margin < 0:
        parser.error("Score margin은 0 이상이어야 합니다.")
    if args.selection_auc_weight < 0:
        parser.error("--selection-auc-weight는 0 이상이어야 합니다.")
    if not 0.0 <= args.localization_label_smoothing < 1.0:
        parser.error("--localization-label-smoothing은 0 이상 1 미만이어야 합니다.")
    if args.synthetic_target_count < 0:
        parser.error("--synthetic-target-count는 0 이상이어야 합니다.")
    if not 0.0 <= args.synthetic_min_target_event_ratio <= 1.0:
        parser.error("--synthetic-min-target-event-ratio는 0~1이어야 합니다.")
    if (
        args.synthetic_patch_size < 8
        or args.synthetic_patch_size > 32
        or args.synthetic_patch_size % 2
    ):
        parser.error("--synthetic-patch-size는 8~32의 짝수여야 합니다.")
    if not 0.0 <= args.synthetic_amplitude_jitter <= 0.75:
        parser.error("--synthetic-amplitude-jitter는 0~0.75여야 합니다.")
    if args.min_target_positive_pixels < 0:
        parser.error("--min-target-positive-pixels는 0 이상이어야 합니다.")
    if args.min_target_event_pixels < 0:
        parser.error("--min-target-event-pixels는 0 이상이어야 합니다.")
    if not 0.0 <= args.min_target_event_ratio <= 1.0:
        parser.error("--min-target-event-ratio는 0~1이어야 합니다.")
    if not 0.0 <= args.min_train_target_event_ratio <= 1.0:
        parser.error("--min-train-target-event-ratio는 0~1이어야 합니다.")
    if args.samples_per_cell not in (0,) and args.samples_per_cell < 3:
        parser.error("--samples-per-cell은 0 또는 3 이상이어야 합니다.")
    return args


def main() -> None:
    args = parse_args()
    if args.mode == "self-test":
        run_self_test()
    else:
        run_training(args)


if __name__ == "__main__":
    main()
