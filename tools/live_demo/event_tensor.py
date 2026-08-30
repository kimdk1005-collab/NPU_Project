#!/usr/bin/env python3
"""Color Frame 2 장 -> 64x64x2 Event Tensor.  ** 전부 A 재구성이다. **

왜 재구성인가
--------------
B 최종 ZIP 에는 Mask 적용기(`color_masked_event.py`)만 들어 있고,
**Tensor 를 처음 만드는 코드(`build_v06_dataset.py`)는 들어 있지 않다.**
B 최종 납품서 `B_TO_A_V06_E4_FINAL_DELIVERY_001.md` §4 의 패키지 목록에도 없다.
`apply_mask()` 는 이미 만들어진 Tensor 를 받아 Mask 밖을 0 으로 만들 뿐이다.

그래서 이 파일은 **A 가 규격과 실측 Golden 으로부터 역산한 재구성**이다.
B 원본과 bit-exact 라는 증거는 없다. `docs/RUNTIME_COLOR_MASK_BLOCKER.md` 참고.

규격 근거 (`docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md` §7.1 · §7.4)
------------------------------------------------------------------
    Shape      64 x 64 x 2
    Channel 0  Positive Event Count
    Channel 1  Negative Event Count
    주소식     addr = (polarity << 12) | (y << 6) | x        (CHW)
    값         signed INT8, 실제 범위 0~127

Binning 을 이렇게 잡은 근거 — `test_vectors/case00/input_event.hex` 실측
--------------------------------------------------------------------------
    nonzero 43 개, 값 범위 12~56, 최댓값 56
    CH0 nonzero 좌표 x 33~36 / y 19~27,  CH1 x 35~38 / y 20~28

    640x480 을 64x64 로 나누면 한 칸이 10 x 7.5 픽셀 = 최대 75~80 개.
    실측 최댓값 56 이 그 안에 들어온다.  칸당 카운트 방식과 맞는다.
    (64x64 로 먼저 축소한 뒤 세는 방식이면 칸당 최댓값이 1 이라 안 맞는다.)

    ** 이건 정황 근거지 증명이 아니다. threshold 값은 역산이 불가능하다. **
    그래서 `--diff-threshold` 로 뺐고 `--calibrate` 로 case00 통계와 맞춰볼 수
    있게 했다.  Golden 재현이 목적이면 `camera_sender.py --replay-hex` 를 써라 —
    그 경로는 이 파일을 아예 타지 않는다.
"""

from __future__ import annotations

import numpy as np

try:
    import cv2
except ImportError:  # pragma: no cover - calibrate/replay 경로는 cv2 없이도 돈다
    cv2 = None

TENSOR_H = 64
TENSOR_W = 64
TENSOR_C = 2
TENSOR_BYTES = TENSOR_C * TENSOR_H * TENSOR_W  # 8192

DEFAULT_DIFF_THRESHOLD = 12


def build_event_tensor(
    previous_bgr: np.ndarray,
    current_bgr: np.ndarray,
    diff_threshold: int = DEFAULT_DIFF_THRESHOLD,
) -> np.ndarray:
    """이전/현재 Color Frame -> (64, 64, 2) uint8 Event Tensor.

    반환 shape 은 B `apply_mask()` 가 요구하는 HWC (64, 64, 2) 다.
    """
    if cv2 is None:
        raise RuntimeError("build_event_tensor 에는 opencv-python 이 필요하다.")
    if previous_bgr.shape != current_bgr.shape:
        raise ValueError(
            f"두 Frame 의 크기가 다르다: {previous_bgr.shape} vs {current_bgr.shape}"
        )
    if diff_threshold < 1:
        raise ValueError("diff_threshold 는 1 이상이어야 한다.")

    prev_gray = cv2.cvtColor(previous_bgr, cv2.COLOR_BGR2GRAY).astype(np.int16)
    cur_gray = cv2.cvtColor(current_bgr, cv2.COLOR_BGR2GRAY).astype(np.int16)
    diff = cur_gray - prev_gray

    positive = diff >= diff_threshold
    negative = diff <= -diff_threshold

    height, width = diff.shape
    # 원본 좌표 -> 64x64 칸.  640x480 이면 칸당 10 x 7.5 픽셀이다.
    ys = (np.arange(height) * TENSOR_H) // height
    xs = (np.arange(width) * TENSOR_W) // width
    flat_index = (ys[:, None] * TENSOR_W + xs[None, :]).ravel()

    tensor = np.zeros((TENSOR_H, TENSOR_W, TENSOR_C), dtype=np.uint8)
    for channel, hit in ((0, positive), (1, negative)):
        counts = np.bincount(
            flat_index[hit.ravel()], minlength=TENSOR_H * TENSOR_W
        )
        # signed INT8 계약이라 127 에서 자른다 (§7.1 실제값 0~127).
        np.clip(counts, 0, 127, out=counts)
        tensor[:, :, channel] = counts.reshape(TENSOR_H, TENSOR_W).astype(np.uint8)
    return tensor


def tensor_to_chw_bytes(tensor_hwc: np.ndarray) -> bytes:
    """(64, 64, 2) HWC -> 8192 byte CHW.  addr = (polarity<<12)|(y<<6)|x."""
    if tensor_hwc.shape != (TENSOR_H, TENSOR_W, TENSOR_C):
        raise ValueError(f"shape 이 (64, 64, 2) 가 아니다: {tensor_hwc.shape}")
    chw = np.transpose(tensor_hwc, (2, 0, 1))          # (C, H, W)
    return chw.astype(np.uint8).tobytes(order="C")


def chw_bytes_to_tensor(payload: bytes) -> np.ndarray:
    """8192 byte CHW -> (64, 64, 2) HWC.  위 함수의 역이다."""
    if len(payload) != TENSOR_BYTES:
        raise ValueError(f"8192 byte 가 아니다: {len(payload)}")
    chw = np.frombuffer(payload, dtype=np.uint8).reshape(TENSOR_C, TENSOR_H, TENSOR_W)
    return np.transpose(chw, (1, 2, 0)).copy()


def load_hex_tensor(path: str) -> bytes:
    """`test_vectors/*/input_event.hex` (한 줄에 1 byte, 16 진) -> 8192 byte."""
    values = bytearray()
    with open(path, "r", encoding="utf-8") as stream:
        for line in stream:
            line = line.strip()
            if line:
                values.append(int(line, 16))
    if len(values) != TENSOR_BYTES:
        raise ValueError(f"{path}: 8192 줄이 아니다 ({len(values)})")
    return bytes(values)


def tensor_stats(payload: bytes) -> dict:
    """Tensor 통계.  `--calibrate` 로 case00 과 비교할 때 쓴다."""
    values = np.frombuffer(payload, dtype=np.uint8)
    nonzero = values[values > 0]
    return {
        "nonzero": int(nonzero.size),
        "max": int(values.max()) if values.size else 0,
        "mean_nonzero": float(nonzero.mean()) if nonzero.size else 0.0,
        "positive_nonzero": int((values[: TENSOR_BYTES // 2] > 0).sum()),
        "negative_nonzero": int((values[TENSOR_BYTES // 2 :] > 0).sum()),
    }
