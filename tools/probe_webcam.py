#!/usr/bin/env python3
"""
UVC 웹캠 능력 조사기  (표준 라이브러리만 사용, OpenCV / v4l2-ctl 불필요)

SPEC §34 Fallback 2순위 "Webcam Frame Difference" 를 쓸 경우,
웹캠의 최대 fps 가 Event Window 길이의 물리적 하한을 정한다.
30 fps 면 프레임 간격이 33.33 ms 이므로 그보다 짧은 Window 는 만들 수 없다.

이 스크립트는 그 숫자를 실측한다. SPEC §0-12 (측정하지 않은 수치를 만들지 않는다)
때문에 CHANGE REQUEST C-002 의 근거를 재현 가능한 형태로 남기는 것이 목적이다.

사용:
  python3 tools/probe_webcam.py                # /dev/video0
  python3 tools/probe_webcam.py /dev/video2

V4L2 ioctl 을 ctypes 로 직접 호출한다. 캡처는 하지 않고 조회만 한다.
"""

import ctypes
import fcntl
import sys

# --- ioctl 인코딩 (Linux asm-generic) --------------------------------------
_IOC_WRITE, _IOC_READ = 1, 2


def _IOC(d, t, nr, size):
    return (d << 30) | (size << 16) | (ord(t) << 8) | nr


def _IOR(t, nr, size):
    return _IOC(_IOC_READ, t, nr, size)


def _IOWR(t, nr, size):
    return _IOC(_IOC_READ | _IOC_WRITE, t, nr, size)


U32 = ctypes.c_uint32
BUF_TYPE_VIDEO_CAPTURE = 1
FRMSIZE_DISCRETE, FRMIVAL_DISCRETE = 1, 1


class Capability(ctypes.Structure):
    _fields_ = [("driver", ctypes.c_char * 16), ("card", ctypes.c_char * 32),
                ("bus_info", ctypes.c_char * 32), ("version", U32),
                ("capabilities", U32), ("device_caps", U32),
                ("reserved", U32 * 3)]


class FmtDesc(ctypes.Structure):
    _fields_ = [("index", U32), ("type", U32), ("flags", U32),
                ("description", ctypes.c_char * 32), ("pixelformat", U32),
                ("mbus_code", U32), ("reserved", U32 * 3)]


class Discrete(ctypes.Structure):
    _fields_ = [("width", U32), ("height", U32)]


class Stepwise(ctypes.Structure):
    _fields_ = [("min_width", U32), ("max_width", U32), ("step_width", U32),
                ("min_height", U32), ("max_height", U32), ("step_height", U32)]


class _SizeUnion(ctypes.Union):
    _fields_ = [("discrete", Discrete), ("stepwise", Stepwise)]


class FrmSizeEnum(ctypes.Structure):
    _fields_ = [("index", U32), ("pixel_format", U32), ("type", U32),
                ("u", _SizeUnion), ("reserved", U32 * 2)]


class Fract(ctypes.Structure):
    _fields_ = [("numerator", U32), ("denominator", U32)]


class IvalStepwise(ctypes.Structure):
    _fields_ = [("min", Fract), ("max", Fract), ("step", Fract)]


class _IvalUnion(ctypes.Union):
    _fields_ = [("discrete", Fract), ("stepwise", IvalStepwise)]


class FrmIvalEnum(ctypes.Structure):
    _fields_ = [("index", U32), ("pixel_format", U32), ("width", U32),
                ("height", U32), ("type", U32), ("u", _IvalUnion),
                ("reserved", U32 * 2)]


VIDIOC_QUERYCAP           = _IOR('V',  0, ctypes.sizeof(Capability))
VIDIOC_ENUM_FMT           = _IOWR('V', 2, ctypes.sizeof(FmtDesc))
VIDIOC_ENUM_FRAMESIZES    = _IOWR('V', 74, ctypes.sizeof(FrmSizeEnum))
VIDIOC_ENUM_FRAMEINTERVALS = _IOWR('V', 75, ctypes.sizeof(FrmIvalEnum))


def fourcc(v):
    return "".join(chr((v >> s) & 0xFF) for s in (0, 8, 16, 24)).strip()


def enum(fd, req, struct, setup):
    """index 를 올려가며 EINVAL 이 날 때까지 열거한다."""
    out, i = [], 0
    while True:
        s = struct()
        s.index = i
        setup(s)
        try:
            fcntl.ioctl(fd, req, s)
        except OSError:
            break
        out.append(s)
        i += 1
        if i > 64:                      # 폭주 방지
            break
    return out


def main():
    dev = sys.argv[1] if len(sys.argv) > 1 else "/dev/video0"
    try:
        fd = open(dev, "rb", buffering=0)
    except OSError as e:
        print("열 수 없음 %s : %s" % (dev, e))
        return 1

    cap = Capability()
    fcntl.ioctl(fd, VIDIOC_QUERYCAP, cap)
    print("device   : %s" % dev)
    print("driver   : %s" % cap.driver.decode(errors="replace"))
    print("card     : %s" % cap.card.decode(errors="replace"))
    print("bus_info : %s" % cap.bus_info.decode(errors="replace"))
    print()

    best_fps = 0.0
    best_mode = None

    def set_fmt(s):
        s.type = BUF_TYPE_VIDEO_CAPTURE

    for f in enum(fd, VIDIOC_ENUM_FMT, FmtDesc, set_fmt):
        name = fourcc(f.pixelformat)
        print("[%s] %s" % (name, f.description.decode(errors="replace")))

        def set_size(s, pf=f.pixelformat):
            s.pixel_format = pf

        for sz in enum(fd, VIDIOC_ENUM_FRAMESIZES, FrmSizeEnum, set_size):
            if sz.type != FRMSIZE_DISCRETE:
                print("    (stepwise/continuous -- 생략)")
                continue
            w, h = sz.u.discrete.width, sz.u.discrete.height

            def set_ival(s, pf=f.pixelformat, w=w, h=h):
                s.pixel_format, s.width, s.height = pf, w, h

            fps = []
            for iv in enum(fd, VIDIOC_ENUM_FRAMEINTERVALS, FrmIvalEnum, set_ival):
                if iv.type == FRMIVAL_DISCRETE and iv.u.discrete.numerator:
                    fps.append(iv.u.discrete.denominator /
                               float(iv.u.discrete.numerator))
            if not fps:
                continue
            top = max(fps)
            if top > best_fps:
                best_fps, best_mode = top, (name, w, h)
            print("    %4dx%-4d  fps %s   -> 프레임 간격 최소 %.2f ms"
                  % (w, h, ",".join("%g" % v for v in sorted(fps, reverse=True)),
                     1000.0 / top))
        print()

    fd.close()

    if best_mode is None:
        print("이 장치에서 discrete 모드를 찾지 못했다")
        return 1

    name, w, h = best_mode
    print("=" * 62)
    print("최대 fps        : %g  (%s %dx%d)" % (best_fps, name, w, h))
    print("프레임 간격     : %.3f ms" % (1000.0 / best_fps))
    print()
    print("Event Window 하한 = 프레임 간격이다.")
    print("프레임 차분은 두 프레임 사이의 변화만 만들 수 있으므로")
    print("프레임 간격보다 짧은 Event Window 는 물리적으로 만들 수 없다.")
    for cand in (5.0, 10.0):
        ok = cand >= 1000.0 / best_fps
        print("  Window %5.1f ms : %s" % (cand, "가능" if ok else "불가능"))
    print("=" * 62)
    return 0


if __name__ == "__main__":
    sys.exit(main())
