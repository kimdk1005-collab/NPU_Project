/*=====================================================================
 * npu_mock.c : npu_axi.v 레지스터 동작 복제 (호스트 시험용)
 * 담당: A
 * 원본: rtl/integration/npu_axi.v  (v1.5 §20.1)
 *
 * 복제한 동작
 *   - VERSION = 0x4E50_0100
 *   - CTRL   : START/SOFT_RESET 은 W1P(읽으면 0), INPUT_SRC/IRQ_EN 은 유지
 *   - STATUS : DONE/ERROR sticky + W1C, BUSY/TARGET_VALID 는 level
 *   - START while BUSY -> 무시 + ERROR
 *   - INBUF_ADDR : 14 bit, write 시 하위 2 bit 를 0 으로 강제(4 정렬)
 *   - INBUF_DATA : 32bit -> 4 byte(LE) 기록 후 포인터 +4
 *                  BUSY / INPUT_SRC=1 / ptr>=8192 이면 버리고 ERROR
 *   - RESULT_SCORE : [7:0] RO score, [23:16] RW SCORE_TH
 *   - 0x58 / 0x5C : RO. 목에서는 npu_mock_set_stat() 으로 심는다
 *   - CTRL[5] HW_START_EN + Direct START (npu_mock_hw_start)
 *   - 미정의 Offset : read 0 / write 무시
 *
 * ** RTL 레지스터 동작을 바꾸면 이 파일도 같이 고쳐야 한다. **
 *    안 그러면 test_driver 45 check 가 거짓 통과한다 (CLAUDE.md §7 지뢰).
 *=====================================================================*/
#include <string.h>
#include "npu_mock.h"

/*---------------------------------------------------------------------
 * 내부 상태 (RTL 레지스터와 1:1)
 *-------------------------------------------------------------------*/
static uint32_t r_event_cfg, r_input_stat;
static uint32_t r_pan, r_tilt, r_laser, r_safe, r_terrx, r_terry;
static uint32_t r_pan2, r_tilt2, r_safe2, r_lcal;
static uint32_t r_scratch;
static uint32_t r_servo_pos, r_control_stat;   /* 0x58 / 0x5C  RO */
static uint32_t r_inbuf_ptr;        /* 14 bit */
static int8_t   r_score_th;

static int      ctrl_input_src, ctrl_irq_en, ctrl_hw_start_en;
static int      done_sticky, err_sticky, busy;
static uint32_t busy_countdown;

/* NPU Core 자리 — 미리 심어둔 결과 */
static int      res_valid;
static uint32_t res_x, res_y, res_cycles;
static int8_t   res_score;
static uint32_t busy_polls_cfg;

/* 관찰용 */
static int8_t   shadow[NPU_TENSOR_BYTES];
static uint32_t stat_byte_writes, stat_dropped, stat_start, stat_regw;

/*=====================================================================*/
void npu_mock_reset(void)
{
    memset(shadow, 0, sizeof(shadow));
    r_event_cfg = r_input_stat = 0;
    r_pan = r_tilt = r_laser = r_safe = r_terrx = r_terry = 0;
    r_pan2 = r_tilt2 = r_safe2 = r_lcal = 0;
    r_scratch = 0; r_inbuf_ptr = 0; r_score_th = 0;
    r_servo_pos = r_control_stat = 0;
    ctrl_input_src = ctrl_irq_en = ctrl_hw_start_en = 0;
    done_sticky = err_sticky = busy = 0;
    busy_countdown = 0;
    res_valid = 0; res_x = res_y = res_cycles = 0; res_score = 0;
    busy_polls_cfg = 0;
    stat_byte_writes = stat_dropped = stat_start = stat_regw = 0;
}

void npu_mock_set_result(int valid, uint32_t x, uint32_t y,
                         int8_t score, uint32_t cycles)
{
    res_valid = valid; res_x = x; res_y = y;
    res_score = score; res_cycles = cycles;
}

void npu_mock_set_busy_polls(uint32_t n) { busy_polls_cfg = n; }

void npu_mock_set_stat(uint32_t servo_pos, uint32_t control)
{
    r_servo_pos    = servo_pos;
    r_control_stat = control;
}

void npu_mock_set_input_stat(uint32_t v) { r_input_stat = v; }

/* RTL: hw_start_armed = ctrl_hw_start_en & ctrl_input_src
 *      무장 상태에서 pulse 가 오면 START, BUSY 중이면 ERROR.        */
void npu_mock_hw_start(void)
{
    if (!(ctrl_hw_start_en && ctrl_input_src)) return;   /* 무장 안 됨 */
    if (busy) { err_sticky = 1; return; }
    stat_start++;
    done_sticky = 0;
    busy = 1;
    busy_countdown = busy_polls_cfg;
    if (busy_countdown == 0) { busy = 0; done_sticky = 1; }
}

const int8_t *npu_mock_buffer(void)   { return shadow; }
uint32_t npu_mock_byte_writes(void)   { return stat_byte_writes; }
uint32_t npu_mock_dropped(void)       { return stat_dropped; }
uint32_t npu_mock_start_pulses(void)  { return stat_start; }
uint32_t npu_mock_reg_writes(void)    { return stat_regw; }
int      npu_mock_irq(void)           { return ctrl_irq_en && done_sticky; }

/*=====================================================================
 * READ
 *=====================================================================*/
uint32_t npu_io_read32(uint32_t off)
{
    switch (off) {
    case NPU_CTRL:
        /* START/SOFT_RESET 은 W1P 라 항상 0 으로 읽힌다. SPARSE_EN 도 0. */
        return ((uint32_t)ctrl_hw_start_en << 5)
             | ((uint32_t)ctrl_irq_en      << 4)
             | ((uint32_t)ctrl_input_src   << 3);

    case NPU_STATUS: {
        uint32_t v;
        /* BUSY 는 STATUS 를 읽을 때마다 카운트다운한다.
         * 실제 하드웨어에서 시간이 흐르는 것을 대신한다.              */
        if (busy) {
            if (busy_countdown > 0) busy_countdown--;
            if (busy_countdown == 0) { busy = 0; done_sticky = 1; }
        }
        v = ((uint32_t)(res_valid ? 1 : 0) << 3)
          | ((uint32_t)(err_sticky  ? 1 : 0) << 2)
          | ((uint32_t)(busy        ? 1 : 0) << 1)
          | ((uint32_t)(done_sticky ? 1 : 0) << 0);
        return v;
    }

    case NPU_EVENT_CFG:    return r_event_cfg;
    case NPU_INPUT_STAT:   return r_input_stat;
    case NPU_CYCLE_CNT:    return res_cycles;
    case NPU_RESULT_X:     return res_x & NPU_RESULT_XY_MASK;
    case NPU_RESULT_Y:     return res_y & NPU_RESULT_XY_MASK;
    case NPU_RESULT_SCORE:
        return (((uint32_t)(uint8_t)r_score_th) << 16)
             |  ((uint32_t)(uint8_t)res_score);
    case NPU_PAN_CMD:      return r_pan;
    case NPU_TILT_CMD:     return r_tilt;
    case NPU_LASER_CTRL:   return r_laser;
    case NPU_SAFE_LIMIT:   return r_safe;
    case NPU_TRACK_ERR_X:  return r_terrx;
    case NPU_TRACK_ERR_Y:  return r_terry;
    case NPU_VERSION:      return NPU_VERSION_EXPECT;
    case NPU_INBUF_ADDR:   return r_inbuf_ptr;
    case NPU_INBUF_DATA:   return 0;          /* write only */
    case NPU_SCRATCH:      return r_scratch;
    case NPU_PAN2_CMD:     return r_pan2;
    case NPU_TILT2_CMD:    return r_tilt2;
    case NPU_SAFE_LIMIT2:  return r_safe2;
    case NPU_LASER_CAL:    return r_lcal;
    case NPU_SERVO_POS_STAT: return r_servo_pos;    /* RO */
    case NPU_CONTROL_STAT:   return r_control_stat; /* RO */
    default:               return 0;          /* 미정의 Offset */
    }
}

/*=====================================================================
 * WRITE
 *=====================================================================*/
void npu_io_write32(uint32_t off, uint32_t v)
{
    stat_regw++;

    switch (off) {
    case NPU_CTRL:
        if (v & NPU_CTRL_START) {
            /* RTL 과 동일: 이 write 를 반영한 뒤의 무장 상태로 판정한다.
             * 무장 중이면 PS START 를 안 먹인다 (두 START 동시 금지).  */
            int arm_after = ((v & NPU_CTRL_HW_START_EN) != 0)
                         && ((v & NPU_CTRL_INPUT_SRC)   != 0);
            if (busy || arm_after) {
                err_sticky = 1;              /* BUSY 중 / 무장 중 START -> ERROR */
            } else {
                stat_start++;
                done_sticky = 0;             /* START 가 DONE 을 지운다 */
                busy = 1;
                busy_countdown = busy_polls_cfg;
                if (busy_countdown == 0) { busy = 0; done_sticky = 1; }
            }
        }
        if (v & NPU_CTRL_SOFT_RESET) {
            /* RTL: done_sticky 와 INBUF 포인터만 지운다.
             *      err_sticky 는 안 지운다 (W1C 로만 지워진다).      */
            done_sticky = 0;
            r_inbuf_ptr = 0;
            busy = 0;
            busy_countdown = 0;
        }
        ctrl_input_src   = (v & NPU_CTRL_INPUT_SRC)   ? 1 : 0;
        ctrl_irq_en      = (v & NPU_CTRL_IRQ_EN)      ? 1 : 0;
        ctrl_hw_start_en = (v & NPU_CTRL_HW_START_EN) ? 1 : 0;
        break;

    case NPU_STATUS:                          /* W1C */
        if (v & NPU_ST_DONE)  done_sticky = 0;
        if (v & NPU_ST_ERROR) err_sticky  = 0;
        break;

    case NPU_EVENT_CFG:   r_event_cfg = v; break;
    case NPU_RESULT_SCORE:
        /* [23:16] 만 반영. [7:0] 은 RO 라 무시된다. */
        r_score_th = (int8_t)((v & NPU_SCORE_TH_MASK) >> NPU_SCORE_TH_SHIFT);
        break;
    case NPU_PAN_CMD:     r_pan   = v; break;
    case NPU_TILT_CMD:    r_tilt  = v; break;
    case NPU_LASER_CTRL:  r_laser = v; break;
    case NPU_SAFE_LIMIT:  r_safe  = v; break;
    case NPU_TRACK_ERR_X: r_terrx = v; break;
    case NPU_TRACK_ERR_Y: r_terry = v; break;
    case NPU_PAN2_CMD:    r_pan2  = v; break;
    case NPU_TILT2_CMD:   r_tilt2 = v; break;
    case NPU_SAFE_LIMIT2: r_safe2 = v; break;
    case NPU_LASER_CAL:   r_lcal  = v; break;
    case NPU_SCRATCH:     r_scratch = v; break;

    case NPU_INBUF_ADDR:
        r_inbuf_ptr = (v & 0x3FFCu);          /* 14 bit + 4 정렬 강제 */
        break;

    case NPU_INBUF_DATA: {
        int i;
        /* RTL: ib_allowed = ~busy & ~input_src & ~ptr[13]  */
        if (busy || ctrl_input_src || (r_inbuf_ptr & 0x2000u)) {
            err_sticky = 1;
            stat_dropped++;
            break;
        }
        for (i = 0; i < 4; i++) {             /* 리틀엔디안 4 byte */
            uint32_t a = r_inbuf_ptr + (uint32_t)i;
            if (a < (uint32_t)NPU_TENSOR_BYTES) {
                shadow[a] = (int8_t)((v >> (8 * i)) & 0xFFu);
                stat_byte_writes++;
            }
        }
        r_inbuf_ptr += 4;
        break;
    }

    default:                                   /* 미정의 Offset: 무시 */
        break;
    }
}
