/*=====================================================================
 * npu_driver.h : NPU 제어 드라이버 (PS bare-metal)
 * 담당: A
 *
 * Xilinx BSP 헤더에 의존하지 않는다. 순수 C99 다.
 *   - Vitis standalone 에서 그대로 쓴다
 *   - 호스트 PC 에서 sw/sim/npu_mock.c 와 링크해 단위시험도 된다
 *
 * 레지스터 접근은 npu_io_read32 / npu_io_write32 두 함수로만 한다.
 * 보드에서는 실제 MMIO, 호스트 시험에서는 mock 이 이 두 함수를 제공한다.
 *=====================================================================*/
#ifndef NPU_DRIVER_H
#define NPU_DRIVER_H

#include <stdint.h>
#include <stddef.h>
#include "npu_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/*---------------------------------------------------------------------
 * 반환 코드
 *-------------------------------------------------------------------*/
typedef enum {
    NPU_OK              =  0,
    NPU_ERR_VERSION     = -1,   /* VERSION 레지스터 불일치 = AXI 배선 문제 */
    NPU_ERR_BUSY        = -2,   /* BUSY 인데 시작/적재를 시도했다          */
    NPU_ERR_TIMEOUT     = -3,   /* DONE 이 기한 안에 안 왔다               */
    NPU_ERR_HW          = -4,   /* STATUS.ERROR 가 섰다                    */
    NPU_ERR_LOAD        = -5,   /* 적재 후 INBUF_ADDR 이 8192 가 아니다    */
    NPU_ERR_ARG         = -6    /* 인자가 틀렸다                           */
} npu_status_t;

/*---------------------------------------------------------------------
 * 추론 결과
 *-------------------------------------------------------------------*/
typedef struct {
    int      valid;        /* STATUS.TARGET_VALID                       */
    uint32_t x;            /* 0~63, 원본 64x64 좌표 (spec §15)          */
    uint32_t y;            /* 0~63                                      */
    int8_t   score;        /* signed INT8, heatmap 최댓값               */
    uint32_t cycles;       /* CYCLE_CNT. @100MHz 로 시간 환산 가능      */
} npu_result_t;

/*---------------------------------------------------------------------
 * Servo 실제 위치 (0x58 SERVO_POS_STAT 디코드)
 *   PT#1 = 카메라 헤드, PT#2 = 레이저 헤드. 각 8-bit unsigned servo pos.
 *-------------------------------------------------------------------*/
typedef struct {
    uint32_t raw;
    uint8_t  pan1, tilt1;      /* 카메라 헤드 */
    uint8_t  pan2, tilt2;      /* 레이저 헤드 */
} npu_servo_pos_t;

/*---------------------------------------------------------------------
 * MMIO 백엔드.  보드용 구현은 npu_driver.c 안에 있고,
 * 호스트 단위시험에서는 NPU_MOCK_IO 를 정의해 mock 이 대신 제공한다.
 *-------------------------------------------------------------------*/
uint32_t npu_io_read32 (uint32_t offset);
void     npu_io_write32(uint32_t offset, uint32_t value);

/*---------------------------------------------------------------------
 * API
 *-------------------------------------------------------------------*/

/* AXI 배선 확인 + soft reset + 기본 설정.
 * 제일 먼저 부른다. VERSION 이 틀리면 NPU_ERR_VERSION.          */
npu_status_t npu_init(void);

/* SCORE_TH (signed INT8) 설정. target_valid = (score > SCORE_TH). */
void npu_set_score_th(int8_t th);
int8_t npu_get_score_th(void);

/* 입력 소스 선택. 0 = PS 가 AXI 로 적재, 1 = C 하드웨어가 직결.  */
void npu_set_input_src(int use_hw);
int  npu_get_input_src(void);

/*---------------------------------------------------------------------
 * Direct START (CR A-003 변경 2. C 승인 2026-08-27, A 구현 2026-08-28)
 *   1 = C 의 Tensor 전송 완료 pulse 가 곧바로 추론을 건다. PS 가 START
 *       경로에서 빠진다. INPUT_SRC 도 1 이어야 무장된다.
 *   0 = PS-managed (reset 기본값). 예전 동작 그대로.
 *   ** 두 방식을 동시에 쓰지 마라. 무장 중 npu_start() 는 NPU_ERR_ARG. **
 *-------------------------------------------------------------------*/
void npu_set_hw_start_en(int en);
int  npu_get_hw_start_en(void);

/*---------------------------------------------------------------------
 * C 상태 Register (전부 RO. bit 의미는 C 가 정의했다)
 *   npu_input_stat   0x0C  ACC_READY / TENSOR_READY / evt·drop count
 *   npu_control_stat 0x5C  NPU_CST_* 비트
 *   npu_get_servo_pos 0x58 Servo 실제 위치 4축
 *-------------------------------------------------------------------*/
uint32_t npu_input_stat(void);
uint32_t npu_control_stat(void);
void     npu_get_servo_pos(npu_servo_pos_t *out);

/* INPUT_STAT.TENSOR_READY 대기. PS-managed START 의 첫 단계.     */
npu_status_t npu_wait_tensor_ready(uint32_t poll_limit);

/* C 하드웨어 경로 한 프레임 (PS-managed):
 * TENSOR_READY -> START -> DONE -> 결과. INPUT_SRC=1 이어야 한다.
 * Direct START 무장 중이면 NPU_ERR_ARG.                          */
npu_status_t npu_run_hw_frame(uint32_t poll_limit, npu_result_t *out);

/* Event Tensor 8192 byte 적재 (CHW 순서 그대로).
 * BUSY 중이거나 INPUT_SRC=1 이면 실패한다.                       */
npu_status_t npu_load_tensor(const int8_t *tensor, size_t len);

/* 추론 시작 (비블로킹). START 는 DONE sticky 를 자동으로 지운다. */
npu_status_t npu_start(void);

/* DONE 폴링. poll_limit 회까지 STATUS 를 읽는다. 0 이면 무한.
 * BUSY 가 아니라 DONE(sticky) 을 본다.                           */
npu_status_t npu_wait_done(uint32_t poll_limit);

/* 결과 읽기. npu_wait_done 이 NPU_OK 를 준 뒤에 부른다.          */
void npu_get_result(npu_result_t *out);

/* 적재 -> 시작 -> 대기 -> 결과 를 한 번에.                       */
npu_status_t npu_run(const int8_t *tensor, size_t len,
                     uint32_t poll_limit, npu_result_t *out);

/* STATUS 의 sticky bit (DONE / ERROR) 클리어.                    */
void npu_clear_status(void);

/* 현재 STATUS 원본값.                                            */
uint32_t npu_status_raw(void);

/* 반환 코드 -> 사람이 읽는 문자열.                               */
const char *npu_strerror(npu_status_t s);

/*---------------------------------------------------------------------
 * Pan/Tilt (C 담당 영역. A 는 레지스터 창구만 제공한다)
 *   PT#1 = 이벤트 카메라 헤드,  PT#2 = 레이저 헤드
 *   bit 의미는 C 가 정한다. 여기서는 32-bit 통째로 읽고 쓴다.
 *-------------------------------------------------------------------*/
void     npu_set_pt1(uint32_t pan, uint32_t tilt);
void     npu_set_pt2(uint32_t pan2, uint32_t tilt2);
uint32_t npu_get_pt1_pan(void);
uint32_t npu_get_pt2_pan(void);

#ifdef __cplusplus
}
#endif
#endif /* NPU_DRIVER_H */
