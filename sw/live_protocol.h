/*=====================================================================
 * live_protocol.h : PC <-> Zybo PS Live 전송 규격 (보드측)
 * 담당: A
 *
 *   ** tools/live_demo/protocol.py 와 한 쌍이다. 따로 고치지 마라. **
 *
 * 값을 바꾸면 sw/sim/test_live_protocol.c 의 고정 CRC 가 깨진다.
 * 그게 Python 과 C 가 어긋났는지 잡아주는 장치다.
 *
 * Register Map 을 안 건드린다
 * ---------------------------
 *   Tensor 를 UART 로 받아 PS 가 npu_load_tensor() 로 넣는다.
 *   INPUT_SRC=0 (reset 기본값) 경로다. AXI Register 는 한 비트도 안 바뀐다.
 *   그래서 §22 CHANGE REQUEST 대상이 아니고 CR A-004 와도 무관하다.
 *
 * Frame 형식 (little-endian)
 * ---------------------------
 *   offset  크기  필드
 *   0       4     magic  'N' 'P' 'U' 'L'
 *   4       1     version = 1
 *   5       1     type
 *   6       2     seq     u16
 *   8       2     length  u16   payload byte 수
 *   10      N     payload
 *   10+N    4     crc32   u32   IEEE 802.3, version~payload 전체
 *=====================================================================*/
#ifndef LIVE_PROTOCOL_H
#define LIVE_PROTOCOL_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LIVE_MAGIC0            'N'
#define LIVE_MAGIC1            'P'
#define LIVE_MAGIC2            'U'
#define LIVE_MAGIC3            'L'

#define LIVE_VERSION           1u

#define LIVE_TYPE_TENSOR_SPARSE 0x01u
#define LIVE_TYPE_TENSOR_RAW    0x02u
#define LIVE_TYPE_PING          0x03u
#define LIVE_TYPE_RESET         0x04u

#define LIVE_HEADER_SIZE       10u
#define LIVE_CRC_SIZE           4u
#define LIVE_TENSOR_BYTES    8192u
#define LIVE_MAX_PAYLOAD     LIVE_TENSOR_BYTES

/* sparse 한 항목 = index u16 + value u8 = 3 byte, 앞에 count u16 */
#define LIVE_MAX_SPARSE_ENTRIES  ((LIVE_MAX_PAYLOAD - 2u) / 3u)   /* 2730 */

/*---------------------------------------------------------------------
 * 디코더 반환 코드
 *-------------------------------------------------------------------*/
typedef enum {
    LIVE_OK              =  0,
    LIVE_ERR_MAGIC       = -1,
    LIVE_ERR_VERSION     = -2,
    LIVE_ERR_LENGTH      = -3,
    LIVE_ERR_CRC         = -4,
    LIVE_ERR_TYPE        = -5,
    LIVE_ERR_SPARSE      = -6,   /* count 와 length 가 안 맞거나 index 범위 밖 */
    LIVE_ERR_ARG         = -7
} live_status_t;

/*---------------------------------------------------------------------
 * CRC-32 (IEEE 802.3, reflected).  zlib.crc32 와 같은 값.
 *   표를 안 만든다. 8192 byte 라도 A9 에서 무시할 만한 시간이다.
 *-------------------------------------------------------------------*/
static inline uint32_t live_crc32(const uint8_t *data, uint32_t len)
{
    uint32_t crc = 0xFFFFFFFFu;
    uint32_t i;
    int b;

    if (data == NULL) {
        return 0u;
    }
    for (i = 0u; i < len; i++) {
        crc ^= (uint32_t)data[i];
        for (b = 0; b < 8; b++) {
            /* (crc & 1) 이 0 이면 0, 1 이면 다항식. 부호 연산을 피한다. */
            crc = (crc >> 1) ^ (0xEDB88320u * (crc & 1u));
        }
    }
    return ~crc;
}

static inline uint16_t live_rd16(const uint8_t *p)
{
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static inline uint32_t live_rd32(const uint8_t *p)
{
    return (uint32_t)p[0]
         | ((uint32_t)p[1] <<  8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

/*---------------------------------------------------------------------
 * sparse payload -> 8192 byte CHW.
 *   tensor 는 호출자가 미리 0 으로 지워 놓아야 한다 (여기서 안 지운다 —
 *   보드에서 8 KB memset 을 매 프레임 반복하지 않으려고 일부러 뺐다).
 *   반환: 채운 항목 수 (>=0) 또는 live_status_t 음수.
 *-------------------------------------------------------------------*/
static inline int live_decode_sparse(const uint8_t *payload, uint32_t length,
                                     int8_t *tensor)
{
    uint32_t count;
    uint32_t n;

    if (payload == NULL || tensor == NULL) {
        return LIVE_ERR_ARG;
    }
    if (length < 2u) {
        return LIVE_ERR_SPARSE;
    }
    count = (uint32_t)live_rd16(payload);
    if (length != 2u + 3u * count) {
        return LIVE_ERR_SPARSE;
    }
    if (count > LIVE_MAX_SPARSE_ENTRIES) {
        return LIVE_ERR_SPARSE;
    }
    for (n = 0u; n < count; n++) {
        const uint8_t *entry = payload + 2u + 3u * n;
        uint32_t index = (uint32_t)live_rd16(entry);
        if (index >= LIVE_TENSOR_BYTES) {
            return LIVE_ERR_SPARSE;
        }
        tensor[index] = (int8_t)entry[2];
    }
    return (int)count;
}

/*---------------------------------------------------------------------
 * 완성된 Frame 하나를 검사한다.  magic 부터 crc 까지 전부 들어 있어야 한다.
 *   frame_len = LIVE_HEADER_SIZE + length + LIVE_CRC_SIZE
 *   성공하면 *out_type / *out_seq / *out_payload / *out_length 를 채운다.
 *-------------------------------------------------------------------*/
static inline live_status_t live_parse_frame(const uint8_t *frame,
                                             uint32_t frame_len,
                                             uint8_t *out_type,
                                             uint16_t *out_seq,
                                             const uint8_t **out_payload,
                                             uint16_t *out_length)
{
    uint16_t length;
    uint32_t want;
    uint32_t got;

    if (frame == NULL) {
        return LIVE_ERR_ARG;
    }
    if (frame_len < LIVE_HEADER_SIZE + LIVE_CRC_SIZE) {
        return LIVE_ERR_LENGTH;
    }
    if (frame[0] != LIVE_MAGIC0 || frame[1] != LIVE_MAGIC1 ||
        frame[2] != LIVE_MAGIC2 || frame[3] != LIVE_MAGIC3) {
        return LIVE_ERR_MAGIC;
    }
    if (frame[4] != LIVE_VERSION) {
        return LIVE_ERR_VERSION;
    }
    length = live_rd16(frame + 8);
    if ((uint32_t)length > LIVE_MAX_PAYLOAD) {
        return LIVE_ERR_LENGTH;
    }
    if (frame_len != LIVE_HEADER_SIZE + (uint32_t)length + LIVE_CRC_SIZE) {
        return LIVE_ERR_LENGTH;
    }
    /* CRC 범위는 magic 을 뺀 version(offset 4) 부터 payload 끝까지. */
    want = live_rd32(frame + LIVE_HEADER_SIZE + length);
    got  = live_crc32(frame + 4, (uint32_t)(LIVE_HEADER_SIZE - 4u) + length);
    if (got != want) {
        return LIVE_ERR_CRC;
    }
    if (out_type != NULL) {
        *out_type = frame[5];
    }
    if (out_seq != NULL) {
        *out_seq = live_rd16(frame + 6);
    }
    if (out_payload != NULL) {
        *out_payload = frame + LIVE_HEADER_SIZE;
    }
    if (out_length != NULL) {
        *out_length = length;
    }
    return LIVE_OK;
}

#ifdef __cplusplus
}
#endif
#endif /* LIVE_PROTOCOL_H */
