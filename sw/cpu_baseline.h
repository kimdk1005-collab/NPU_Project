/*=====================================================================
 * cpu_baseline.h : PS CPU 단독 추론 (NPU 미사용) — Baseline 측정용
 *
 * 목적은 하나다. "NPU 가 CPU 대비 얼마나 빠른가"를 같은 보드에서 재는 것.
 *   docs/TEAM_ROLE_PLAN.md §4.1 의 PS CPU FP32/INT8 Baseline 항목.
 *
 * INT8 경로는 RTL/Golden 과 **bit-exact 하게 같은 값**을 낸다.
 * 그래서 보드에 NPU 가 없어도, 또 호스트 PC 에서도 정합성 검증이 된다.
 * FP32 경로는 B checkpoint 의 float weight 를 그대로 돌린 참고값이며
 * 양자화 오차 때문에 INT8 과 결과가 다를 수 있다 (그게 정상이다).
 *
 * weight 는 자동 생성 헤더에서 온다:
 *   sw/int8_weights.h  <- tools/gen_int8_weights_c.py
 *   sw/fp32_weights.h  <- tools/dump_fp32_weights.py
 *===================================================================*/
#ifndef CPU_BASELINE_H
#define CPU_BASELINE_H

#include <stdint.h>

#define CPU_IN_C    2
#define CPU_IN_HW   64
#define CPU_IN_LEN  (CPU_IN_C * CPU_IN_HW * CPU_IN_HW)   /* 8192, CHW */

typedef struct {
    int   heatmap_x;    /* 0..7  */
    int   heatmap_y;    /* 0..7  */
    int   target_x;     /* heatmap_x * 8 + 4 */
    int   target_y;     /* heatmap_y * 8 + 4 */
    int   score;        /* INT8 경로: signed INT8 heatmap 최댓값 */
    float score_f;      /* FP32 경로: heatmap 최댓값. INT8 경로에선 0 */
} cpu_result_t;

/* INT8 정수 추론. NPU/Golden 과 bit-exact 일치해야 한다. */
void cpu_infer_int8(const int8_t *in, cpu_result_t *out);

/* FP32 참고 추론. 입력 정규화 = input_int8 / 127.0 (checkpoint 규격) */
void cpu_infer_fp32(const int8_t *in, cpu_result_t *out);

/* 레이어별 출력을 받아보는 판. 검증용이고 측정에는 쓰지 마라 (복사 비용이 붙는다).
 * tap[i] 가 NULL 이 아니면 conv{i+1} 출력을 그리로 복사한다.
 * 필요한 크기: 8192 / 4096 / 2048 / 64  (test_vectors 각 case 의 conv{N}_out.hex 와 같은 순서) */
void cpu_infer_int8_tap(const int8_t *in, cpu_result_t *out, int8_t *const tap[4]);

#endif /* CPU_BASELINE_H */
