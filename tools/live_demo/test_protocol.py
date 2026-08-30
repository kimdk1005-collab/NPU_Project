#!/usr/bin/env python3
"""Live 전송 규격 Python 측 시험.  보드도 카메라도 opencv 도 필요 없다.

    python3 tools/live_demo/test_protocol.py

여기 박힌 Frame 바이트열은 `sw/sim/test_live_protocol.c` 에 있는 것과
**같은 값**이다.  한쪽만 고치면 다른 쪽이 깨진다 — 그게 목적이다.
"""

from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import protocol as P                                          # noqa: E402
from event_tensor import (                                    # noqa: E402
    TENSOR_BYTES,
    chw_bytes_to_tensor,
    load_hex_tensor,
    tensor_stats,
    tensor_to_chw_bytes,
)

CHECKS = 0
FAILS = 0


def ok(cond: bool, what: str, detail: str = "") -> None:
    global CHECKS, FAILS
    CHECKS += 1
    if cond:
        print(f"  [OK]   {what}{('  ' + detail) if detail else ''}")
    else:
        FAILS += 1
        print(f"  [FAIL] {what}{('  ' + detail) if detail else ''}")


def _brief(value, limit: int = 60) -> str:
    """긴 bytes/list 는 잘라서 보여준다. 8192 byte Tensor 를 그대로 찍지 않는다."""
    text = repr(value)
    if len(text) > limit:
        return f"{text[:limit]}... ({len(value)} 개)" if hasattr(value, "__len__") \
            else f"{text[:limit]}..."
    return text


def eq(got, want, what: str) -> None:
    ok(got == want, what,
       _brief(got) if got == want else f"{_brief(got)}  (기대 {_brief(want)})")


# sw/sim/test_live_protocol.c 의 FRAME_PING 과 같아야 한다
FRAME_PING = bytes.fromhex("4e50554c0103070000006f30e9a0")
# sw/sim/test_live_protocol.c 의 FRAME_SPARSE3 과 같아야 한다
FRAME_SPARSE3 = bytes.fromhex(
    "4e50554c010134120b000300000001ff0f7fff1fc82cb9cf4a"
)


def main() -> int:
    print("=====================================================")
    print(" Live 전송 규격 시험  (protocol.py <-> live_protocol.h)")
    print("=====================================================")

    print("\n[1] CRC-32 가 표준(IEEE 802.3 / zlib) 인가")
    eq(f"{P.crc32(b'123456789'):08x}", "cbf43926", 'crc32("123456789") 표준 검사값')
    eq(f"{P.crc32(b''):08x}", "00000000", 'crc32("")')
    eq(f"{P.crc32(b'NPUL'):08x}", "8e957a08", 'crc32("NPUL")')

    print("\n[2] 규격 상수")
    eq(P.HEADER_SIZE, 10, "HEADER_SIZE")
    eq(P.CRC_SIZE, 4, "CRC_SIZE")
    eq(P.TENSOR_BYTES, 8192, "TENSOR_BYTES")
    eq(P.MAX_SPARSE_ENTRIES, 2730, "MAX_SPARSE_ENTRIES")
    eq(P.VERSION, 1, "VERSION")

    print("\n[3] C 시험파일에 박힌 PING Frame 과 바이트가 같은가")
    built = P.build_frame(P.TYPE_PING, 7, b"")
    eq(built.hex(), FRAME_PING.hex(), "build_frame(PING, 7) 바이트열")
    t, s, pl = P.parse_frame(FRAME_PING)
    eq((t, s, pl), (P.TYPE_PING, 7, b""), "parse_frame(PING)")

    print("\n[4] C 시험파일에 박힌 sparse Frame 과 바이트가 같은가")
    tensor = bytearray(TENSOR_BYTES)
    tensor[0], tensor[4095], tensor[8191] = 1, 127, 200
    payload = P.encode_sparse_payload(bytes(tensor))
    built = P.build_frame(P.TYPE_TENSOR_SPARSE, 0x1234, payload)
    eq(built.hex(), FRAME_SPARSE3.hex(), "build_frame(SPARSE, 0x1234) 바이트열")
    t, s, pl = P.parse_frame(FRAME_SPARSE3)
    eq(t, P.TYPE_TENSOR_SPARSE, "  type")
    eq(s, 0x1234, "  seq")
    eq(len(pl), 11, "  length")
    eq(P.decode_sparse_payload(pl), bytes(tensor), "  decode 결과가 원본과 같다")

    print("\n[5] 망가진 Frame 을 거부하나  (시험 3 의 근거)")
    for mode, expect in (
        ("crc", "CRC"),
        ("payload", "CRC"),
        ("magic", "magic"),
        ("version", "version"),
        ("len", "length"),     # C 쪽은 LIVE_ERR_LENGTH 로 같은 판정을 한다
    ):
        from camera_sender import corrupt_frame

        bad = corrupt_frame(FRAME_SPARSE3, mode)
        try:
            P.parse_frame(bad)
            ok(False, f"--corrupt {mode} 를 거부", "통과해버렸다")
        except ValueError as exc:
            ok(expect in str(exc) or "불일치" in str(exc),
               f"--corrupt {mode} 를 거부", str(exc))

    try:
        P.parse_frame(FRAME_SPARSE3[:-1])
        ok(False, "1 byte 잘린 Frame 을 거부", "통과해버렸다")
    except ValueError as exc:
        ok(True, "1 byte 잘린 Frame 을 거부", str(exc))

    print("\n[6] sparse payload 안쪽 방어")
    for bad, why in (
        (bytes([0x02, 0x00, 0x00, 0x00, 0x01]), "count 와 length 불일치"),
        (bytes([0x01, 0x00, 0x00, 0x20, 0x7F]), "index 8192 (범위 밖)"),
    ):
        try:
            P.decode_sparse_payload(bad)
            ok(False, f"{why} 를 거부", "통과해버렸다")
        except ValueError as exc:
            ok(True, f"{why} 를 거부", str(exc))

    edge = P.decode_sparse_payload(bytes([0x01, 0x00, 0xFF, 0x1F, 0x7F]))
    eq(edge[8191], 127, "index 8191 (마지막 유효) 은 통과")

    print("\n[7] CHW 왕복 + 실물 Golden 3 케이스")
    for case in ("case00", "case01", "case02"):
        path = ROOT / "test_vectors" / case / "input_event.hex"
        raw = load_hex_tensor(str(path))
        eq(len(raw), 8192, f"{case} 8192 byte")
        hwc = chw_bytes_to_tensor(raw)
        ok(tensor_to_chw_bytes(hwc) == raw, f"{case} CHW <-> HWC 왕복 무손실")

        sparse = P.encode_sparse_payload(raw)
        if sparse:
            ok(P.decode_sparse_payload(sparse) == raw, f"{case} sparse 왕복 무손실")
        frame, ftype = P.build_tensor_frame(raw, 1)
        t, s, pl = P.parse_frame(frame)
        eq(t, ftype, f"{case} build -> parse type 일치")
        got = P.decode_sparse_payload(pl) if t == P.TYPE_TENSOR_SPARSE else pl
        ok(got == raw, f"{case} Frame 왕복 무손실")

        st = tensor_stats(raw)
        kind = "sparse" if ftype == P.TYPE_TENSOR_SPARSE else "raw"
        ms = len(frame) * 10 / 115200 * 1000
        print(f"         {case}: nonzero {st['nonzero']:>4}  {kind:>6}  "
              f"{len(frame):>5} byte  115200 baud 에서 {ms:.1f} ms")

    print("\n[8] 결과 줄 파싱")
    parsed = P.parse_result_line(
        "RES seq=12 valid=1 x=36 y=28 score=43 cycle=125845 nz=43"
    )
    eq(parsed, {"seq": 12, "valid": 1, "x": 36, "y": 28,
                "score": 43, "cycle": 125845, "nz": 43}, "parse_result_line")
    eq(P.parse_result_line("READY"), None, "RES 가 아닌 줄은 None")

    print("\n=====================================================")
    print(f" 결과: {'PASS' if FAILS == 0 else 'FAIL'}   "
          f"({CHECKS} check, 실패 {FAILS}건)")
    print("=====================================================")
    return 0 if FAILS == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
