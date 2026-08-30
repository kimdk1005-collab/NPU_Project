/*=====================================================================
 * test_live_protocol.c : Live 전송 규격 호스트 시험 (보드 불필요)
 * 담당: A
 *
 *   cd sw && make live        (make test 에도 딸려 들어간다)
 *
 * 여기 박힌 Frame 바이트열은 tools/live_demo/protocol.py 가 만든 것을
 * 그대로 옮긴 것이다.  ** 이게 Python 과 C 가 어긋났는지 잡는 장치다. **
 * 한쪽만 고치면 이 시험이 깨진다.  같은 값을
 * tools/live_demo/test_protocol.py 도 검사한다.
 *=====================================================================*/
#include "live_protocol.h"

#include <stdio.h>
#include <string.h>

static int s_checks;
static int s_fails;

static void ok(int cond, const char *what)
{
    s_checks++;
    if (cond) {
        printf("  [OK]   %s\n", what);
    } else {
        s_fails++;
        printf("  [FAIL] %s\n", what);
    }
}

static void eq_u32(uint32_t got, uint32_t want, const char *what)
{
    s_checks++;
    if (got == want) {
        printf("  [OK]   %-46s 0x%08lx\n", what, (unsigned long)got);
    } else {
        s_fails++;
        printf("  [FAIL] %-46s 0x%08lx  (기대 0x%08lx)\n",
               what, (unsigned long)got, (unsigned long)want);
    }
}

static void eq_int(int got, int want, const char *what)
{
    s_checks++;
    if (got == want) {
        printf("  [OK]   %-46s %d\n", what, got);
    } else {
        s_fails++;
        printf("  [FAIL] %-46s %d  (기대 %d)\n", what, got, want);
    }
}

/*---------------------------------------------------------------------
 * Python protocol.py 가 만든 Frame 원본
 *-------------------------------------------------------------------*/

/* P.build_frame(TYPE_PING, 7, b"")  -> 14 byte */
static const uint8_t FRAME_PING[] = {
    0x4e, 0x50, 0x55, 0x4c,        /* NPUL              */
    0x01,                          /* version 1         */
    0x03,                          /* type PING         */
    0x07, 0x00,                    /* seq 7             */
    0x00, 0x00,                    /* length 0          */
    0x6f, 0x30, 0xe9, 0xa0         /* crc32             */
};

/* tensor[0]=1, tensor[4095]=127, tensor[8191]=200(-56) 을 sparse 로
 * P.build_frame(TYPE_TENSOR_SPARSE, 0x1234, payload) -> 25 byte */
static const uint8_t FRAME_SPARSE3[] = {
    0x4e, 0x50, 0x55, 0x4c,
    0x01,
    0x01,                          /* type TENSOR_SPARSE */
    0x34, 0x12,                    /* seq 0x1234         */
    0x0b, 0x00,                    /* length 11          */
    0x03, 0x00,                    /* count 3            */
    0x00, 0x00, 0x01,              /* index 0    val 1   */
    0xff, 0x0f, 0x7f,              /* index 4095 val 127 */
    0xff, 0x1f, 0xc8,              /* index 8191 val 200 */
    0x2c, 0xb9, 0xcf, 0x4a         /* crc32              */
};

static int8_t s_tensor[LIVE_TENSOR_BYTES];

int main(void)
{
    uint8_t  type = 0;
    uint16_t seq = 0, length = 0;
    const uint8_t *payload = NULL;
    live_status_t st;
    uint8_t scratch[sizeof(FRAME_SPARSE3)];
    int n;

    printf("=====================================================\n");
    printf(" Live 전송 규격 시험  (live_protocol.h <-> protocol.py)\n");
    printf("=====================================================\n");

    /*----------------------------------------------------- CRC-32 */
    printf("\n[1] CRC-32 가 표준(IEEE 802.3 / zlib) 인가\n");
    eq_u32(live_crc32((const uint8_t *)"123456789", 9u), 0xcbf43926u,
           "crc32(\"123456789\")  표준 검사값");
    eq_u32(live_crc32((const uint8_t *)"", 0u), 0x00000000u, "crc32(\"\")");
    eq_u32(live_crc32((const uint8_t *)"NPUL", 4u), 0x8e957a08u, "crc32(\"NPUL\")");

    /*------------------------------------------------- 상수 대조 */
    printf("\n[2] 규격 상수가 protocol.py 와 같은가\n");
    eq_int((int)LIVE_HEADER_SIZE, 10, "LIVE_HEADER_SIZE");
    eq_int((int)LIVE_CRC_SIZE, 4, "LIVE_CRC_SIZE");
    eq_int((int)LIVE_TENSOR_BYTES, 8192, "LIVE_TENSOR_BYTES");
    eq_int((int)LIVE_MAX_SPARSE_ENTRIES, 2730, "LIVE_MAX_SPARSE_ENTRIES");
    eq_int((int)LIVE_VERSION, 1, "LIVE_VERSION");

    /*------------------------------------------------- PING Frame */
    printf("\n[3] Python 이 만든 PING Frame 을 C 가 받아들이나\n");
    eq_int((int)sizeof(FRAME_PING), 14, "PING Frame 길이");
    st = live_parse_frame(FRAME_PING, (uint32_t)sizeof(FRAME_PING),
                          &type, &seq, &payload, &length);
    eq_int((int)st, (int)LIVE_OK, "live_parse_frame(PING)");
    eq_int((int)type, (int)LIVE_TYPE_PING, "  type");
    eq_int((int)seq, 7, "  seq");
    eq_int((int)length, 0, "  length");

    /*----------------------------------------------- SPARSE Frame */
    printf("\n[4] Python 이 만든 sparse Frame 을 C 가 같은 Tensor 로 푸나\n");
    eq_int((int)sizeof(FRAME_SPARSE3), 25, "sparse Frame 길이");
    st = live_parse_frame(FRAME_SPARSE3, (uint32_t)sizeof(FRAME_SPARSE3),
                          &type, &seq, &payload, &length);
    eq_int((int)st, (int)LIVE_OK, "live_parse_frame(SPARSE)");
    eq_int((int)type, (int)LIVE_TYPE_TENSOR_SPARSE, "  type");
    eq_int((int)seq, 0x1234, "  seq");
    eq_int((int)length, 11, "  length");

    memset(s_tensor, 0, sizeof(s_tensor));
    n = live_decode_sparse(payload, (uint32_t)length, s_tensor);
    eq_int(n, 3, "  live_decode_sparse 항목 수");
    eq_int((int)s_tensor[0], 1, "  tensor[0]");
    eq_int((int)s_tensor[4095], 127, "  tensor[4095]");
    eq_int((int)s_tensor[8191], -56, "  tensor[8191]  0xC8 = -56 signed");
    {
        int zeros = 1;
        uint32_t i;
        for (i = 0u; i < LIVE_TENSOR_BYTES; i++) {
            if (i != 0u && i != 4095u && i != 8191u && s_tensor[i] != 0) {
                zeros = 0;
                break;
            }
        }
        ok(zeros, "  나머지 8189 칸은 전부 0");
    }

    /*----------------------------------------------- 손상 검출 */
    printf("\n[5] 망가진 Frame 을 거부하나  (시험 3 의 근거)\n");

    memcpy(scratch, FRAME_SPARSE3, sizeof(FRAME_SPARSE3));
    scratch[sizeof(scratch) - 1] ^= 0xFF;                    /* CRC 훼손 */
    st = live_parse_frame(scratch, (uint32_t)sizeof(scratch),
                          &type, &seq, &payload, &length);
    eq_int((int)st, (int)LIVE_ERR_CRC, "CRC 1 byte 훼손 -> LIVE_ERR_CRC");

    memcpy(scratch, FRAME_SPARSE3, sizeof(FRAME_SPARSE3));
    scratch[LIVE_HEADER_SIZE] ^= 0xFF;                       /* payload 훼손 */
    st = live_parse_frame(scratch, (uint32_t)sizeof(scratch),
                          &type, &seq, &payload, &length);
    eq_int((int)st, (int)LIVE_ERR_CRC, "payload 1 byte 훼손 -> LIVE_ERR_CRC");

    memcpy(scratch, FRAME_SPARSE3, sizeof(FRAME_SPARSE3));
    scratch[0] = 'X';                                        /* magic 훼손 */
    st = live_parse_frame(scratch, (uint32_t)sizeof(scratch),
                          &type, &seq, &payload, &length);
    eq_int((int)st, (int)LIVE_ERR_MAGIC, "magic 훼손 -> LIVE_ERR_MAGIC");

    memcpy(scratch, FRAME_SPARSE3, sizeof(FRAME_SPARSE3));
    scratch[4] = 0x7F;                                       /* version 훼손 */
    st = live_parse_frame(scratch, (uint32_t)sizeof(scratch),
                          &type, &seq, &payload, &length);
    eq_int((int)st, (int)LIVE_ERR_VERSION, "version 훼손 -> LIVE_ERR_VERSION");

    memcpy(scratch, FRAME_SPARSE3, sizeof(FRAME_SPARSE3));
    scratch[8] = 0xFF;
    scratch[9] = 0xFF;                                       /* length 65535 */
    st = live_parse_frame(scratch, (uint32_t)sizeof(scratch),
                          &type, &seq, &payload, &length);
    eq_int((int)st, (int)LIVE_ERR_LENGTH, "length 65535 -> LIVE_ERR_LENGTH");

    st = live_parse_frame(FRAME_SPARSE3, (uint32_t)sizeof(FRAME_SPARSE3) - 1u,
                          &type, &seq, &payload, &length);
    eq_int((int)st, (int)LIVE_ERR_LENGTH, "1 byte 잘린 Frame -> LIVE_ERR_LENGTH");

    /*----------------------------- sparse payload 자체 방어 */
    printf("\n[6] sparse payload 안쪽 방어\n");
    {
        /* count 는 2 인데 항목이 1 개뿐 */
        static const uint8_t bad_count[] = { 0x02, 0x00, 0x00, 0x00, 0x01 };
        n = live_decode_sparse(bad_count, (uint32_t)sizeof(bad_count), s_tensor);
        eq_int(n, (int)LIVE_ERR_SPARSE, "count 와 length 불일치 -> LIVE_ERR_SPARSE");
    }
    {
        /* index 8192 는 범위 밖 (0x2000) */
        static const uint8_t bad_index[] = { 0x01, 0x00, 0x00, 0x20, 0x7f };
        n = live_decode_sparse(bad_index, (uint32_t)sizeof(bad_index), s_tensor);
        eq_int(n, (int)LIVE_ERR_SPARSE, "index 8192 (범위 밖) -> LIVE_ERR_SPARSE");
    }
    {
        /* index 8191 은 마지막 유효 칸 */
        static const uint8_t edge[] = { 0x01, 0x00, 0xff, 0x1f, 0x7f };
        memset(s_tensor, 0, sizeof(s_tensor));
        n = live_decode_sparse(edge, (uint32_t)sizeof(edge), s_tensor);
        eq_int(n, 1, "index 8191 (마지막 유효) 은 통과");
        eq_int((int)s_tensor[8191], 127, "  tensor[8191]");
    }
    {
        n = live_decode_sparse(NULL, 5u, s_tensor);
        eq_int(n, (int)LIVE_ERR_ARG, "payload NULL -> LIVE_ERR_ARG");
    }

    printf("\n=====================================================\n");
    printf(" 결과: %s   (%d check, 실패 %d건)\n",
           s_fails == 0 ? "PASS" : "FAIL", s_checks, s_fails);
    printf("=====================================================\n");
    return s_fails == 0 ? 0 : 1;
}
