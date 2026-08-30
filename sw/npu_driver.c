/*=====================================================================
 * npu_driver.c : NPU 제어 드라이버 구현
 * 담당: A
 * 기준: TEAM_COMMON_AI_INTEGRATION_SPEC v1.5 §20.1
 *
 * 이 파일의 시퀀스는 tb/integration/tb_top_system.v 가 AXI 로 검증한
 * 순서와 동일하다. 순서를 바꾸지 마라.
 *=====================================================================*/
#include "npu_driver.h"

/*---------------------------------------------------------------------
 * MMIO 백엔드
 *   보드(Vitis standalone) : 실제 메모리 맵 접근
 *   호스트 단위시험         : NPU_MOCK_IO 정의 -> sw/sim/npu_mock.c 가 제공
 *-------------------------------------------------------------------*/
#ifndef NPU_MOCK_IO
uint32_t npu_io_read32(uint32_t offset)
{
    return *(volatile uint32_t *)((uintptr_t)NPU_BASE_ADDR + offset);
}

void npu_io_write32(uint32_t offset, uint32_t value)
{
    *(volatile uint32_t *)((uintptr_t)NPU_BASE_ADDR + offset) = value;
}
#endif

#define RD(o)      npu_io_read32(o)
#define WR(o, v)   npu_io_write32((o), (uint32_t)(v))

/*---------------------------------------------------------------------
 * CTRL 은 START/SOFT_RESET 이 W1P(자동 클리어)라 read-modify-write 를
 * 하면 안 된다. 유지해야 하는 bit(INPUT_SRC/IRQ_EN)만 따로 들고 있는다.
 *-------------------------------------------------------------------*/
static uint32_t s_ctrl_sticky = 0;   /* INPUT_SRC | IRQ_EN | HW_START_EN */

/* Direct START 무장 상태. RTL 의 hw_start_armed 와 같은 식이다.
 * 무장 중에 PS 가 CTRL.START 를 쓰면 RTL 이 pulse 를 안 내고 ERROR 를 세운다. */
#define CTRL_ARMED() (((s_ctrl_sticky) & (NPU_CTRL_HW_START_EN | NPU_CTRL_INPUT_SRC)) \
                      == (NPU_CTRL_HW_START_EN | NPU_CTRL_INPUT_SRC))

static void ctrl_pulse(uint32_t pulse_bits)
{
    WR(NPU_CTRL, s_ctrl_sticky | pulse_bits);
}

/*=====================================================================*/
npu_status_t npu_init(void)
{
    uint32_t ver = RD(NPU_VERSION);
    if (ver != NPU_VERSION_EXPECT)
        return NPU_ERR_VERSION;

    s_ctrl_sticky = 0;
    ctrl_pulse(NPU_CTRL_SOFT_RESET);     /* NPU 리셋 + INBUF 포인터 0 */
    ctrl_pulse(0);                       /* pulse 해제                */

    npu_clear_status();                  /* sticky DONE/ERROR 정리    */
    npu_set_score_th(0);                 /* spec §16.1 기본값         */
    return NPU_OK;
}

/*=====================================================================*/
void npu_set_score_th(int8_t th)
{
    /* 0x1C 는 [7:0] RO(target_score) + [23:16] RW(SCORE_TH) 혼합이다.
     * RTL 이 wstrb[2] 인 byte lane 만 반영하므로 통째로 써도 안전하다. */
    WR(NPU_RESULT_SCORE, ((uint32_t)(uint8_t)th) << NPU_SCORE_TH_SHIFT);
}

int8_t npu_get_score_th(void)
{
    return (int8_t)((RD(NPU_RESULT_SCORE) & NPU_SCORE_TH_MASK)
                    >> NPU_SCORE_TH_SHIFT);
}

/*=====================================================================*/
void npu_set_input_src(int use_hw)
{
    if (use_hw) s_ctrl_sticky |=  NPU_CTRL_INPUT_SRC;
    else        s_ctrl_sticky &= ~NPU_CTRL_INPUT_SRC;
    ctrl_pulse(0);
}

int npu_get_input_src(void)
{
    return (RD(NPU_CTRL) & NPU_CTRL_INPUT_SRC) ? 1 : 0;
}

/*=====================================================================
 * Direct START (CR A-003 변경 2)
 *   1 로 켜면 C 의 event_accumulator 가 Tensor 전송을 끝내는 순간
 *   PS 를 거치지 않고 추론이 걸린다. INPUT_SRC 도 1 이어야 무장된다.
 *   무장 중에는 npu_start() 가 NPU_ERR_ARG 를 준다 — 두 START 를
 *   동시에 쓰면 안 된다는 C 지시를 드라이버에서도 막는다.
 *===================================================================*/
void npu_set_hw_start_en(int en)
{
    if (en) s_ctrl_sticky |=  NPU_CTRL_HW_START_EN;
    else    s_ctrl_sticky &= ~NPU_CTRL_HW_START_EN;
    ctrl_pulse(0);
}

int npu_get_hw_start_en(void)
{
    return (RD(NPU_CTRL) & NPU_CTRL_HW_START_EN) ? 1 : 0;
}

/*=====================================================================
 * C 상태 Register (0x0C / 0x58 / 0x5C)
 *   전부 RO 다. 값의 의미는 C 가 정의했다.
 *===================================================================*/
uint32_t npu_input_stat(void)   { return RD(NPU_INPUT_STAT);   }
uint32_t npu_control_stat(void) { return RD(NPU_CONTROL_STAT); }

void npu_get_servo_pos(npu_servo_pos_t *out)
{
    uint32_t v;
    if (out == NULL) return;
    v = RD(NPU_SERVO_POS_STAT);
    out->raw   = v;
    out->pan1  = (uint8_t)NPU_SPS_PAN1(v);
    out->tilt1 = (uint8_t)NPU_SPS_TILT1(v);
    out->pan2  = (uint8_t)NPU_SPS_PAN2(v);
    out->tilt2 = (uint8_t)NPU_SPS_TILT2(v);
}

/*=====================================================================
 * PS-managed START 용 : INPUT_STAT.TENSOR_READY(bit1) 폴링
 *   C 가 Tensor 한 장을 다 넣었다는 신호다. sticky 라 놓치지 않는다.
 *   npu_busy 가 서면 하드웨어가 알아서 지운다.
 *===================================================================*/
npu_status_t npu_wait_tensor_ready(uint32_t poll_limit)
{
    uint32_t n = 0;
    for (;;) {
        if (RD(NPU_INPUT_STAT) & NPU_IS_TENSOR_READY) return NPU_OK;
        if (poll_limit && ++n >= poll_limit) return NPU_ERR_TIMEOUT;
    }
}

/*=====================================================================
 * C 하드웨어 경로 한 프레임 (PS-managed START)
 *   TENSOR_READY 대기 -> START -> DONE 대기 -> 결과
 *   Direct START 를 켜 뒀다면 이걸 쓰면 안 된다. NPU_ERR_ARG 를 준다.
 *===================================================================*/
npu_status_t npu_run_hw_frame(uint32_t poll_limit, npu_result_t *out)
{
    npu_status_t s;

    if (!(s_ctrl_sticky & NPU_CTRL_INPUT_SRC)) return NPU_ERR_ARG;
    if (CTRL_ARMED())                          return NPU_ERR_ARG;

    s = npu_wait_tensor_ready(poll_limit);
    if (s != NPU_OK) return s;

    s = npu_start();
    if (s != NPU_OK) return s;

    s = npu_wait_done(poll_limit);
    if (s != NPU_OK) return s;

    npu_get_result(out);
    return NPU_OK;
}

/*=====================================================================*/
npu_status_t npu_load_tensor(const int8_t *tensor, size_t len)
{
    size_t i;

    if (tensor == NULL || len != (size_t)NPU_TENSOR_BYTES)
        return NPU_ERR_ARG;
    if (RD(NPU_STATUS) & NPU_ST_BUSY)
        return NPU_ERR_BUSY;
    if (s_ctrl_sticky & NPU_CTRL_INPUT_SRC)
        return NPU_ERR_ARG;              /* C 하드웨어가 입력 소스다 */

    npu_clear_status();
    WR(NPU_INBUF_ADDR, 0);

    /* 4 byte 씩 리틀엔디안으로 묶어서 쓴다.
     * 포인터 캐스팅 대신 byte 조립 -> 정렬/aliasing 문제 없음.
     * RTL 이 wdata[7:0] 을 낮은 주소에 넣으므로 이 순서가 맞다.      */
    for (i = 0; i < (size_t)NPU_TENSOR_BYTES; i += 4) {
        uint32_t w =  ((uint32_t)(uint8_t)tensor[i    ])
                   | (((uint32_t)(uint8_t)tensor[i + 1]) <<  8)
                   | (((uint32_t)(uint8_t)tensor[i + 2]) << 16)
                   | (((uint32_t)(uint8_t)tensor[i + 3]) << 24);
        WR(NPU_INBUF_DATA, w);
    }

    /* 한 프레임이 정확히 다 들어갔는지 하드웨어에 되물어본다. */
    if (RD(NPU_INBUF_ADDR) != (uint32_t)NPU_TENSOR_BYTES)
        return NPU_ERR_LOAD;
    if (RD(NPU_STATUS) & NPU_ST_ERROR)
        return NPU_ERR_HW;

    return NPU_OK;
}

/*=====================================================================*/
npu_status_t npu_start(void)
{
    if (RD(NPU_STATUS) & NPU_ST_BUSY)
        return NPU_ERR_BUSY;
    /* Direct START 무장 중이면 RTL 이 이 write 를 거부하고 ERROR 를 세운다.
     * 여기서 먼저 막아 ERROR sticky 를 더럽히지 않는다.                 */
    if (CTRL_ARMED())
        return NPU_ERR_ARG;
    ctrl_pulse(NPU_CTRL_START);          /* START 가 DONE sticky 를 지운다 */
    return NPU_OK;
}

/*=====================================================================*/
npu_status_t npu_wait_done(uint32_t poll_limit)
{
    uint32_t n = 0;
    for (;;) {
        uint32_t st = RD(NPU_STATUS);
        if (st & NPU_ST_ERROR) return NPU_ERR_HW;
        if (st & NPU_ST_DONE)  return NPU_OK;      /* BUSY 아님. DONE 이다 */
        if (poll_limit && ++n >= poll_limit) return NPU_ERR_TIMEOUT;
    }
}

/*=====================================================================*/
void npu_get_result(npu_result_t *out)
{
    uint32_t st, sc;
    if (out == NULL) return;

    st = RD(NPU_STATUS);
    sc = RD(NPU_RESULT_SCORE);

    out->valid  = (st & NPU_ST_TARGET_VALID) ? 1 : 0;
    out->x      = RD(NPU_RESULT_X) & NPU_RESULT_XY_MASK;
    out->y      = RD(NPU_RESULT_Y) & NPU_RESULT_XY_MASK;
    out->score  = (int8_t)(sc & NPU_SCORE_MASK);
    out->cycles = RD(NPU_CYCLE_CNT);
}

/*=====================================================================*/
npu_status_t npu_run(const int8_t *tensor, size_t len,
                     uint32_t poll_limit, npu_result_t *out)
{
    npu_status_t s;

    s = npu_load_tensor(tensor, len);
    if (s != NPU_OK) return s;

    s = npu_start();
    if (s != NPU_OK) return s;

    s = npu_wait_done(poll_limit);
    if (s != NPU_OK) return s;

    npu_get_result(out);
    return NPU_OK;
}

/*=====================================================================*/
void npu_clear_status(void)
{
    WR(NPU_STATUS, NPU_ST_DONE | NPU_ST_ERROR);   /* W1C */
}

uint32_t npu_status_raw(void)
{
    return RD(NPU_STATUS);
}

/*=====================================================================*/
const char *npu_strerror(npu_status_t s)
{
    switch (s) {
    case NPU_OK:          return "OK";
    case NPU_ERR_VERSION: return "VERSION 불일치 (AXI 배선/주소 확인)";
    case NPU_ERR_BUSY:    return "NPU BUSY";
    case NPU_ERR_TIMEOUT: return "DONE timeout";
    case NPU_ERR_HW:      return "STATUS.ERROR 세워짐";
    case NPU_ERR_LOAD:    return "Tensor 적재 실패 (INBUF_ADDR != 8192)";
    case NPU_ERR_ARG:     return "인자 오류";
    default:              return "unknown";
    }
}

/*=====================================================================
 * Pan/Tilt — C 담당 영역. A 는 레지스터 창구만 제공한다.
 *   PT#1 (0x20/0x24) = 이벤트 카메라 헤드
 *   PT#2 (0x48/0x4C) = 레이저 헤드
 * PT#2 각도는 반드시 spec §15.2 좌표 변환식으로 구한다:
 *   theta_pan_target = theta_pan1 + k_x*(target_x-32)
 *   PAN2_CMD         = theta_pan_target + LASER_OFFSET_PAN
 * PAN2_CMD = f(error_x) 로 짜면 레이저가 표적이 아니라 오차를 따라간다.
 *=====================================================================*/
void npu_set_pt1(uint32_t pan, uint32_t tilt)
{
    WR(NPU_PAN_CMD,  pan);
    WR(NPU_TILT_CMD, tilt);
}

void npu_set_pt2(uint32_t pan2, uint32_t tilt2)
{
    WR(NPU_PAN2_CMD,  pan2);
    WR(NPU_TILT2_CMD, tilt2);
}

uint32_t npu_get_pt1_pan(void) { return RD(NPU_PAN_CMD);  }
uint32_t npu_get_pt2_pan(void) { return RD(NPU_PAN2_CMD); }
