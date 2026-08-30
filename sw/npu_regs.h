/*=====================================================================
 * npu_regs.h : NPU AXI4-Lite Register Map
 * 담당: A
 * 기준: TEAM_COMMON_AI_INTEGRATION_SPEC v1.5 §20.1
 *       docs/freeze/D3_FREEZE_REQUEST_A_002.md rev.2
 *
 * 이 파일은 rtl/integration/npu_axi.v 와 1:1로 대응한다.
 * 한쪽을 고치면 반드시 다른 쪽도 고친다.
 *=====================================================================*/
#ifndef NPU_REGS_H
#define NPU_REGS_H

#include <stdint.h>

/*---------------------------------------------------------------------
 * Base Address (Vivado assign_bd_address 결과)
 *   PS7 M_AXI_GP0 -> AXI SmartConnect -> top_system.s_axi
 * Vitis 에서는 xparameters.h 의 XPAR_..._S_AXI_BASEADDR 로도 나온다.
 *-------------------------------------------------------------------*/
#ifndef NPU_BASE_ADDR
#define NPU_BASE_ADDR        0x40000000u
#endif
#define NPU_ADDR_RANGE       0x00001000u   /* 4 KB */

/* PS IRQ_F2P 인터럽트 번호 (XSA 확인값: XPAR_FABRIC_NPU_0_IRQ_INTR).
 * CTRL.IRQ_EN 을 켜면 DONE 시 이 인터럽트가 뜬다.               */
#define NPU_IRQ_ID           61u

/*---------------------------------------------------------------------
 * Register Offset  (§20 예약 맵. 임의로 바꾸지 마라)
 *-------------------------------------------------------------------*/
#define NPU_CTRL             0x00u  /* A */
#define NPU_STATUS           0x04u  /* A */
#define NPU_EVENT_CFG        0x08u  /* C */
#define NPU_INPUT_STAT       0x0Cu  /* C, RO */
#define NPU_CYCLE_CNT        0x10u  /* A, RO */
#define NPU_RESULT_X         0x14u  /* A, RO */
#define NPU_RESULT_Y         0x18u  /* A, RO */
#define NPU_RESULT_SCORE     0x1Cu  /* A, RO+RW 혼합 */
#define NPU_PAN_CMD          0x20u  /* C, PT#1 카메라 헤드 */
#define NPU_TILT_CMD         0x24u  /* C, PT#1 카메라 헤드 */
#define NPU_LASER_CTRL       0x28u  /* C */
#define NPU_SAFE_LIMIT       0x2Cu  /* C, PT#1 */
#define NPU_TRACK_ERR_X      0x30u  /* C */
#define NPU_TRACK_ERR_Y      0x34u  /* C */
#define NPU_VERSION          0x38u  /* A, RO */
#define NPU_INBUF_ADDR       0x3Cu  /* A */
#define NPU_INBUF_DATA       0x40u  /* A, WO */
#define NPU_SCRATCH          0x44u  /* A */
#define NPU_PAN2_CMD         0x48u  /* C, PT#2 레이저 헤드 */
#define NPU_TILT2_CMD        0x4Cu  /* C, PT#2 레이저 헤드 */
#define NPU_SAFE_LIMIT2      0x50u  /* C, PT#2 */
#define NPU_LASER_CAL        0x54u  /* C */
/* --- CHANGE_REQUEST_A_003 변경 1. C 승인 2026-08-27, A 구현 2026-08-28 --- */
#define NPU_SERVO_POS_STAT   0x58u  /* C, RO. {TILT2,PAN2,TILT1,PAN1} 각 8bit */
#define NPU_CONTROL_STAT     0x5Cu  /* C, RO. 아래 NPU_CST_* 비트            */
/* 0x60 이후는 비어 있다. read 0 / write 무시 / RESP OKAY. */

/*---------------------------------------------------------------------
 * CTRL (0x00)
 *-------------------------------------------------------------------*/
#define NPU_CTRL_START       (1u << 0)  /* W1P. 쓰면 1 cycle 후 자동 클리어  */
#define NPU_CTRL_SOFT_RESET  (1u << 1)  /* W1P. NPU 16 cycle 리셋            */
#define NPU_CTRL_SPARSE_EN   (1u << 2)  /* 예약. Dense 빌드에서는 항상 0     */
#define NPU_CTRL_INPUT_SRC   (1u << 3)  /* 0 = PS/AXI, 1 = C 하드웨어 직결   */
#define NPU_CTRL_IRQ_EN      (1u << 4)  /* DONE 시 PS IRQ_F2P                */
/* --- CR A-003 변경 2. Direct START --------------------------------------
 * 1 = C 의 event_accumulator.tensor_start 가 곧바로 추론을 건다.
 *     INPUT_SRC 도 1 이어야 실제로 먹는다 (둘 다 봐야 무장).
 * 0 = PS-managed. PS 가 INPUT_STAT.TENSOR_READY 를 보고 START 를 쓴다.
 *     reset 기본값이라 아무것도 안 하면 예전과 완전히 같다.
 * ** 두 방식을 동시에 켜지 마라 (C 지시). 무장 중 PS 가 START 를 쓰면
 *    pulse 가 안 나가고 STATUS.ERROR 만 선다. **                          */
#define NPU_CTRL_HW_START_EN (1u << 5)

/*---------------------------------------------------------------------
 * STATUS (0x04)
 *   DONE / ERROR 는 sticky. 1 을 써서 클리어한다 (W1C).
 *   PS 는 BUSY 가 아니라 DONE 을 폴링해야 한다. done 은 RTL 에서 1 cycle
 *   펄스라 AXI 폴링으로는 절대 못 잡는다.
 *-------------------------------------------------------------------*/
#define NPU_ST_DONE          (1u << 0)  /* sticky, W1C */
#define NPU_ST_BUSY          (1u << 1)  /* level       */
#define NPU_ST_ERROR         (1u << 2)  /* sticky, W1C */
#define NPU_ST_TARGET_VALID  (1u << 3)  /* level       */

/*---------------------------------------------------------------------
 * RESULT_SCORE (0x1C) — RO 와 RW 가 섞여 있다
 *   [7:0]   TARGET_SCORE  RO, signed INT8
 *   [23:16] SCORE_TH      RW, signed INT8, 기본 0
 *-------------------------------------------------------------------*/
#define NPU_SCORE_MASK       0x000000FFu
#define NPU_SCORE_TH_SHIFT   16
#define NPU_SCORE_TH_MASK    0x00FF0000u

/*---------------------------------------------------------------------
 * RESULT_X / RESULT_Y (0x14 / 0x18) — [5:0] 만 유효 (0~63)
 *-------------------------------------------------------------------*/
#define NPU_RESULT_XY_MASK   0x0000003Fu

/*---------------------------------------------------------------------
 * INPUT_STAT (0x0C, RO) — C 가 정의한 bit (c_event_control_top.v 머리주석)
 *-------------------------------------------------------------------*/
#define NPU_IS_ACC_READY     (1u << 0)
#define NPU_IS_TENSOR_READY  (1u << 1)  /* sticky, npu_busy 로 자동 클리어 */
#define NPU_IS_OVERRUN       (1u << 2)
#define NPU_IS_EVENT_ENABLE  (1u << 3)
#define NPU_IS_NPU_BUSY      (1u << 4)
#define NPU_IS_TARGET_VALID  (1u << 5)
#define NPU_IS_LASER_LOCK    (1u << 6)
#define NPU_IS_LASER_TIMEOUT (1u << 7)
#define NPU_IS_EVT_CNT(v)    (((v) >> 8)  & 0xFFFu)   /* 12bit 포화 */
#define NPU_IS_DROP_CNT(v)   (((v) >> 20) & 0xFFFu)   /* 12bit 포화 */

/*---------------------------------------------------------------------
 * SERVO_POS_STAT (0x58, RO) — Servo 실제 위치 4축. 각 8-bit unsigned
 *   [7:0] PAN1  [15:8] TILT1  [23:16] PAN2  [31:24] TILT2
 *   PT#1 = 카메라 헤드, PT#2 = 레이저 헤드 (§15.2)
 *-------------------------------------------------------------------*/
#define NPU_SPS_PAN1(v)      ( (v)        & 0xFFu)
#define NPU_SPS_TILT1(v)     (((v) >>  8) & 0xFFu)
#define NPU_SPS_PAN2(v)      (((v) >> 16) & 0xFFu)
#define NPU_SPS_TILT2(v)     (((v) >> 24) & 0xFFu)

/*---------------------------------------------------------------------
 * CONTROL_STAT (0x5C, RO) — bit 배치는 C 가 정의했다.
 *   근거: rtl/control/c_event_control_top.v 머리주석,
 *         docs/from_c/C_TO_A_REPLY_004.md §5
 *-------------------------------------------------------------------*/
#define NPU_CST_LASER_EN         (1u <<  0)
#define NPU_CST_LASER_LOCK       (1u <<  1)
#define NPU_CST_TARGET_FRESH     (1u <<  2)
#define NPU_CST_LASER_TIMEOUT    (1u <<  3)
#define NPU_CST_AIM_READY        (1u <<  4)
#define NPU_CST_MANUAL_OVERRIDE  (1u <<  5)
#define NPU_CST_LIMIT_ACTIVE     (1u <<  6)
#define NPU_CST_LIMIT_FAULT      (1u <<  7)
#define NPU_CST_SERVO_ENABLE     (1u <<  8)
#define NPU_CST_HW_ARM           (1u <<  9)  /* SW1 물리 Arm 스위치       */
#define NPU_CST_SW_ARM           (1u << 10)  /* LASER_CTRL[1]             */
#define NPU_CST_EMERGENCY_STOP   (1u << 11)  /* SW3 또는 LASER_CTRL[2]    */
#define NPU_CST_TENSOR_READY     (1u << 12)
#define NPU_CST_ACC_READY        (1u << 13)
#define NPU_CST_OVERRUN          (1u << 14)
#define NPU_CST_TARGET_VALID     (1u << 15)
#define NPU_CST_REARM_REQUIRED   (1u << 16)
/* [31:17] 은 0 이다. 0 이 아니면 배선이 틀렸거나 옛 비트스트림이다. */
#define NPU_CST_RSVD_MASK        0xFFFE0000u

/*---------------------------------------------------------------------
 * VERSION (0x38) — 읽으면 이 값이 나와야 한다.
 *   [31:16] 0x4E50 = ASCII "NP"   [15:8] Major   [7:0] Minor
 *   보드에 올리고 이 값이 안 나오면 그 아래는 볼 필요도 없다.
 *
 *   0x4E50_0100  초판 (0x00~0x54)
 *   0x4E50_0101  0x58/0x5C RO + CTRL[5] HW_START_EN 추가 (CR A-003)
 *                기존 offset 은 한 비트도 안 바뀌었다. minor 를 올린 이유는
 *                "새 ELF + 옛 비트스트림" 조합을 STEP 1 에서 잡기 위해서다.
 *                그 조합에서는 0x58 이 조용히 0 으로 읽히고 Direct START 도
 *                조용히 안 걸려서, 안 잡으면 원인을 못 찾는다.
 *-------------------------------------------------------------------*/
#define NPU_VERSION_EXPECT   0x4E500101u

/*---------------------------------------------------------------------
 * Event Tensor (§7.4 CHW)
 *   addr = (polarity << 12) | (y << 6) | x
 *-------------------------------------------------------------------*/
#define NPU_TENSOR_BYTES     8192
#define NPU_TENSOR_WORDS     (NPU_TENSOR_BYTES / 4)
#define NPU_TENSOR_W         64
#define NPU_TENSOR_H         64
#define NPU_TENSOR_C         2

static inline uint32_t npu_tensor_addr(uint32_t pol, uint32_t y, uint32_t x)
{
    return (pol << 12) | (y << 6) | x;
}

#endif /* NPU_REGS_H */
