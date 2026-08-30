# A 역할 — PS 소프트웨어

> 소유: A · 대상: Zynq-7000 bare-metal + 호스트 Mock

## 구성

| 파일 | 역할 |
|---|---|
| `npu_regs.h` | `ifc_v0.5` AXI Register 정의 |
| `npu_driver.c/.h` | Tensor 적재, START, DONE 폴링, 결과·C 상태 읽기 |
| `npu_test.c` | 보드 자체시험 STEP 1~7 |
| `cpu_baseline.c/.h` | FP32/INT8 CPU 기준 구현 |
| `live_tracker.c`, `live_protocol.h` | PC UART Frame 수신과 연속 NPU 실행 |
| `sim/` | MMIO Mock 및 호스트 자동시험 |
| `build_vitis*.{tcl,py}` | Classic/Unified Vitis 재현 스크립트 |

`test_tensor.h`, `int8_weights.h`, `fp32_weights.h`는 현재 Version Lock에서 생성된 C
헤더다. Weight/Test Vector 변경 시 함께 재생성한다.

## 호스트 검증

```bash
cd sw
make test       # Driver/AXI Mock 76 check
make cpu        # CPU baseline 21 check
make live       # C/Python/UART protocol 90 check
make all
```

`make live`의 Python 검증에는 NumPy가 필요하다. 카메라까지 사용할 환경은 저장소 루트에서:

```bash
python3 -m venv .venv
.venv/bin/pip install -r tools/live_demo/requirements.txt
```

## 생성·ARM 빌드

```bash
python3 tools/pack_weights.py
python3 tools/gen_requant_tv.py
python3 tools/gen_test_tensor_c.py test_vectors/case00
python3 tools/gen_int8_weights_c.py
python3 tools/dump_fp32_weights.py

cd sw
make arm
```

보드용 `npu_test.elf`와 `live_tracker.elf`는 Vitis에서 로컬 생성한다. ELF/XSA/Bitstream은
Git에 올리지 않으며 현재 승인 체크섬은 `../docs/integration_manifest.md`에 기록한다.

Live 운용은 `../docs/LIVE_RUNTIME_GUIDE.md`를 따른다. 실제 레이저는 물리 안전 Gate가 모두
확인되기 전 연결하지 않는다.
