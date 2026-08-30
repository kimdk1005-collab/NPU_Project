#!/usr/bin/env python3
"""color_masked_event_v02_radius1 런타임 재현 — PS/PC Live 경로용.

역할
----
B `model_v04_demo_masked_radius1_x1` 은 학습·검증·런타임에서 **같은** 전처리를
쓰도록 고정돼 있다 (`color_masked_event_v02_radius1.json` →
`constraints.identical_logic_for_train_validation_runtime = true`).
이 모듈은 그 전처리를 Live 경로에서 재현한다.

출처 구분 — 이게 이 파일에서 제일 중요하다
-------------------------------------------
B 최종 ZIP (`b_deliver_v04_demo_masked_radius1_x1_final.zip`, SHA
`1f3034c1…a4b210`) 의 `preprocess/color_masked_event.py` 원본 사본은
`_b_original_color_masked_event.py.ref` 로 같이 뒀다 (SHA `c02d6993…f0c2`).

| 구간 | 출처 |
|---|---|
| `build_mask()` step_1~step_3 본체 | **B 원본 그대로 옮김** |
| `apply_mask()` | **B 원본 그대로 옮김** |
| `ColorGateConfig` / `validate_config` / `hsv_gate_mask` | **A 재구성** |

B 원본 `build_mask()` 는 `color_presence_gate.detect_target_presence_detailed()`
를 부르는데 **그 모듈은 최종 ZIP 에 들어 있지 않다.** 그래서 A 가 고정 Config
(`hsv_gate` 9 개 값) 로 같은 일을 하는 `hsv_gate_mask()` 를 다시 만들었다.

  ** 이 한 함수만 A 재구성이다. B 원본과 bit-exact 라는 증거는 없다. **

다만 B 원본 `build_mask()` 가 `hsv_mask` 를 받은 뒤 findContours → 면적 필터 →
최대 blob → drawContours(FILLED) 를 **자기가 다시 하므로**, 재구성 오차는
"HSV inRange + morphology OPEN/CLOSE 결과가 같은가" 하나로 좁혀진다.
`detail.present` 도 `build_mask()` 가 `candidates` 로 다시 판정하므로 영향 없다.

근거·한계: `docs/RUNTIME_COLOR_MASK_BLOCKER.md`
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

CONFIG_PATH = Path(__file__).resolve().parent / "color_masked_event_v02_radius1.json"

TENSOR_SHAPE = (64, 64, 2)
MASK_SHAPE = (64, 64)


# =====================================================================
# [A 재구성]  B 의 color_presence_gate 모듈이 최종 ZIP 에 없어서 다시 만든 부분
# =====================================================================
@dataclass(frozen=True)
class ColorGateConfig:
    """`color_masked_event_v02_radius1.json` 의 `hsv_gate` 9 개 값.

    B 원본 `ColorGateConfig` 와 필드 이름을 일부러 똑같이 맞췄다.
    B 가 나중에 `color_presence_gate.py` 를 주면 이 클래스만 갈아끼우면 된다.
    """

    hue_low: int
    hue_high: int
    saturation_minimum: int
    value_minimum: int
    minimum_area: float
    maximum_area: float
    morphology_kernel_size: int
    morphology_open_iterations: int
    morphology_close_iterations: int


def validate_config(gate: ColorGateConfig) -> None:
    """Config 범위 검사. OpenCV Hue 는 0~179 다 (0~359 아님)."""
    if not (0 <= gate.hue_low <= gate.hue_high <= 179):
        raise ValueError(f"hue 범위가 잘못됐다: {gate.hue_low}~{gate.hue_high} (0~179)")
    if not (0 <= gate.saturation_minimum <= 255):
        raise ValueError(f"saturation_minimum 범위 밖: {gate.saturation_minimum}")
    if not (0 <= gate.value_minimum <= 255):
        raise ValueError(f"value_minimum 범위 밖: {gate.value_minimum}")
    if not (0.0 <= gate.minimum_area <= gate.maximum_area):
        raise ValueError(f"area 범위가 잘못됐다: {gate.minimum_area}~{gate.maximum_area}")
    if gate.morphology_kernel_size < 1 or gate.morphology_kernel_size % 2 == 0:
        raise ValueError(f"morphology_kernel_size 는 홀수여야 한다: {gate.morphology_kernel_size}")
    if gate.morphology_open_iterations < 0 or gate.morphology_close_iterations < 0:
        raise ValueError("morphology iteration 은 0 이상이어야 한다.")


def hsv_gate_mask(frame_bgr: np.ndarray, gate: ColorGateConfig) -> np.ndarray:
    """[A 재구성] BGR Frame -> 0/255 uint8 HSV Gate Mask (morphology 적용 후).

    B 원본 `detect_target_presence_detailed()` 가 돌려주던 `hsv_mask` 자리다.
    ** 이 함수가 A 재구성의 전부다. 나머지는 전부 B 원본이다. **
    """
    hsv = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2HSV)
    mask = cv2.inRange(
        hsv,
        (gate.hue_low, gate.saturation_minimum, gate.value_minimum),
        (gate.hue_high, 255, 255),
    )
    k = gate.morphology_kernel_size
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (k, k))
    if gate.morphology_open_iterations > 0:
        mask = cv2.morphologyEx(
            mask, cv2.MORPH_OPEN, kernel, iterations=gate.morphology_open_iterations
        )
    if gate.morphology_close_iterations > 0:
        mask = cv2.morphologyEx(
            mask, cv2.MORPH_CLOSE, kernel, iterations=gate.morphology_close_iterations
        )
    return mask


# =====================================================================
# [B 원본]  _b_original_color_masked_event.py.ref 의 build_mask / apply_mask
#           step 주석까지 그대로 옮겼다. 로직을 고치지 마라.
# =====================================================================
def build_mask(frame_bgr: np.ndarray, gate: ColorGateConfig, radius: int) -> np.ndarray:
    """Current Color Frame에서 64x64 bool Mask를 만든다. Ground Truth를 쓰지 않는다.

    `mask_pipeline` 순서를 그대로 따른다.
    표적을 찾지 못하면 예외 없이 전부 False인 Mask를 반환한다.
    """
    validate_config(gate)
    if radius < 0:
        raise ValueError("dilation radius는 0 이상이어야 합니다.")
    if frame_bgr is None or frame_bgr.ndim != 3 or frame_bgr.shape[2] != 3:
        raise ValueError("Mask 생성에는 BGR HxWx3 Frame이 필요합니다.")

    empty = np.zeros(MASK_SHAPE, dtype=bool)

    # step_1: Color Gate 로직으로 표적 Blob Mask(0/255)를 만든다.
    #         [A 재구성] B 는 detect_target_presence_detailed() 를 썼다.
    hsv_mask = hsv_gate_mask(frame_bgr, gate)
    contours, _ = cv2.findContours(hsv_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    candidates = [
        contour
        for contour in contours
        if gate.minimum_area <= float(cv2.contourArea(contour)) <= gate.maximum_area
    ]
    if not candidates:
        return empty
    best = max(candidates, key=cv2.contourArea)
    blob_mask = np.zeros(hsv_mask.shape, dtype=np.uint8)
    cv2.drawContours(blob_mask, [best], -1, 255, thickness=cv2.FILLED)

    # step_2: 64x64 축소 후 >0 이면 True.
    small = cv2.resize(blob_mask, (MASK_SHAPE[1], MASK_SHAPE[0]), interpolation=cv2.INTER_AREA)
    mask = small > 0
    if not mask.any():
        return empty

    # step_3: 64x64 좌표계에서 반경 radius로 팽창.
    if radius > 0:
        kernel = cv2.getStructuringElement(
            cv2.MORPH_ELLIPSE, (2 * radius + 1, 2 * radius + 1)
        )
        mask = cv2.dilate(mask.astype(np.uint8), kernel, iterations=1) > 0

    return mask.astype(bool)


def apply_mask(tensor_hwc: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """64x64x2 Tensor에서 Mask 밖을 0으로 만든다. dtype과 shape은 그대로 유지."""
    if tensor_hwc.shape != TENSOR_SHAPE:
        raise ValueError(f"Tensor shape이 {TENSOR_SHAPE}이 아닙니다: {tensor_hwc.shape}")
    mask_bool = np.asarray(mask).astype(bool)
    if mask_bool.shape != MASK_SHAPE:
        raise ValueError(f"Mask shape이 {MASK_SHAPE}이 아닙니다: {mask_bool.shape}")
    masked = tensor_hwc.copy()
    masked[~mask_bool] = 0
    return masked


# =====================================================================
# Config 로더
# =====================================================================
def load_config(path: Path | str = CONFIG_PATH) -> dict:
    """B 가 동결한 Config 를 읽고 최소 계약을 검사한다."""
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    config_id = payload.get("config_id")
    if not isinstance(config_id, str) or not config_id.startswith("color_masked_event_v"):
        raise ValueError(f"유효하지 않은 color mask config_id입니다: {config_id}")
    if not payload.get("frozen_before_any_result"):
        raise ValueError("확정되지 않은 Config입니다.")
    return payload


def gate_from_config(payload: dict) -> ColorGateConfig:
    """Config 의 `hsv_gate` 로 ColorGateConfig 를 만든다.

    B 원본은 촬영 Session 의 `session.json.color_gate_candidate` 에서 읽었다.
    Live 경로에는 session.json 이 없으므로 동결 Config 의 같은 9 개 값을 쓴다.
    두 값은 Config 의 `hsv_gate.source` 주석대로 같은 것이다.
    """
    g = payload["hsv_gate"]
    gate = ColorGateConfig(
        hue_low=int(g["hue_low"]),
        hue_high=int(g["hue_high"]),
        saturation_minimum=int(g["saturation_minimum"]),
        value_minimum=int(g["value_minimum"]),
        minimum_area=float(g["minimum_area"]),
        maximum_area=float(g["maximum_area"]),
        morphology_kernel_size=int(g["morphology_kernel_size"]),
        morphology_open_iterations=int(g["morphology_open_iterations"]),
        morphology_close_iterations=int(g["morphology_close_iterations"]),
    )
    validate_config(gate)
    return gate


def radius_from_config(payload: dict) -> int:
    return int(payload["mask_pipeline"]["dilation_radius_px"])
