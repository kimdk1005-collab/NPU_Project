/*=====================================================================
 * test_cpu_baseline.c : PS CPU Baseline 구현 검증 (호스트 전용)
 *
 * cpu_baseline.c 의 INT8 경로가 B Golden 과 bit-exact 인지 본다.
 * 레이어별로 다 비교하기 때문에, 틀리면 어느 레이어에서 갈렸는지 바로 나온다.
 *
 *   ./build/test_cpu_baseline [test_vectors 루트]
 *
 * 보드가 없어도 돌고, 보드에서 잴 latency 의 값 정합성을 여기서 미리 보장한다.
 *===================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cpu_baseline.h"

static int checks = 0, errs = 0;

static void chk(const char *what, long got, long exp)
{
    checks++;
    if (got != exp) {
        errs++;
        printf("  [FAIL] %-28s got %ld  exp %ld\n", what, got, exp);
    }
}

/* .hex 한 줄 = 8bit two's complement */
static int read_hex_i8(const char *path, int8_t *dst, int n)
{
    char line[64];
    int i = 0;
    FILE *f = fopen(path, "r");
    if (!f) { printf("  [FAIL] 못 엶: %s\n", path); errs++; return -1; }
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') { p++; }
        if (*p == '\0' || *p == '\n' || *p == '/') { continue; }
        if (i >= n) { i++; break; }
        dst[i++] = (int8_t)(int)strtol(p, NULL, 16);
    }
    fclose(f);
    if (i != n) { printf("  [FAIL] %s: %d 줄 기대, %d\n", path, n, i); errs++; return -1; }
    return 0;
}

static int read_result(const char *path, int *tx, int *ty, int *score)
{
    char key[64];
    long val;
    FILE *f = fopen(path, "r");
    if (!f) { printf("  [FAIL] 못 엶: %s\n", path); errs++; return -1; }
    while (fscanf(f, "%63s %ld", key, &val) == 2) {
        if      (!strcmp(key, "target_x"))     { *tx    = (int)val; }
        else if (!strcmp(key, "target_y"))     { *ty    = (int)val; }
        else if (!strcmp(key, "target_score")) { *score = (int)val; }
    }
    fclose(f);
    return 0;
}

static int8_t in_buf[CPU_IN_LEN];
static int8_t g1[8 * 32 * 32], g2[16 * 16 * 16], g3[32 * 8 * 8], g4[64];
static int8_t t1[8 * 32 * 32], t2[16 * 16 * 16], t3[32 * 8 * 8], t4[64];

static int cmp_layer(const char *name, const int8_t *got, const int8_t *exp, int n)
{
    int i, bad = 0, first = -1;
    for (i = 0; i < n; i++) {
        if (got[i] != exp[i]) { if (first < 0) { first = i; } bad++; }
    }
    checks++;
    if (bad) {
        errs++;
        printf("  [FAIL] %-12s %d/%d 불일치, 첫 위치 %d (got %d exp %d)\n",
               name, bad, n, first, got[first], exp[first]);
    }
    return bad;
}

static void run_case(const char *root, const char *cs)
{
    char p[512];
    cpu_result_t r;
    int tx = -1, ty = -1, score = -999;
    int8_t *const tap[4] = { t1, t2, t3, t4 };

    printf("=== %s ===\n", cs);

    sprintf(p, "%s/%s/input_event.hex", root, cs);
    if (read_hex_i8(p, in_buf, CPU_IN_LEN) < 0) { return; }
    sprintf(p, "%s/%s/conv1_out.hex", root, cs); read_hex_i8(p, g1, 8 * 32 * 32);
    sprintf(p, "%s/%s/conv2_out.hex", root, cs); read_hex_i8(p, g2, 16 * 16 * 16);
    sprintf(p, "%s/%s/conv3_out.hex", root, cs); read_hex_i8(p, g3, 32 * 8 * 8);
    sprintf(p, "%s/%s/conv4_out.hex", root, cs); read_hex_i8(p, g4, 64);
    sprintf(p, "%s/%s/result_xy.txt", root, cs); read_result(p, &tx, &ty, &score);

    cpu_infer_int8_tap(in_buf, &r, tap);

    cmp_layer("conv1_out", t1, g1, 8 * 32 * 32);
    cmp_layer("conv2_out", t2, g2, 16 * 16 * 16);
    cmp_layer("conv3_out", t3, g3, 32 * 8 * 8);
    cmp_layer("conv4_out", t4, g4, 64);
    chk("target_x", r.target_x, tx);
    chk("target_y", r.target_y, ty);
    chk("target_score", r.score, score);

    printf("  INT8 : x=%d y=%d score=%d   (golden x=%d y=%d score=%d)\n",
           r.target_x, r.target_y, r.score, tx, ty, score);

    cpu_infer_fp32(in_buf, &r);
    printf("  FP32 : x=%d y=%d score=%.4f  <- 참고값. INT8 과 달라도 정상\n",
           r.target_x, r.target_y, (double)r.score_f);
}

int main(int argc, char **argv)
{
    const char *root = (argc > 1) ? argv[1] : "../test_vectors";
    const char *cases[3] = { "case00", "case01", "case02" };
    int i;

    printf("== PS CPU Baseline 구현 검증 (vectors: %s) ==\n\n", root);
    for (i = 0; i < 3; i++) { run_case(root, cases[i]); printf("\n"); }

    if (errs) {
        printf("[FAIL] test_cpu_baseline : %d / %d 불일치\n", errs, checks);
        return 1;
    }
    printf("[PASS] test_cpu_baseline : %d check 전부 일치\n", checks);
    return 0;
}
