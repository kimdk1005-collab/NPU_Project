#!/usr/bin/env python3
"""Zybo UART 모니터 + 로그 저장.

picocom/screen 이 없는 PC 용. pyserial 만 있으면 된다.
화면에 그대로 뿌리면서 동시에 results/board_uart_log.txt 에 append 한다.

  python3 tools/uart_log.py                 # /dev/ttyUSB1 115200
  python3 tools/uart_log.py /dev/ttyUSB0    # 포트 지정
  Ctrl+C 로 종료.

주의: 같은 포트를 다른 프로그램(Vitis/VS Code Serial Monitor, picocom 등)이
      먼저 열고 있으면 둘 다 글자를 놓친다. 하나만 열어라.
"""
import os
import sys
import time
import datetime
import subprocess
import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB1"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG = os.path.join(ROOT, "results", "board_uart_log.txt")


def who_holds(port):
    """포트를 잡고 있는 프로세스를 알려준다. 없으면 빈 문자열."""
    try:
        out = subprocess.run(["fuser", "-v", port], capture_output=True,
                             text=True, timeout=5)
        txt = (out.stdout + out.stderr).strip()
        return txt if port in txt else ""
    except Exception:
        return ""


def open_port():
    return serial.Serial(port=PORT, baudrate=BAUD, bytesize=8,
                         parity=serial.PARITY_NONE, stopbits=1,
                         timeout=0.2, rtscts=False, xonxoff=False,
                         exclusive=True)


held = who_holds(PORT)
if held:
    sys.stderr.write(
        "\n[!] %s 를 이미 다른 프로세스가 잡고 있다:\n%s\n"
        "    그쪽을 먼저 닫아라 (Vitis/VS Code Serial Monitor 탭 등).\n\n"
        % (PORT, held))

stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
head = "\n===== UART 세션 시작 %s  %s @ %d 8-N-1 =====\n" % (stamp, PORT, BAUD)
sys.stdout.write(head)
sys.stdout.flush()

f = open(LOG, "a", encoding="utf-8", errors="replace")
f.write(head)
f.flush()

ser = None
try:
    while True:
        if ser is None:
            try:
                ser = open_port()
            except Exception as e:
                msg = "\n[!] 포트 열기 실패: %s\n" % e
                held = who_holds(PORT)
                if held:
                    msg += "    잡고 있는 쪽:\n%s\n" % held
                msg += "    5 초 뒤 재시도. 중단은 Ctrl+C\n"
                sys.stdout.write(msg)
                sys.stdout.flush()
                time.sleep(5)
                continue
        try:
            data = ser.read(4096)
        except Exception as e:
            # 흔한 경우: USB 재열거, 또는 다른 프로세스가 같은 포트를 염
            note = ("\n[!] 읽기 중단: %s\n"
                    "    포트가 사라졌거나 다른 프로그램과 겹쳤다. 재연결 시도.\n" % e)
            sys.stdout.write(note)
            sys.stdout.flush()
            f.write(note)
            f.flush()
            try:
                ser.close()
            except Exception:
                pass
            ser = None
            time.sleep(2)
            continue
        if not data:
            continue
        text = data.decode("utf-8", errors="replace")
        sys.stdout.write(text)
        sys.stdout.flush()
        f.write(text)
        f.flush()
except KeyboardInterrupt:
    tail = "\n===== UART 세션 종료 %s =====\n" % (
        datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    sys.stdout.write(tail)
    f.write(tail)
finally:
    if ser is not None:
        try:
            ser.close()
        except Exception:
            pass
    f.close()
