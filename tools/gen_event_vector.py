#!/usr/bin/env python3
"""
Event Test Vector 생성기  (표준 라이브러리만 사용, numpy 불필요)

이벤트 카메라 실물이 없어도 Event Adapter / Accumulator RTL을 개발·검증할 수 있도록
가상의 이동 표적에서 (x, y, polarity, timestamp) 이벤트 스트림을 생성한다.

개발계획서 §4.2가 정의한 4가지 입력원 중 3번(PC 생성 Test Vector)에 해당한다.
실물 카메라를 붙일 때 Adapter 입력만 바뀌고 NPU 쪽은 그대로 유지된다.

출력:
  events.csv        x, y, polarity, t_us        (원본 센서 좌표)
                    polarity 0 = Positive(Ch0) / 1 = Negative(Ch1)
  labels.csv        window_id, t_start_us, t_end_us, cx, cy, n_events   (64x64 좌표 정답)
  tensor_wNNN.hex   Window별 64x64x2 INT8 Tensor  ($readmemh 용)

사용 예:
  python3 tools/gen_event_vector.py
  python3 tools/gen_event_vector.py --sensor 346x260 --traj circle --windows 40

주의:
  기본 출력 경로는 sim/event_vectors/ 다. C 의 로컬 개발용 자극(stimulus)이며
  팀 공식 Test Vector 가 아니다. test_vectors/ 와 golden_outputs/ 는
  TEAM_COMMON_AI_INTEGRATION_SPEC v1.2 §5.2 에 따라 B 소유이므로 여기서 쓰지 않는다.
"""

import argparse
import math
import os
import random

TENSOR_W = 64
TENSOR_H = 64

# Polarity 인코딩 -- docs/D3_FREEZE_REQUEST_A_001.md 및 C 회신 CR C-004
#   ext_addr = (polarity << 12) | (y << 6) | x   이므로
#   polarity 값이 곧 Channel 번호다.
#   SPEC §7.1 : Channel 0 = Positive, Channel 1 = Negative
POL_POS = 0        # 밝아짐 -> Positive -> Channel 0 -> addr 0    ~ 4095
POL_NEG = 1        # 어두워짐 -> Negative -> Channel 1 -> addr 4096 ~ 8191


# --------------------------------------------------------------------------
# 표적 궤적
# --------------------------------------------------------------------------
def target_pos(traj, phase, w, h):
    """phase 0.0~1.0 -> 원본 센서 좌표계의 표적 중심 (float)."""
    mx, my = w * 0.5, h * 0.5
    rx, ry = w * 0.32, h * 0.32

    if traj == "linear":
        # 좌 -> 우 왕복
        t = abs(((phase * 2.0) % 2.0) - 1.0)
        return w * 0.15 + t * w * 0.70, my
    if traj == "circle":
        a = phase * 2.0 * math.pi
        return mx + rx * math.cos(a), my + ry * math.sin(a)
    if traj == "sine":
        t = phase
        return w * 0.10 + t * w * 0.80, my + ry * math.sin(phase * 4.0 * math.pi)
    raise ValueError("unknown trajectory: %s" % traj)


def disc(cx, cy, r, w, h):
    """중심 (cx,cy) 반지름 r 원반이 덮는 픽셀 집합."""
    out = set()
    r2 = r * r
    for y in range(max(0, int(cy - r) - 1), min(h, int(cy + r) + 2)):
        for x in range(max(0, int(cx - r) - 1), min(w, int(cx + r) + 2)):
            dx, dy = x - cx, y - cy
            if dx * dx + dy * dy <= r2:
                out.add((x, y))
    return out


# --------------------------------------------------------------------------
# 이벤트 생성
# --------------------------------------------------------------------------
def generate(args, rng):
    sw, sh = args.sensor_w, args.sensor_h
    events = []          # (t_us, x, y, pol)
    labels = []          # (wid, t0, t1, cx64, cy64, n)

    sub = args.substeps                       # Window 하나를 몇 조각으로 쪼개 움직일지
    dt = args.window_us / sub

    prev = None
    for wid in range(args.windows):
        t_win0 = wid * args.window_us
        n_before = len(events)

        for s in range(sub):
            t0 = t_win0 + s * dt
            phase = ((wid * sub + s) / float(args.windows * sub)) * args.laps
            phase = phase % 1.0
            cx, cy = target_pos(args.traj, phase, sw, sh)
            cur = disc(cx, cy, args.radius, sw, sh)

            if prev is not None:
                # 새로 밝아진 픽셀 -> Positive / 어두워진 픽셀 -> Negative
                for (x, y) in cur - prev:
                    if rng.random() < args.fire_prob:
                        events.append((t0 + rng.random() * dt, x, y, POL_POS))
                for (x, y) in prev - cur:
                    if rng.random() < args.fire_prob:
                        events.append((t0 + rng.random() * dt, x, y, POL_NEG))
            prev = cur

        # 배경 노이즈 이벤트
        n_noise = int(args.noise * args.window_us / 1000.0)
        for _ in range(n_noise):
            events.append((t_win0 + rng.random() * args.window_us,
                           rng.randrange(sw), rng.randrange(sh), rng.randint(0, 1)))

        # 정답 라벨은 Window 끝 시점 표적 위치를 64x64 좌표로 환산
        phase_end = ((wid * sub + sub - 1) / float(args.windows * sub)) * args.laps % 1.0
        cx, cy = target_pos(args.traj, phase_end, sw, sh)
        labels.append((wid, t_win0, t_win0 + args.window_us,
                       min(63, int(cx * TENSOR_W / sw)),
                       min(63, int(cy * TENSOR_H / sh)),
                       len(events) - n_before + n_noise))

    events.sort(key=lambda e: e[0])
    return events, labels


# --------------------------------------------------------------------------
# Tensor 누적 (RTL event_accumulator.v 의 참조 모델)
# --------------------------------------------------------------------------
def accumulate(events, args):
    """Window별 64x64x2 Tensor. RTL이 맞춰야 할 정답이다."""
    sw, sh = args.sensor_w, args.sensor_h
    sat = args.saturate
    tensors = []
    for wid in range(args.windows):
        t0 = wid * args.window_us
        t1 = t0 + args.window_us
        pos = [[0] * TENSOR_W for _ in range(TENSOR_H)]
        neg = [[0] * TENSOR_W for _ in range(TENSOR_H)]
        for (t, x, y, p) in events:
            if t < t0 or t >= t1:
                continue
            bx = x * TENSOR_W // sw
            by = y * TENSOR_H // sh
            if bx >= TENSOR_W or by >= TENSOR_H:      # 범위 밖은 버린다
                continue
            m = pos if p == POL_POS else neg
            if m[by][bx] < sat:                       # 포화. Wrap 금지
                m[by][bx] += 1
        tensors.append((pos, neg))
    return tensors


def write_hex(path, pos, neg, layout):
    """1 byte = 1 line, 2 hex digits.

    chw 가 팀 확정 순서다 (docs/D3_FREEZE_REQUEST_A_001.md 1번, SPEC §21).
        ext_addr = (polarity << 12) | (y << 6) | x
        polarity 0 = Positive(Channel 0), 1 = Negative(Channel 1)
    아래 chw 분기가 정확히 이 주소 순서로 쓴다.
    hwc 는 비교용으로만 남긴다.
    """
    with open(path, "w") as f:
        if layout == "hwc":        # ch 최내측: (y, x, ch)
            for y in range(TENSOR_H):
                for x in range(TENSOR_W):
                    f.write("%02x\n%02x\n" % (pos[y][x], neg[y][x]))
        else:                      # chw: ch 최외측
            for m in (pos, neg):
                for y in range(TENSOR_H):
                    for x in range(TENSOR_W):
                        f.write("%02x\n" % m[y][x])


def ascii_preview(pos, neg, step=2):
    """numpy/matplotlib 없이 눈으로 확인용."""
    chars = " .:-=+*#%@"
    lines = []
    for y in range(0, TENSOR_H, step):
        row = []
        for x in range(0, TENSOR_W, step):
            v = pos[y][x] + neg[y][x]
            row.append(chars[min(len(chars) - 1, v)])
        lines.append("".join(row))
    return "\n".join(lines)


# --------------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser(description="Event Test Vector 생성기")
    p.add_argument("--out", default="sim/event_vectors", help="출력 디렉토리")
    p.add_argument("--sensor", default="64x64", help="원본 센서 해상도 (예: 346x260)")
    p.add_argument("--traj", default="circle", choices=["linear", "circle", "sine"])
    p.add_argument("--windows", type=int, default=20, help="생성할 Window 수")
    p.add_argument("--window-us", type=int, default=10000, help="Window 길이 [us] (5000 또는 10000)")
    p.add_argument("--substeps", type=int, default=8, help="Window당 표적 이동 분할 수")
    p.add_argument("--radius", type=float, default=6.0, help="표적 반지름 [px]")
    p.add_argument("--laps", type=float, default=1.0, help="전체 구간 동안 궤적 반복 횟수")
    p.add_argument("--fire-prob", type=float, default=0.9, help="변화 픽셀이 이벤트를 낼 확률")
    p.add_argument("--noise", type=float, default=2.0, help="배경 노이즈 [events/ms]")
    p.add_argument("--saturate", type=int, default=127, help="Event Count 포화 상한 (SPEC v1.2 §9.1 = 127)")
    p.add_argument("--layout", default="chw", choices=["hwc", "chw"],
                   help="Tensor 메모리 배치. 기본 chw = SPEC D3 Freeze (A-001 1번). "
                        "addr = (pol<<12)|(y<<6)|x")
    p.add_argument("--seed", type=int, default=20260820, help="난수 시드 (팀 공통값)")
    p.add_argument("--no-hex", action="store_true", help="Tensor hex 덤프 생략")
    args = p.parse_args()

    args.sensor_w, args.sensor_h = (int(v) for v in args.sensor.lower().split("x"))
    rng = random.Random(args.seed)
    os.makedirs(args.out, exist_ok=True)

    events, labels = generate(args, rng)
    tensors = accumulate(events, args)

    ev_path = os.path.join(args.out, "events.csv")
    with open(ev_path, "w") as f:
        f.write("# Event Test Vector  seed=%d sensor=%dx%d traj=%s window_us=%d\n"
                % (args.seed, args.sensor_w, args.sensor_h, args.traj, args.window_us))
        f.write("x,y,polarity,t_us\n")
        for (t, x, y, pol) in events:
            f.write("%d,%d,%d,%d\n" % (x, y, pol, int(t)))

    lb_path = os.path.join(args.out, "labels.csv")
    with open(lb_path, "w") as f:
        f.write("window_id,t_start_us,t_end_us,cx,cy,n_events\n")
        for row in labels:
            f.write("%d,%d,%d,%d,%d,%d\n" % row)

    if not args.no_hex:
        for wid, (pos, neg) in enumerate(tensors):
            write_hex(os.path.join(args.out, "tensor_w%03d.hex" % wid), pos, neg, args.layout)

    nz = sum(1 for (pos, neg) in tensors
             for y in range(TENSOR_H) for x in range(TENSOR_W) if pos[y][x] or neg[y][x])
    print("events        : %d" % len(events))
    print("windows       : %d  (%d us each)" % (args.windows, args.window_us))
    print("event rate    : %.1f events/ms" % (len(events) / (args.windows * args.window_us / 1000.0)))
    print("avg nonzero   : %.1f / 8192 cells (%.1f%%)"
          % (nz / len(tensors), 100.0 * nz / len(tensors) / (TENSOR_W * TENSOR_H * 2)))
    print("layout        : %s   saturate=%d" % (args.layout, args.saturate))
    print("output        : %s" % args.out)
    print()
    print("Window 0 미리보기 (표적 위치 = 라벨 %d,%d):" % (labels[0][3], labels[0][4]))
    print(ascii_preview(*tensors[0]))


if __name__ == "__main__":
    main()
