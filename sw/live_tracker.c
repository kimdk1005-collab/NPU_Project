/*=====================================================================
 * live_tracker.c : PC 카메라 -> UART -> NPU 실시간 추론 루프 (보드측)
 * 담당: A
 *
 * 무엇을 하나
 * ------------
 *   1. UART 로 Event Tensor Frame 을 받는다 (sw/live_protocol.h 규격)
 *   2. CRC 검사 -> 8192 byte CHW 복원
 *   3. npu_load_tensor() -> npu_start() -> npu_wait_done()
 *   4. 결과 한 줄을 UART 로 되돌려 준다
 *
 * 무엇을 안 하나 — 중요
 * ----------------------
 *   Servo / Laser 를 PS 가 건드리지 않는다.  NPU 결과는 RTL 안에서 바로
 *   C 제어부로 간다 (rtl/integration/top_system_c.v: npu_target_valid/x/y/
 *   score -> u_c.target_*).  PS 는 Tensor 를 넣어 주는 일만 한다.
 *   Tracking / Servo / Laser interlock 은 전부 C 소유 RTL 이 한다.
 *
 * 어느 경로인가
 * --------------
 *   INPUT_SRC = 0 (PS 적재), HW_START_EN = 0 (PS-managed START).
 *   AXI Register Map 을 한 비트도 안 바꾼다.  CR A-004 / WINDOW_SRC 무관.
 *
 *   ** Direct START 와 PS START 를 동시에 켜지 마라 (C 지시). **
 *   이 프로그램은 시작할 때 두 비트를 명시적으로 0 으로 만든다.
 *
 * 빌드
 * -----
 *   보드 : vitis -s sw/build_vitis_unified.py --app live_tracker
 *   호스트: cd sw && make live-host      (프로토콜/디코더 문법 확인용)
 *
 * ** 이 프로그램은 npu_test.elf 를 대체하지 않는다. **
 *    보드 자체시험 STEP 1~7 은 여전히 npu_test.elf 로 한다.
 *    Live 시연 때만 live_tracker.elf 를 올린다.
 *=====================================================================*/
#include "npu_driver.h"
#include "live_protocol.h"

#include <string.h>

/*---------------------------------------------------------------------
 * 플랫폼 입출력
 *   보드   : xil_printf + inbyte (UART)
 *   호스트 : printf + stdin      (-DNPU_NO_XIL, 문법/로직 확인용)
 *-------------------------------------------------------------------*/
#ifdef NPU_NO_XIL
#include <stdio.h>
#define PR printf
static int rx_byte(uint8_t *out)
{
    int c = getchar();
    if (c == EOF) {
        return 0;
    }
    *out = (uint8_t)c;
    return 1;
}
#else
#include "xil_printf.h"
#define PR xil_printf
static int rx_byte(uint8_t *out)
{
    *out = (uint8_t)inbyte();
    return 1;                    /* inbyte 는 블로킹이라 실패가 없다 */
}
#endif

/*---------------------------------------------------------------------
 * 버퍼
 *   Frame 최대 = header 10 + payload 8192 + crc 4 = 8206
 *-------------------------------------------------------------------*/
#define FRAME_MAX (LIVE_HEADER_SIZE + LIVE_MAX_PAYLOAD + LIVE_CRC_SIZE)

static uint8_t s_frame[FRAME_MAX];
static int8_t  s_tensor[LIVE_TENSOR_BYTES];

/* NPU 폴링 한계. 1 프레임이 125,845 cycle @100MHz = 1.258 ms 다.
 * 넉넉히 잡되 무한대기는 안 한다 (멈추면 사람이 원인을 못 본다). */
#define POLL_LIMIT 4000000u

static uint32_t s_rx_ok, s_rx_crc_err, s_rx_bad, s_run_err;

/*---------------------------------------------------------------------
 * magic 을 찾을 때까지 읽는다. 잡음/재동기화 대응.
 *-------------------------------------------------------------------*/
static int sync_to_magic(void)
{
    uint8_t window[4];
    uint8_t b;
    int filled = 0;

    for (;;) {
        if (!rx_byte(&b)) {
            return 0;                     /* 호스트 모드 EOF */
        }
        if (filled < 4) {
            window[filled++] = b;
        } else {
            window[0] = window[1];
            window[1] = window[2];
            window[2] = window[3];
            window[3] = b;
        }
        if (filled == 4 &&
            window[0] == LIVE_MAGIC0 && window[1] == LIVE_MAGIC1 &&
            window[2] == LIVE_MAGIC2 && window[3] == LIVE_MAGIC3) {
            s_frame[0] = LIVE_MAGIC0;
            s_frame[1] = LIVE_MAGIC1;
            s_frame[2] = LIVE_MAGIC2;
            s_frame[3] = LIVE_MAGIC3;
            return 1;
        }
    }
}

/* n byte 를 s_frame[offset..] 에 채운다. */
static int rx_exact(uint32_t offset, uint32_t n)
{
    uint32_t i;
    for (i = 0u; i < n; i++) {
        if (!rx_byte(&s_frame[offset + i])) {
            return 0;
        }
    }
    return 1;
}

/*---------------------------------------------------------------------
 * Frame 하나를 통째로 받는다.  성공하면 전체 길이를 준다.
 *-------------------------------------------------------------------*/
static uint32_t receive_frame(void)
{
    uint16_t length;
    uint32_t rest;

    if (!sync_to_magic()) {
        return 0u;
    }
    /* version/type/seq/length = 6 byte */
    if (!rx_exact(4u, LIVE_HEADER_SIZE - 4u)) {
        return 0u;
    }
    length = live_rd16(s_frame + 8);
    if ((uint32_t)length > LIVE_MAX_PAYLOAD) {
        s_rx_bad++;
        PR("ERR len=%u\r\n", (unsigned)length);   /* 다음 magic 부터 재동기화 */
        return 0xFFFFFFFFu;
    }
    rest = (uint32_t)length + LIVE_CRC_SIZE;
    if (!rx_exact(LIVE_HEADER_SIZE, rest)) {
        return 0u;
    }
    return LIVE_HEADER_SIZE + rest;
}

/*---------------------------------------------------------------------
 * Tensor Frame 하나 처리
 *-------------------------------------------------------------------*/
static void handle_tensor(uint8_t type, uint16_t seq,
                          const uint8_t *payload, uint16_t length)
{
    npu_result_t r;
    npu_status_t st;
    int nz = 0;

    memset(s_tensor, 0, sizeof(s_tensor));

    if (type == LIVE_TYPE_TENSOR_SPARSE) {
        nz = live_decode_sparse(payload, (uint32_t)length, s_tensor);
        if (nz < 0) {
            s_rx_bad++;
            PR("ERR sparse seq=%u code=%d\r\n", (unsigned)seq, nz);
            return;
        }
    } else {                                   /* LIVE_TYPE_TENSOR_RAW */
        uint32_t i;
        if ((uint32_t)length != LIVE_TENSOR_BYTES) {
            s_rx_bad++;
            PR("ERR raw seq=%u len=%u\r\n", (unsigned)seq, (unsigned)length);
            return;
        }
        memcpy(s_tensor, payload, LIVE_TENSOR_BYTES);
        for (i = 0u; i < LIVE_TENSOR_BYTES; i++) {
            if (s_tensor[i] != 0) {
                nz++;
            }
        }
    }

    st = npu_run(s_tensor, LIVE_TENSOR_BYTES, POLL_LIMIT, &r);
    if (st != NPU_OK) {
        s_run_err++;
        PR("ERR npu seq=%u %s\r\n", (unsigned)seq, npu_strerror(st));
        npu_clear_status();
        return;
    }

    s_rx_ok++;
    /* xil_printf 는 %d 로 signed char 를 그대로 못 찍는다. int 로 올린다. */
    PR("RES seq=%u valid=%d x=%u y=%u score=%d cycle=%u nz=%d\r\n",
       (unsigned)seq, r.valid, (unsigned)r.x, (unsigned)r.y,
       (int)r.score, (unsigned)r.cycles, nz);
}

/*---------------------------------------------------------------------
 * main
 *-------------------------------------------------------------------*/
int main(void)
{
    npu_status_t st;

    PR("\r\n=============================================\r\n");
    PR(" NPU Live Tracker  (a_live_v01)\r\n");
    PR("   protocol : NPUL v%u   tensor %u byte CHW\r\n",
       (unsigned)LIVE_VERSION, (unsigned)LIVE_TENSOR_BYTES);
    PR("   path     : INPUT_SRC=0 (PS load) + PS-managed START\r\n");
    PR("   servo/laser : RTL 안에서 C 제어부가 직접 받는다. PS 는 안 건드린다\r\n");
    PR("=============================================\r\n");

    st = npu_init();
    if (st != NPU_OK) {
        PR("FATAL npu_init: %s\r\n", npu_strerror(st));
        PR("  VERSION 이 0x4E500101 이 아니면 옛 비트스트림이다.\r\n");
        return 1;
    }

    /* Live 경로 계약을 못 박는다. 둘 다 0 이어야 PS 가 START 를 걸 수 있다. */
    npu_set_input_src(0);
    npu_set_hw_start_en(0);
    npu_set_score_th(0);              /* spec §16.1, B 계약 SCORE_TH=0 */

    PR("READY\r\n");

    for (;;) {
        uint32_t frame_len = receive_frame();
        uint8_t  type = 0;
        uint16_t seq = 0, length = 0;
        const uint8_t *payload = NULL;
        live_status_t ps;

        if (frame_len == 0u) {
            break;                                  /* 호스트 모드 EOF */
        }
        if (frame_len == 0xFFFFFFFFu) {
            continue;                               /* 길이 이상 -> 재동기화 */
        }

        ps = live_parse_frame(s_frame, frame_len, &type, &seq, &payload, &length);
        if (ps != LIVE_OK) {
            if (ps == LIVE_ERR_CRC) {
                s_rx_crc_err++;
                PR("ERR crc seq=%u\r\n", (unsigned)live_rd16(s_frame + 6));
            } else {
                s_rx_bad++;
                PR("ERR frame code=%d\r\n", (int)ps);
            }
            continue;
        }

        switch (type) {
        case LIVE_TYPE_TENSOR_SPARSE:
        case LIVE_TYPE_TENSOR_RAW:
            handle_tensor(type, seq, payload, length);
            break;

        case LIVE_TYPE_PING:
            PR("PONG seq=%u ok=%u crc_err=%u bad=%u npu_err=%u ctrl=0x%08x\r\n",
               (unsigned)seq, (unsigned)s_rx_ok, (unsigned)s_rx_crc_err,
               (unsigned)s_rx_bad, (unsigned)s_run_err,
               (unsigned)npu_control_stat());
            break;

        case LIVE_TYPE_RESET:
            npu_clear_status();
            s_rx_ok = 0u; s_rx_crc_err = 0u; s_rx_bad = 0u; s_run_err = 0u;
            PR("RESET seq=%u\r\n", (unsigned)seq);
            break;

        default:
            s_rx_bad++;
            PR("ERR type=%u\r\n", (unsigned)type);
            break;
        }
    }

    PR("BYE ok=%u crc_err=%u bad=%u npu_err=%u\r\n",
       (unsigned)s_rx_ok, (unsigned)s_rx_crc_err,
       (unsigned)s_rx_bad, (unsigned)s_run_err);
    return 0;
}
