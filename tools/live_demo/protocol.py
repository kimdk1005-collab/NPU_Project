#!/usr/bin/env python3
"""PC <-> Zybo PS Live 전송 규격.  `sw/live_protocol.h` 와 한 쌍이다.

** 이 파일과 sw/live_protocol.h 를 따로 고치지 마라. 둘이 같은 규격이다. **
값을 바꾸면 `sw/sim/test_live_protocol.c` 의 고정 CRC 도 같이 깨진다 —
그게 두 언어가 어긋났는지 잡아주는 장치다.

Register Map 을 건드리지 않는다
--------------------------------
이 경로는 UART 로 Tensor 를 받아 PS 가 `npu_load_tensor()` 로 넣는다.
`INPUT_SRC=0` (reset 기본값) 을 쓴다.  AXI Register 는 한 비트도 안 바뀐다.
그래서 §22 CHANGE REQUEST 대상이 아니고, CR A-004 / `WINDOW_SRC=1` 과도 무관하다.

Frame 형식 (little-endian)
---------------------------
    offset  크기  필드
    0       4     magic   'N' 'P' 'U' 'L'
    4       1     version = 1
    5       1     type
    6       2     seq       u16
    8       2     length    u16  = payload byte 수
    10      N     payload
    10+N    4     crc32     u32  IEEE 802.3, type~payload 전체

TYPE_TENSOR_SPARSE payload
    0       2     count u16                 nonzero 개수
    2       3*k   (index u16, value u8) x k  index = (polarity<<12)|(y<<6)|x

    Mask 를 걸면 Tensor 가 아주 성기다 (case00 은 8192 중 43 개).
    43 개면 132 byte 라 115200 baud 에서 12 ms 다. Raw 는 711 ms.

TYPE_TENSOR_RAW payload
    8192 byte CHW 통째로.  Sparse 가 Raw 보다 커지면 자동으로 이쪽을 쓴다.
"""

from __future__ import annotations

import struct
import zlib

MAGIC = b"NPUL"
VERSION = 1

TYPE_TENSOR_SPARSE = 0x01
TYPE_TENSOR_RAW = 0x02
TYPE_PING = 0x03
TYPE_RESET = 0x04

HEADER_SIZE = 10          # magic4 + ver1 + type1 + seq2 + len2
CRC_SIZE = 4
TENSOR_BYTES = 8192
MAX_PAYLOAD = TENSOR_BYTES          # RAW 가 최대다
MAX_SPARSE_ENTRIES = (MAX_PAYLOAD - 2) // 3      # 2730

# 성긴 정도가 이 이상이면 Sparse 가 Raw 보다 커진다: 2 + 3k > 8192  ->  k > 2730
SPARSE_BREAK_EVEN = MAX_SPARSE_ENTRIES


def crc32(data: bytes) -> int:
    """IEEE 802.3 CRC-32.  C 쪽 `live_crc32()` 와 같은 값이어야 한다."""
    return zlib.crc32(data) & 0xFFFFFFFF


def encode_sparse_payload(tensor_chw: bytes) -> bytes:
    """8192 byte CHW -> sparse payload.  nonzero 가 너무 많으면 None."""
    if len(tensor_chw) != TENSOR_BYTES:
        raise ValueError(f"8192 byte 가 아니다: {len(tensor_chw)}")
    entries = [(i, v) for i, v in enumerate(tensor_chw) if v != 0]
    if len(entries) > MAX_SPARSE_ENTRIES:
        return b""
    out = bytearray(struct.pack("<H", len(entries)))
    for index, value in entries:
        out += struct.pack("<HB", index, value)
    return bytes(out)


def decode_sparse_payload(payload: bytes) -> bytes:
    """sparse payload -> 8192 byte CHW.  C 디코더와 같은 결과여야 한다."""
    if len(payload) < 2:
        raise ValueError("payload 가 너무 짧다.")
    (count,) = struct.unpack_from("<H", payload, 0)
    if len(payload) != 2 + 3 * count:
        raise ValueError(f"payload 길이 불일치: count={count} len={len(payload)}")
    tensor = bytearray(TENSOR_BYTES)
    for n in range(count):
        index, value = struct.unpack_from("<HB", payload, 2 + 3 * n)
        if index >= TENSOR_BYTES:
            raise ValueError(f"index 범위 밖: {index}")
        tensor[index] = value
    return bytes(tensor)


def build_frame(msg_type: int, seq: int, payload: bytes) -> bytes:
    """완성된 전송 Frame 을 만든다."""
    if len(payload) > MAX_PAYLOAD:
        raise ValueError(f"payload 가 너무 크다: {len(payload)}")
    body = struct.pack("<BBHH", VERSION, msg_type, seq & 0xFFFF, len(payload)) + payload
    #                      ^ver ^type ^seq  ^len
    # CRC 는 magic 을 뺀 나머지 전체 (version 부터 payload 끝까지).
    return MAGIC + body + struct.pack("<I", crc32(body))


def build_tensor_frame(tensor_chw: bytes, seq: int) -> tuple[bytes, int]:
    """Tensor 를 Sparse/Raw 중 작은 쪽으로 싸서 (frame, type) 을 준다."""
    sparse = encode_sparse_payload(tensor_chw)
    if sparse and len(sparse) < TENSOR_BYTES:
        return build_frame(TYPE_TENSOR_SPARSE, seq, sparse), TYPE_TENSOR_SPARSE
    return build_frame(TYPE_TENSOR_RAW, seq, tensor_chw), TYPE_TENSOR_RAW


def parse_frame(buffer: bytes) -> tuple[int, int, bytes]:
    """Frame -> (type, seq, payload).  검증 실패는 ValueError.

    보드 C 디코더와 같은 판정을 해야 한다. 시험은
    `sw/sim/test_live_protocol.c` 와 `tools/live_demo/test_protocol.py`.
    """
    if len(buffer) < HEADER_SIZE + CRC_SIZE:
        raise ValueError("Frame 이 너무 짧다.")
    if buffer[:4] != MAGIC:
        raise ValueError("magic 불일치")
    version, msg_type, seq, length = struct.unpack_from("<BBHH", buffer, 4)
    if version != VERSION:
        raise ValueError(f"version 불일치: {version}")
    if length > MAX_PAYLOAD:
        raise ValueError(f"length 가 너무 크다: {length}")
    if len(buffer) != HEADER_SIZE + length + CRC_SIZE:
        raise ValueError(
            f"길이 불일치: 선언 {length}, 실제 {len(buffer) - HEADER_SIZE - CRC_SIZE}"
        )
    body = buffer[4 : HEADER_SIZE + length]
    (want,) = struct.unpack_from("<I", buffer, HEADER_SIZE + length)
    got = crc32(body)
    if got != want:
        raise ValueError(f"CRC 불일치: 기대 {want:08x}, 계산 {got:08x}")
    return msg_type, seq, buffer[HEADER_SIZE : HEADER_SIZE + length]


def parse_result_line(line: str) -> dict | None:
    """보드가 돌려주는 한 줄 -> dict.

        RES seq=12 valid=1 x=36 y=28 score=43 cycle=125845 nz=43 us=1310
    """
    line = line.strip()
    if not line.startswith("RES "):
        return None
    out: dict[str, int] = {}
    for token in line[4:].split():
        if "=" not in token:
            continue
        key, _, value = token.partition("=")
        try:
            out[key] = int(value)
        except ValueError:
            continue
    return out or None
