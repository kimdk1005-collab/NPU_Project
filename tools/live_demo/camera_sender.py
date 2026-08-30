#!/usr/bin/env python3
"""PC 카메라 -> Color Mask -> Event Tensor -> UART -> Zybo NPU.

보드측 짝은 `sw/live_tracker.c` 다 (`live_tracker.elf`).
** 보드 자체시험 `npu_test.elf` 와 다른 프로그램이다. 섞지 마라. **

경로
-----
    Camera previous/current Color Frame
      -> HSV Blue Gate + 최대 blob (B color_masked_event_v02_radius1)
      -> 64x64 축소 + radius-1 팽창 Mask
      -> Positive/Negative Event Tensor 생성        [A 재구성]
      -> Mask 밖 Event 0                            [B 원본]
      -> CHW signed INT8 8192 byte
      -> UART Frame (sparse/raw + CRC32)
      -> live_tracker -> npu_load_tensor -> NPU
      -> x / y / score / valid
      -> (RTL 안에서) C Tracking / Servo / Laser

시험 순서 — 이 순서로 올라가라
--------------------------------
    1  ./camera_sender.py --replay-hex ../../test_vectors/case00/input_event.hex
                                                -> valid=1 x=36 y=28 score=43
    2  ./camera_sender.py --zero                -> valid=0
    3  ./camera_sender.py --corrupt crc         -> ERR crc  (보드가 거부해야 정상)
       ./camera_sender.py --corrupt len         -> ERR len
       ./camera_sender.py --corrupt magic       -> 조용히 재동기화 (응답 없음이 정상)
    4  ./camera_sender.py --camera 0            -> 레이저 미연결/SW1 DOWN 상태로
    5~8 은 실물 서보/레이저가 붙은 뒤. runbook 을 봐라.

1~3 은 카메라도 opencv 도 필요 없다.  4 부터 opencv-python 이 필요하다.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import protocol                                    # noqa: E402
from event_tensor import (                         # noqa: E402
    TENSOR_BYTES,
    chw_bytes_to_tensor,
    load_hex_tensor,
    tensor_stats,
    tensor_to_chw_bytes,
)


# =====================================================================
# UART
# =====================================================================
class BoardLink:
    """UART 한 개를 잡고 Frame 을 보내고 응답 줄을 읽는다."""

    def __init__(self, port: str, baud: int, timeout: float = 3.0):
        import serial                               # 여기서만 필요하다

        self.serial = serial.Serial(port, baud, timeout=0.2)
        self.timeout = timeout
        time.sleep(0.2)
        self.serial.reset_input_buffer()

    def send(self, frame: bytes) -> None:
        self.serial.write(frame)
        self.serial.flush()

    def read_reply(self) -> list[str]:
        """RES / PONG / RESET / ERR 한 줄이 나올 때까지 읽는다."""
        lines: list[str] = []
        deadline = time.time() + self.timeout
        buffer = b""
        while time.time() < deadline:
            chunk = self.serial.read(256)
            if chunk:
                buffer += chunk
                while b"\n" in buffer:
                    raw, _, buffer = buffer.partition(b"\n")
                    text = raw.decode("utf-8", "replace").strip()
                    if text:
                        lines.append(text)
                    if text.startswith(("RES ", "PONG ", "RESET ", "ERR ")):
                        return lines
        return lines

    def close(self) -> None:
        self.serial.close()


# =====================================================================
# Tensor 소스
# =====================================================================
def tensor_from_hex(path: str) -> bytes:
    return load_hex_tensor(path)


def tensor_zero() -> bytes:
    return bytes(TENSOR_BYTES)


def open_camera(index: int, width: int, height: int):
    import cv2

    cap = cv2.VideoCapture(index)
    if not cap.isOpened():
        raise RuntimeError(f"카메라를 못 열었다: index={index}")
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    return cap


def camera_tensors(cap, diff_threshold: int, verbose: bool):
    """카메라에서 (masked_chw_bytes, mask_pixels, gate_hit) 을 계속 뽑는다."""
    import color_mask
    from event_tensor import build_event_tensor

    config = color_mask.load_config()
    gate = color_mask.gate_from_config(config)
    radius = color_mask.radius_from_config(config)
    if verbose:
        print(f"  config_id = {config['config_id']}  radius = {radius}")
        print(
            f"  HSV gate  = hue {gate.hue_low}~{gate.hue_high} "
            f"sat>={gate.saturation_minimum} val>={gate.value_minimum} "
            f"area {gate.minimum_area}~{gate.maximum_area}"
        )

    previous = None
    while True:
        ok, frame = cap.read()
        if not ok:
            raise RuntimeError("카메라 Frame 을 못 읽었다.")
        if previous is None:
            previous = frame
            continue

        # [A 재구성] previous/current -> 64x64x2
        tensor = build_event_tensor(previous, frame, diff_threshold)
        # [B 원본] Current Frame 으로 Mask 를 만들고 밖을 0 으로
        mask = color_mask.build_mask(frame, gate, radius)
        masked = color_mask.apply_mask(tensor, mask)

        previous = frame
        yield tensor_to_chw_bytes(masked), int(mask.sum()), bool(mask.any())


# =====================================================================
# 손상 Frame (시험 3)
# =====================================================================
def corrupt_frame(frame: bytes, mode: str) -> bytes:
    data = bytearray(frame)
    if mode == "crc":
        data[-1] ^= 0xFF                       # CRC 마지막 byte 뒤집기
    elif mode == "payload":
        if len(data) > protocol.HEADER_SIZE:
            data[protocol.HEADER_SIZE] ^= 0xFF  # payload 1 byte -> CRC 불일치
    elif mode == "len":
        data[8] = 0xFF
        data[9] = 0xFF                          # length = 65535 > 8192
    elif mode == "magic":
        data[0] = ord("X")
    elif mode == "version":
        data[4] = 0x7F
    else:
        raise ValueError(f"모르는 corrupt 모드: {mode}")
    return bytes(data)


# =====================================================================
# main
# =====================================================================
def main() -> int:
    p = argparse.ArgumentParser(
        description="Live Event Tensor 송신기 (PC -> Zybo)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--replay-hex", metavar="PATH",
                     help="test_vectors/*/input_event.hex 를 그대로 보낸다 (시험 1)")
    src.add_argument("--zero", action="store_true",
                     help="전 0 Tensor 를 보낸다. valid=0 이 나와야 한다 (시험 2)")
    src.add_argument("--camera", type=int, metavar="INDEX",
                     help="카메라 실시간 (시험 4~). opencv-python 필요")
    src.add_argument("--ping", action="store_true", help="보드 상태만 물어본다")

    p.add_argument("--port", default="/dev/ttyUSB1", help="기본 /dev/ttyUSB1")
    p.add_argument("--baud", type=int, default=115200, help="기본 115200")
    p.add_argument("--frames", type=int, default=1,
                   help="보낼 Frame 수. 0 이면 무한 (카메라 기본값)")
    p.add_argument("--interval", type=float, default=0.0, help="Frame 간 초")
    p.add_argument("--diff-threshold", type=int, default=12,
                   help="Event 임계 (A 재구성 값. event_tensor.py 주석 참고)")
    p.add_argument("--width", type=int, default=640)
    p.add_argument("--height", type=int, default=480)
    p.add_argument("--corrupt", choices=["crc", "payload", "len", "magic", "version"],
                   help="일부러 망가뜨려 보낸다 (시험 3). 보드가 거부해야 정상")
    p.add_argument("--raw", action="store_true", help="sparse 대신 raw 8192 byte 강제")
    p.add_argument("--dry-run", action="store_true",
                   help="UART 를 안 열고 Frame 통계만 찍는다. 보드 없이 확인용")
    args = p.parse_args()

    # ---------------- Frame 만들기 ----------------
    seq = 0
    link = None
    if not args.dry_run:
        try:
            link = BoardLink(args.port, args.baud)
        except Exception as exc:                    # noqa: BLE001
            print(f"[FAIL] UART 를 못 열었다: {exc}")
            print(f"       포트 확인:  ls -l {args.port} ;  fuser -v {args.port}")
            print("       보드 없이 확인만 할 거면 --dry-run")
            return 2

    def ship(frame: bytes, note: str) -> None:
        nonlocal seq
        if args.corrupt:
            frame = corrupt_frame(frame, args.corrupt)
            note += f"  [corrupt={args.corrupt}]"
        print(f"  -> seq={seq:<5} {len(frame):>5} byte  {note}")
        if link is None:
            return
        link.send(frame)
        for line in link.read_reply():
            print(f"     {line}")

    def make(tensor_chw: bytes) -> bytes:
        if args.raw:
            return protocol.build_frame(protocol.TYPE_TENSOR_RAW, seq, tensor_chw)
        frame, _ = protocol.build_tensor_frame(tensor_chw, seq)
        return frame

    try:
        if args.ping:
            ship(protocol.build_frame(protocol.TYPE_PING, seq, b""), "PING")
            return 0

        if args.replay_hex or args.zero:
            tensor = tensor_zero() if args.zero else tensor_from_hex(args.replay_hex)
            stats = tensor_stats(tensor)
            label = "zero" if args.zero else Path(args.replay_hex).parent.name
            print(f"[Tensor] {label}  nonzero={stats['nonzero']} "
                  f"max={stats['max']} (CH0 {stats['positive_nonzero']} / "
                  f"CH1 {stats['negative_nonzero']})")
            count = max(1, args.frames)
            for _ in range(count):
                ship(make(tensor), label)
                seq = (seq + 1) & 0xFFFF
                if args.interval:
                    time.sleep(args.interval)
            return 0

        # ---------------- 카메라 ----------------
        try:
            cap = open_camera(args.camera, args.width, args.height)
        except ImportError:
            print("[FAIL] opencv-python 이 없다.  pip install opencv-python")
            return 2
        except Exception as exc:                    # noqa: BLE001
            print(f"[FAIL] {exc}")
            return 2

        print(f"[Camera] index={args.camera} {args.width}x{args.height} "
              f"diff_threshold={args.diff_threshold}")
        print("  ** SW1(laser_arm_hw) DOWN, 레이저 미연결 상태에서 먼저 돌려라 **")
        limit = args.frames if args.frames > 0 else -1
        sent = 0
        try:
            for tensor_chw, mask_px, hit in camera_tensors(
                cap, args.diff_threshold, verbose=(sent == 0)
            ):
                stats = tensor_stats(tensor_chw)
                note = (f"mask={mask_px:>4}px  nonzero={stats['nonzero']:>4}  "
                        f"max={stats['max']:>3}" + ("" if hit else "  [표적 없음]"))
                ship(make(tensor_chw), note)
                seq = (seq + 1) & 0xFFFF
                sent += 1
                if limit > 0 and sent >= limit:
                    break
                if args.interval:
                    time.sleep(args.interval)
        except KeyboardInterrupt:
            print("\n중단.")
        finally:
            cap.release()
        return 0
    finally:
        if link is not None:
            link.close()


if __name__ == "__main__":
    raise SystemExit(main())
