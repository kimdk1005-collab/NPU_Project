/*=====================================================================
 * npu_mock.h : npu_axi.v 동작을 흉내내는 호스트 목(mock)
 * 담당: A
 *
 * 목적: 보드 없이 sw/npu_driver.c 를 검증한다.
 *   RTL 은 tb_npu_axi / tb_top_system 으로 검증했다.
 *   이 목은 그 RTL 과 "같은 계약"을 구현한다.
 *   -> 드라이버가 이 목을 통과하면 RTL 과도 맞는다.
 *
 * 이 파일은 보드 빌드에 들어가지 않는다. 호스트 시험 전용.
 *=====================================================================*/
#ifndef NPU_MOCK_H
#define NPU_MOCK_H

#include <stdint.h>
#include "../npu_regs.h"

void npu_mock_reset(void);

/* 추론 결과를 미리 심어둔다 (RTL 의 NPU Core 자리) */
void npu_mock_set_result(int valid, uint32_t x, uint32_t y,
                         int8_t score, uint32_t cycles);

/* START 후 몇 번의 STATUS 읽기 동안 BUSY 를 유지할지.
 * 0 이면 즉시 완료. 폴링 루프를 시험할 때 쓴다.                 */
void npu_mock_set_busy_polls(uint32_t n);

/* 0x58 SERVO_POS_STAT / 0x5C CONTROL_STAT 에 실릴 값을 심는다.
 * RTL 에서는 C 모듈이 만드는 값이라 목에서는 TB 가 직접 준다.  */
void npu_mock_set_stat(uint32_t servo_pos, uint32_t control);

/* 0x0C INPUT_STAT 값을 심는다. C 의 Event 경로 상태다.        */
void npu_mock_set_input_stat(uint32_t v);

/* C 의 event_accumulator.tensor_start 1 cycle pulse 를 흉내낸다.
 * CTRL.HW_START_EN & CTRL.INPUT_SRC 가 둘 다 1 일 때만 먹는다. */
void npu_mock_hw_start(void);

/* 드라이버가 INBUF 로 실제로 써넣은 8192 byte.
 * 원본 tensor 와 byte 단위로 비교해 순서/엔디안을 검증한다.     */
const int8_t *npu_mock_buffer(void);

/* 통계 / 내부 상태 관찰용 */
uint32_t npu_mock_byte_writes(void);   /* INBUF 에 들어간 byte 수      */
uint32_t npu_mock_dropped(void);       /* 거부된 INBUF write 횟수      */
uint32_t npu_mock_start_pulses(void);  /* START 가 실제로 먹은 횟수    */
uint32_t npu_mock_reg_writes(void);    /* 전체 레지스터 write 횟수     */
int      npu_mock_irq(void);           /* irq = IRQ_EN & DONE          */

#endif /* NPU_MOCK_H */
