# NPU PS 소프트웨어 빌드
#
#   make test        호스트에서 드라이버 단위시험 (보드 불필요)   <- 주로 이거
#   make cpu         PS CPU Baseline 구현이 Golden 과 bit-exact 인지 검증
#   make live        Live 전송 규격 시험 (C) + tools/live_demo 시험 (Python)
#   make arm         ARM cross compile 확인 (보드 코드가 실제로 빌드되는지)
#   make tensor      test_vectors -> test_tensor.h 재생성
#   make clean
#
# 보드용 최종 빌드는 Vitis 가 한다 (build_vitis.tcl 참고).
# 여기 arm 타깃은 "문법/타입이 ARM 에서도 맞는가"만 확인하는 용도다.

CC        ?= gcc
CFLAGS    := -std=c99 -O2 -Wall -Wextra -Wpedantic -Werror
ARMCC     ?= arm-none-eabi-gcc
ARMFLAGS  := -std=c99 -O2 -Wall -Wextra -mcpu=cortex-a9 -mfpu=vfpv3 \
             -mfloat-abi=hard -ffreestanding -c

ROOT      := ..
BUILD     := build

.PHONY: all test cpu live live-host arm tensor clean

all: test cpu live

# ---------------------------------------------------------------- 호스트 시험
$(BUILD)/test_driver: npu_driver.c npu_driver.h npu_regs.h test_tensor.h \
                      sim/npu_mock.c sim/npu_mock.h sim/test_driver.c
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -DNPU_MOCK_IO -I. -Isim \
	    npu_driver.c sim/npu_mock.c sim/test_driver.c -o $@

test: $(BUILD)/test_driver
	@./$(BUILD)/test_driver

# ------------------------------------------------ PS CPU Baseline 정합성 검증
$(BUILD)/test_cpu_baseline: cpu_baseline.c cpu_baseline.h int8_weights.h \
                            fp32_weights.h sim/test_cpu_baseline.c
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -I. cpu_baseline.c sim/test_cpu_baseline.c -o $@ -lm

cpu: $(BUILD)/test_cpu_baseline
	@./$(BUILD)/test_cpu_baseline $(ROOT)/test_vectors

# ------------------------------------------------- Live 전송 규격 (보드 불필요)
# C 디코더와 Python 인코더가 같은 바이트열/CRC 를 쓰는지 교차 검사한다.
$(BUILD)/test_live_protocol: live_protocol.h sim/test_live_protocol.c
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -I. sim/test_live_protocol.c -o $@

live: $(BUILD)/test_live_protocol live-host
	@./$(BUILD)/test_live_protocol
	@python3 $(ROOT)/tools/live_demo/test_protocol.py

# live_tracker.c 를 호스트에서 컴파일해 본다 (문법/로직 확인용. 보드 ELF 아님)
$(BUILD)/live_tracker_host: live_tracker.c live_protocol.h npu_driver.c \
                            npu_driver.h npu_regs.h sim/npu_mock.c sim/npu_mock.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -DNPU_MOCK_IO -DNPU_NO_XIL -I. -Isim \
	    npu_driver.c sim/npu_mock.c live_tracker.c -o $@

live-host: $(BUILD)/live_tracker_host
	@echo "[OK] live_tracker.c 호스트 빌드 통과 -> $(BUILD)/live_tracker_host"
	@bash $(ROOT)/tools/live_demo/test_live_host.sh

# ---------------------------------------------------------------- ARM 빌드 확인
arm: npu_driver.c npu_test.c cpu_baseline.c live_tracker.c
	@mkdir -p $(BUILD)
	$(ARMCC) $(ARMFLAGS) -I. npu_driver.c -o $(BUILD)/npu_driver.o
	$(ARMCC) $(ARMFLAGS) -I. -DNPU_NO_XIL npu_test.c -o $(BUILD)/npu_test.o
	$(ARMCC) $(ARMFLAGS) -I. cpu_baseline.c -o $(BUILD)/cpu_baseline.o
	$(ARMCC) $(ARMFLAGS) -I. -DNPU_NO_XIL live_tracker.c -o $(BUILD)/live_tracker.o
	@echo "[OK] ARM cross compile 통과 (cortex-a9)"

# ---------------------------------------------------------------- 벡터 재생성
tensor:
	python3 $(ROOT)/tools/gen_test_tensor_c.py $(if $(TV),$(TV),$(ROOT)/test_vectors/case00)

clean:
	rm -rf $(BUILD)
