# Live Runtime 운용 가이드

> 대상: `model_v04_demo_masked_radius1_x1 / DEMO_BLUE_01 / DEMO_ONLY`
>
> 경로: PC Camera → Color Mask/Event Tensor → UART → PS → AXI NPU → C Tracking

## 1. 전제

먼저 고정 Golden 보드 자체시험을 통과해야 한다. Live는 `INPUT_SRC=0`과 PS-managed START를
사용하며 AXI Register Map을 변경하지 않는다. PS는 Tensor를 전달하고 결과를 회신하지만
Servo/Laser를 직접 구동하지 않는다.

v04의 No-target 성능은 `color_masked_event_v02_radius1`이 적용된 조건에서만 유효하다.
Mask를 제거하거나 HSV/Blob/resize/dilation 규칙을 임의 변경하지 않는다.

## 2. PC 준비

```bash
python3 -m venv .venv
.venv/bin/pip install -r tools/live_demo/requirements.txt
.venv/bin/python -c "import cv2, numpy, serial"
```

관련 파일:

- `tools/live_demo/camera_sender.py`: Camera/replay/zero/corrupt 송신
- `tools/live_demo/color_mask.py`: B 전처리 정본 적용
- `tools/live_demo/event_tensor.py`: A가 재구성한 Frame 차분 Event Tensor
- `tools/live_demo/protocol.py`: NPUL v1 Frame/CRC32
- `sw/live_tracker.c`, `sw/live_protocol.h`: 보드 수신·추론·응답

Event Tensor 생성기는 A 재구성이므로 B Dataset Builder와 bit-exact하다는 근거가 없다.
정확한 Golden 재현에는 `--replay-hex`를 사용한다.

## 3. 시험 순서

### 3.1 Golden replay

```bash
.venv/bin/python tools/live_demo/camera_sender.py \
  --replay-hex test_vectors/case00/input_event.hex --port /dev/ttyUSB1
```

기대 응답:

```text
RES seq=0 valid=1 x=36 y=28 score=43 cycle=125845 nz=43
```

case01은 `(4,4), score=101`, case02는 `valid=0, score=0`이어야 한다.

### 3.2 Zero와 손상 Frame

```bash
.venv/bin/python tools/live_demo/camera_sender.py --zero --port /dev/ttyUSB1
for mode in crc payload magic version len; do
  .venv/bin/python tools/live_demo/camera_sender.py \
    --replay-hex test_vectors/case00/input_event.hex \
    --corrupt "$mode" --port /dev/ttyUSB1
done
```

Zero는 `valid=0`이어야 한다. CRC/payload/length/version 손상은 거부되고 magic 손상은 조용히
재동기화된다. 손상 시험 뒤 Golden replay로 복구를 확인한다.

### 3.3 실제 Camera — Laser 미연결

```text
laser_arm_hw     OFF
emergency_stop   안전 상태
KY-008           연결하지 않음
```

```bash
.venv/bin/python tools/live_demo/camera_sender.py \
  --camera 0 --port /dev/ttyUSB1 --frames 0 --interval 0.05
```

Mask pixel, Event nonzero, `valid/x/y/score/cycle`을 기록한다. 표적을 제거했을 때 Mask와
Tensor가 0이 되고 `valid=0`으로 전환되는지 먼저 확인한다.

## 4. Servo와 Laser Gate

Servo 시험은 축 방향·기구 안전 범위·FOV·Offset을 확인한 뒤 Laser를 연결하지 않은 상태에서
수행한다. 다음이 모두 끝나기 전 Laser를 연결하지 않는다.

```text
[ ] Golden/zero/corrupt 시험 통과
[ ] 실제 Camera 무표적에서 valid=0 및 LASER_EN=0
[ ] emergency_stop 즉시 OFF 확인
[ ] Servo 축 방향·안전 범위·FOV·Offset 실측
[ ] KY-008 소비전류·광출력 등급 확인
[ ] FPGA 미프로그램 default-OFF 확인
[ ] 물리 NC E-stop이 5 V를 직접 차단
[ ] 보호안경·반사물 제거·사람 없는 방향 확보
```

C의 `LOCK_CONFIRM_UPDATES`, Lock/Safe Zone, freshness timeout, max-on 제한을 낮추거나
우회하지 않는다.

## 5. 호스트 회귀

```bash
PATH="$PWD/.venv/bin:$PATH" make -C sw live
```

보드·카메라 없이 C 34 + Python 41 + host end-to-end 15, 합계 90 check를 검증한다. 이
PASS는 실제 Camera/보드/Servo/Laser 동작을 증명하지 않는다.
