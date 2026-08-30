#!/usr/bin/env bash
#=====================================================================
# test_live_host.sh : Live 경로 호스트 종단 시험 (보드·카메라 불필요)
#
#   cd sw && make live-host
#
# 무엇을 증명하나
#   Python 송신기가 만든 바이트열을 보드측 C 루프(live_tracker.c)가
#   그대로 받아 8192 byte Tensor 로 풀고, 손상 Frame 을 거부하고,
#   잡음 뒤에 재동기화하는지.
#
# 무엇을 증명하지 않나  ** 중요 **
#   추론 결과. sw/sim/npu_mock.c 는 rtl/integration/npu_axi.v 의
#   **레지스터 동작** 복제본이지 CNN 이 아니다. 그래서 RES 줄의
#   valid/x/y/score 는 전부 0 으로 나오고 그게 정상이다.
#   추론이 맞는지는 RTL 회귀 48/48 과 make cpu 21 check 가 이미 증명했다.
#   실제 (36,28,43) 은 보드에서 확인한다.
#=====================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/sw/build/live_tracker_host"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -x "$BIN" ]; then
    echo "[FAIL] $BIN 이 없다. cd sw && make live-host 로 먼저 빌드해라."
    exit 1
fi

python3 - "$ROOT" > "$TMP/stream.bin" <<'PY'
import sys
root = sys.argv[1]
sys.path.insert(0, root + "/tools/live_demo")
import protocol as P
import camera_sender as CS
from event_tensor import load_hex_tensor

out = sys.stdout.buffer
def tv(case):
    return load_hex_tensor(f"{root}/test_vectors/{case}/input_event.hex")

out.write(P.build_frame(P.TYPE_PING, 0, b""))
for seq, case in ((1, "case00"), (2, "case01"), (3, "case02")):
    out.write(P.build_tensor_frame(tv(case), seq)[0])
out.write(P.build_frame(P.TYPE_TENSOR_RAW, 4, tv("case00")))   # raw 강제
good = P.build_tensor_frame(tv("case00"), 5)[0]
out.write(CS.corrupt_frame(good, "crc"))                       # 거부돼야 한다
out.write(CS.corrupt_frame(good, "magic"))                     # 조용히 무시
out.write(CS.corrupt_frame(good, "len"))                       # 거부돼야 한다
out.write(b"\x00\xff\x5a" * 20)                                # 잡음
out.write(P.build_tensor_frame(tv("case00"), 6)[0])            # 재동기화 확인
out.write(P.build_frame(P.TYPE_RESET, 7, b""))
out.write(P.build_frame(P.TYPE_PING, 8, b""))
PY

# 보드측 코드는 UART 규약대로 CRLF 로 찍는다. grep 의 $ 앵커를 위해 CR 을 벗긴다.
"$BIN" < "$TMP/stream.bin" 2>&1 | tr -d '\r' > "$TMP/out.txt"
rc=${PIPESTATUS[0]}

checks=0
fails=0
want() {   # want <설명> <정규식>
    checks=$((checks + 1))
    if grep -qE "$2" "$TMP/out.txt"; then
        echo "  [OK]   $1"
    else
        fails=$((fails + 1))
        echo "  [FAIL] $1   (찾는 패턴: $2)"
    fi
}
absent() {
    checks=$((checks + 1))
    if grep -qE "$2" "$TMP/out.txt"; then
        fails=$((fails + 1))
        echo "  [FAIL] $1   (있으면 안 되는 패턴이 나왔다: $2)"
    else
        echo "  [OK]   $1"
    fi
}

echo "====================================================="
echo " Live 경로 호스트 종단 시험 (mock NPU)"
echo "====================================================="
echo
echo "[1] 기동"
want "배너 + READY"                      '^READY$'
want "npu_init 성공 (FATAL 없음)"        '^READY$'
absent "npu_init 실패 메시지 없음"        '^FATAL'

echo
echo "[2] Tensor Frame 을 8192 byte 로 정확히 푸나  (nz = 실측 nonzero)"
want "case00 sparse -> nz=43"            '^RES seq=1 .* nz=43$'
want "case01 sparse -> nz=602"           '^RES seq=2 .* nz=602$'
want "case02 (전 0) -> nz=0"             '^RES seq=3 .* nz=0$'
want "case00 raw 8192B -> nz=43"         '^RES seq=4 .* nz=43$'

echo
echo "[3] 망가진 Frame 처리"
want "CRC 훼손 -> ERR crc"               '^ERR crc seq=5$'
want "length 65535 -> ERR len"           '^ERR len=65535$'
absent "magic 훼손은 조용히 재동기화"     '^ERR (magic|frame code=-1)'

echo
echo "[4] 잡음 뒤 재동기화"
want "잡음 60 byte 뒤 seq=6 정상 처리"    '^RES seq=6 .* nz=43$'

echo
echo "[5] 카운터"
want "RESET 처리"                        '^RESET seq=7$'
want "RESET 뒤 카운터 0"                 '^PONG seq=8 ok=0 crc_err=0 bad=0 npu_err=0 '
want "종료 줄 (RESET 뒤라 전부 0)"        '^BYE ok=0 crc_err=0 bad=0 npu_err=0$'
checks=$((checks + 1))
if [ "$rc" -eq 0 ]; then echo "  [OK]   exit code 0"; else fails=$((fails+1)); echo "  [FAIL] exit code $rc"; fi

echo
echo "====================================================="
if [ "$fails" -eq 0 ]; then
    echo " 결과: PASS   ($checks check, 실패 0건)"
else
    echo " 결과: FAIL   ($checks check, 실패 ${fails}건)"
    echo "--- 실제 출력 ---"
    cat "$TMP/out.txt"
fi
echo " ** 추론값(valid/x/y/score)은 검사하지 않았다. mock 은 CNN 이 아니다. **"
echo "====================================================="
[ "$fails" -eq 0 ]
