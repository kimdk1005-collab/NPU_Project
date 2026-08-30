/*=====================================================================
 * cpu_baseline.c : PS CPU 단독 추론 구현
 *
 * 산술은 tools/npu_spec.py / tools/gen_dummy.py 의 Golden 과 같다.
 *   conv   : INT32 누산, zero pad, stride
 *   requant: 부호분리 -> |acc|*M -> +(1<<23) -> >>24 -> 부호복원 (spec 9.4)
 *   clamp  : ReLU 레이어 [0,127], conv4 [-128,127]
 *   argmax : 8x8 을 YX raster 로 훑고 first-max 우선 (spec 14.1)
 *
 * !! 이 파일의 산술을 바꾸면 RTL 과 어긋난다. 바꾸기 전에 spec 9.4 / 14.1 을 봐라.
 *===================================================================*/
#include "cpu_baseline.h"
#include "int8_weights.h"
#include "fp32_weights.h"

#define NLAYER 4

/* name, cin, cout, k, stride, pad, in_hw, out_hw, relu — npu_spec.py LAYERS 와 동일 */
static const struct {
    int cin, cout, k, stride, pad, in_hw, out_hw, relu;
} LAYER[NLAYER] = {
    {  2,  8, 3, 2, 1, 64, 32, 1 },
    {  8, 16, 3, 2, 1, 32, 16, 1 },
    { 16, 32, 3, 2, 1, 16,  8, 1 },
    { 32,  1, 1, 1, 0,  8,  8, 0 },
};

static const int8_t *const W_I8[NLAYER] = {
    conv1_w_i8, conv2_w_i8, conv3_w_i8, conv4_w_i8
};
static const float *const W_F32[NLAYER] = {
    conv1_w, conv2_w, conv3_w, conv4_w
};

/* 가장 큰 중간 텐서 = conv1 출력 8*32*32 = 8192. 입력도 8192 라 같은 크기면 된다. */
#define BUF_LEN 8192

static int8_t  buf_a_i8[BUF_LEN], buf_b_i8[BUF_LEN];
static float   buf_a_f [BUF_LEN], buf_b_f [BUF_LEN];

/*---------------------------------------------------------------------
 * spec 9.4 requantize. acc 는 INT32 범위 안이라고 가정한다.
 *-------------------------------------------------------------------*/
static int8_t requant(int32_t acc, int32_t m, int relu)
{
    int64_t mag = (acc < 0) ? -(int64_t)acc : (int64_t)acc;
    int64_t sh  = (mag * (int64_t)m + ((int64_t)1 << 23)) >> 24;
    int64_t val = (acc < 0) ? -sh : sh;

    if (relu && val < 0) {
        val = 0;
    }
    if (val >  127) { val =  127; }
    if (val < -128) { val = -128; }
    return (int8_t)val;
}

/*---------------------------------------------------------------------
 * INT8 conv 한 레이어. 입출력 모두 CHW.
 *-------------------------------------------------------------------*/
static void conv_i8(int li, const int8_t *x, int8_t *y)
{
    const int cin  = LAYER[li].cin,  cout   = LAYER[li].cout;
    const int k    = LAYER[li].k,    stride = LAYER[li].stride;
    const int pad  = LAYER[li].pad,  ihw    = LAYER[li].in_hw;
    const int ohw  = LAYER[li].out_hw, relu = LAYER[li].relu;
    const int8_t *w = W_I8[li];
    const int32_t m = requant_m[li];
    int oc, oy, ox, ic, ky, kx;

    for (oc = 0; oc < cout; oc++) {
        for (oy = 0; oy < ohw; oy++) {
            for (ox = 0; ox < ohw; ox++) {
                int32_t acc = 0;
                for (ic = 0; ic < cin; ic++) {
                    for (ky = 0; ky < k; ky++) {
                        const int iy = oy * stride - pad + ky;
                        if (iy < 0 || iy >= ihw) { continue; }   /* zero pad */
                        for (kx = 0; kx < k; kx++) {
                            const int ix = ox * stride - pad + kx;
                            if (ix < 0 || ix >= ihw) { continue; }
                            acc += (int32_t)w[((oc * cin + ic) * k + ky) * k + kx]
                                 * (int32_t)x[(ic * ihw + iy) * ihw + ix];
                        }
                    }
                }
                y[(oc * ohw + oy) * ohw + ox] = requant(acc, m, relu);
            }
        }
    }
}

/*---------------------------------------------------------------------
 * FP32 conv 한 레이어. bias 없음 (checkpoint architecture.bias = false).
 *-------------------------------------------------------------------*/
static void conv_f32(int li, const float *x, float *y)
{
    const int cin  = LAYER[li].cin,  cout   = LAYER[li].cout;
    const int k    = LAYER[li].k,    stride = LAYER[li].stride;
    const int pad  = LAYER[li].pad,  ihw    = LAYER[li].in_hw;
    const int ohw  = LAYER[li].out_hw, relu = LAYER[li].relu;
    const float *w = W_F32[li];
    int oc, oy, ox, ic, ky, kx;

    for (oc = 0; oc < cout; oc++) {
        for (oy = 0; oy < ohw; oy++) {
            for (ox = 0; ox < ohw; ox++) {
                float acc = 0.0f;
                for (ic = 0; ic < cin; ic++) {
                    for (ky = 0; ky < k; ky++) {
                        const int iy = oy * stride - pad + ky;
                        if (iy < 0 || iy >= ihw) { continue; }
                        for (kx = 0; kx < k; kx++) {
                            const int ix = ox * stride - pad + kx;
                            if (ix < 0 || ix >= ihw) { continue; }
                            acc += w[((oc * cin + ic) * k + ky) * k + kx]
                                 * x[(ic * ihw + iy) * ihw + ix];
                        }
                    }
                }
                if (relu && acc < 0.0f) { acc = 0.0f; }
                y[(oc * ohw + oy) * ohw + ox] = acc;
            }
        }
    }
}

/*---------------------------------------------------------------------
 * spec 14.1 argmax : 8x8, YX raster, first-max 우선, target = cell*8+4
 *-------------------------------------------------------------------*/
static void fill_result(cpu_result_t *out, int hx, int hy)
{
    out->heatmap_x = hx;
    out->heatmap_y = hy;
    out->target_x  = hx * 8 + 4;
    out->target_y  = hy * 8 + 4;
}

static const int OUT_LEN[NLAYER] = { 8 * 32 * 32, 16 * 16 * 16, 32 * 8 * 8, 1 * 8 * 8 };

void cpu_infer_int8_tap(const int8_t *in, cpu_result_t *out, int8_t *const tap[4])
{
    const int8_t *src = in;
    int8_t *dst = buf_a_i8;
    int li, i, best_i;
    int8_t best;

    for (li = 0; li < NLAYER; li++) {
        conv_i8(li, src, dst);
        if (tap != 0 && tap[li] != 0) {
            for (i = 0; i < OUT_LEN[li]; i++) { tap[li][i] = dst[i]; }
        }
        src = dst;
        dst = (dst == buf_a_i8) ? buf_b_i8 : buf_a_i8;
    }

    best = src[0];
    best_i = 0;
    for (i = 1; i < 64; i++) {
        if (src[i] > best) { best = src[i]; best_i = i; }  /* > 라서 first-max 유지 */
    }
    fill_result(out, best_i % 8, best_i / 8);
    out->score   = (int)best;
    out->score_f = 0.0f;
}

void cpu_infer_int8(const int8_t *in, cpu_result_t *out)
{
    cpu_infer_int8_tap(in, out, 0);
}

void cpu_infer_fp32(const int8_t *in, cpu_result_t *out)
{
    const float *src;
    float *dst = buf_b_f;
    int li, i, best_i;
    float best;

    for (i = 0; i < CPU_IN_LEN; i++) {
        buf_a_f[i] = (float)in[i] / 127.0f;      /* checkpoint 규격 정규화 */
    }
    src = buf_a_f;

    for (li = 0; li < NLAYER; li++) {
        conv_f32(li, src, dst);
        src = dst;
        dst = (dst == buf_a_f) ? buf_b_f : buf_a_f;
    }

    best = src[0];
    best_i = 0;
    for (i = 1; i < 64; i++) {
        if (src[i] > best) { best = src[i]; best_i = i; }
    }
    fill_result(out, best_i % 8, best_i / 8);
    out->score   = 0;
    out->score_f = best;
}
