/*=====================================================================
 * test_driver.c : npu_driver.c 호스트 단위시험
 * 담당: A
 *
 * 보드 없이 드라이버 로직을 검증한다.
 * 상대는 sw/sim/npu_mock.c — npu_axi.v 와 같은 계약을 구현한 목이다.
 *
 * 검증 대상
 *   - VERSION 확인 / 실패 감지
 *   - Tensor 적재 byte 순서 (리틀엔디안) 와 주소 순서
 *   - DONE(sticky) 폴링.  BUSY 폴링이 아니라는 것
 *   - SCORE_TH 가 0x1C 상위 byte 에만 들어가고 target_score 를 안 건드리는 것
 *   - BUSY 중 START / 적재 거부
 *   - INPUT_SRC=1 일 때 PS 적재 거부
 *   - timeout / ERROR 경로
 *   - PT#1 / PT#2 레지스터 독립성
 *   - 0x58 / 0x5C RO 디코드 (CR A-003 변경 1)
 *   - Direct START 무장/해제 와 두 START 동시 금지 (CR A-003 변경 2)
 *
 * 빌드/실행:  cd sw && make test
 *=====================================================================*/
#include <stdio.h>
#include <string.h>
#include "../npu_driver.h"
#include "../test_tensor.h"
#include "npu_mock.h"

static int checks = 0, errs = 0;

#define CHK(cond, msg)                                                 \
    do {                                                               \
        checks++;                                                      \
        if (!(cond)) {                                                 \
            errs++;                                                    \
            printf("  [FAIL] %s\n", (msg));                            \
        }                                                              \
    } while (0)

#define CHK_EQ(got, exp, name)                                         \
    do {                                                               \
        long g = (long)(got), e = (long)(exp);                         \
        checks++;                                                      \
        if (g != e) {                                                  \
            errs++;                                                    \
            printf("  [FAIL] %s : got %ld exp %ld\n", (name), g, e);   \
        }                                                              \
    } while (0)

static void section(const char *s) { printf("\n=== %s ===\n", s); }

/*---------------------------------------------------------------------*/
static void t_init(void)
{
    npu_status_t s;
    section("1. npu_init / VERSION");

    npu_mock_reset();
    s = npu_init();
    CHK_EQ(s, NPU_OK, "npu_init");
    CHK_EQ(npu_get_score_th(), 0, "init 후 SCORE_TH 기본값 0");
    CHK_EQ(npu_status_raw() & (NPU_ST_DONE | NPU_ST_ERROR), 0,
           "init 후 sticky bit 정리됨");
    CHK_EQ(npu_get_input_src(), 0, "init 후 INPUT_SRC=0");
}

/*---------------------------------------------------------------------*/
static void t_load_order(void)
{
    npu_status_t s;
    const int8_t *shadow;
    int i, mism = 0;

    section("2. Tensor 적재 — byte 순서 / 엔디안");

    npu_mock_reset();
    npu_init();

    s = npu_load_tensor(test_tensor, TEST_TENSOR_BYTES);
    CHK_EQ(s, NPU_OK, "npu_load_tensor");
    CHK_EQ(npu_mock_byte_writes(), TEST_TENSOR_BYTES, "기록된 byte 수");
    CHK_EQ(npu_mock_dropped(), 0, "버려진 write 없음");

    /* RTL 이 wdata[7:0] 을 낮은 주소에 넣는다.
     * 드라이버가 그 순서로 묶었는지 byte 단위로 전수 확인. */
    shadow = npu_mock_buffer();
    for (i = 0; i < TEST_TENSOR_BYTES; i++) {
        if (shadow[i] != test_tensor[i]) {
            if (mism < 3)
                printf("  [FAIL] byte %d : got %d exp %d\n",
                       i, shadow[i], test_tensor[i]);
            mism++;
        }
    }
    CHK_EQ(mism, 0, "8192 byte 전수 일치");

    /* 하드웨어에 되물어보는 검사가 실제로 동작하는가 */
    CHK_EQ(npu_io_read32(NPU_INBUF_ADDR), TEST_TENSOR_BYTES,
           "적재 후 INBUF_ADDR == 8192");
}

/*---------------------------------------------------------------------*/
static void t_run_poll(void)
{
    npu_result_t r;
    npu_status_t s;

    section("3. 추론 + DONE 폴링");

    npu_mock_reset();
    npu_init();
    npu_mock_set_result(TEST_EXPECT_VALID, TEST_EXPECT_X, TEST_EXPECT_Y,
                        (int8_t)TEST_EXPECT_SCORE, 125845u);
    npu_mock_set_busy_polls(50);        /* 50 번 폴링해야 DONE */

    memset(&r, 0, sizeof(r));
    s = npu_run(test_tensor, TEST_TENSOR_BYTES, 5000, &r);

    CHK_EQ(s, NPU_OK, "npu_run");
    CHK_EQ(npu_mock_start_pulses(), 1, "START 정확히 1회");
    CHK_EQ(r.valid,  TEST_EXPECT_VALID, "target_valid");
    CHK_EQ(r.x,      TEST_EXPECT_X,     "target_x");
    CHK_EQ(r.y,      TEST_EXPECT_Y,     "target_y");
    CHK_EQ(r.score,  TEST_EXPECT_SCORE, "target_score");
    CHK_EQ(r.cycles, 125845u,           "cycle_cnt");

    printf("  결과: valid=%d (x,y)=(%u,%u) score=%d cycle=%u (@100MHz %.3f ms)\n",
           r.valid, r.x, r.y, r.score, r.cycles, r.cycles / 100000.0);
}

/*---------------------------------------------------------------------*/
static void t_done_not_busy(void)
{
    npu_status_t s;

    section("4. BUSY 가 아니라 DONE 을 봐야 한다");

    npu_mock_reset();
    npu_init();
    npu_mock_set_result(1, 52, 28, 127, 125845u);

    /* busy_polls = 0 -> START 직후 바로 DONE.
     * BUSY 를 폴링하는 구현이면 여기서 "시작도 안 했는데 끝났다"고
     * 오판하거나, BUSY 를 못 봐서 무한 대기한다.                    */
    npu_mock_set_busy_polls(0);
    npu_load_tensor(test_tensor, TEST_TENSOR_BYTES);
    npu_start();
    s = npu_wait_done(100);
    CHK_EQ(s, NPU_OK, "busy_polls=0 이어도 DONE 을 놓치지 않는다");

    /* START 는 이전 DONE sticky 를 지워야 한다.
     * 안 지우면 다음 프레임에서 이전 결과를 완료로 오인한다.        */
    npu_mock_set_busy_polls(20);
    npu_load_tensor(test_tensor, TEST_TENSOR_BYTES);
    npu_start();
    CHK_EQ(npu_io_read32(NPU_STATUS) & NPU_ST_DONE, 0,
           "START 직후 DONE 이 지워져 있다");
    s = npu_wait_done(1000);
    CHK_EQ(s, NPU_OK, "두 번째 프레임도 정상 완료");
}

/*---------------------------------------------------------------------*/
static void t_score_th(void)
{
    uint32_t raw;

    section("5. SCORE_TH — 0x1C 혼합 레지스터");

    npu_mock_reset();
    npu_init();
    npu_mock_set_result(1, 52, 28, -7, 100u);

    npu_set_score_th(20);
    CHK_EQ(npu_get_score_th(), 20, "SCORE_TH=20 왕복");

    raw = npu_io_read32(NPU_RESULT_SCORE);
    CHK_EQ((int8_t)(raw & 0xFF), -7,
           "SCORE_TH 를 써도 target_score(RO) 는 안 바뀐다");
    CHK_EQ((raw >> 16) & 0xFF, 20, "SCORE_TH 가 [23:16] 에 있다");

    npu_set_score_th(-30);
    CHK_EQ(npu_get_score_th(), -30, "음수 SCORE_TH (signed INT8)");

    npu_set_score_th(0);
}

/*---------------------------------------------------------------------*/
static void t_error_paths(void)
{
    npu_status_t s;
    npu_result_t r;

    section("6. 오류 경로");

    /* 6-1. BUSY 중 적재 / START 거부 */
    npu_mock_reset();
    npu_init();
    npu_mock_set_result(1, 52, 28, 127, 100u);
    npu_mock_set_busy_polls(1000);
    npu_load_tensor(test_tensor, TEST_TENSOR_BYTES);
    npu_start();

    s = npu_load_tensor(test_tensor, TEST_TENSOR_BYTES);
    CHK_EQ(s, NPU_ERR_BUSY, "BUSY 중 적재는 NPU_ERR_BUSY");
    s = npu_start();
    CHK_EQ(s, NPU_ERR_BUSY, "BUSY 중 START 는 NPU_ERR_BUSY");
    CHK_EQ(npu_mock_start_pulses(), 1, "START 는 여전히 1회뿐");

    /* 6-2. timeout */
    npu_mock_reset();
    npu_init();
    npu_mock_set_busy_polls(100000);
    npu_load_tensor(test_tensor, TEST_TENSOR_BYTES);
    npu_start();
    s = npu_wait_done(50);
    CHK_EQ(s, NPU_ERR_TIMEOUT, "폴링 한도 초과 -> NPU_ERR_TIMEOUT");

    /* 6-3. INPUT_SRC=1 이면 PS 적재 거부 */
    npu_mock_reset();
    npu_init();
    npu_set_input_src(1);
    CHK_EQ(npu_get_input_src(), 1, "INPUT_SRC=1 설정됨");
    s = npu_load_tensor(test_tensor, TEST_TENSOR_BYTES);
    CHK_EQ(s, NPU_ERR_ARG, "INPUT_SRC=1 이면 PS 적재 거부");
    CHK_EQ(npu_mock_byte_writes(), 0, "실제로 한 byte 도 안 썼다");
    npu_set_input_src(0);

    /* 6-4. 인자 오류 */
    npu_mock_reset(); npu_init();
    CHK_EQ(npu_load_tensor(NULL, TEST_TENSOR_BYTES), NPU_ERR_ARG, "NULL tensor");
    CHK_EQ(npu_load_tensor(test_tensor, 100), NPU_ERR_ARG, "잘못된 길이");

    /* 6-5. VERSION 불일치는 init 에서 잡힌다 (mock 은 항상 맞으므로
     *      여기서는 반환 코드 문자열만 확인) */
    CHK(strlen(npu_strerror(NPU_ERR_VERSION)) > 0, "strerror(VERSION)");
    CHK(strlen(npu_strerror(NPU_ERR_HW)) > 0, "strerror(HW)");

    (void)r;
}

/*---------------------------------------------------------------------*/
static void t_pantilt(void)
{
    section("7. Pan/Tilt 2 헤드 레지스터 독립성");

    npu_mock_reset();
    npu_init();

    npu_set_pt1(0x00000090u, 0xFFFFFF80u);   /* 카메라 헤드 */
    npu_set_pt2(0x000000A5u, 0xFFFFFFC4u);   /* 레이저 헤드 */

    CHK_EQ(npu_get_pt1_pan(), 0x00000090u, "PT#1 pan 왕복");
    CHK_EQ(npu_get_pt2_pan(), 0x000000A5u, "PT#2 pan 왕복");
    CHK_EQ(npu_io_read32(NPU_TILT_CMD),  0xFFFFFF80u, "PT#1 tilt 왕복");
    CHK_EQ(npu_io_read32(NPU_TILT2_CMD), 0xFFFFFFC4u, "PT#2 tilt 왕복");

    /* PT#2 를 써도 PT#1 이 오염되면 안 된다 */
    npu_set_pt2(0xDEADBEEFu, 0xCAFEBABEu);
    CHK_EQ(npu_get_pt1_pan(), 0x00000090u, "PT#2 write 가 PT#1 을 안 건드린다");
}

/*---------------------------------------------------------------------*/
static void t_repeat(void)
{
    npu_result_t r;
    int i, bad = 0;

    section("8. 연속 프레임 반복 (32회)");

    npu_mock_reset();
    npu_init();
    npu_mock_set_result(1, TEST_EXPECT_X, TEST_EXPECT_Y,
                        (int8_t)TEST_EXPECT_SCORE, 125845u);
    npu_mock_set_busy_polls(10);

    for (i = 0; i < 32; i++) {
        npu_status_t s = npu_run(test_tensor, TEST_TENSOR_BYTES, 1000, &r);
        if (s != NPU_OK || r.x != TEST_EXPECT_X || r.y != TEST_EXPECT_Y)
            bad++;
    }
    CHK_EQ(bad, 0, "32 프레임 전부 동일 결과");
    CHK_EQ(npu_mock_start_pulses(), 32, "START 32회");
    CHK_EQ(npu_io_read32(NPU_STATUS) & NPU_ST_ERROR, 0, "ERROR 안 섰다");
}

/*---------------------------------------------------------------------*/
static void t_irq(void)
{
    section("9. IRQ = IRQ_EN & DONE");

    npu_mock_reset();
    npu_init();
    npu_mock_set_result(1, 52, 28, 127, 100u);
    npu_mock_set_busy_polls(5);

    npu_load_tensor(test_tensor, TEST_TENSOR_BYTES);
    npu_start();
    npu_wait_done(100);
    CHK_EQ(npu_mock_irq(), 0, "IRQ_EN=0 이면 irq 안 뜬다");

    npu_io_write32(NPU_CTRL, NPU_CTRL_IRQ_EN);
    CHK_EQ(npu_mock_irq(), 1, "IRQ_EN=1 + DONE -> irq");

    npu_clear_status();
    CHK_EQ(npu_mock_irq(), 0, "DONE W1C 하면 irq 내려간다");
}

/*---------------------------------------------------------------------
 * 10. 0x58 SERVO_POS_STAT / 0x5C CONTROL_STAT (RO)  — CR A-003 변경 1
 *-------------------------------------------------------------------*/
static void t_stat_regs(void)
{
    npu_servo_pos_t sp;

    section("10. C 상태 RO Register (0x0C / 0x58 / 0x5C)");

    npu_mock_reset();
    npu_init();

    /* C 가 만드는 값을 심는다. RTL 에서는 c_event_control_top 이 준다. */
    npu_mock_set_stat(0x6E5A4632u,          /* {TILT2,PAN2,TILT1,PAN1} */
                      NPU_CST_SERVO_ENABLE | NPU_CST_SW_ARM
                    | NPU_CST_ACC_READY    | NPU_CST_LASER_LOCK);
    npu_mock_set_input_stat(0x0001190Bu);   /* evt=281 drop=0 (tb F1 실측값) */

    npu_get_servo_pos(&sp);
    CHK_EQ(sp.raw,   0x6E5A4632u, "SERVO_POS_STAT raw");
    CHK_EQ(sp.pan1,  0x32u, "SERVO_POS pan1  (카메라)");
    CHK_EQ(sp.tilt1, 0x46u, "SERVO_POS tilt1 (카메라)");
    CHK_EQ(sp.pan2,  0x5Au, "SERVO_POS pan2  (레이저)");
    CHK_EQ(sp.tilt2, 0x6Eu, "SERVO_POS tilt2 (레이저)");

    CHK(  npu_control_stat() & NPU_CST_SERVO_ENABLE, "CONTROL_STAT SERVO_ENABLE");
    CHK(  npu_control_stat() & NPU_CST_SW_ARM,       "CONTROL_STAT SW_ARM");
    CHK(!(npu_control_stat() & NPU_CST_HW_ARM),      "CONTROL_STAT HW_ARM=0");
    CHK(!(npu_control_stat() & NPU_CST_LASER_EN),    "CONTROL_STAT LASER_EN=0");
    CHK_EQ(npu_control_stat() & NPU_CST_RSVD_MASK, 0u,
           "CONTROL_STAT [31:17] = 0");

    /* RO 다. write 해도 안 바뀐다 (RTL 은 default 로 무시한다) */
    npu_io_write32(NPU_SERVO_POS_STAT, 0xFFFFFFFFu);
    npu_io_write32(NPU_CONTROL_STAT,   0xFFFFFFFFu);
    npu_get_servo_pos(&sp);
    CHK_EQ(sp.raw, 0x6E5A4632u, "0x58 은 RO (write 무시)");
    CHK_EQ(npu_control_stat() & NPU_CST_RSVD_MASK, 0u, "0x5C 은 RO (write 무시)");

    /* INPUT_STAT 디코드 매크로 */
    CHK_EQ(NPU_IS_EVT_CNT(npu_input_stat()),  281, "INPUT_STAT evt count");
    CHK_EQ(NPU_IS_DROP_CNT(npu_input_stat()),   0, "INPUT_STAT drop count");
    CHK(  npu_input_stat() & NPU_IS_TENSOR_READY, "INPUT_STAT TENSOR_READY");
}

/*---------------------------------------------------------------------
 * 11. Direct START (CTRL[5] HW_START_EN)  — CR A-003 변경 2
 *-------------------------------------------------------------------*/
static void t_direct_start(void)
{
    npu_result_t r;
    npu_status_t s;

    section("11. Direct START (CTRL[5] HW_START_EN)");

    npu_mock_reset();
    npu_init();
    npu_mock_set_result(1, TEST_EXPECT_X, TEST_EXPECT_Y,
                        (int8_t)TEST_EXPECT_SCORE, 125845u);
    npu_mock_set_busy_polls(5);

    /* 무장 전에는 HW pulse 를 무시한다 */
    npu_mock_hw_start();
    CHK_EQ(npu_mock_start_pulses(), 0, "무장 전 hw pulse 무시");

    /* HW_START_EN 만 켜도 INPUT_SRC=0 이면 무장이 아니다 */
    npu_set_hw_start_en(1);
    CHK_EQ(npu_get_hw_start_en(), 1, "HW_START_EN 왕복");
    npu_mock_hw_start();
    CHK_EQ(npu_mock_start_pulses(), 0, "INPUT_SRC=0 이면 여전히 무시");

    /* 무장 */
    npu_set_input_src(1);
    npu_mock_hw_start();
    CHK_EQ(npu_mock_start_pulses(), 1, "무장 후 hw pulse -> START");
    CHK_EQ(npu_wait_done(100), NPU_OK, "Direct START 로 DONE 도달");
    npu_get_result(&r);
    CHK_EQ(r.x, TEST_EXPECT_X, "Direct START 결과 x");
    CHK_EQ(r.y, TEST_EXPECT_Y, "Direct START 결과 y");

    /* 무장 중 PS START 는 드라이버가 먼저 막는다 (ERROR sticky 오염 방지) */
    s = npu_start();
    CHK_EQ(s, NPU_ERR_ARG, "무장 중 npu_start 는 ERR_ARG");
    CHK_EQ(npu_io_read32(NPU_STATUS) & NPU_ST_ERROR, 0,
           "드라이버가 막았으니 ERROR 도 안 선다");
    CHK_EQ(npu_run_hw_frame(100, &r), NPU_ERR_ARG,
           "무장 중 PS-managed 프레임은 ERR_ARG");

    /* 그래도 PS 가 직접 CTRL 을 쓰면 RTL 이 거부하고 ERROR 를 세운다 */
    npu_io_write32(NPU_CTRL, NPU_CTRL_START | NPU_CTRL_INPUT_SRC
                           | NPU_CTRL_HW_START_EN);
    CHK_EQ(npu_mock_start_pulses(), 1, "무장 중 CTRL.START 는 pulse 안 남");
    CHK(npu_io_read32(NPU_STATUS) & NPU_ST_ERROR, "무장 중 START -> ERROR");
    npu_clear_status();

    /* 무장 해제 후에는 PS-managed 가 정상 동작한다 */
    npu_set_hw_start_en(0);
    npu_mock_set_input_stat(NPU_IS_ACC_READY | NPU_IS_TENSOR_READY);
    CHK_EQ(npu_run_hw_frame(100, &r), NPU_OK, "해제 후 PS-managed 프레임 OK");
    CHK_EQ(npu_mock_start_pulses(), 2, "START 누적 2회");
    npu_mock_hw_start();
    CHK_EQ(npu_mock_start_pulses(), 2, "해제 후 hw pulse 다시 무시");

    /* INPUT_SRC=0 이면 PS-managed 프레임 자체가 인자 오류 */
    npu_set_input_src(0);
    CHK_EQ(npu_run_hw_frame(100, &r), NPU_ERR_ARG,
           "INPUT_SRC=0 에서 hw frame 은 ERR_ARG");
}

/*=====================================================================*/
int main(void)
{
    printf("=====================================================\n");
    printf(" npu_driver 호스트 단위시험 (보드 없이)\n");
    printf(" 상대: sw/sim/npu_mock.c  = npu_axi.v 와 동일 계약\n");
    printf("=====================================================\n");

    t_init();
    t_load_order();
    t_run_poll();
    t_done_not_busy();
    t_score_th();
    t_error_paths();
    t_pantilt();
    t_repeat();
    t_irq();
    t_stat_regs();
    t_direct_start();

    printf("\n");
    if (errs == 0) printf("[PASS] test_driver : %d check 전부 일치\n", checks);
    else           printf("[FAIL] test_driver : %d / %d 불일치\n", errs, checks);
    return errs ? 1 : 0;
}
