#!/usr/bin/env python3
"""B 역할 데이터셋 파이프라인용 웹캠 프레임 차분 입력 모듈.

이 파일은 승인된 대체 입력 경로, 실제 표적 마커 Label, 진단용 레이저 Preview,
Label Mapping, 저장된 Dataset Sample 검증을 구현한다.

    RGB 웹캠 → 프레임 차분 → 양/음 변화 맵 → 64×64×2
    RGB 웹캠 → 실제 표적 색상 Blob → 원본 카메라 중심 좌표
    원본 좌표 → 64×64 좌표 → 8×8 One-hot Heatmap → Tracking 좌표

생성되는 NumPy 배열의 HWC 형상 ``(64, 64, 2)``는 B의 Python 내부 논리
표현으로만 사용한다. 좌표 변환은 Common Spec v1.5에서 유지된 규칙을
사용한다. NPU의 물리적 메모리 순서를 확정하거나 RTL용 ``.hex`` 파일을
만들지는 않는다.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import cv2
import numpy as np


TENSOR_HEIGHT = 64
TENSOR_WIDTH = 64
TENSOR_CHANNELS = 2
POSITIVE_CHANNEL = 0
NEGATIVE_CHANNEL = 1
SIGNED_INT8_MAX = 127
HEATMAP_HEIGHT = 8
HEATMAP_WIDTH = 8
HEATMAP_CELL_SIZE = 8
BASE_SPEC_VERSION = "common_v1.5"
LEGACY_SPEC_VERSIONS = frozenset({"common_v1.2", "common_v1.3"})
LABEL_SOURCE_TARGET_MARKER = "TARGET_MARKER"
REJECTED_LABEL_SOURCES = frozenset({"RED_LASER", "LASER", "RED_LASER_DOT"})
NO_TARGET_SAMPLE_PURPOSE = "NO_TARGET_SCORE_TH"
COLLECTION_VERSION = "v03_reshoot_1"
CAPTURE_SPLITS = frozenset({"train", "validation", "test"})
DEFAULT_MAXIMUM_ACTIVE_PIXELS = 1_800
DEFAULT_REQUIRE_TARGET_POSITIVE_ARGMAX = False
LEGACY_CAPTURE_SESSION_ID = "LEGACY_UNSPECIFIED"
LEGACY_CAPTURE_SPLIT = "unspecified"
SESSION_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


@dataclass(frozen=True)
class CameraConfig:
    device: int = 2
    width: int = 640
    height: int = 480
    fps: int = 30
    lock_v03_controls: bool = False
    brightness: int = 5
    saturation: int = 128
    exposure_time_absolute: int = 78
    white_balance_temperature: int = 4866
    focus_absolute: int = 4096


@dataclass(frozen=True)
class LaserDetection:
    """진단 전용 빨간 레이저 검출 결과."""

    center_x: int
    center_y: int
    area: float
    radius: float
    circularity: float
    local_contrast: float


@dataclass(frozen=True)
class TargetDetection:
    """원본 카메라 좌표계에서 검출한 실제 추적 표적 마커."""

    center_x: int
    center_y: int
    area: float


@dataclass(frozen=True)
class CaptureMetadata:
    """v03 재촬영 Sample의 누수 방지용 촬영 출처."""

    session_id: str
    split: str
    frame_sequence_index: int
    camera_device: int
    camera_fps: float
    environment_note: str = ""
    captured_at_utc: str = ""


@dataclass(frozen=True)
class NoTargetSampleInfo:
    """SCORE_TH 보정용 실제 무표적 NPZ의 검증 결과."""

    path: Path
    sample_index: int
    active_pixel_count: int
    capture_session_id: str = LEGACY_CAPTURE_SESSION_ID
    capture_split: str = LEGACY_CAPTURE_SPLIT
    captured_at_utc: str = ""
    audit_image_relative_path: str = ""
    collection_version: str = ""


@dataclass(frozen=True)
class LabelMapping:
    """Common Spec v1.5에 따라 생성한 학습 및 Tracking 좌표."""

    source_x: int
    source_y: int
    tensor_x: int
    tensor_y: int
    heatmap_x: int
    heatmap_y: int
    target_x: int
    target_y: int


@dataclass(frozen=True)
class DatasetSampleInfo:
    """검증을 통과한 NPZ Sample의 분포 요약 정보."""

    path: Path
    sample_index: int
    heatmap_x: int
    heatmap_y: int
    target_x: int
    target_y: int
    active_pixel_count: int
    target_positive_pixel_count: int
    target_event_pixel_count: int
    positive_energy_argmax_match: bool
    total_energy_argmax_match: bool
    capture_session_id: str = LEGACY_CAPTURE_SESSION_ID
    capture_split: str = LEGACY_CAPTURE_SPLIT
    captured_at_utc: str = ""
    audit_image_relative_path: str = ""
    collection_version: str = ""


@dataclass(frozen=True)
class EventLabelAlignment:
    """Event Tensor 신호와 정답 Heatmap Cell의 정렬 측정값."""

    target_positive_pixel_count: int
    target_event_pixel_count: int
    positive_energy_argmax_x: int
    positive_energy_argmax_y: int
    total_energy_argmax_x: int
    total_energy_argmax_y: int
    positive_energy_argmax_match: bool
    total_energy_argmax_match: bool


def utc_now_text() -> str:
    """재현 가능한 ISO-8601 UTC 시각 문자열을 반환한다."""
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def validate_capture_metadata(metadata: CaptureMetadata) -> None:
    """v03 재촬영 Session 식별자와 Split을 저장 전에 검증한다."""
    if not SESSION_ID_PATTERN.fullmatch(metadata.session_id):
        raise ValueError(
            "session_id는 영문 소문자·숫자로 시작하고 소문자·숫자·_·-만 "
            "사용하는 1~64자여야 합니다."
        )
    if metadata.split not in CAPTURE_SPLITS:
        allowed = ", ".join(sorted(CAPTURE_SPLITS))
        raise ValueError(f"capture split은 {allowed} 중 하나여야 합니다.")
    if metadata.frame_sequence_index < 1:
        raise ValueError("frame_sequence_index는 1 이상이어야 합니다.")
    if metadata.camera_device < 0:
        raise ValueError("camera_device는 0 이상이어야 합니다.")
    if metadata.camera_fps <= 0:
        raise ValueError("camera_fps는 0보다 커야 합니다.")
    if len(metadata.environment_note) > 500:
        raise ValueError("environment_note는 500자 이하여야 합니다.")
    if metadata.captured_at_utc:
        try:
            captured_at = datetime.fromisoformat(metadata.captured_at_utc)
        except ValueError as error:
            raise ValueError("captured_at_utc가 ISO-8601 형식이 아닙니다.") from error
        if captured_at.tzinfo is None:
            raise ValueError("captured_at_utc에는 UTC offset이 필요합니다.")


def build_audit_image(frame_bgr: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """사후 Label 검수를 위해 원본과 검출 Mask를 나란히 합친다."""
    if frame_bgr.ndim != 3 or frame_bgr.shape[2] != 3:
        raise ValueError("audit 원본은 BGR H×W×3이어야 합니다.")
    if mask.shape != frame_bgr.shape[:2] or mask.dtype != np.uint8:
        raise ValueError("audit Mask는 원본과 같은 H×W uint8이어야 합니다.")
    mask_bgr = cv2.cvtColor(mask, cv2.COLOR_GRAY2BGR)
    return np.concatenate((frame_bgr, mask_bgr), axis=1)


def save_jpeg_snapshot(output_path: Path, image: np.ndarray) -> None:
    """현재 진단 Frame을 원자적으로 JPEG에 저장한다."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    encoded_ok, encoded = cv2.imencode(
        output_path.suffix or ".jpg",
        image,
        [int(cv2.IMWRITE_JPEG_QUALITY), 95],
    )
    if not encoded_ok:
        raise RuntimeError("Camera Snapshot 인코딩에 실패했습니다.")
    temporary_path = output_path.with_name(f".{output_path.name}.tmp")
    temporary_path.write_bytes(encoded.tobytes())
    temporary_path.replace(output_path)


def save_audit_image(
    output_directory: Path,
    sample_index: int,
    audit_image: np.ndarray,
) -> str:
    """검수 JPEG를 audit/ 아래에 저장하고 NPZ용 상대경로를 반환한다."""
    audit_directory = output_directory / "audit"
    audit_directory.mkdir(parents=True, exist_ok=True)
    relative_path = Path("audit") / f"sample_{sample_index:06d}.jpg"
    output_path = output_directory / relative_path
    if output_path.exists():
        raise FileExistsError(f"이미 존재하는 Audit 이미지입니다: {output_path}")

    encoded_ok, encoded = cv2.imencode(
        ".jpg",
        audit_image,
        [int(cv2.IMWRITE_JPEG_QUALITY), 88],
    )
    if not encoded_ok:
        raise RuntimeError("Audit JPEG 인코딩에 실패했습니다.")
    temporary_path = audit_directory / f".{output_path.name}.tmp"
    temporary_path.write_bytes(encoded.tobytes())
    temporary_path.replace(output_path)
    return relative_path.as_posix()


def read_capture_metadata(
    sample: np.lib.npyio.NpzFile,
    sample_path: Path,
) -> tuple[str, str, str, str, str]:
    """새 v03 메타데이터를 엄격히 읽되 기존 Sample은 legacy로 유지한다."""
    required_keys = {
        "collection_version",
        "capture_session_id",
        "capture_split",
        "captured_at_utc",
        "camera_device",
        "camera_fps",
        "frame_sequence_index",
        "environment_note",
        "audit_image_relative_path",
    }
    present_keys = required_keys & set(sample.files)
    if not present_keys:
        return (
            LEGACY_CAPTURE_SESSION_ID,
            LEGACY_CAPTURE_SPLIT,
            "",
            "",
            "",
        )
    missing_keys = sorted(required_keys - set(sample.files))
    if missing_keys:
        raise ValueError(
            f"v03 촬영 메타데이터 일부 누락: {', '.join(missing_keys)}"
        )

    text_values: dict[str, str] = {}
    for name in (
        "collection_version",
        "capture_session_id",
        "capture_split",
        "captured_at_utc",
        "environment_note",
        "audit_image_relative_path",
    ):
        value = sample[name]
        if value.shape != ():
            raise ValueError(f"{name}은 문자열 Scalar여야 합니다.")
        text_values[name] = str(value.item())

    if text_values["collection_version"] != COLLECTION_VERSION:
        raise ValueError(
            "collection_version 불일치: "
            f"저장={text_values['collection_version']}, 필요={COLLECTION_VERSION}"
        )
    metadata = CaptureMetadata(
        session_id=text_values["capture_session_id"],
        split=text_values["capture_split"],
        frame_sequence_index=int(sample["frame_sequence_index"]),
        camera_device=int(sample["camera_device"]),
        camera_fps=float(sample["camera_fps"]),
        environment_note=text_values["environment_note"],
        captured_at_utc=text_values["captured_at_utc"],
    )
    if sample["camera_device"].shape != () or sample["camera_device"].dtype != np.int16:
        raise ValueError("camera_device는 int16 Scalar여야 합니다.")
    if sample["camera_fps"].shape != () or sample["camera_fps"].dtype != np.float32:
        raise ValueError("camera_fps는 float32 Scalar여야 합니다.")
    if (
        sample["frame_sequence_index"].shape != ()
        or sample["frame_sequence_index"].dtype != np.int32
    ):
        raise ValueError("frame_sequence_index는 int32 Scalar여야 합니다.")
    validate_capture_metadata(metadata)

    audit_relative_path = Path(text_values["audit_image_relative_path"])
    if (
        audit_relative_path.is_absolute()
        or ".." in audit_relative_path.parts
        or not text_values["audit_image_relative_path"]
    ):
        raise ValueError("audit_image_relative_path는 안전한 상대경로여야 합니다.")
    if not (sample_path.parent / audit_relative_path).is_file():
        raise ValueError(
            "Audit 이미지 누락: "
            f"{text_values['audit_image_relative_path']}"
        )

    return (
        metadata.session_id,
        metadata.split,
        metadata.captured_at_utc,
        text_values["audit_image_relative_path"],
        text_values["collection_version"],
    )


def write_session_manifest(
    output_directory: Path,
    metadata: CaptureMetadata,
    sample_kind: str,
    settings: dict[str, object],
) -> Path:
    """Session 설정을 JSON으로 고정하고 다른 설정으로의 실수 재개를 막는다."""
    validate_capture_metadata(metadata)
    if sample_kind not in {"target", "no_target"}:
        raise ValueError("sample_kind는 target 또는 no_target이어야 합니다.")
    output_directory.mkdir(parents=True, exist_ok=True)
    manifest_path = output_directory / f"session_{metadata.session_id}.json"
    identity = {
        "collection_version": COLLECTION_VERSION,
        "session_id": metadata.session_id,
        "capture_split": metadata.split,
        "sample_kind": sample_kind,
    }
    if manifest_path.exists():
        existing = json.loads(manifest_path.read_text(encoding="utf-8"))
        for name, expected in identity.items():
            if existing.get(name) != expected:
                raise RuntimeError(
                    f"기존 Session Manifest의 {name}이 다릅니다: "
                    f"저장={existing.get(name)}, 요청={expected}"
                )
        if existing.get("settings") != settings:
            raise RuntimeError(
                "같은 session_id를 다른 카메라/품질 설정으로 재개할 수 없습니다. "
                "새 session_id를 사용하세요."
            )
        return manifest_path

    payload = {
        **identity,
        "created_at_utc": utc_now_text(),
        "environment_note": metadata.environment_note,
        "settings": settings,
    }
    temporary_path = output_directory / f".{manifest_path.name}.tmp"
    temporary_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary_path.replace(manifest_path)
    return manifest_path


def apply_v03_camera_controls(config: CameraConfig) -> None:
    """Pilot에서 검증한 UVC 제어값을 매 촬영 실행 전에 재적용한다."""
    if not config.lock_v03_controls:
        return
    device_path = f"/dev/video{config.device}"
    commands = (
        (
            "v4l2-ctl",
            "--device",
            device_path,
            "--set-ctrl="
            f"power_line_frequency=2,white_balance_automatic=0,"
            f"white_balance_temperature={config.white_balance_temperature},"
            f"auto_exposure=1,"
            f"exposure_time_absolute={config.exposure_time_absolute},"
            f"gain=0,brightness={config.brightness},"
            f"saturation={config.saturation}",
        ),
        (
            "v4l2-ctl",
            "--device",
            device_path,
            "--set-ctrl=focus_automatic_continuous=0",
        ),
        (
            "v4l2-ctl",
            "--device",
            device_path,
            f"--set-ctrl=focus_absolute={config.focus_absolute}",
        ),
    )
    for command in commands:
        try:
            subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            detail = (
                error.stderr.strip()
                if isinstance(error, subprocess.CalledProcessError) and error.stderr
                else str(error)
            )
            raise RuntimeError(
                f"v03 카메라 제어값 적용 실패({device_path}): {detail}"
            ) from error


def camera_control_manifest(config: CameraConfig) -> dict[str, object]:
    """Session Manifest에 기록할 고정 카메라 제어값을 반환한다."""
    return {
        "locked": config.lock_v03_controls,
        "power_line_frequency_hz": 60 if config.lock_v03_controls else None,
        "brightness": config.brightness if config.lock_v03_controls else None,
        "saturation": config.saturation if config.lock_v03_controls else None,
        "gain": 0 if config.lock_v03_controls else None,
        "auto_exposure": False if config.lock_v03_controls else None,
        "exposure_time_absolute": (
            config.exposure_time_absolute if config.lock_v03_controls else None
        ),
        "automatic_white_balance": False if config.lock_v03_controls else None,
        "white_balance_temperature": (
            config.white_balance_temperature if config.lock_v03_controls else None
        ),
        "continuous_autofocus": False if config.lock_v03_controls else None,
        "focus_absolute": config.focus_absolute if config.lock_v03_controls else None,
    }


def open_camera(config: CameraConfig) -> cv2.VideoCapture:
    """선택한 V4L2 카메라를 열고 승인된 촬영 형식을 요청한다."""
    apply_v03_camera_controls(config)
    capture = cv2.VideoCapture(config.device, cv2.CAP_V4L2)
    capture.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, config.width)
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, config.height)
    capture.set(cv2.CAP_PROP_FPS, config.fps)

    if not capture.isOpened():
        capture.release()
        raise RuntimeError(f"/dev/video{config.device} 장치를 열 수 없습니다.")

    return capture


def camera_status(capture: cv2.VideoCapture, device: int) -> str:
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = capture.get(cv2.CAP_PROP_FPS)
    fourcc_value = int(capture.get(cv2.CAP_PROP_FOURCC))
    fourcc = "".join(chr((fourcc_value >> (8 * i)) & 0xFF) for i in range(4))
    return f"/dev/video{device}: {width}x{height}, {fps:.1f} fps, {fourcc}"


def frame_to_gray64(frame_bgr: np.ndarray) -> np.ndarray:
    """BGR 프레임 한 장을 64×64 uint8 흑백 영상으로 변환한다."""
    if frame_bgr.ndim != 3 or frame_bgr.shape[2] != 3:
        raise ValueError(
            f"BGR H×W×3 형식이 필요하지만 {frame_bgr.shape} 형식이 입력됐습니다."
        )

    gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY)
    return cv2.resize(
        gray,
        (TENSOR_WIDTH, TENSOR_HEIGHT),
        interpolation=cv2.INTER_AREA,
    )


def build_event_tensor(
    previous_gray64: np.ndarray,
    current_gray64: np.ndarray,
    noise_threshold: int = 8,
) -> np.ndarray:
    """고정 논리 형식인 64×64×2 signed INT8 입력 Tensor를 생성한다.

    채널 0에는 밝아진 변화량을, 채널 1에는 어두워진 변화량을 저장한다.
    공통 규격에 따라 두 채널 모두 signed INT8의 음수가 아닌 범위인
    0~127만 사용한다.
    """
    expected_shape = (TENSOR_HEIGHT, TENSOR_WIDTH)
    if previous_gray64.shape != expected_shape:
        raise ValueError(
            f"이전 프레임 형상은 {expected_shape}이어야 하지만 "
            f"{previous_gray64.shape}이 입력됐습니다."
        )
    if current_gray64.shape != expected_shape:
        raise ValueError(
            f"현재 프레임 형상은 {expected_shape}이어야 하지만 "
            f"{current_gray64.shape}이 입력됐습니다."
        )
    if not 0 <= noise_threshold <= 127:
        raise ValueError("noise_threshold는 0~127 범위여야 합니다.")

    # uint8끼리 바로 빼면 음수가 순환되므로 먼저 int16으로 확장한다.
    difference = current_gray64.astype(np.int16) - previous_gray64.astype(np.int16)

    # 밝아진 변화는 Positive, 어두워진 변화의 절댓값은 Negative에 저장한다.
    positive = np.where(difference > noise_threshold, difference, 0)
    negative = np.where(difference < -noise_threshold, -difference, 0)

    # Conv1 입력 규격에 맞춰 0~127로 포화시킨 뒤 signed INT8로 저장한다.
    positive = np.clip(positive, 0, SIGNED_INT8_MAX).astype(np.int8)
    negative = np.clip(negative, 0, SIGNED_INT8_MAX).astype(np.int8)

    # 이 HWC 배열은 B의 Python 내부 표현이며 하드웨어 메모리 순서 확정값이 아니다.
    tensor_hwc = np.stack((positive, negative), axis=-1)
    assert tensor_hwc.shape == (
        TENSOR_HEIGHT,
        TENSOR_WIDTH,
        TENSOR_CHANNELS,
    )
    assert tensor_hwc.dtype == np.int8
    return tensor_hwc


def scale_for_display(channel: np.ndarray) -> np.ndarray:
    """64×64 변화 맵을 확인하기 쉽도록 최근접 보간으로 확대한다."""
    display = channel.astype(np.uint8) * 2
    return cv2.resize(
        display,
        (TENSOR_WIDTH * 8, TENSOR_HEIGHT * 8),
        interpolation=cv2.INTER_NEAREST,
    )


def build_red_laser_mask(
    frame_bgr: np.ndarray,
    red_minimum: int = 220,
    red_dominance: int = 80,
    saturation_minimum: int = 160,
) -> np.ndarray:
    """[진단 전용] HSV와 BGR 조건으로 빨간 레이저 후보 Mask를 만든다."""
    if frame_bgr.ndim != 3 or frame_bgr.shape[2] != 3:
        raise ValueError(
            f"BGR H×W×3 형식이 필요하지만 {frame_bgr.shape} 형식이 입력됐습니다."
        )
    if not 0 <= red_minimum <= 255:
        raise ValueError("red_minimum은 0~255 범위여야 합니다.")
    if not 0 <= red_dominance <= 255:
        raise ValueError("red_dominance는 0~255 범위여야 합니다.")
    if not 0 <= saturation_minimum <= 255:
        raise ValueError("saturation_minimum은 0~255 범위여야 합니다.")

    blue, green, red = cv2.split(frame_bgr)
    other_maximum = cv2.max(blue, green)
    dominance = red.astype(np.int16) - other_maximum.astype(np.int16)

    # 피부와 흰색 반사광을 줄이기 위해 Red Hue와 높은 채도를 함께 요구한다.
    hsv = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2HSV)
    hue, saturation, value = cv2.split(hsv)
    red_hue = (hue <= 10) | (hue >= 170)

    red_candidate = (
        red_hue
        & (saturation >= saturation_minimum)
        & (value >= red_minimum)
        & (red >= red_minimum)
        & (dominance >= red_dominance)
    )
    mask = red_candidate.astype(np.uint8) * 255

    # 작은 레이저 점이 끊겨 보이지 않도록 3×3 범위에서 한 번만 연결한다.
    kernel = np.ones((3, 3), dtype=np.uint8)
    return cv2.dilate(mask, kernel, iterations=1)


def detect_red_laser(
    frame_bgr: np.ndarray,
    red_minimum: int = 220,
    red_dominance: int = 80,
    saturation_minimum: int = 160,
    minimum_area: float = 2.0,
    maximum_area: float = 300.0,
    minimum_circularity: float = 0.45,
    minimum_local_contrast: float = 15.0,
    border_margin: int = 3,
) -> tuple[LaserDetection | None, np.ndarray]:
    """[진단 전용] 색·크기·원형도·주변 대비를 통과한 레이저 좌표를 반환한다.

    이 함수가 반환하는 좌표는 640×480 등의 원본 카메라 좌표다.
    좌표 Mapping은 별도의 ``map_source_to_label`` 함수에서 수행한다.
    """
    if minimum_area < 0 or maximum_area <= minimum_area:
        raise ValueError("레이저 면적 범위가 올바르지 않습니다.")
    if not 0.0 <= minimum_circularity <= 1.0:
        raise ValueError("minimum_circularity는 0.0~1.0 범위여야 합니다.")
    if minimum_local_contrast < 0:
        raise ValueError("minimum_local_contrast는 0 이상이어야 합니다.")
    if border_margin < 0:
        raise ValueError("border_margin은 0 이상이어야 합니다.")

    mask = build_red_laser_mask(
        frame_bgr,
        red_minimum=red_minimum,
        red_dominance=red_dominance,
        saturation_minimum=saturation_minimum,
    )
    contours, _ = cv2.findContours(
        mask,
        cv2.RETR_EXTERNAL,
        cv2.CHAIN_APPROX_SIMPLE,
    )

    best_contour = None
    best_score = -1.0
    best_circularity = 0.0
    best_local_contrast = 0.0
    frame_height, frame_width = mask.shape
    blue_channel, green_channel, red_channel = cv2.split(frame_bgr)
    other_maximum = cv2.max(blue_channel, green_channel)
    red_excess = np.clip(
        red_channel.astype(np.int16) - other_maximum.astype(np.int16),
        0,
        255,
    ).astype(np.uint8)

    for contour in contours:
        area = float(cv2.contourArea(contour))
        if not minimum_area <= area <= maximum_area:
            continue

        x, y, width, height = cv2.boundingRect(contour)
        if (
            x <= border_margin
            or y <= border_margin
            or x + width >= frame_width - border_margin
            or y + height >= frame_height - border_margin
        ):
            continue

        perimeter = float(cv2.arcLength(contour, closed=True))
        if perimeter <= 0.0:
            continue
        circularity = float(4.0 * np.pi * area / (perimeter * perimeter))
        if circularity < minimum_circularity:
            continue

        contour_mask = np.zeros(mask.shape, dtype=np.uint8)
        cv2.drawContours(contour_mask, [contour], -1, 255, thickness=-1)
        mean_red = float(cv2.mean(red_channel, mask=contour_mask)[0])

        # 레이저는 주변보다 Red 우세도가 뚜렷해야 한다.
        expanded_mask = cv2.dilate(
            contour_mask,
            np.ones((11, 11), dtype=np.uint8),
            iterations=1,
        )
        surrounding_mask = cv2.subtract(expanded_mask, contour_mask)
        mean_excess = float(cv2.mean(red_excess, mask=contour_mask)[0])
        surrounding_excess = float(
            cv2.mean(red_excess, mask=surrounding_mask)[0]
        )
        local_contrast = mean_excess - surrounding_excess
        if local_contrast < minimum_local_contrast:
            continue

        # 밝기, 주변 대비, 원형도를 우선하고 면적 영향은 작게 제한한다.
        score = (
            mean_red
            + local_contrast * 2.0
            + circularity * 25.0
            + min(area, 100.0) * 0.01
        )
        if score > best_score:
            best_score = score
            best_contour = contour
            best_circularity = circularity
            best_local_contrast = local_contrast

    if best_contour is None:
        return None, mask

    moments = cv2.moments(best_contour)
    if moments["m00"] == 0:
        return None, mask

    center_x = int(round(moments["m10"] / moments["m00"]))
    center_y = int(round(moments["m01"] / moments["m00"]))
    (_, _), radius = cv2.minEnclosingCircle(best_contour)

    return (
        LaserDetection(
            center_x=center_x,
            center_y=center_y,
            area=float(cv2.contourArea(best_contour)),
            radius=float(radius),
            circularity=best_circularity,
            local_contrast=best_local_contrast,
        ),
        mask,
    )


def build_target_marker_mask(
    frame_bgr: np.ndarray,
    hue_low: int = 88,
    hue_high: int = 118,
    saturation_minimum: int = 120,
    value_minimum: int = 100,
) -> np.ndarray:
    """실제 추적 표적의 색상 Blob 후보 Mask를 만든다.

    OpenCV Hue 범위는 0~179다. ``hue_low > hue_high``이면 빨강처럼
    0/179 경계를 지나는 범위로 처리한다. 레이저와 달리 자기발광·고명도
    조건을 요구하지 않는다.
    """
    if frame_bgr.ndim != 3 or frame_bgr.shape[2] != 3:
        raise ValueError(
            f"BGR H×W×3 형식이 필요하지만 {frame_bgr.shape} 형식이 입력됐습니다."
        )
    if not 0 <= hue_low <= 179 or not 0 <= hue_high <= 179:
        raise ValueError("target Hue는 0~179 범위여야 합니다.")
    if not 0 <= saturation_minimum <= 255:
        raise ValueError("target saturation_minimum은 0~255 범위여야 합니다.")
    if not 0 <= value_minimum <= 255:
        raise ValueError("target value_minimum은 0~255 범위여야 합니다.")

    hue, saturation, value = cv2.split(cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2HSV))
    if hue_low <= hue_high:
        hue_match = (hue >= hue_low) & (hue <= hue_high)
    else:
        hue_match = (hue >= hue_low) | (hue <= hue_high)
    mask = (
        hue_match
        & (saturation >= saturation_minimum)
        & (value >= value_minimum)
    ).astype(np.uint8) * 255

    kernel = np.ones((3, 3), dtype=np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel, iterations=1)
    return cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=1)


def detect_target_marker(
    frame_bgr: np.ndarray,
    hue_low: int = 88,
    hue_high: int = 118,
    saturation_minimum: int = 120,
    value_minimum: int = 100,
    minimum_area: float = 400.0,
    maximum_area: float = 5_000.0,
) -> tuple[TargetDetection | None, np.ndarray]:
    """가장 큰 실제 표적 색상 Blob의 중심을 반환한다.

    면적 하한을 레이저 점보다 크게 고정해 작은 광점을 학습 Label로
    오인하지 않게 한다.
    """
    if minimum_area < 0 or maximum_area <= minimum_area:
        raise ValueError("표적 마커 면적 범위가 올바르지 않습니다.")
    mask = build_target_marker_mask(
        frame_bgr,
        hue_low=hue_low,
        hue_high=hue_high,
        saturation_minimum=saturation_minimum,
        value_minimum=value_minimum,
    )
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    candidates = [
        contour
        for contour in contours
        if minimum_area <= float(cv2.contourArea(contour)) <= maximum_area
    ]
    if not candidates:
        return None, mask

    best = max(candidates, key=cv2.contourArea)
    moments = cv2.moments(best)
    if moments["m00"] == 0:
        return None, mask
    return (
        TargetDetection(
            center_x=int(round(moments["m10"] / moments["m00"])),
            center_y=int(round(moments["m01"] / moments["m00"])),
            area=float(cv2.contourArea(best)),
        ),
        mask,
    )


def map_source_to_label(
    source_x: int,
    source_y: int,
    frame_width: int,
    frame_height: int,
) -> LabelMapping:
    """원본 좌표를 동결된 64×64, Heatmap, Tracking 좌표로 변환한다.

    Common Spec v1.5 규칙:

    - Crop, Padding, 좌우 반전을 적용하지 않는다.
    - X축은 왼쪽에서 오른쪽, Y축은 위에서 아래로 증가한다.
    - Source → 64×64 변환은 floor를 사용한다.
    - 64×64 → 8×8 변환은 floor(coord / 8)를 사용한다.
    - Tracking 좌표는 Heatmap Cell 중심인 cell * 8 + 4를 사용한다.
    """
    if frame_width <= 0 or frame_height <= 0:
        raise ValueError("원본 프레임의 가로와 세로 크기는 1 이상이어야 합니다.")
    if not 0 <= source_x < frame_width:
        raise ValueError(
            f"source_x는 0~{frame_width - 1} 범위여야 하지만 {source_x}입니다."
        )
    if not 0 <= source_y < frame_height:
        raise ValueError(
            f"source_y는 0~{frame_height - 1} 범위여야 하지만 {source_y}입니다."
        )

    # 양의 정수 나눗셈 //은 floor와 동일하다.
    tensor_x = min(TENSOR_WIDTH - 1, source_x * TENSOR_WIDTH // frame_width)
    tensor_y = min(TENSOR_HEIGHT - 1, source_y * TENSOR_HEIGHT // frame_height)

    heatmap_x = tensor_x // HEATMAP_CELL_SIZE
    heatmap_y = tensor_y // HEATMAP_CELL_SIZE

    target_x = heatmap_x * HEATMAP_CELL_SIZE + HEATMAP_CELL_SIZE // 2
    target_y = heatmap_y * HEATMAP_CELL_SIZE + HEATMAP_CELL_SIZE // 2

    return LabelMapping(
        source_x=source_x,
        source_y=source_y,
        tensor_x=tensor_x,
        tensor_y=tensor_y,
        heatmap_x=heatmap_x,
        heatmap_y=heatmap_y,
        target_x=target_x,
        target_y=target_y,
    )


def build_one_hot_heatmap(label: LabelMapping) -> np.ndarray:
    """동결된 [Y][X] 순서의 8×8 float32 One-hot Label을 생성한다."""
    if not 0 <= label.heatmap_x < HEATMAP_WIDTH:
        raise ValueError("heatmap_x는 0~7 범위여야 합니다.")
    if not 0 <= label.heatmap_y < HEATMAP_HEIGHT:
        raise ValueError("heatmap_y는 0~7 범위여야 합니다.")

    heatmap = np.zeros((HEATMAP_HEIGHT, HEATMAP_WIDTH), dtype=np.float32)
    heatmap[label.heatmap_y, label.heatmap_x] = 1.0
    return heatmap


def measure_event_label_alignment(
    input_tensor: np.ndarray,
    heatmap_x: int,
    heatmap_y: int,
) -> EventLabelAlignment:
    """정답 Cell 내부 Event와 8×8 Cell별 Energy 우세 여부를 측정한다.

    현재 위치에서 새로 나타난 표적 움직임은 Positive 채널에 나타나야 한다.
    따라서 자동수집에서는 정답 Cell에 Positive Event가 존재하고 그 Cell의
    Positive Energy가 전체 Cell 중 가장 큰 Frame만 선택할 수 있다.
    """
    if input_tensor.shape != (TENSOR_HEIGHT, TENSOR_WIDTH, TENSOR_CHANNELS):
        raise ValueError("input_tensor 형상은 (64, 64, 2)여야 합니다.")
    if not 0 <= heatmap_x < HEATMAP_WIDTH:
        raise ValueError("heatmap_x는 0~7 범위여야 합니다.")
    if not 0 <= heatmap_y < HEATMAP_HEIGHT:
        raise ValueError("heatmap_y는 0~7 범위여야 합니다.")

    event_int32 = input_tensor.astype(np.int32, copy=False)
    positive = event_int32[:, :, POSITIVE_CHANNEL]
    total = (
        event_int32[:, :, POSITIVE_CHANNEL]
        + event_int32[:, :, NEGATIVE_CHANNEL]
    )

    y0 = heatmap_y * HEATMAP_CELL_SIZE
    x0 = heatmap_x * HEATMAP_CELL_SIZE
    y1 = y0 + HEATMAP_CELL_SIZE
    x1 = x0 + HEATMAP_CELL_SIZE

    target_positive_pixel_count = int(
        np.count_nonzero(positive[y0:y1, x0:x1])
    )
    target_event_pixel_count = int(np.count_nonzero(total[y0:y1, x0:x1]))

    # reshape 순서: [Cell Y][Cell 내부 Y][Cell X][Cell 내부 X]
    positive_cell_energy = positive.reshape(
        HEATMAP_HEIGHT,
        HEATMAP_CELL_SIZE,
        HEATMAP_WIDTH,
        HEATMAP_CELL_SIZE,
    ).sum(axis=(1, 3))
    total_cell_energy = total.reshape(
        HEATMAP_HEIGHT,
        HEATMAP_CELL_SIZE,
        HEATMAP_WIDTH,
        HEATMAP_CELL_SIZE,
    ).sum(axis=(1, 3))

    positive_flat_index = int(np.argmax(positive_cell_energy.reshape(-1)))
    total_flat_index = int(np.argmax(total_cell_energy.reshape(-1)))
    positive_argmax_y, positive_argmax_x = divmod(
        positive_flat_index,
        HEATMAP_WIDTH,
    )
    total_argmax_y, total_argmax_x = divmod(
        total_flat_index,
        HEATMAP_WIDTH,
    )

    return EventLabelAlignment(
        target_positive_pixel_count=target_positive_pixel_count,
        target_event_pixel_count=target_event_pixel_count,
        positive_energy_argmax_x=positive_argmax_x,
        positive_energy_argmax_y=positive_argmax_y,
        total_energy_argmax_x=total_argmax_x,
        total_energy_argmax_y=total_argmax_y,
        positive_energy_argmax_match=(
            positive_argmax_x == heatmap_x and positive_argmax_y == heatmap_y
        ),
        total_energy_argmax_match=(
            total_argmax_x == heatmap_x and total_argmax_y == heatmap_y
        ),
    )


def find_next_sample_index(output_directory: Path) -> int:
    """기존 Sample을 덮어쓰지 않도록 다음 일련번호를 찾는다."""
    maximum_index = 0
    if not output_directory.exists():
        return 1

    for sample_path in output_directory.glob("sample_*.npz"):
        index_text = sample_path.stem.removeprefix("sample_")
        if index_text.isdigit():
            maximum_index = max(maximum_index, int(index_text))

    return maximum_index + 1


def save_dataset_sample(
    output_directory: Path,
    sample_index: int,
    input_tensor: np.ndarray,
    label_heatmap: np.ndarray,
    label: LabelMapping,
    frame_width: int,
    frame_height: int,
    noise_threshold: int,
    label_source: str = LABEL_SOURCE_TARGET_MARKER,
    capture_metadata: CaptureMetadata | None = None,
    audit_image: np.ndarray | None = None,
    target_marker_area: float | None = None,
) -> Path:
    """학습 입력, One-hot Label, 좌표 정보를 하나의 NPZ로 안전하게 저장한다.

    ``input_tensor``의 HWC 순서는 B의 Python 논리 표현이다. 이 파일은
    RTL용 ``.hex/.mem``이나 FPGA 물리 메모리 순서를 의미하지 않는다.
    """
    if sample_index < 1:
        raise ValueError("sample_index는 1 이상이어야 합니다.")
    if input_tensor.shape != (TENSOR_HEIGHT, TENSOR_WIDTH, TENSOR_CHANNELS):
        raise ValueError("input_tensor 형상은 (64, 64, 2)여야 합니다.")
    if input_tensor.dtype != np.int8:
        raise ValueError("input_tensor 자료형은 int8이어야 합니다.")
    if label_heatmap.shape != (HEATMAP_HEIGHT, HEATMAP_WIDTH):
        raise ValueError("label_heatmap 형상은 (8, 8)이어야 합니다.")
    if label_heatmap.dtype != np.float32:
        raise ValueError("label_heatmap 자료형은 float32여야 합니다.")
    if not np.isclose(float(label_heatmap.sum()), 1.0):
        raise ValueError("label_heatmap에는 정확히 하나의 정답 Cell이 필요합니다.")
    if float(label_heatmap[label.heatmap_y, label.heatmap_x]) != 1.0:
        raise ValueError("label_heatmap의 정답 Cell과 Label 좌표가 일치하지 않습니다.")
    if frame_width <= 0 or frame_height <= 0:
        raise ValueError("원본 프레임 크기는 1 이상이어야 합니다.")
    if label_source in REJECTED_LABEL_SOURCES:
        raise ValueError(
            f"레이저 기반 Label Sample은 사용할 수 없습니다: label_source={label_source}."
        )
    if label_source != LABEL_SOURCE_TARGET_MARKER:
        raise ValueError(
            f"label_source는 {LABEL_SOURCE_TARGET_MARKER}만 허용합니다: {label_source}"
        )
    if (capture_metadata is None) != (audit_image is None):
        raise ValueError(
            "v03 capture_metadata와 audit_image는 반드시 함께 제공해야 합니다."
        )
    if capture_metadata is not None:
        validate_capture_metadata(capture_metadata)
        if target_marker_area is None or target_marker_area <= 0:
            raise ValueError("v03 표적 Sample에는 target_marker_area가 필요합니다.")

    output_directory.mkdir(parents=True, exist_ok=True)
    output_path = output_directory / f"sample_{sample_index:06d}.npz"
    if output_path.exists():
        raise FileExistsError(f"이미 존재하는 Sample입니다: {output_path}")

    payload: dict[str, np.ndarray] = {
        "input_tensor": input_tensor,
        "label_heatmap": label_heatmap,
        "source_xy": np.array([label.source_x, label.source_y], dtype=np.int16),
        "tensor_xy": np.array([label.tensor_x, label.tensor_y], dtype=np.int16),
        "heatmap_xy": np.array(
            [label.heatmap_x, label.heatmap_y],
            dtype=np.int16,
        ),
        "target_xy": np.array([label.target_x, label.target_y], dtype=np.int16),
        "frame_size_wh": np.array([frame_width, frame_height], dtype=np.int16),
        "noise_threshold": np.array(noise_threshold, dtype=np.int16),
        "active_pixel_count": np.array(
            np.count_nonzero(input_tensor),
            dtype=np.int32,
        ),
        "sample_index": np.array(sample_index, dtype=np.int32),
        "spec_version": np.array(BASE_SPEC_VERSION),
        "tensor_layout": np.array("HWC_LOGICAL_ONLY"),
        "channel_order": np.array("POSITIVE_NEGATIVE"),
        "heatmap_layout": np.array("YX"),
        "label_source": np.array(label_source),
    }
    audit_relative_path = ""
    if capture_metadata is not None and audit_image is not None:
        captured_at_utc = capture_metadata.captured_at_utc or utc_now_text()
        audit_relative_path = save_audit_image(
            output_directory,
            sample_index,
            audit_image,
        )
        payload.update(
            {
                "collection_version": np.array(COLLECTION_VERSION),
                "capture_session_id": np.array(capture_metadata.session_id),
                "capture_split": np.array(capture_metadata.split),
                "captured_at_utc": np.array(captured_at_utc),
                "camera_device": np.array(capture_metadata.camera_device, dtype=np.int16),
                "camera_fps": np.array(capture_metadata.camera_fps, dtype=np.float32),
                "frame_sequence_index": np.array(
                    capture_metadata.frame_sequence_index,
                    dtype=np.int32,
                ),
                "environment_note": np.array(capture_metadata.environment_note),
                "audit_image_relative_path": np.array(audit_relative_path),
                "target_marker_area": np.array(target_marker_area, dtype=np.float32),
            }
        )

    temporary_path = output_directory / f".{output_path.name}.tmp"
    try:
        with temporary_path.open("wb") as temporary_file:
            np.savez_compressed(temporary_file, **payload)
        temporary_path.replace(output_path)
    except Exception:
        temporary_path.unlink(missing_ok=True)
        if audit_relative_path:
            (output_directory / audit_relative_path).unlink(missing_ok=True)
        raise
    return output_path


def validate_dataset_sample(sample_path: Path) -> DatasetSampleInfo:
    """NPZ 한 개가 Common Spec v1.5 논리 Dataset 규격과 맞는지 검사한다.

    이 검사는 B의 Python 내부 논리 형식만 확인한다. 아직 TBD인 FPGA 물리
    메모리 순서나 Event Tensor 전송 순서를 확정하지 않는다.
    """
    required_keys = {
        "input_tensor",
        "label_heatmap",
        "source_xy",
        "tensor_xy",
        "heatmap_xy",
        "target_xy",
        "frame_size_wh",
        "noise_threshold",
        "active_pixel_count",
        "sample_index",
        "spec_version",
        "tensor_layout",
        "channel_order",
        "heatmap_layout",
        "label_source",
    }

    with np.load(sample_path, allow_pickle=False) as sample:
        missing_keys = sorted(required_keys - set(sample.files))
        if missing_keys:
            raise ValueError(f"필수 항목 누락: {', '.join(missing_keys)}")

        input_tensor = sample["input_tensor"]
        label_heatmap = sample["label_heatmap"]
        source_xy = sample["source_xy"]
        tensor_xy = sample["tensor_xy"]
        heatmap_xy = sample["heatmap_xy"]
        target_xy = sample["target_xy"]
        frame_size_wh = sample["frame_size_wh"]

        if input_tensor.shape != (TENSOR_HEIGHT, TENSOR_WIDTH, TENSOR_CHANNELS):
            raise ValueError(
                f"input_tensor 형상 오류: {input_tensor.shape}, 필요=(64, 64, 2)"
            )
        if input_tensor.dtype != np.int8:
            raise ValueError(
                f"input_tensor 자료형 오류: {input_tensor.dtype}, 필요=int8"
            )
        if int(input_tensor.min()) < 0 or int(input_tensor.max()) > SIGNED_INT8_MAX:
            raise ValueError("input_tensor 값은 signed INT8의 0~127 범위여야 합니다.")

        if label_heatmap.shape != (HEATMAP_HEIGHT, HEATMAP_WIDTH):
            raise ValueError(
                f"label_heatmap 형상 오류: {label_heatmap.shape}, 필요=(8, 8)"
            )
        if label_heatmap.dtype != np.float32:
            raise ValueError(
                f"label_heatmap 자료형 오류: {label_heatmap.dtype}, 필요=float32"
            )

        coordinate_arrays = {
            "source_xy": source_xy,
            "tensor_xy": tensor_xy,
            "heatmap_xy": heatmap_xy,
            "target_xy": target_xy,
            "frame_size_wh": frame_size_wh,
        }
        for name, coordinate_array in coordinate_arrays.items():
            if coordinate_array.shape != (2,) or coordinate_array.dtype != np.int16:
                raise ValueError(
                    f"{name} 형식 오류: shape={coordinate_array.shape}, "
                    f"dtype={coordinate_array.dtype}, 필요=(2,) int16"
                )

        frame_width, frame_height = (int(value) for value in frame_size_wh)
        source_x, source_y = (int(value) for value in source_xy)
        expected_label = map_source_to_label(
            source_x=source_x,
            source_y=source_y,
            frame_width=frame_width,
            frame_height=frame_height,
        )
        expected_tensor_xy = [expected_label.tensor_x, expected_label.tensor_y]
        expected_heatmap_xy = [expected_label.heatmap_x, expected_label.heatmap_y]
        expected_target_xy = [expected_label.target_x, expected_label.target_y]

        if tensor_xy.tolist() != expected_tensor_xy:
            raise ValueError(
                f"tensor_xy 불일치: 저장={tensor_xy.tolist()}, "
                f"계산={expected_tensor_xy}"
            )
        if heatmap_xy.tolist() != expected_heatmap_xy:
            raise ValueError(
                f"heatmap_xy 불일치: 저장={heatmap_xy.tolist()}, "
                f"계산={expected_heatmap_xy}"
            )
        if target_xy.tolist() != expected_target_xy:
            raise ValueError(
                f"target_xy 불일치: 저장={target_xy.tolist()}, "
                f"계산={expected_target_xy}"
            )

        expected_heatmap = build_one_hot_heatmap(expected_label)
        if not np.array_equal(label_heatmap, expected_heatmap):
            raise ValueError(
                "label_heatmap이 저장 좌표와 일치하는 [Y][X] One-hot이 아닙니다."
            )

        scalar_dtypes = {
            "noise_threshold": np.dtype(np.int16),
            "active_pixel_count": np.dtype(np.int32),
            "sample_index": np.dtype(np.int32),
        }
        for name, expected_dtype in scalar_dtypes.items():
            value = sample[name]
            if value.shape != () or value.dtype != expected_dtype:
                raise ValueError(
                    f"{name} 형식 오류: shape={value.shape}, dtype={value.dtype}"
                )

        noise_threshold = int(sample["noise_threshold"])
        active_pixel_count = int(sample["active_pixel_count"])
        sample_index = int(sample["sample_index"])
        if not 0 <= noise_threshold <= SIGNED_INT8_MAX:
            raise ValueError("noise_threshold는 0~127 범위여야 합니다.")
        if active_pixel_count <= 0:
            raise ValueError("Event Tensor가 비어 있는 Sample입니다.")
        measured_active_pixel_count = int(np.count_nonzero(input_tensor))
        if active_pixel_count != measured_active_pixel_count:
            raise ValueError(
                f"활성 픽셀 수 불일치: 저장={active_pixel_count}, "
                f"계산={measured_active_pixel_count}"
            )
        if sample_index < 1:
            raise ValueError("sample_index는 1 이상이어야 합니다.")

        filename_index = sample_path.stem.removeprefix("sample_")
        if not filename_index.isdigit() or int(filename_index) != sample_index:
            raise ValueError(
                f"파일명 일련번호와 sample_index가 다릅니다: {sample_index}"
            )

        text_metadata = {
            "tensor_layout": "HWC_LOGICAL_ONLY",
            "channel_order": "POSITIVE_NEGATIVE",
            "heatmap_layout": "YX",
            "label_source": LABEL_SOURCE_TARGET_MARKER,
        }
        for name, expected_text in text_metadata.items():
            value = sample[name]
            actual_text = str(value.item()) if value.shape == () else str(value)
            if name == "label_source" and actual_text in REJECTED_LABEL_SOURCES:
                raise ValueError(
                    "레이저 기반 Label Sample은 사용할 수 없습니다: "
                    f"label_source={actual_text}."
                )
            if value.shape != () or actual_text != expected_text:
                raise ValueError(
                    f"{name} 불일치: 저장={value}, 필요={expected_text}"
                )

        spec_version = sample["spec_version"]
        if spec_version.shape != ():
            raise ValueError(
                f"spec_version 형식 오류: shape={spec_version.shape}, 필요=()"
            )
        saved_spec_version = str(spec_version.item())
        supported_spec_versions = {BASE_SPEC_VERSION, *LEGACY_SPEC_VERSIONS}
        if saved_spec_version not in supported_spec_versions:
            supported_text = ", ".join(sorted(supported_spec_versions))
            raise ValueError(
                f"spec_version 불일치: 저장={saved_spec_version}, "
                f"지원={supported_text}"
            )

        alignment = measure_event_label_alignment(
            input_tensor,
            heatmap_x=expected_label.heatmap_x,
            heatmap_y=expected_label.heatmap_y,
        )
        (
            capture_session_id,
            capture_split,
            captured_at_utc,
            audit_image_relative_path,
            collection_version,
        ) = read_capture_metadata(sample, sample_path)
        if collection_version:
            if "target_marker_area" not in sample.files:
                raise ValueError("v03 표적 Sample에 target_marker_area가 없습니다.")
            marker_area = sample["target_marker_area"]
            if marker_area.shape != () or marker_area.dtype != np.float32:
                raise ValueError("target_marker_area는 float32 Scalar여야 합니다.")
            if float(marker_area) <= 0:
                raise ValueError("target_marker_area는 0보다 커야 합니다.")

    return DatasetSampleInfo(
        path=sample_path,
        sample_index=sample_index,
        heatmap_x=expected_label.heatmap_x,
        heatmap_y=expected_label.heatmap_y,
        target_x=expected_label.target_x,
        target_y=expected_label.target_y,
        active_pixel_count=active_pixel_count,
        target_positive_pixel_count=alignment.target_positive_pixel_count,
        target_event_pixel_count=alignment.target_event_pixel_count,
        positive_energy_argmax_match=alignment.positive_energy_argmax_match,
        total_energy_argmax_match=alignment.total_energy_argmax_match,
        capture_session_id=capture_session_id,
        capture_split=capture_split,
        captured_at_utc=captured_at_utc,
        audit_image_relative_path=audit_image_relative_path,
        collection_version=collection_version,
    )


def inspect_dataset_directory(
    output_directory: Path,
) -> tuple[list[Path], list[DatasetSampleInfo], list[tuple[Path, str]], np.ndarray]:
    """Dataset 폴더를 검사하고 파일·정상 Sample·오류·분포를 반환한다."""
    sample_paths = sorted(output_directory.glob("sample_*.npz"))
    distribution = np.zeros((HEATMAP_HEIGHT, HEATMAP_WIDTH), dtype=np.int32)
    valid_samples: list[DatasetSampleInfo] = []
    errors: list[tuple[Path, str]] = []

    for sample_path in sample_paths:
        try:
            sample_info = validate_dataset_sample(sample_path)
        except (OSError, ValueError, KeyError) as error:
            errors.append((sample_path, str(error)))
            continue

        valid_samples.append(sample_info)
        distribution[sample_info.heatmap_y, sample_info.heatmap_x] += 1

    return sample_paths, valid_samples, errors, distribution


def save_no_target_sample(
    output_directory: Path,
    sample_index: int,
    input_tensor: np.ndarray,
    frame_width: int,
    frame_height: int,
    noise_threshold: int,
    capture_metadata: CaptureMetadata | None = None,
    audit_image: np.ndarray | None = None,
) -> Path:
    """실제 무표적 Event Tensor를 SCORE_TH 보정용 NPZ로 저장한다."""
    if sample_index < 1:
        raise ValueError("sample_index는 1 이상이어야 합니다.")
    if input_tensor.shape != (TENSOR_HEIGHT, TENSOR_WIDTH, TENSOR_CHANNELS):
        raise ValueError("input_tensor 형상은 (64, 64, 2)여야 합니다.")
    if input_tensor.dtype != np.int8:
        raise ValueError("input_tensor 자료형은 int8이어야 합니다.")
    if int(input_tensor.min()) < 0 or int(input_tensor.max()) > SIGNED_INT8_MAX:
        raise ValueError("input_tensor 값은 0~127 범위여야 합니다.")
    if frame_width <= 0 or frame_height <= 0:
        raise ValueError("원본 프레임 크기는 1 이상이어야 합니다.")
    if not 0 <= noise_threshold <= SIGNED_INT8_MAX:
        raise ValueError("noise_threshold는 0~127 범위여야 합니다.")
    if (capture_metadata is None) != (audit_image is None):
        raise ValueError(
            "v03 capture_metadata와 audit_image는 반드시 함께 제공해야 합니다."
        )
    if capture_metadata is not None:
        validate_capture_metadata(capture_metadata)

    output_directory.mkdir(parents=True, exist_ok=True)
    output_path = output_directory / f"sample_{sample_index:06d}.npz"
    if output_path.exists():
        raise FileExistsError(f"이미 존재하는 Sample입니다: {output_path}")
    payload: dict[str, np.ndarray] = {
        "input_tensor": input_tensor,
        "frame_size_wh": np.array([frame_width, frame_height], dtype=np.int16),
        "noise_threshold": np.array(noise_threshold, dtype=np.int16),
        "active_pixel_count": np.array(
            np.count_nonzero(input_tensor),
            dtype=np.int32,
        ),
        "sample_index": np.array(sample_index, dtype=np.int32),
        "spec_version": np.array(BASE_SPEC_VERSION),
        "tensor_layout": np.array("HWC_LOGICAL_ONLY"),
        "channel_order": np.array("POSITIVE_NEGATIVE"),
        "sample_purpose": np.array(NO_TARGET_SAMPLE_PURPOSE),
    }
    audit_relative_path = ""
    if capture_metadata is not None and audit_image is not None:
        captured_at_utc = capture_metadata.captured_at_utc or utc_now_text()
        audit_relative_path = save_audit_image(
            output_directory,
            sample_index,
            audit_image,
        )
        payload.update(
            {
                "collection_version": np.array(COLLECTION_VERSION),
                "capture_session_id": np.array(capture_metadata.session_id),
                "capture_split": np.array(capture_metadata.split),
                "captured_at_utc": np.array(captured_at_utc),
                "camera_device": np.array(capture_metadata.camera_device, dtype=np.int16),
                "camera_fps": np.array(capture_metadata.camera_fps, dtype=np.float32),
                "frame_sequence_index": np.array(
                    capture_metadata.frame_sequence_index,
                    dtype=np.int32,
                ),
                "environment_note": np.array(capture_metadata.environment_note),
                "audit_image_relative_path": np.array(audit_relative_path),
            }
        )
    temporary_path = output_directory / f".{output_path.name}.tmp"
    try:
        with temporary_path.open("wb") as temporary_file:
            np.savez_compressed(temporary_file, **payload)
        temporary_path.replace(output_path)
    except Exception:
        temporary_path.unlink(missing_ok=True)
        if audit_relative_path:
            (output_directory / audit_relative_path).unlink(missing_ok=True)
        raise
    return output_path


def validate_no_target_sample(sample_path: Path) -> NoTargetSampleInfo:
    """SCORE_TH 보정용 무표적 NPZ 형식과 provenance를 검증한다."""
    required_keys = {
        "input_tensor",
        "frame_size_wh",
        "noise_threshold",
        "active_pixel_count",
        "sample_index",
        "spec_version",
        "tensor_layout",
        "channel_order",
        "sample_purpose",
    }
    with np.load(sample_path, allow_pickle=False) as sample:
        missing = sorted(required_keys - set(sample.files))
        if missing:
            raise ValueError(f"필수 항목 누락: {', '.join(missing)}")
        input_tensor = sample["input_tensor"]
        if input_tensor.shape != (TENSOR_HEIGHT, TENSOR_WIDTH, TENSOR_CHANNELS):
            raise ValueError(f"input_tensor 형상 오류: {input_tensor.shape}")
        if input_tensor.dtype != np.int8:
            raise ValueError(f"input_tensor 자료형 오류: {input_tensor.dtype}")
        if int(input_tensor.min()) < 0 or int(input_tensor.max()) > SIGNED_INT8_MAX:
            raise ValueError("input_tensor 값은 0~127 범위여야 합니다.")

        frame_size = sample["frame_size_wh"]
        if frame_size.shape != (2,) or frame_size.dtype != np.int16:
            raise ValueError("frame_size_wh는 (2,) int16이어야 합니다.")
        if int(frame_size[0]) <= 0 or int(frame_size[1]) <= 0:
            raise ValueError("원본 프레임 크기는 1 이상이어야 합니다.")

        scalar_dtypes = {
            "noise_threshold": np.dtype(np.int16),
            "active_pixel_count": np.dtype(np.int32),
            "sample_index": np.dtype(np.int32),
        }
        for name, expected_dtype in scalar_dtypes.items():
            value = sample[name]
            if value.shape != () or value.dtype != expected_dtype:
                raise ValueError(f"{name} 형식 오류: shape={value.shape}, dtype={value.dtype}")

        active_pixel_count = int(sample["active_pixel_count"])
        if active_pixel_count != int(np.count_nonzero(input_tensor)):
            raise ValueError("active_pixel_count가 input_tensor 실측과 다릅니다.")
        sample_index = int(sample["sample_index"])
        filename_index = sample_path.stem.removeprefix("sample_")
        if sample_index < 1 or not filename_index.isdigit() or int(filename_index) != sample_index:
            raise ValueError("파일명 일련번호와 sample_index가 다릅니다.")

        expected_text = {
            "spec_version": BASE_SPEC_VERSION,
            "tensor_layout": "HWC_LOGICAL_ONLY",
            "channel_order": "POSITIVE_NEGATIVE",
            "sample_purpose": NO_TARGET_SAMPLE_PURPOSE,
        }
        for name, expected in expected_text.items():
            value = sample[name]
            if value.shape != () or str(value.item()) != expected:
                raise ValueError(f"{name} 불일치: 저장={value}, 필요={expected}")

        (
            capture_session_id,
            capture_split,
            captured_at_utc,
            audit_image_relative_path,
            collection_version,
        ) = read_capture_metadata(sample, sample_path)

    return NoTargetSampleInfo(
        path=sample_path,
        sample_index=sample_index,
        active_pixel_count=active_pixel_count,
        capture_session_id=capture_session_id,
        capture_split=capture_split,
        captured_at_utc=captured_at_utc,
        audit_image_relative_path=audit_image_relative_path,
        collection_version=collection_version,
    )


def inspect_no_target_directory(
    output_directory: Path,
) -> tuple[list[Path], list[NoTargetSampleInfo], list[tuple[Path, str]]]:
    """무표적 폴더의 전체 파일·정상 Sample·오류를 반환한다."""
    sample_paths = sorted(output_directory.glob("sample_*.npz"))
    valid_samples: list[NoTargetSampleInfo] = []
    errors: list[tuple[Path, str]] = []
    for sample_path in sample_paths:
        try:
            valid_samples.append(validate_no_target_sample(sample_path))
        except (OSError, ValueError, KeyError) as error:
            errors.append((sample_path, str(error)))
    return sample_paths, valid_samples, errors


def build_quality_distribution(
    valid_samples: list[DatasetSampleInfo],
    minimum_active_pixels: int,
    maximum_active_pixels: int,
    minimum_target_positive_pixels: int = 0,
    require_target_positive_argmax: bool = False,
    minimum_target_event_pixels: int = 0,
    minimum_target_event_ratio: float = 0.0,
) -> tuple[list[DatasetSampleInfo], list[DatasetSampleInfo], np.ndarray]:
    """전체 활성량과 Target 정렬 품질을 적용한 8×8 분포를 생성한다."""
    if minimum_active_pixels < 1:
        raise ValueError("minimum_active_pixels는 1 이상이어야 합니다.")
    if maximum_active_pixels < minimum_active_pixels:
        raise ValueError(
            "maximum_active_pixels는 minimum_active_pixels 이상이어야 합니다."
        )
    if minimum_target_positive_pixels < 0:
        raise ValueError("minimum_target_positive_pixels는 0 이상이어야 합니다.")
    if minimum_target_event_pixels < 0:
        raise ValueError("minimum_target_event_pixels는 0 이상이어야 합니다.")
    if not 0.0 <= minimum_target_event_ratio <= 1.0:
        raise ValueError("minimum_target_event_ratio는 0~1이어야 합니다.")

    accepted_samples: list[DatasetSampleInfo] = []
    rejected_samples: list[DatasetSampleInfo] = []
    distribution = np.zeros((HEATMAP_HEIGHT, HEATMAP_WIDTH), dtype=np.int32)

    for sample_info in valid_samples:
        if (
            minimum_active_pixels
            <= sample_info.active_pixel_count
            <= maximum_active_pixels
            and sample_info.target_positive_pixel_count
            >= minimum_target_positive_pixels
            and sample_info.target_event_pixel_count
            >= minimum_target_event_pixels
            and sample_info.target_event_pixel_count
            / max(1, sample_info.active_pixel_count)
            >= minimum_target_event_ratio
            and (
                not require_target_positive_argmax
                or sample_info.positive_energy_argmax_match
            )
        ):
            accepted_samples.append(sample_info)
            distribution[sample_info.heatmap_y, sample_info.heatmap_x] += 1
        else:
            rejected_samples.append(sample_info)

    return accepted_samples, rejected_samples, distribution


def run_dataset_check(
    output_directory: Path,
    minimum_active_pixels: int,
    maximum_active_pixels: int,
    samples_per_cell: int,
    minimum_target_positive_pixels: int,
    require_target_positive_argmax: bool,
    capture_session_id: str | None = None,
    capture_split: str | None = None,
    require_session_metadata: bool = False,
    minimum_target_event_pixels: int = 0,
    minimum_target_event_ratio: float = 0.0,
) -> None:
    """NPZ 전체 형식과 품질 적용 후 8×8 균형 분포를 검사한다."""
    if samples_per_cell < 1:
        raise ValueError("samples_per_cell은 1 이상이어야 합니다.")

    sample_paths, valid_samples, errors, _ = inspect_dataset_directory(
        output_directory
    )
    if not sample_paths:
        raise RuntimeError(f"검사할 Sample이 없습니다: {output_directory}")

    if require_session_metadata:
        legacy_samples = [
            sample
            for sample in valid_samples
            if sample.capture_split == LEGACY_CAPTURE_SPLIT
        ]
        if legacy_samples:
            examples = ", ".join(sample.path.name for sample in legacy_samples[:5])
            raise RuntimeError(
                f"Session 메타데이터가 없는 legacy Sample {len(legacy_samples)}개: "
                f"{examples}"
            )
    if capture_session_id is not None:
        valid_samples = [
            sample
            for sample in valid_samples
            if sample.capture_session_id == capture_session_id
        ]
    if capture_split is not None:
        valid_samples = [
            sample
            for sample in valid_samples
            if sample.capture_split == capture_split
        ]
    if not valid_samples:
        raise RuntimeError("지정한 Session/Split 조건에 맞는 정상 Sample이 없습니다.")

    accepted_samples, rejected_samples, distribution = build_quality_distribution(
        valid_samples,
        minimum_active_pixels=minimum_active_pixels,
        maximum_active_pixels=maximum_active_pixels,
        minimum_target_positive_pixels=minimum_target_positive_pixels,
        require_target_positive_argmax=require_target_positive_argmax,
        minimum_target_event_pixels=minimum_target_event_pixels,
        minimum_target_event_ratio=minimum_target_event_ratio,
    )

    target_positive_present_count = sum(
        sample_info.target_positive_pixel_count > 0
        for sample_info in valid_samples
    )
    positive_argmax_match_count = sum(
        sample_info.positive_energy_argmax_match
        for sample_info in valid_samples
    )

    print(f"Dataset 검사 경로: {output_directory}")
    if capture_session_id is not None or capture_split is not None:
        print(
            f"검사 필터: Session={capture_session_id or '전체'}, "
            f"Split={capture_split or '전체'}"
        )
    print(
        f"전체={len(sample_paths)} 정상={len(valid_samples)} 오류={len(errors)}"
    )
    print(
        f"품질 사용={len(accepted_samples)} 품질 제외={len(rejected_samples)} "
        f"활성 픽셀 범위={minimum_active_pixels}~{maximum_active_pixels}"
    )
    if valid_samples:
        print(
            "Target Cell Positive Event 존재="
            f"{target_positive_present_count}/{len(valid_samples)} "
            f"({target_positive_present_count / len(valid_samples) * 100:.2f}%)"
        )
        print(
            "Target Cell Positive Energy Argmax 일치="
            f"{positive_argmax_match_count}/{len(valid_samples)} "
            f"({positive_argmax_match_count / len(valid_samples) * 100:.2f}%)"
        )
    print(
        "정렬 품질 조건: "
        f"Target Positive Pixel>={minimum_target_positive_pixels}, "
        f"Target Event Pixel>={minimum_target_event_pixels}, "
        f"Target/Active>={minimum_target_event_ratio:.3f}, "
        f"Positive Argmax={'필수' if require_target_positive_argmax else '미적용'}"
    )
    print("품질 적용 8×8 Cell별 Sample 수 [Y][X]")
    print("       x=0 x=1 x=2 x=3 x=4 x=5 x=6 x=7")
    for heatmap_y, row in enumerate(distribution):
        counts = " ".join(f"{int(count):3d}" for count in row)
        print(f"y={heatmap_y}: {counts}")

    completed_cell_count = int(np.count_nonzero(distribution >= samples_per_cell))
    partial_cell_count = int(
        np.count_nonzero((distribution > 0) & (distribution < samples_per_cell))
    )
    empty_cell_count = int(np.count_nonzero(distribution == 0))
    print(
        f"완료 Cell={completed_cell_count}/64, "
        f"부분 Cell={partial_cell_count}/64, "
        f"미수집 Cell={empty_cell_count}/64"
    )

    if errors:
        print("검증 오류 목록")
        for sample_path, message in errors:
            print(f"- {sample_path.name}: {message}")
        raise SystemExit(1)

    print("Dataset 파일 형식 검증 통과")
    if completed_cell_count < HEATMAP_HEIGHT * HEATMAP_WIDTH:
        print(
            f"분포 상태: 추가 수집 필요 — 목표는 각 Cell {samples_per_cell}개"
        )
    else:
        print(
            f"분포 상태: 8×8 전체 Cell × {samples_per_cell}개 품질 수집 완료"
        )


def run_no_target_check(
    output_directory: Path,
    minimum_active_pixels: int,
    maximum_active_pixels: int,
    capture_session_id: str | None = None,
    capture_split: str | None = None,
    require_session_metadata: bool = False,
) -> None:
    """v03 무표적 Sample의 형식·Session·활성량 범위를 검사한다."""
    sample_paths, valid_samples, errors = inspect_no_target_directory(output_directory)
    if not sample_paths:
        raise RuntimeError(f"검사할 무표적 Sample이 없습니다: {output_directory}")
    if require_session_metadata:
        legacy_samples = [
            sample
            for sample in valid_samples
            if sample.capture_split == LEGACY_CAPTURE_SPLIT
        ]
        if legacy_samples:
            raise RuntimeError(
                "Session 메타데이터가 없는 무표적 legacy Sample: "
                f"{len(legacy_samples)}개"
            )
    if capture_session_id is not None:
        valid_samples = [
            sample
            for sample in valid_samples
            if sample.capture_session_id == capture_session_id
        ]
    if capture_split is not None:
        valid_samples = [
            sample
            for sample in valid_samples
            if sample.capture_split == capture_split
        ]
    if not valid_samples:
        raise RuntimeError("지정한 Session/Split 조건에 맞는 무표적 Sample이 없습니다.")

    outside_quality = [
        sample
        for sample in valid_samples
        if not minimum_active_pixels
        <= sample.active_pixel_count
        <= maximum_active_pixels
    ]
    active_counts = np.asarray(
        [sample.active_pixel_count for sample in valid_samples],
        dtype=np.int32,
    )
    print(f"무표적 Dataset 검사 경로: {output_directory}")
    print(
        f"검사 필터: Session={capture_session_id or '전체'}, "
        f"Split={capture_split or '전체'}"
    )
    print(
        f"전체 파일={len(sample_paths)} 필터 정상={len(valid_samples)} "
        f"형식 오류={len(errors)} 품질 범위 밖={len(outside_quality)}"
    )
    print(
        "활성 픽셀 min/median/max="
        f"{int(active_counts.min())}/"
        f"{float(np.median(active_counts)):.1f}/"
        f"{int(active_counts.max())}"
    )
    if errors:
        for sample_path, message in errors:
            print(f"- {sample_path.name}: {message}")
        raise SystemExit(1)
    if outside_quality:
        examples = ", ".join(sample.path.name for sample in outside_quality[:5])
        raise SystemExit(
            f"활성 픽셀 품질 범위를 벗어난 무표적 Sample: "
            f"{len(outside_quality)}개 ({examples})"
        )
    print("무표적 Dataset 형식·Session·Audit·품질 검증 통과")


def run_camera_preview(config: CameraConfig, snapshot_output: Path) -> None:
    """원본 웹캠 영상만 표시하여 카메라 연결 상태를 확인한다."""
    capture = open_camera(config)
    print(f"카메라 확인 통과: {camera_status(capture, config.device)}")
    print(
        f"현재 Frame 저장: s ({snapshot_output}), 종료: q"
    )

    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                raise RuntimeError("카메라 프레임을 읽지 못했습니다.")

            cv2.imshow("B Camera Preview", frame)
            key = cv2.waitKey(1) & 0xFF
            if key == ord("s"):
                save_jpeg_snapshot(snapshot_output, frame)
                print(f"Camera Snapshot 저장 완료: {snapshot_output}")
            if key == ord("q"):
                break
    finally:
        capture.release()
        cv2.destroyAllWindows()


def run_event_preview(config: CameraConfig, noise_threshold: int) -> None:
    """실시간 프레임 차분과 두 Event 채널을 화면에 표시한다."""
    capture = open_camera(config)
    print(f"카메라 확인 통과: {camera_status(capture, config.device)}")
    print(
        "Tensor 규격: shape=(64, 64, 2), dtype=int8, "
        "채널0=Positive, 채널1=Negative, 범위=0~127"
    )
    print("종료하려면 영상 창에서 q를 누르세요.")

    ok, first_frame = capture.read()
    if not ok:
        capture.release()
        raise RuntimeError("첫 번째 카메라 프레임을 읽지 못했습니다.")

    previous_gray64 = frame_to_gray64(first_frame)
    frame_count = 0

    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                raise RuntimeError("카메라 프레임을 읽지 못했습니다.")

            current_gray64 = frame_to_gray64(frame)
            tensor = build_event_tensor(
                previous_gray64,
                current_gray64,
                noise_threshold=noise_threshold,
            )
            previous_gray64 = current_gray64
            frame_count += 1

            positive_view = scale_for_display(tensor[:, :, POSITIVE_CHANNEL])
            negative_view = scale_for_display(tensor[:, :, NEGATIVE_CHANNEL])

            cv2.imshow("B Camera Preview", frame)
            cv2.imshow("Positive Change - Channel 0", positive_view)
            cv2.imshow("Negative Change - Channel 1", negative_view)

            if frame_count % 30 == 0:
                print(
                    f"프레임={frame_count} 형상={tensor.shape} "
                    f"자료형={tensor.dtype} 최솟값={tensor.min()} 최댓값={tensor.max()}"
                )

            if cv2.waitKey(1) & 0xFF == ord("q"):
                break
    finally:
        capture.release()
        cv2.destroyAllWindows()


def run_laser_preview(
    config: CameraConfig,
    red_minimum: int,
    red_dominance: int,
    saturation_minimum: int,
    minimum_area: float,
    maximum_area: float,
    minimum_circularity: float,
    minimum_local_contrast: float,
    border_margin: int,
) -> None:
    """[진단 전용] 레이저 좌표 Mapping을 실시간으로 표시한다."""
    capture = open_camera(config)
    print("경고: --mode laser는 좌표 진단 전용이며 학습 Label 수집에 사용하지 않습니다.")
    print(f"카메라 확인 통과: {camera_status(capture, config.device)}")
    print("Common Spec v1.5 Label Mapping 적용: 원본→64×64→8×8→Tracking")
    print("종료하려면 영상 창에서 q를 누르거나 터미널에서 Ctrl+C를 누르세요.")
    frame_count = 0

    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                raise RuntimeError("카메라 프레임을 읽지 못했습니다.")

            detection, mask = detect_red_laser(
                frame,
                red_minimum=red_minimum,
                red_dominance=red_dominance,
                saturation_minimum=saturation_minimum,
                minimum_area=minimum_area,
                maximum_area=maximum_area,
                minimum_circularity=minimum_circularity,
                minimum_local_contrast=minimum_local_contrast,
                border_margin=border_margin,
            )
            preview = frame.copy()
            label = None
            one_hot_heatmap = np.zeros(
                (HEATMAP_HEIGHT, HEATMAP_WIDTH),
                dtype=np.float32,
            )
            frame_count += 1

            if detection is not None:
                frame_height, frame_width = frame.shape[:2]
                label = map_source_to_label(
                    detection.center_x,
                    detection.center_y,
                    frame_width=frame_width,
                    frame_height=frame_height,
                )
                one_hot_heatmap = build_one_hot_heatmap(label)

                center = (detection.center_x, detection.center_y)
                display_radius = max(8, int(round(detection.radius)) + 4)
                cv2.circle(preview, center, display_radius, (0, 255, 0), 2)
                cv2.drawMarker(
                    preview,
                    center,
                    (0, 255, 0),
                    markerType=cv2.MARKER_CROSS,
                    markerSize=20,
                    thickness=2,
                )
                cv2.putText(
                    preview,
                    f"RAW x={detection.center_x}, y={detection.center_y}",
                    (10, 25),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.6,
                    (0, 255, 0),
                    2,
                )
                cv2.putText(
                    preview,
                    (
                        f"64=({label.tensor_x},{label.tensor_y}) "
                        f"HM=({label.heatmap_x},{label.heatmap_y}) "
                        f"TARGET=({label.target_x},{label.target_y})"
                    ),
                    (10, 50),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.55,
                    (0, 255, 0),
                    2,
                )

            if frame_count % 30 == 0:
                if detection is None or label is None:
                    print("레이저 미검출")
                else:
                    print(
                        f"원본=({label.source_x},{label.source_y}) "
                        f"64=({label.tensor_x},{label.tensor_y}) "
                        f"Heatmap=({label.heatmap_x},{label.heatmap_y}) "
                        f"Target=({label.target_x},{label.target_y}) "
                        f"면적={detection.area:.1f} "
                        f"원형도={detection.circularity:.2f} "
                        f"대비={detection.local_contrast:.1f}"
                    )

            heatmap_view = cv2.resize(
                (one_hot_heatmap * 255).astype(np.uint8),
                (HEATMAP_WIDTH * 64, HEATMAP_HEIGHT * 64),
                interpolation=cv2.INTER_NEAREST,
            )
            cv2.imshow("Red Laser Raw Coordinate Preview", preview)
            cv2.imshow("Red Laser Candidate Mask", mask)
            cv2.imshow("One-hot Heatmap Label YX", heatmap_view)

            if cv2.waitKey(1) & 0xFF == ord("q"):
                break
    finally:
        capture.release()
        cv2.destroyAllWindows()


def draw_collection_grid(
    preview: np.ndarray,
    distribution: np.ndarray,
    current_label: LabelMapping | None,
    samples_per_cell: int,
) -> None:
    """원본 Preview에 8×8 Cell 경계와 현재 Sample 수를 표시한다."""
    frame_height, frame_width = preview.shape[:2]

    for heatmap_y in range(HEATMAP_HEIGHT):
        for heatmap_x in range(HEATMAP_WIDTH):
            x0 = heatmap_x * frame_width // HEATMAP_WIDTH
            y0 = heatmap_y * frame_height // HEATMAP_HEIGHT
            x1 = (heatmap_x + 1) * frame_width // HEATMAP_WIDTH - 1
            y1 = (heatmap_y + 1) * frame_height // HEATMAP_HEIGHT - 1
            sample_count = int(distribution[heatmap_y, heatmap_x])

            if sample_count >= samples_per_cell:
                color = (0, 180, 0)
            else:
                color = (100, 100, 100)
            thickness = 1

            if (
                current_label is not None
                and current_label.heatmap_x == heatmap_x
                and current_label.heatmap_y == heatmap_y
            ):
                color = (0, 255, 255)
                thickness = 3

            cv2.rectangle(preview, (x0, y0), (x1, y1), color, thickness)
            cv2.putText(
                preview,
                f"{sample_count}/{samples_per_cell}",
                (x0 + 4, y0 + 17),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.38,
                color,
                1,
            )


def run_collect_mode(
    config: CameraConfig,
    noise_threshold: int,
    target_hue_low: int,
    target_hue_high: int,
    target_saturation_minimum: int,
    target_value_minimum: int,
    minimum_area: float,
    maximum_area: float,
    output_directory: Path,
    auto_save: bool,
    samples_per_cell: int,
    save_cooldown_frames: int,
    minimum_active_pixels: int,
    maximum_active_pixels: int,
    minimum_target_positive_pixels: int,
    require_target_positive_argmax: bool,
    capture_session_id: str,
    capture_split: str,
    environment_note: str,
    debug_snapshot_output: Path,
    maximum_preview_frames: int = 0,
    minimum_target_event_pixels: int = 0,
    minimum_target_event_ratio: float = 0.0,
) -> None:
    """수동 또는 8×8 균형 자동 방식으로 Dataset Sample을 저장한다."""
    if samples_per_cell < 1:
        raise ValueError("samples_per_cell은 1 이상이어야 합니다.")
    if save_cooldown_frames < 1:
        raise ValueError("save_cooldown_frames는 1 이상이어야 합니다.")
    if minimum_active_pixels < 1:
        raise ValueError("minimum_active_pixels는 1 이상이어야 합니다.")
    if maximum_active_pixels < minimum_active_pixels:
        raise ValueError(
            "maximum_active_pixels는 minimum_active_pixels 이상이어야 합니다."
        )
    if minimum_target_positive_pixels < 0:
        raise ValueError("minimum_target_positive_pixels는 0 이상이어야 합니다.")
    if minimum_target_event_pixels < 0:
        raise ValueError("minimum_target_event_pixels는 0 이상이어야 합니다.")
    if not 0.0 <= minimum_target_event_ratio <= 1.0:
        raise ValueError("minimum_target_event_ratio는 0~1이어야 합니다.")
    if maximum_preview_frames < 0:
        raise ValueError("maximum_preview_frames는 0 이상이어야 합니다.")
    session_template = CaptureMetadata(
        session_id=capture_session_id,
        split=capture_split,
        frame_sequence_index=1,
        camera_device=config.device,
        camera_fps=float(config.fps),
        environment_note=environment_note,
    )
    validate_capture_metadata(session_template)

    (
        _,
        all_valid_samples,
        existing_errors,
        _,
    ) = inspect_dataset_directory(output_directory)
    if existing_errors:
        error_summary = "; ".join(
            f"{path.name}: {message}" for path, message in existing_errors
        )
        raise RuntimeError(
            "기존 Dataset에 검증 오류가 있어 수집을 시작하지 않습니다. "
            f"{error_summary}"
        )

    valid_samples = [
        sample
        for sample in all_valid_samples
        if sample.capture_session_id == capture_session_id
    ]

    accepted_samples, rejected_samples, distribution = build_quality_distribution(
        valid_samples,
        minimum_active_pixels=minimum_active_pixels,
        maximum_active_pixels=maximum_active_pixels,
        minimum_target_positive_pixels=minimum_target_positive_pixels,
        require_target_positive_argmax=require_target_positive_argmax,
        minimum_target_event_pixels=minimum_target_event_pixels,
        minimum_target_event_ratio=minimum_target_event_ratio,
    )

    if auto_save and bool(np.all(distribution >= samples_per_cell)):
        print(
            f"자동수집 목표가 이미 완료되었습니다: "
            f"64개 Cell × {samples_per_cell}개 이상"
        )
        return

    capture = open_camera(config)
    try:
        manifest_path = write_session_manifest(
            output_directory,
            metadata=session_template,
            sample_kind="target",
            settings={
            "camera": {
                "device": config.device,
                "width": config.width,
                "height": config.height,
                "fps": config.fps,
                "controls": camera_control_manifest(config),
            },
            "event_noise_threshold": noise_threshold,
            "target_detector": {
                "hue_low": target_hue_low,
                "hue_high": target_hue_high,
                "saturation_minimum": target_saturation_minimum,
                "value_minimum": target_value_minimum,
                "minimum_area": minimum_area,
                "maximum_area": maximum_area,
            },
            "quality_gate": {
                "minimum_active_pixels": minimum_active_pixels,
                "maximum_active_pixels": maximum_active_pixels,
                "minimum_target_positive_pixels": minimum_target_positive_pixels,
                "minimum_target_event_pixels": minimum_target_event_pixels,
                "minimum_target_event_ratio": minimum_target_event_ratio,
                "require_target_positive_argmax": require_target_positive_argmax,
            },
            "samples_per_cell": samples_per_cell,
            "save_cooldown_frames": save_cooldown_frames,
            "audit_images": True,
            },
        )
    except Exception:
        capture.release()
        raise
    print(f"카메라 확인 통과: {camera_status(capture, config.device)}")
    print(f"Dataset 저장 경로: {output_directory}")
    print(
        f"촬영 Session: {capture_session_id} / Split={capture_split} / "
        f"Manifest={manifest_path.name}"
    )
    print(
        f"전체 정상 Sample: {len(all_valid_samples)}개, "
        f"현재 Session: {len(valid_samples)}개, "
        f"품질 사용: {len(accepted_samples)}개, "
        f"품질 제외: {len(rejected_samples)}개"
    )
    if auto_save:
        print(
            f"균형 자동수집: 8×8 각 Cell {samples_per_cell}개, "
            f"활성 픽셀 {minimum_active_pixels}~{maximum_active_pixels}개"
        )
        print(
            "Target 정렬 조건: "
            f"Positive Pixel {minimum_target_positive_pixels}개 이상, "
            f"전체 Event {minimum_target_event_pixels}개 이상, "
            f"Target/Active {minimum_target_event_ratio:.3f} 이상, "
            f"Positive Energy Argmax="
            f"{'필수' if require_target_positive_argmax else '미적용'}"
        )
        print(
            "실제 추적 표적 마커를 화면 전체로 천천히 움직이세요. "
            "s 키는 무시되며 목표 완료 시 자동 종료합니다."
        )
    else:
        print(
            "실제 표적 마커를 움직이면서 s를 누르면 저장합니다. "
            "오검출 순간 c=진단 Frame 저장, q=종료입니다."
        )

    ok, first_frame = capture.read()
    if not ok:
        capture.release()
        raise RuntimeError("첫 번째 카메라 프레임을 읽지 못했습니다.")

    previous_gray64 = frame_to_gray64(first_frame)
    next_sample_index = find_next_sample_index(output_directory)
    frame_count = 0
    last_saved_frame = -save_cooldown_frames
    detected_frame_count = 0
    active_range_frame_count = 0
    target_positive_frame_count = 0
    positive_argmax_frame_count = 0
    quality_without_argmax_frame_count = 0
    quality_gate_frame_count = 0
    marker_areas: list[float] = []
    detected_active_pixel_counts: list[int] = []
    target_positive_pixel_counts: list[int] = []

    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                raise RuntimeError("카메라 프레임을 읽지 못했습니다.")

            current_gray64 = frame_to_gray64(frame)
            input_tensor = build_event_tensor(
                previous_gray64,
                current_gray64,
                noise_threshold=noise_threshold,
            )
            previous_gray64 = current_gray64
            active_pixel_count = int(np.count_nonzero(input_tensor))
            frame_count += 1

            detection, target_mask = detect_target_marker(
                frame,
                hue_low=target_hue_low,
                hue_high=target_hue_high,
                saturation_minimum=target_saturation_minimum,
                value_minimum=target_value_minimum,
                minimum_area=minimum_area,
                maximum_area=maximum_area,
            )

            preview = frame.copy()
            label = None
            alignment = None
            label_heatmap = np.zeros(
                (HEATMAP_HEIGHT, HEATMAP_WIDTH),
                dtype=np.float32,
            )

            if detection is not None:
                detected_frame_count += 1
                marker_areas.append(detection.area)
                detected_active_pixel_counts.append(active_pixel_count)
                frame_height, frame_width = frame.shape[:2]
                label = map_source_to_label(
                    detection.center_x,
                    detection.center_y,
                    frame_width=frame_width,
                    frame_height=frame_height,
                )
                label_heatmap = build_one_hot_heatmap(label)
                alignment = measure_event_label_alignment(
                    input_tensor,
                    heatmap_x=label.heatmap_x,
                    heatmap_y=label.heatmap_y,
                )
                target_positive_pixel_counts.append(
                    alignment.target_positive_pixel_count
                )

                active_in_range = (
                    minimum_active_pixels
                    <= active_pixel_count
                    <= maximum_active_pixels
                )
                if active_in_range:
                    active_range_frame_count += 1
                if (
                    alignment.target_positive_pixel_count
                    >= minimum_target_positive_pixels
                ):
                    target_positive_frame_count += 1
                if alignment.positive_energy_argmax_match:
                    positive_argmax_frame_count += 1
                if (
                    active_in_range
                    and alignment.target_positive_pixel_count
                    >= minimum_target_positive_pixels
                    and alignment.target_event_pixel_count
                    >= minimum_target_event_pixels
                    and alignment.target_event_pixel_count
                    / max(1, active_pixel_count)
                    >= minimum_target_event_ratio
                ):
                    quality_without_argmax_frame_count += 1
                if (
                    active_in_range
                    and alignment.target_positive_pixel_count
                    >= minimum_target_positive_pixels
                    and alignment.target_event_pixel_count
                    >= minimum_target_event_pixels
                    and alignment.target_event_pixel_count
                    / max(1, active_pixel_count)
                    >= minimum_target_event_ratio
                    and (
                        not require_target_positive_argmax
                        or alignment.positive_energy_argmax_match
                    )
                ):
                    quality_gate_frame_count += 1

            draw_collection_grid(
                preview,
                distribution=distribution,
                current_label=label,
                samples_per_cell=samples_per_cell,
            )

            if detection is not None and label is not None:
                center = (detection.center_x, detection.center_y)
                cv2.drawMarker(
                    preview,
                    center,
                    (0, 255, 0),
                    markerType=cv2.MARKER_CROSS,
                    markerSize=20,
                    thickness=2,
                )
                cv2.putText(
                    preview,
                    (
                        f"TARGET=({label.target_x},{label.target_y}) "
                        f"HM=({label.heatmap_x},{label.heatmap_y}) "
                        f"AREA={detection.area:.0f}"
                    ),
                    (10, frame.shape[0] - 35),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.6,
                    (0, 255, 0),
                    2,
                )
            else:
                cv2.putText(
                    preview,
                    "TARGET MARKER NOT DETECTED",
                    (10, frame.shape[0] - 35),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.6,
                    (0, 0, 255),
                    2,
                )

            cv2.putText(
                preview,
                (
                    f"ACTIVE={active_pixel_count}  "
                    f"TGT_POS="
                    f"{alignment.target_positive_pixel_count if alignment else 0}  "
                    f"TGT_EVT="
                    f"{alignment.target_event_pixel_count if alignment else 0}  "
                    f"RATIO="
                    f"{alignment.target_event_pixel_count / max(1, active_pixel_count):.2f}  "
                    if alignment
                    else "TGT_POS=0  TGT_EVT=0  RATIO=0.00  "
                )
                + (
                    f"POS_TOP="
                    f"{'YES' if alignment and alignment.positive_energy_argmax_match else 'NO'}  "
                    f"{'AUTO=ON' if auto_save else 'S=SAVE'}  C=DEBUG  Q=QUIT"
                ),
                (10, frame.shape[0] - 10),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.55,
                (255, 255, 0),
                2,
            )

            event_view = scale_for_display(
                np.maximum(
                    input_tensor[:, :, POSITIVE_CHANNEL],
                    input_tensor[:, :, NEGATIVE_CHANNEL],
                )
            )
            heatmap_view = cv2.resize(
                (label_heatmap * 255).astype(np.uint8),
                (HEATMAP_WIDTH * 64, HEATMAP_HEIGHT * 64),
                interpolation=cv2.INTER_NEAREST,
            )

            cv2.imshow("Dataset Collection Preview", preview)
            cv2.imshow("Target Marker Mask", target_mask)
            cv2.imshow("Dataset Event Activity", event_view)
            cv2.imshow("Dataset One-hot Label YX", heatmap_view)

            key = cv2.waitKey(1) & 0xFF
            if key == ord("c"):
                debug_visual_path = debug_snapshot_output.with_name(
                    f"{debug_snapshot_output.stem}_debug"
                    f"{debug_snapshot_output.suffix or '.jpg'}"
                )
                save_jpeg_snapshot(debug_snapshot_output, frame)
                save_jpeg_snapshot(
                    debug_visual_path,
                    build_audit_image(preview, target_mask),
                )
                if detection is None:
                    detection_summary = "검출 없음"
                else:
                    detection_summary = (
                        f"검출 중심=({detection.center_x},{detection.center_y}), "
                        f"면적={detection.area:.1f}px²"
                    )
                print(
                    f"Debug Snapshot 저장 완료: {debug_snapshot_output} / "
                    f"{debug_visual_path} / {detection_summary}"
                )
            if key == ord("q"):
                break
            if maximum_preview_frames and frame_count >= maximum_preview_frames:
                print(f"Preview Frame 목표 도달: {maximum_preview_frames}개")
                break

            # 자동 모드에서는 사용자의 s 입력을 무시하여 Cell 목표 수 초과를 막는다.
            manual_save_requested = not auto_save and key == ord("s")
            automatic_save_requested = (
                auto_save
                and label is not None
                and active_pixel_count >= minimum_active_pixels
                and active_pixel_count <= maximum_active_pixels
                and alignment is not None
                and alignment.target_positive_pixel_count
                >= minimum_target_positive_pixels
                and alignment.target_event_pixel_count
                >= minimum_target_event_pixels
                and alignment.target_event_pixel_count
                / max(1, active_pixel_count)
                >= minimum_target_event_ratio
                and (
                    not require_target_positive_argmax
                    or alignment.positive_energy_argmax_match
                )
                and int(distribution[label.heatmap_y, label.heatmap_x])
                < samples_per_cell
                and frame_count - last_saved_frame >= save_cooldown_frames
            )
            if not manual_save_requested and not automatic_save_requested:
                continue

            if detection is None or label is None:
                if manual_save_requested:
                    print("저장 취소: 실제 표적 마커가 검출되지 않았습니다.")
                continue
            if active_pixel_count < minimum_active_pixels:
                if manual_save_requested:
                    print(
                        "저장 취소: Event Tensor 활성 픽셀이 부족합니다. "
                        f"현재={active_pixel_count}, 필요={minimum_active_pixels}"
                    )
                continue
            if active_pixel_count > maximum_active_pixels:
                if manual_save_requested:
                    print(
                        "저장 취소: Event Tensor 활성 픽셀이 너무 많습니다. "
                        f"현재={active_pixel_count}, 최대={maximum_active_pixels}"
                    )
                continue
            if alignment is None:
                if manual_save_requested:
                    print("저장 취소: Event-Label 정렬값을 계산하지 못했습니다.")
                continue
            if alignment.target_event_pixel_count < minimum_target_event_pixels:
                if manual_save_requested:
                    print(
                        "저장 취소: Label Cell의 전체 Event가 부족합니다. "
                        f"현재={alignment.target_event_pixel_count}, "
                        f"필요={minimum_target_event_pixels}"
                    )
                continue
            target_event_ratio = alignment.target_event_pixel_count / max(
                1,
                active_pixel_count,
            )
            if target_event_ratio < minimum_target_event_ratio:
                if manual_save_requested:
                    print(
                        "저장 취소: 전체 Event 중 Label Cell 비율이 낮습니다. "
                        f"현재={target_event_ratio:.3f}, "
                        f"필요={minimum_target_event_ratio:.3f}"
                    )
                continue
            if (
                alignment.target_positive_pixel_count
                < minimum_target_positive_pixels
            ):
                if manual_save_requested:
                    print(
                        "저장 취소: Label Cell의 Positive Event가 부족합니다. "
                        f"현재={alignment.target_positive_pixel_count}, "
                        f"필요={minimum_target_positive_pixels}"
                    )
                continue
            if (
                require_target_positive_argmax
                and not alignment.positive_energy_argmax_match
            ):
                if manual_save_requested:
                    print(
                        "저장 취소: 가장 강한 Positive Event Cell과 "
                        "표적 Label Cell이 다릅니다."
                    )
                continue

            frame_height, frame_width = frame.shape[:2]
            saved_path = save_dataset_sample(
                output_directory=output_directory,
                sample_index=next_sample_index,
                input_tensor=input_tensor,
                label_heatmap=label_heatmap,
                label=label,
                frame_width=frame_width,
                frame_height=frame_height,
                noise_threshold=noise_threshold,
                capture_metadata=CaptureMetadata(
                    session_id=capture_session_id,
                    split=capture_split,
                    frame_sequence_index=frame_count,
                    camera_device=config.device,
                    camera_fps=float(config.fps),
                    environment_note=environment_note,
                ),
                audit_image=build_audit_image(preview, target_mask),
                target_marker_area=detection.area,
            )
            print(
                f"Sample 저장 완료: {saved_path} "
                f"Target=({label.target_x},{label.target_y}) "
                f"활성 픽셀={active_pixel_count} "
                f"Target Positive={alignment.target_positive_pixel_count} "
                f"Cell=({label.heatmap_x},{label.heatmap_y}) "
                f"개수={int(distribution[label.heatmap_y, label.heatmap_x]) + 1}/"
                f"{samples_per_cell}"
            )
            distribution[label.heatmap_y, label.heatmap_x] += 1
            next_sample_index += 1
            last_saved_frame = frame_count

            if auto_save and bool(np.all(distribution >= samples_per_cell)):
                print(
                    f"균형 자동수집 완료: 64개 Cell × {samples_per_cell}개 이상"
                )
                break
    finally:
        capture.release()
        cv2.destroyAllWindows()
        print(
            "촬영 품질 요약: "
            f"전체 Frame={frame_count}, "
            f"파란 Label 검출={detected_frame_count}, "
            f"활성량 범위 통과={active_range_frame_count}, "
            f"Target Positive 통과={target_positive_frame_count}, "
            f"Positive Argmax 일치={positive_argmax_frame_count}, "
            f"Argmax 제외 품질 통과={quality_without_argmax_frame_count}, "
            f"최종 품질 Gate 통과={quality_gate_frame_count}"
        )
        if marker_areas:
            marker_area_array = np.asarray(marker_areas, dtype=np.float32)
            print(
                "파란 Label 면적 min/median/max="
                f"{float(marker_area_array.min()):.1f}/"
                f"{float(np.median(marker_area_array)):.1f}/"
                f"{float(marker_area_array.max()):.1f} px²"
            )
        nonzero_active_counts = np.asarray(
            [count for count in detected_active_pixel_counts if count > 0],
            dtype=np.int32,
        )
        if nonzero_active_counts.size:
            active_percentiles = np.percentile(
                nonzero_active_counts,
                [10, 50, 90, 99],
            )
            print(
                "움직임 Frame 활성 픽셀 p10/p50/p90/p99/max="
                f"{active_percentiles[0]:.1f}/"
                f"{active_percentiles[1]:.1f}/"
                f"{active_percentiles[2]:.1f}/"
                f"{active_percentiles[3]:.1f}/"
                f"{int(nonzero_active_counts.max())}"
            )
        nonzero_target_positive_counts = np.asarray(
            [count for count in target_positive_pixel_counts if count > 0],
            dtype=np.int32,
        )
        if nonzero_target_positive_counts.size:
            target_percentiles = np.percentile(
                nonzero_target_positive_counts,
                [10, 50, 90, 99],
            )
            print(
                "Target Positive 픽셀 p10/p50/p90/p99/max="
                f"{target_percentiles[0]:.1f}/"
                f"{target_percentiles[1]:.1f}/"
                f"{target_percentiles[2]:.1f}/"
                f"{target_percentiles[3]:.1f}/"
                f"{int(nonzero_target_positive_counts.max())}"
            )


def run_collect_no_target_mode(
    config: CameraConfig,
    noise_threshold: int,
    target_hue_low: int,
    target_hue_high: int,
    target_saturation_minimum: int,
    target_value_minimum: int,
    target_minimum_area: float,
    target_maximum_area: float,
    output_directory: Path,
    auto_save: bool,
    maximum_samples: int,
    save_cooldown_frames: int,
    minimum_active_pixels: int,
    maximum_active_pixels: int,
    capture_session_id: str,
    capture_split: str,
    environment_note: str,
) -> None:
    """실제 표적 마커가 없는 프레임의 Event Tensor를 수집한다."""
    if maximum_samples < 1:
        raise ValueError("maximum_samples는 1 이상이어야 합니다.")
    if save_cooldown_frames < 1:
        raise ValueError("save_cooldown_frames는 1 이상이어야 합니다.")
    if minimum_active_pixels < 0:
        raise ValueError("무표적 minimum_active_pixels는 0 이상이어야 합니다.")
    if maximum_active_pixels < minimum_active_pixels:
        raise ValueError(
            "maximum_active_pixels는 minimum_active_pixels 이상이어야 합니다."
        )
    session_template = CaptureMetadata(
        session_id=capture_session_id,
        split=capture_split,
        frame_sequence_index=1,
        camera_device=config.device,
        camera_fps=float(config.fps),
        environment_note=environment_note,
    )
    validate_capture_metadata(session_template)

    _, all_valid_samples, errors = inspect_no_target_directory(output_directory)
    if errors:
        error_summary = "; ".join(f"{p.name}: {m}" for p, m in errors)
        raise RuntimeError(f"기존 무표적 Dataset 형식 오류: {error_summary}")
    valid_samples = [
        sample
        for sample in all_valid_samples
        if sample.capture_session_id == capture_session_id
    ]
    if auto_save and len(valid_samples) >= maximum_samples:
        print(f"무표적 자동수집 목표가 이미 완료되었습니다: {len(valid_samples)}개")
        return

    capture = open_camera(config)
    try:
        manifest_path = write_session_manifest(
            output_directory,
            metadata=session_template,
            sample_kind="no_target",
            settings={
            "camera": {
                "device": config.device,
                "width": config.width,
                "height": config.height,
                "fps": config.fps,
                "controls": camera_control_manifest(config),
            },
            "event_noise_threshold": noise_threshold,
            "target_absence_detector": {
                "hue_low": target_hue_low,
                "hue_high": target_hue_high,
                "saturation_minimum": target_saturation_minimum,
                "value_minimum": target_value_minimum,
                "minimum_area": target_minimum_area,
                "maximum_area": target_maximum_area,
            },
            "quality_gate": {
                "minimum_active_pixels": minimum_active_pixels,
                "maximum_active_pixels": maximum_active_pixels,
            },
            "maximum_samples": maximum_samples,
            "save_cooldown_frames": save_cooldown_frames,
            "audit_images": True,
            },
        )
    except Exception:
        capture.release()
        raise
    print(f"카메라 확인 통과: {camera_status(capture, config.device)}")
    print(f"무표적 Dataset 저장 경로: {output_directory}")
    print(
        f"촬영 Session: {capture_session_id} / Split={capture_split} / "
        f"Manifest={manifest_path.name}"
    )
    print("실제 표적 마커를 화면에서 치운 뒤 s로 저장하거나 --auto-save를 사용하세요.")

    ok, first_frame = capture.read()
    if not ok:
        capture.release()
        raise RuntimeError("첫 번째 카메라 프레임을 읽지 못했습니다.")
    previous_gray64 = frame_to_gray64(first_frame)
    next_sample_index = find_next_sample_index(output_directory)
    frame_count = 0
    last_saved_frame = -save_cooldown_frames

    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                raise RuntimeError("카메라 프레임을 읽지 못했습니다.")
            current_gray64 = frame_to_gray64(frame)
            input_tensor = build_event_tensor(
                previous_gray64,
                current_gray64,
                noise_threshold=noise_threshold,
            )
            previous_gray64 = current_gray64
            frame_count += 1
            active_pixel_count = int(np.count_nonzero(input_tensor))
            detection, mask = detect_target_marker(
                frame,
                hue_low=target_hue_low,
                hue_high=target_hue_high,
                saturation_minimum=target_saturation_minimum,
                value_minimum=target_value_minimum,
                minimum_area=target_minimum_area,
                maximum_area=target_maximum_area,
            )

            preview = frame.copy()
            state = "TARGET PRESENT - DO NOT SAVE" if detection else "NO TARGET"
            color = (0, 0, 255) if detection else (0, 255, 0)
            cv2.putText(
                preview,
                f"{state} ACTIVE={active_pixel_count} SAVED={len(valid_samples)}",
                (10, 30),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.6,
                color,
                2,
            )
            cv2.imshow("No-target Collection Preview", preview)
            cv2.imshow("Target Marker Mask", mask)
            key = cv2.waitKey(1) & 0xFF
            if key == ord("q"):
                break

            eligible = (
                detection is None
                and minimum_active_pixels <= active_pixel_count <= maximum_active_pixels
                and frame_count - last_saved_frame >= save_cooldown_frames
            )
            save_requested = (not auto_save and key == ord("s")) or (auto_save and eligible)
            if not save_requested:
                continue
            if not eligible:
                if not auto_save:
                    print(
                        "저장 취소: 표적 마커가 있거나 Event 활성 픽셀 범위를 벗어났습니다. "
                        f"active={active_pixel_count}"
                    )
                continue

            frame_height, frame_width = frame.shape[:2]
            saved_path = save_no_target_sample(
                output_directory=output_directory,
                sample_index=next_sample_index,
                input_tensor=input_tensor,
                frame_width=frame_width,
                frame_height=frame_height,
                noise_threshold=noise_threshold,
                capture_metadata=CaptureMetadata(
                    session_id=capture_session_id,
                    split=capture_split,
                    frame_sequence_index=frame_count,
                    camera_device=config.device,
                    camera_fps=float(config.fps),
                    environment_note=environment_note,
                ),
                audit_image=build_audit_image(preview, mask),
            )
            valid_samples.append(validate_no_target_sample(saved_path))
            print(f"무표적 Sample 저장 완료: {saved_path} active={active_pixel_count}")
            next_sample_index += 1
            last_saved_frame = frame_count
            if auto_save and len(valid_samples) >= maximum_samples:
                print(f"무표적 자동수집 완료: {len(valid_samples)}개")
                break
    finally:
        capture.release()
        cv2.destroyAllWindows()


def run_self_test() -> None:
    """Event Tensor, 실제 표적/레이저 경계, Dataset provenance를 검증한다."""
    dark = np.zeros((TENSOR_HEIGHT, TENSOR_WIDTH), dtype=np.uint8)
    bright = dark.copy()
    bright[10, 20] = 255

    positive_tensor = build_event_tensor(dark, bright, noise_threshold=0)
    assert positive_tensor.shape == (64, 64, 2)
    assert positive_tensor.dtype == np.int8
    assert int(positive_tensor[10, 20, POSITIVE_CHANNEL]) == 127
    assert int(positive_tensor[10, 20, NEGATIVE_CHANNEL]) == 0

    negative_tensor = build_event_tensor(bright, dark, noise_threshold=0)
    assert int(negative_tensor[10, 20, POSITIVE_CHANNEL]) == 0
    assert int(negative_tensor[10, 20, NEGATIVE_CHANNEL]) == 127

    # 가상의 빨간 레이저 점을 만들어 원본 좌표 검출도 함께 확인한다.
    synthetic_frame = np.zeros((480, 640, 3), dtype=np.uint8)
    cv2.circle(synthetic_frame, (320, 240), 5, (0, 0, 255), thickness=-1)
    laser, _ = detect_red_laser(synthetic_frame)
    assert laser is not None
    assert abs(laser.center_x - 320) <= 1
    assert abs(laser.center_y - 240) <= 1

    # 피부색, 흰색 시계 반사광, 화면 가장자리의 빨간 점은 제외해야 한다.
    false_positive_frame = np.zeros((480, 640, 3), dtype=np.uint8)
    cv2.ellipse(
        false_positive_frame,
        (200, 240),
        (35, 70),
        0,
        0,
        360,
        (70, 120, 210),
        thickness=-1,
    )
    cv2.circle(
        false_positive_frame,
        (350, 240),
        8,
        (255, 255, 255),
        thickness=-1,
    )
    cv2.circle(
        false_positive_frame,
        (420, 1),
        3,
        (0, 0, 255),
        thickness=-1,
    )
    false_laser, _ = detect_red_laser(false_positive_frame)
    assert false_laser is None

    # 파랑 실제 표적 Blob은 검출하고 레이저 크기의 작은 점은 거부한다.
    target_hsv = np.zeros((480, 640, 3), dtype=np.uint8)
    target_hsv[190:250, 280:360] = (103, 176, 200)
    target_frame = cv2.cvtColor(target_hsv, cv2.COLOR_HSV2BGR)
    target, _ = detect_target_marker(target_frame)
    assert target is not None
    assert abs(target.center_x - 319) <= 1
    assert abs(target.center_y - 219) <= 1
    tiny_target_hsv = np.zeros((480, 640, 3), dtype=np.uint8)
    cv2.circle(tiny_target_hsv, (320, 240), 3, (103, 255, 255), thickness=-1)
    tiny_target_frame = cv2.cvtColor(tiny_target_hsv, cv2.COLOR_HSV2BGR)
    tiny_target, _ = detect_target_marker(tiny_target_frame)
    assert tiny_target is None

    # 카메라 색조 때문에 피부가 푸르게 보여도 저채도 피부는 제외하고
    # 고채도 파란 라벨만 Target으로 선택해야 한다.
    color_cast_hsv = np.zeros((480, 640, 3), dtype=np.uint8)
    color_cast_hsv[:, :] = (0, 0, 245)
    color_cast_hsv[120:430, 100:300] = (116, 80, 230)
    color_cast_hsv[220:260, 450:480] = (109, 170, 245)
    color_cast_frame = cv2.cvtColor(color_cast_hsv, cv2.COLOR_HSV2BGR)
    color_cast_target, color_cast_mask = detect_target_marker(color_cast_frame)
    assert color_cast_target is not None
    assert abs(color_cast_target.center_x - 464) <= 1
    assert abs(color_cast_target.center_y - 239) <= 1
    assert int(np.count_nonzero(color_cast_mask[120:430, 100:300])) == 0

    # Hue wrap-around(예: 빨강 170~10)도 하나의 범위로 처리한다.
    wrapped_hsv = np.zeros((100, 100, 3), dtype=np.uint8)
    wrapped_hsv[20:80, 20:80] = (179, 200, 200)
    wrapped_mask = build_target_marker_mask(
        cv2.cvtColor(wrapped_hsv, cv2.COLOR_HSV2BGR),
        hue_low=170,
        hue_high=10,
    )
    assert int(np.count_nonzero(wrapped_mask)) > 0

    # 승인 예시 좌표로 v1.5 Label Mapping과 [Y][X] One-hot 순서를 검증한다.
    label = map_source_to_label(
        source_x=299,
        source_y=228,
        frame_width=640,
        frame_height=480,
    )
    assert label.tensor_x == 29
    assert label.tensor_y == 30
    assert label.heatmap_x == 3
    assert label.heatmap_y == 3
    assert label.target_x == 28
    assert label.target_y == 28

    one_hot_heatmap = build_one_hot_heatmap(label)
    assert one_hot_heatmap.shape == (8, 8)
    assert one_hot_heatmap.dtype == np.float32
    assert float(one_hot_heatmap.sum()) == 1.0
    assert float(one_hot_heatmap[3, 3]) == 1.0

    # 정답 Cell에 Positive Event가 있고 해당 Cell Energy가 가장 큰지 검증한다.
    aligned_tensor = np.zeros(
        (TENSOR_HEIGHT, TENSOR_WIDTH, TENSOR_CHANNELS),
        dtype=np.int8,
    )
    aligned_tensor[label.tensor_y, label.tensor_x, POSITIVE_CHANNEL] = 100
    aligned = measure_event_label_alignment(
        aligned_tensor,
        heatmap_x=label.heatmap_x,
        heatmap_y=label.heatmap_y,
    )
    assert aligned.target_positive_pixel_count == 1
    assert aligned.target_event_pixel_count == 1
    assert aligned.positive_energy_argmax_match
    assert aligned.total_energy_argmax_match

    # 원본 영상의 우하단 좌표가 각 출력 범위를 넘지 않는지 확인한다.
    edge_label = map_source_to_label(639, 479, 640, 480)
    assert (edge_label.tensor_x, edge_label.tensor_y) == (63, 63)
    assert (edge_label.heatmap_x, edge_label.heatmap_y) == (7, 7)
    assert (edge_label.target_x, edge_label.target_y) == (60, 60)

    # 임시 폴더에서 NPZ Dataset 저장 형식과 다음 일련번호를 검증한다.
    with tempfile.TemporaryDirectory() as temporary_directory:
        output_directory = Path(temporary_directory)
        saved_path = save_dataset_sample(
            output_directory=output_directory,
            sample_index=1,
            input_tensor=positive_tensor,
            label_heatmap=one_hot_heatmap,
            label=label,
            frame_width=640,
            frame_height=480,
            noise_threshold=8,
        )
        assert saved_path.exists()
        assert find_next_sample_index(output_directory) == 2

        sample_info = validate_dataset_sample(saved_path)
        assert sample_info.sample_index == 1
        assert (sample_info.heatmap_x, sample_info.heatmap_y) == (3, 3)
        assert (sample_info.target_x, sample_info.target_y) == (28, 28)
        assert sample_info.active_pixel_count == 1

        paths, valid_samples, errors, distribution = inspect_dataset_directory(
            output_directory
        )
        assert len(paths) == 1
        assert len(valid_samples) == 1
        assert not errors
        assert int(distribution[3, 3]) == 1

        accepted, rejected, quality_distribution = build_quality_distribution(
            valid_samples,
            minimum_active_pixels=1,
            maximum_active_pixels=300,
        )
        assert len(accepted) == 1
        assert not rejected
        assert int(quality_distribution[3, 3]) == 1

        aligned_accepted, aligned_rejected, aligned_distribution = (
            build_quality_distribution(
                valid_samples,
                minimum_active_pixels=1,
                maximum_active_pixels=300,
                minimum_target_positive_pixels=1,
                require_target_positive_argmax=True,
            )
        )
        assert not aligned_accepted
        assert len(aligned_rejected) == 1
        assert int(aligned_distribution.sum()) == 0

        with np.load(saved_path, allow_pickle=False) as saved_sample:
            assert saved_sample["input_tensor"].shape == (64, 64, 2)
            assert saved_sample["input_tensor"].dtype == np.int8
            assert saved_sample["label_heatmap"].shape == (8, 8)
            assert saved_sample["label_heatmap"].dtype == np.float32
            assert saved_sample["source_xy"].tolist() == [299, 228]
            assert saved_sample["tensor_xy"].tolist() == [29, 30]
            assert saved_sample["heatmap_xy"].tolist() == [3, 3]
            assert saved_sample["target_xy"].tolist() == [28, 28]
            assert str(saved_sample["spec_version"]) == BASE_SPEC_VERSION
            assert str(saved_sample["tensor_layout"]) == "HWC_LOGICAL_ONLY"
            assert str(saved_sample["heatmap_layout"]) == "YX"
            assert str(saved_sample["label_source"]) == LABEL_SOURCE_TARGET_MARKER

        for rejected_source in (*sorted(REJECTED_LABEL_SOURCES), "UNKNOWN"):
            try:
                save_dataset_sample(
                    output_directory=output_directory,
                    sample_index=2,
                    input_tensor=positive_tensor,
                    label_heatmap=one_hot_heatmap,
                    label=label,
                    frame_width=640,
                    frame_height=480,
                    noise_threshold=8,
                    label_source=rejected_source,
                )
            except ValueError:
                pass
            else:
                raise AssertionError(f"금지 label_source가 허용됨: {rejected_source}")

        _, target_mask = detect_target_marker(target_frame)
        v03_path = save_dataset_sample(
            output_directory=output_directory,
            sample_index=2,
            input_tensor=positive_tensor,
            label_heatmap=one_hot_heatmap,
            label=label,
            frame_width=640,
            frame_height=480,
            noise_threshold=8,
            capture_metadata=CaptureMetadata(
                session_id="target_train_a",
                split="train",
                frame_sequence_index=17,
                camera_device=2,
                camera_fps=30.0,
                environment_note="self-test",
            ),
            audit_image=build_audit_image(target_frame, target_mask),
            target_marker_area=1_000.0,
        )
        v03_info = validate_dataset_sample(v03_path)
        assert v03_info.capture_session_id == "target_train_a"
        assert v03_info.capture_split == "train"
        assert v03_info.collection_version == COLLECTION_VERSION
        assert (output_directory / v03_info.audit_image_relative_path).is_file()

        no_target_directory = output_directory / "no_target"
        no_target_path = save_no_target_sample(
            output_directory=no_target_directory,
            sample_index=1,
            input_tensor=positive_tensor,
            frame_width=640,
            frame_height=480,
            noise_threshold=8,
            capture_metadata=CaptureMetadata(
                session_id="no_target_train_motion",
                split="train",
                frame_sequence_index=9,
                camera_device=2,
                camera_fps=30.0,
                environment_note="self-test",
            ),
            audit_image=build_audit_image(false_positive_frame, np.zeros((480, 640), dtype=np.uint8)),
        )
        no_target_info = validate_no_target_sample(no_target_path)
        assert no_target_info.sample_index == 1
        assert no_target_info.capture_session_id == "no_target_train_motion"
        assert no_target_info.collection_version == COLLECTION_VERSION
        no_target_paths, no_target_samples, no_target_errors = (
            inspect_no_target_directory(no_target_directory)
        )
        assert len(no_target_paths) == len(no_target_samples) == 1
        assert not no_target_errors

    print("자체 검증 통과")
    print("형상=(64, 64, 2), 자료형=int8, 채널 범위=0~127")
    print("가상 빨간 레이저 원본 좌표 검출 통과")
    print("피부·반사광·화면 가장자리 오검출 차단 자체 검증 통과")
    print("실제 표적(색상 마커) 중심 검출 자체 검증 통과")
    print("파란 색조 저채도 피부 제외·고채도 라벨 선택 자체 검증 통과")
    print("레이저 크기 점을 표적으로 오인하지 않음 자체 검증 통과")
    print("Hue wrap-around 색 범위 자체 검증 통과")
    print("label_source 출처 기록 및 레이저 Label 거부 자체 검증 통과")
    print("무표적 Sample 저장·검증 자체 검증 통과")
    print("확정 Label Mapping 자체 검증 통과")
    print("NPZ Dataset Sample 저장 형식 자체 검증 통과")
    print("NPZ Dataset Sample 전체 항목 검증 통과")
    print("8×8 Dataset 분포 집계 자체 검증 통과")
    print("활성 픽셀 품질 범위 필터 자체 검증 통과")
    print("Target Cell Positive Event 정렬 품질 필터 자체 검증 통과")
    print("예시: 원본=(299,228) → 64=(29,30) → Heatmap=(3,3) → Target=(28,28)")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="B 역할 웹캠 프레임 차분 데이터셋 입력 모듈"
    )
    parser.add_argument(
        "--mode",
        choices=(
            "camera",
            "event",
            "laser",
            "collect",
            "collect-no-target",
            "dataset-check",
            "no-target-check",
            "self-test",
        ),
        default="event",
    )
    parser.add_argument("--device", type=int, default=2)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument(
        "--lock-v03-camera-controls",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="수동 노출·밝기·WB·초점 값을 카메라 열기 전에 재적용(기본: 미적용)",
    )
    parser.add_argument("--threshold", type=int, default=8)
    parser.add_argument("--red-min", type=int, default=220, help="진단용 --mode laser 전용")
    parser.add_argument("--red-dominance", type=int, default=80, help="진단용 --mode laser 전용")
    parser.add_argument("--laser-saturation-min", type=int, default=160, help="진단용 --mode laser 전용")
    parser.add_argument("--laser-min-area", type=float, default=2.0, help="진단용 --mode laser 전용")
    parser.add_argument("--laser-max-area", type=float, default=300.0, help="진단용 --mode laser 전용")
    parser.add_argument("--laser-min-circularity", type=float, default=0.45, help="진단용 --mode laser 전용")
    parser.add_argument("--laser-min-contrast", type=float, default=15.0, help="진단용 --mode laser 전용")
    parser.add_argument("--laser-border-margin", type=int, default=3, help="진단용 --mode laser 전용")
    parser.add_argument("--target-hue-low", type=int, default=88)
    parser.add_argument("--target-hue-high", type=int, default=118)
    parser.add_argument("--target-sat-min", type=int, default=120)
    parser.add_argument("--target-val-min", type=int, default=100)
    parser.add_argument("--target-min-area", type=float, default=400.0)
    parser.add_argument("--target-max-area", type=float, default=5_000.0)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
    )
    parser.add_argument(
        "--snapshot-output",
        type=Path,
        default=Path("/tmp/event_camera_snapshot.jpg"),
        help="camera Preview에서 s를 눌렀을 때 저장할 현재 Frame 경로",
    )
    parser.add_argument(
        "--session-id",
        default=None,
        help="v03 촬영 Session ID(예: target_train_a); collect 모드에서 필수",
    )
    parser.add_argument(
        "--capture-split",
        choices=tuple(sorted(CAPTURE_SPLITS)),
        default=None,
        help="Session 전체에 고정할 train/validation/test 역할; collect 모드에서 필수",
    )
    parser.add_argument(
        "--environment-note",
        default="",
        help="조명·배경·움직임 조건을 500자 이내로 기록",
    )
    parser.add_argument(
        "--require-session-metadata",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="dataset-check에서 v03 촬영 Session 메타데이터를 필수로 검사",
    )
    parser.add_argument(
        "--auto-save",
        action="store_true",
        help="collect 모드에서 8×8 Cell별 목표 수까지 자동 저장",
    )
    parser.add_argument(
        "--samples-per-cell",
        type=int,
        default=5,
        help="수집 화면 표시 및 자동수집에 사용할 Cell별 목표 수",
    )
    parser.add_argument(
        "--max-samples",
        type=int,
        default=500,
        help="collect-no-target 자동수집 목표 Sample 수",
    )
    parser.add_argument(
        "--save-cooldown-frames",
        type=int,
        default=3,
        help="자동 저장 사이의 최소 프레임 간격",
    )
    parser.add_argument(
        "--max-preview-frames",
        type=int,
        default=0,
        help="collect Preview를 자동 종료할 Frame 수; 0이면 q까지 계속",
    )
    parser.add_argument(
        "--min-active-pixels",
        type=int,
        default=5,
        help="저장에 필요한 Event Tensor의 최소 활성 픽셀 수",
    )
    parser.add_argument(
        "--max-active-pixels",
        type=int,
        default=DEFAULT_MAXIMUM_ACTIVE_PIXELS,
        help="넓은 배경 움직임을 제외하기 위한 최대 활성 픽셀 수",
    )
    parser.add_argument(
        "--min-target-positive-pixels",
        type=int,
        default=3,
        help="Label Cell 내부에 필요한 Positive Event 최소 픽셀 수",
    )
    parser.add_argument(
        "--min-target-event-pixels",
        type=int,
        default=0,
        help="Label Cell 내부 양·음 전체 Event 최소 픽셀 수",
    )
    parser.add_argument(
        "--min-target-event-ratio",
        type=float,
        default=0.0,
        help="전체 active Event 중 Label Cell 내부 Event의 최소 비율",
    )
    parser.add_argument(
        "--require-target-positive-argmax",
        action=argparse.BooleanOptionalAction,
        default=DEFAULT_REQUIRE_TARGET_POSITIVE_ARGMAX,
        help="Positive Energy가 가장 큰 Cell과 Label Cell이 같은 Frame만 사용",
    )
    args = parser.parse_args()
    if args.min_target_event_pixels < 0:
        parser.error("--min-target-event-pixels는 0 이상이어야 합니다.")
    if not 0.0 <= args.min_target_event_ratio <= 1.0:
        parser.error("--min-target-event-ratio는 0~1이어야 합니다.")
    if args.mode in {"collect", "collect-no-target"}:
        if args.session_id is None:
            parser.error("collect 모드에는 --session-id가 필요합니다.")
        if args.capture_split is None:
            parser.error("collect 모드에는 --capture-split이 필요합니다.")
    return args


def main() -> None:
    args = parse_args()
    output_directory = args.output_dir
    if output_directory is None:
        output_directory = (
            Path("ai/no_target_samples_v03")
            if args.mode in {"collect-no-target", "no-target-check"}
            else Path("ai/dataset_samples_target_v03")
        )
    config = CameraConfig(
        device=args.device,
        width=args.width,
        height=args.height,
        fps=args.fps,
        lock_v03_controls=args.lock_v03_camera_controls,
    )

    if args.mode == "self-test":
        run_self_test()
    elif args.mode == "dataset-check":
        run_dataset_check(
            output_directory,
            minimum_active_pixels=args.min_active_pixels,
            maximum_active_pixels=args.max_active_pixels,
            samples_per_cell=args.samples_per_cell,
            minimum_target_positive_pixels=args.min_target_positive_pixels,
            require_target_positive_argmax=args.require_target_positive_argmax,
            capture_session_id=args.session_id,
            capture_split=args.capture_split,
            require_session_metadata=args.require_session_metadata,
            minimum_target_event_pixels=args.min_target_event_pixels,
            minimum_target_event_ratio=args.min_target_event_ratio,
        )
    elif args.mode == "camera":
        run_camera_preview(config, snapshot_output=args.snapshot_output)
    elif args.mode == "laser":
        run_laser_preview(
            config,
            red_minimum=args.red_min,
            red_dominance=args.red_dominance,
            saturation_minimum=args.laser_saturation_min,
            minimum_area=args.laser_min_area,
            maximum_area=args.laser_max_area,
            minimum_circularity=args.laser_min_circularity,
            minimum_local_contrast=args.laser_min_contrast,
            border_margin=args.laser_border_margin,
        )
    elif args.mode == "collect":
        run_collect_mode(
            config,
            noise_threshold=args.threshold,
            target_hue_low=args.target_hue_low,
            target_hue_high=args.target_hue_high,
            target_saturation_minimum=args.target_sat_min,
            target_value_minimum=args.target_val_min,
            minimum_area=args.target_min_area,
            maximum_area=args.target_max_area,
            output_directory=output_directory,
            auto_save=args.auto_save,
            samples_per_cell=args.samples_per_cell,
            save_cooldown_frames=args.save_cooldown_frames,
            minimum_active_pixels=args.min_active_pixels,
            maximum_active_pixels=args.max_active_pixels,
            minimum_target_positive_pixels=args.min_target_positive_pixels,
            require_target_positive_argmax=args.require_target_positive_argmax,
            capture_session_id=args.session_id,
            capture_split=args.capture_split,
            environment_note=args.environment_note,
            debug_snapshot_output=args.snapshot_output,
            maximum_preview_frames=args.max_preview_frames,
            minimum_target_event_pixels=args.min_target_event_pixels,
            minimum_target_event_ratio=args.min_target_event_ratio,
        )
    elif args.mode == "no-target-check":
        run_no_target_check(
            output_directory,
            minimum_active_pixels=args.min_active_pixels,
            maximum_active_pixels=args.max_active_pixels,
            capture_session_id=args.session_id,
            capture_split=args.capture_split,
            require_session_metadata=args.require_session_metadata,
        )
    elif args.mode == "collect-no-target":
        run_collect_no_target_mode(
            config,
            noise_threshold=args.threshold,
            target_hue_low=args.target_hue_low,
            target_hue_high=args.target_hue_high,
            target_saturation_minimum=args.target_sat_min,
            target_value_minimum=args.target_val_min,
            target_minimum_area=args.target_min_area,
            target_maximum_area=args.target_max_area,
            output_directory=output_directory,
            auto_save=args.auto_save,
            maximum_samples=args.max_samples,
            save_cooldown_frames=args.save_cooldown_frames,
            minimum_active_pixels=args.min_active_pixels,
            maximum_active_pixels=args.max_active_pixels,
            capture_session_id=args.session_id,
            capture_split=args.capture_split,
            environment_note=args.environment_note,
        )
    else:
        run_event_preview(config, noise_threshold=args.threshold)


if __name__ == "__main__":
    main()
