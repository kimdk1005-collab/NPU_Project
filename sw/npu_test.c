/*=====================================================================
 * npu_test.c : 보드 자체시험 프로그램 (Zybo Z7-20, PS bare-metal)
 * 담당: A
 *
 * 보드를 받으면 이 프로그램부터 돌린다. 순서대로 4단계이고,
 * 앞 단계가 실패하면 뒤는 볼 필요가 없게 짜여 있다.
 *
 *   STEP 1  AXI 링크        VERSION(0x38) == 0x4E50_0101 ?
 *   STEP 2  레지스터 경로   SCRATCH / SCORE_TH / PT#1 / PT#2 / 0x58 / 0x5C
 *   STEP 3  입력버퍼        8192 byte 적재 후 INBUF_ADDR == 8192 ?
 *   STEP 4  추론            시뮬레이션과 같은 (x,y,score) 가 나오는가?
 *   STEP 5  반복 32 회      결과·cycle 이 흔들리지 않는가?
 *   STEP 6  PS CPU Baseline NPU 를 안 쓰고 A9 가 직접 돌린 시간
 *   STEP 7  C 통합 상태     지금 올라간 게 A 단독인가 전 기능인가
 *
 * STEP 4 가 통과하면 RTL 시뮬레이션 결과가 실물에서 재현된 것이다.
 * 기대값은 sw/test_tensor.h (tb_top_system 이 쓴 것과 동일한 벡터).
 *
 * 빌드: Vitis standalone (sw/build_vitis.tcl)
 *       호스트 시험은 sw/sim/test_driver.c 로 따로 한다.
 *=====================================================================*/
#include "npu_driver.h"
#include "test_tensor.h"
#include "cpu_baseline.h"

/*---------------------------------------------------------------------
 * 출력 함수
 *   Vitis standalone 에서는 xil_printf (UART).
 *   -DNPU_NO_XIL 로 빌드하면 표준 printf (문법 확인용).
 *-------------------------------------------------------------------*/
#ifdef NPU_NO_XIL
#include <stdio.h>
#define PR printf
#define HAVE_TIMER 0
#else
#include "xil_printf.h"
#include "xparameters.h"
/* 전역 타이머 헤더가 Vitis 종류마다 다르다.
 *   통합(SDT)  : xiltimer.h + xtimer_config.h  (COUNTS_PER_SECOND = CPU_FREQ/2)
 *   classic    : xtime_l.h
 * SDT 매크로는 통합 Vitis 가 -DSDT 로 넣어준다. */
#ifdef SDT
#include "xiltimer.h"
#include "xtimer_config.h"
/* sleep.h 의 usleep() 은 xiltimer.c 안에 있고, 그 파일에는
 * __attribute__((constructor)) xtimerinit() 도 같이 들어 있다.
 * usleep 을 참조해야 xiltimer.o 가 링크되고 constructor 가
 * .init_array 에 들어온다. 이유는 STEP 6 주석 참고. */
#include "sleep.h"
#else
#include "xtime_l.h"
#endif
#define PR xil_printf
typedef XTime npu_tick_t;
static npu_tick_t tick_now(void) { XTime t; XTime_GetTime(&t); return t; }
/* COUNTS_PER_SECOND 는 SDT 쪽에서 괄호 없이 A/2 로 정의돼 있다. 감싸서 쓴다. */
#define TICKS_PER_SEC ((unsigned long long)(COUNTS_PER_SECOND))
#define HAVE_TIMER 1

/* Vivado 가 주소를 바꾸면 조용히 엉뚱한 데를 읽는 대신 빌드가 깨지게 한다. */
#ifdef XPAR_NPU_0_BASEADDR
#  if (XPAR_NPU_0_BASEADDR) != (NPU_BASE_ADDR)
#    error "NPU_BASE_ADDR 이 XSA 의 XPAR_NPU_0_BASEADDR 과 다르다. npu_regs.h 를 맞춰라."
#  endif
#endif
#ifdef XPAR_FABRIC_NPU_0_IRQ_INTR
#  if (XPAR_FABRIC_NPU_0_IRQ_INTR) != (NPU_IRQ_ID)
#    error "NPU_IRQ_ID 가 XSA 와 다르다. npu_regs.h 를 맞춰라."
#  endif
#endif
#endif

/* 폴링 한도. 추론 1.26 ms 인데 AXI read 1 회가 수백 ns 이므로
 * 200000 이면 실제 소요보다 수십 배 여유다. 멈추면 하드웨어 문제다. */
#define POLL_LIMIT   200000u

static int g_fail = 0;

static void step_hdr(int n, const char *name)
{
    PR("\r\n");
    PR("---------------------------------------------\r\n");
    PR(" STEP %d  %s\r\n", n, name);
    PR("---------------------------------------------\r\n");
}

static void ok(const char *msg)   { PR("  [OK]   %s\r\n", msg); }
static void ng(const char *msg)   { PR("  [FAIL] %s\r\n", msg); g_fail++; }

static void chk(int cond, const char *msg)
{
    if (cond) ok(msg); else ng(msg);
}

/*=====================================================================
 * STEP 1 : AXI 링크
 *=====================================================================*/
static int step1_link(void)
{
    uint32_t ver;
    npu_status_t s;

    step_hdr(1, "AXI 링크 확인");

    ver = npu_io_read32(NPU_VERSION);
    PR("  VERSION = 0x%08x  (기대 0x%08x)\r\n",
       (unsigned)ver, (unsigned)NPU_VERSION_EXPECT);

    s = npu_init();
    if (s != NPU_OK) {
        ng("npu_init 실패");
        PR("  -> %s\r\n", npu_strerror(s));
        PR("\r\n");
        PR("  확인할 것:\r\n");
        PR("   1. LD0 heartbeat 가 깜빡이는가 (bitstream/클럭)\r\n");
        PR("   2. Base Address 가 0x40000000 인가 (Vivado Address Editor)\r\n");
        PR("   3. PS7 M_AXI_GP0 이 켜져 있는가\r\n");
        PR("   4. bitstream 을 실제로 올렸는가 (Program FPGA)\r\n");
        return -1;
    }
    ok("VERSION 일치 — AXI 배선 정상");
    return 0;
}

/*=====================================================================
 * STEP 2 : 레지스터 읽기/쓰기 경로
 *=====================================================================*/
static void step2_regs(void)
{
    uint32_t v;

    step_hdr(2, "레지스터 왕복");

    /* SCRATCH — 아무 의미 없는 순수 시험용 레지스터 */
    npu_io_write32(NPU_SCRATCH, 0xDEADBEEFu);
    v = npu_io_read32(NPU_SCRATCH);
    chk(v == 0xDEADBEEFu, "SCRATCH 0xDEADBEEF 왕복");

    npu_io_write32(NPU_SCRATCH, 0x5A5A5A5Au);
    v = npu_io_read32(NPU_SCRATCH);
    chk(v == 0x5A5A5A5Au, "SCRATCH 0x5A5A5A5A 왕복");

    /* SCORE_TH — 0x1C 는 RO(score)+RW(th) 혼합이라 따로 본다 */
    npu_set_score_th(20);
    chk(npu_get_score_th() == 20, "SCORE_TH = +20");
    npu_set_score_th(-30);
    chk(npu_get_score_th() == -30, "SCORE_TH = -30 (signed)");
    npu_set_score_th(0);

    /* Pan/Tilt 2 헤드 — C 영역이지만 레지스터 경로는 A 가 보장한다 */
    npu_set_pt1(0x00000090u, 0xFFFFFF80u);
    npu_set_pt2(0x000000A5u, 0xFFFFFFC4u);
    chk(npu_io_read32(NPU_PAN_CMD)   == 0x00000090u, "PT#1 PAN_CMD  (카메라 헤드)");
    chk(npu_io_read32(NPU_TILT_CMD)  == 0xFFFFFF80u, "PT#1 TILT_CMD (카메라 헤드)");
    chk(npu_io_read32(NPU_PAN2_CMD)  == 0x000000A5u, "PT#2 PAN2_CMD (레이저 헤드)");
    chk(npu_io_read32(NPU_TILT2_CMD) == 0xFFFFFFC4u, "PT#2 TILT2_CMD(레이저 헤드)");
    npu_set_pt1(0, 0);
    npu_set_pt2(0, 0);

    /* 0x58 / 0x5C 는 RO 다 (CR A-003 변경 1). write 해도 안 바뀐다.
     * A 단독 비트스트림에서는 C 가 없어 두 값 다 0 이다. 그건 정상이다.
     * 여기서 보는 건 "write 가 값을 오염시키지 않는가" 뿐이다.        */
    {
        uint32_t sp0 = npu_io_read32(NPU_SERVO_POS_STAT);
        uint32_t cs0 = npu_io_read32(NPU_CONTROL_STAT);
        npu_io_write32(NPU_SERVO_POS_STAT, 0xFFFFFFFFu);
        npu_io_write32(NPU_CONTROL_STAT,   0xFFFFFFFFu);
        chk(npu_io_read32(NPU_SERVO_POS_STAT) == sp0, "0x58 SERVO_POS_STAT RO");
        chk(npu_io_read32(NPU_CONTROL_STAT)   == cs0, "0x5C CONTROL_STAT RO");
    }

    /* 미정의 Offset 은 0 이 읽히고 write 는 무시된다 (Bus Error 안 남).
     * 0x58/0x5C 가 실제 Register 가 됐으므로 0x60 으로 옮겼다.
     * ** CR A-004 (0x60 EVENT_IN) 를 구현하는 날 0x64 로 다시 옮겨라. **
     * 안 옮기면 0x60 이 WO Register 라 read 가 어차피 0 이고 이 시험이
     * 조용히 무의미해진다. tb/integration/tb_npu_axi.v 의 UNKNOWN 도 같이. */
    npu_io_write32(0x60u, 0xFFFFFFFFu);
    chk(npu_io_read32(0x60u) == 0u, "미정의 Offset(0x60) read 0 / write 무시");

    /* CTRL[5] HW_START_EN 왕복 (CR A-003 변경 2).
     * 여기서는 켰다 끄기만 한다. 실제 Direct START 는 STEP 7 에서 본다. */
    npu_set_hw_start_en(1);
    chk(npu_get_hw_start_en() == 1, "CTRL.HW_START_EN = 1");
    npu_set_hw_start_en(0);
    chk(npu_get_hw_start_en() == 0, "CTRL.HW_START_EN = 0 (기본값 복귀)");
}

/*=====================================================================
 * STEP 3 : 입력 버퍼 적재
 *=====================================================================*/
static int step3_load(void)
{
    npu_status_t s;
    uint32_t ptr;

    step_hdr(3, "Event Tensor 적재 (8192 byte)");

    npu_set_input_src(0);              /* PS 가 AXI 로 적재 */
    s = npu_load_tensor(test_tensor, TEST_TENSOR_BYTES);

    ptr = npu_io_read32(NPU_INBUF_ADDR);
    PR("  INBUF_ADDR = %u  (기대 %u)\r\n",
       (unsigned)ptr, (unsigned)TEST_TENSOR_BYTES);

    if (s != NPU_OK) {
        ng("npu_load_tensor 실패");
        PR("  -> %s\r\n", npu_strerror(s));
        return -1;
    }
    ok("8192 byte 적재 완료, 포인터 정상");
    chk((npu_status_raw() & NPU_ST_ERROR) == 0, "STATUS.ERROR 안 섰다");
    return 0;
}

/*=====================================================================
 * STEP 4 : 추론 — 시뮬레이션 결과 재현
 *=====================================================================*/
static int step4_infer(void)
{
    npu_result_t r;
    npu_status_t s;
    int pass = 1;

    step_hdr(4, "추론 (시뮬레이션 결과 재현 확인)");

    s = npu_start();
    if (s != NPU_OK) { ng("npu_start 실패"); return -1; }

    s = npu_wait_done(POLL_LIMIT);
    if (s != NPU_OK) {
        ng("추론 완료 대기 실패");
        PR("  -> %s\r\n", npu_strerror(s));
        PR("  STATUS = 0x%08x\r\n", (unsigned)npu_status_raw());
        return -1;
    }
    ok("DONE 도달");

    npu_get_result(&r);

    PR("\r\n");
    PR("           보드      시뮬(golden)\r\n");
    PR("  valid  : %d         %d\r\n", r.valid,  TEST_EXPECT_VALID);
    PR("  x      : %u        %u\r\n",  (unsigned)r.x, (unsigned)TEST_EXPECT_X);
    PR("  y      : %u        %u\r\n",  (unsigned)r.y, (unsigned)TEST_EXPECT_Y);
    PR("  score  : %d       %d\r\n",   r.score,  TEST_EXPECT_SCORE);
    PR("  cycle  : %u\r\n", (unsigned)r.cycles);
    PR("  latency: %u.%03u ms @100MHz\r\n",
       (unsigned)(r.cycles / 100000u),
       (unsigned)((r.cycles % 100000u) / 100u));
    PR("\r\n");

    if (r.valid != TEST_EXPECT_VALID)      { ng("target_valid 불일치"); pass = 0; }
    if (r.x     != (uint32_t)TEST_EXPECT_X){ ng("target_x 불일치");     pass = 0; }
    if (r.y     != (uint32_t)TEST_EXPECT_Y){ ng("target_y 불일치");     pass = 0; }
    if (r.score != (int8_t)TEST_EXPECT_SCORE){ ng("target_score 불일치"); pass = 0; }

    if (pass) ok("시뮬레이션과 완전 일치 — RTL 이 실물에서 재현됨");
    return pass ? 0 : -1;
}

/*=====================================================================
 * STEP 5 : 반복 안정성 (선택)
 *=====================================================================*/
static void step5_repeat(int n)
{
    npu_result_t r;
    int i, bad = 0;
    uint32_t cyc_min = 0xFFFFFFFFu, cyc_max = 0;

    step_hdr(5, "반복 안정성");

    for (i = 0; i < n; i++) {
        npu_status_t s = npu_run(test_tensor, TEST_TENSOR_BYTES,
                                 POLL_LIMIT, &r);
        if (s != NPU_OK ||
            r.x != (uint32_t)TEST_EXPECT_X ||
            r.y != (uint32_t)TEST_EXPECT_Y ||
            r.score != (int8_t)TEST_EXPECT_SCORE) {
            bad++;
            if (bad <= 3)
                PR("  [FAIL] %d 회차: %s (x=%u y=%u score=%d)\r\n",
                   i, npu_strerror(s),
                   (unsigned)r.x, (unsigned)r.y, r.score);
        }
        if (r.cycles < cyc_min) cyc_min = r.cycles;
        if (r.cycles > cyc_max) cyc_max = r.cycles;
    }

    PR("  cycle 범위: %u ~ %u\r\n", (unsigned)cyc_min, (unsigned)cyc_max);
    chk(bad == 0, "전 회차 동일 결과");
    chk(cyc_min == cyc_max, "cycle 수 고정 (데이터 의존성 없음)");
    PR("  %d 회 실행, 실패 %d 회\r\n", n, bad);
}

/*---------------------------------------------------------------------
 * step 6 : PS CPU 단독 추론 Baseline
 *
 *   docs/TEAM_ROLE_PLAN.md 4.1 의 "PS CPU FP32/INT8 Baseline" 항목.
 *   NPU 를 전혀 안 쓰고 Cortex-A9 가 같은 텐서를 직접 돌린다.
 *   INT8 경로는 Golden 과 bit-exact 라, 값이 틀리면 측정도 무의미하므로
 *   먼저 결과를 확인하고 나서 시간을 잰다.
 *
 *   NPU 쪽 기준값은 상수로 안 박는다. STEP 4/5 가 남긴 CYCLE_CNT 를
 *   그대로 읽어 쓴다 (§35 — 측정 안 한 숫자를 쓰지 않는다).
 *-------------------------------------------------------------------*/
static void step6_cpu_baseline(int n)
{
    cpu_result_t r;

    step_hdr(6, "PS CPU Baseline (NPU 미사용)");

    cpu_infer_int8(test_tensor, &r);
    chk(r.target_x == TEST_EXPECT_X, "CPU INT8 target_x");
    chk(r.target_y == TEST_EXPECT_Y, "CPU INT8 target_y");
    chk(r.score    == TEST_EXPECT_SCORE, "CPU INT8 target_score");
    PR("  CPU INT8 결과 : x=%d y=%d score=%d  (기대 x=%d y=%d score=%d)\r\n",
       r.target_x, r.target_y, r.score,
       TEST_EXPECT_X, TEST_EXPECT_Y, TEST_EXPECT_SCORE);

    cpu_infer_fp32(test_tensor, &r);
    chk(r.target_x == TEST_EXPECT_X, "CPU FP32 target_x");
    chk(r.target_y == TEST_EXPECT_Y, "CPU FP32 target_y");
    PR("  CPU FP32 결과 : x=%d y=%d  (score 는 float 이라 생략)\r\n",
       r.target_x, r.target_y);

#if HAVE_TIMER
    {
        /* 측정 구간이 이보다 짧으면 us 환산에서 자릿수가 다 날아간다.
         * A9 Global Timer 는 CPU_FREQ/2 = 333.33 MHz 이므로
         * 1e6 tick = 3 ms. 반복 횟수를 늘려서 이 선을 넘긴다.       */
        const unsigned long long MIN_TICKS = 1000000ull;
        unsigned long long dt_i8, dt_f32;
        unsigned int us_i8, us_f32, npu_us;
        uint32_t npu_cycles;
        npu_tick_t t0, t1;
        int i, iter;
        int timer_dead = 0;

#ifdef SDT
        /*-------------------------------------------------------------
         * 통합(SDT) Vitis 의 xiltimer 는 XTime_GetTime() 만 불러서는
         * Global Timer 를 시작하지 않는다. enable(0xF8F00208 <- 1) 은
         * globaltimer_sleep_zynq.c 의 XGlobalTimer_Start() 가 하는데
         * 그건 static 이고 XGlobalTimer_ModifyInterval() 즉 sleep 경로
         * 에서만 불린다. XTime_GetTime() 만 참조하던 예전 ELF 는
         * xiltimer.o 자체가 링크되지 않아 constructor 도 안 돌았고,
         * Counter 가 0 에 멈춘 채였다 (보드 실측 tick 0).
         *
         * public sleep API 를 한 번 부르면 두 가지가 같이 해결된다.
         *   1. Timer 가 켜진다 (Start 가 Counter 도 0 으로 리셋한다)
         *   2. usleep 이 들어 있는 xiltimer.o 가 링크되면서
         *      그 안의 xtimerinit() 이 .init_array 에 들어온다
         * XilTimer_Sleep() 은 내부 함수라 public header 에 prototype 이
         * 없다. 직접 부르지 말고 sleep.h 의 usleep() 을 쓴다.
         *-------------------------------------------------------------*/
        usleep(1);
#endif

        /*-------------------------------------------------------------
         * 예전 판은 그냥 n 번 돌고 나눠서 출력했다. 그래서 타이머가
         * 안 돌면 (t1==t0) 조용히 "0 us" 가 찍혔다. 0 us 는 측정값이
         * 아니라 고장이다. 이제 그 둘을 구분한다.
         *   1. 0 < tick < MIN_TICKS  -> 짧은 것이다. 횟수를 4 배로 늘려 다시 잰다
         *   2. tick == 0             -> 고장이다. 늘리지 않고 [FAIL] 로 끝낸다
         *   3. raw tick 과 tick/sec 를 같이 찍어 원인을 볼 수 있게 한다
         *-------------------------------------------------------------*/
        iter = n;
        for (;;) {
            t0 = tick_now();
            for (i = 0; i < iter; i++) { cpu_infer_int8(test_tensor, &r); }
            t1 = tick_now();
            dt_i8 = (unsigned long long)(t1 - t0);
            /* dt 가 0 이면 "구간이 짧다" 가 아니라 "타이머가 죽었다" 다.
             * A9 에서 INT8 추론 16 회는 최소 수 ms 라 타이머가 살아 있으면
             * 0 이 나올 수 없다. 여기서 횟수를 늘리면 4096 회까지
             * 몇 분을 갈아넣고도 결국 0 이고, 보드가 멈춘 것처럼 보인다.
             * 늘리지 말고 FAIL 을 남긴 뒤 STEP 7 까지 바로 간다.
             * 결과 정합성 검사는 위에서 이미 1 회 했으므로
             * 여기서 반복을 생략해도 기능 검증 범위는 안 줄어든다. */
            if (dt_i8 == 0) { timer_dead = 1; break; }
            if (dt_i8 >= MIN_TICKS || iter >= 4096) break;
            iter *= 4;
        }

        t0 = tick_now();
        for (i = 0; i < iter; i++) { cpu_infer_fp32(test_tensor, &r); }
        t1 = tick_now();
        dt_f32 = (unsigned long long)(t1 - t0);
        if (dt_f32 == 0) timer_dead = 1;

        /* xil_printf 는 %llu / %f 를 모른다. 32bit 로 줄여서 찍는다.
         * 333 MHz 기준 u32 는 약 12.8 초까지 담으므로 여기선 충분하다. */
        PR("\r\n  --- 타이머 상태 ---\r\n");
        PR("  tick/sec    : %u\r\n", (unsigned)TICKS_PER_SEC);
        PR("  반복 횟수   : %d\r\n", iter);
        PR("  INT8 %d회 tick : %u\r\n", iter, (unsigned)dt_i8);
        PR("  FP32 %d회 tick : %u\r\n", iter, (unsigned)dt_f32);
        chk(dt_i8  > 0, "전역 타이머가 돈다 (INT8 구간 tick > 0)");
        chk(dt_f32 > 0, "전역 타이머가 돈다 (FP32 구간 tick > 0)");

        if (timer_dead) {
            PR("  [!] tick 이 0 이다. 시간 환산은 의미가 없어 건너뛴다.\r\n");
            PR("      반복 횟수는 늘리지 않았다. 늘려도 0 이고 시간만 버린다.\r\n");
            PR("      확인: SDT 빌드면 usleep 이 ELF 에 실제로 링크됐는지\r\n");
            PR("            arm-none-eabi-nm -an results/npu_test.elf | grep xtimerinit\r\n");
            PR("            arm-none-eabi-objdump -s -j .init_array results/npu_test.elf\r\n");
            PR("            그리고 xtimer_config.h 의 tick/sec\r\n");
        } else {
            us_i8  = (unsigned int)((dt_i8  * 1000000ull)
                                    / (TICKS_PER_SEC * (unsigned long long)iter));
            us_f32 = (unsigned int)((dt_f32 * 1000000ull)
                                    / (TICKS_PER_SEC * (unsigned long long)iter));

            /* NPU 쪽은 상수로 박지 않는다 (§35).
             * STEP 4/5 가 남긴 CYCLE_CNT 실측값을 그대로 환산한다. */
            npu_cycles = npu_io_read32(NPU_CYCLE_CNT);
            npu_us     = (unsigned int)(npu_cycles / 100u);   /* 100 MHz */

            PR("\r\n  --- Baseline (%d 회 평균) ---\r\n", iter);
            PR("  PS CPU INT8 : %u us\r\n", us_i8);
            PR("  PS CPU FP32 : %u us\r\n", us_f32);
            PR("  NPU         : %u us  (%u cycle @100 MHz, CYCLE_CNT 실측)\r\n",
               npu_us, (unsigned)npu_cycles);
            chk(npu_cycles != 0, "CYCLE_CNT 실측값 있음");
            if (npu_us != 0) {
                PR("  speedup INT8 대비 : %u.%02ux\r\n",
                   us_i8 / npu_us, ((us_i8 * 100u) / npu_us) % 100u);
                PR("  speedup FP32 대비 : %u.%02ux\r\n",
                   us_f32 / npu_us, ((us_f32 * 100u) / npu_us) % 100u);
            }
            PR("  ^ 이 줄들이 results/board_uart_log.txt 에 남아야 Baseline 근거가 된다\r\n");
        }
    }
#else
    (void)n;
    PR("  (호스트 빌드라 시간 측정은 건너뛴다. 값 정합성만 확인)\r\n");
#endif
}

/*=====================================================================
 * STEP 7 : C 통합 상태 (전 기능 비트스트림에서만 의미가 있다)
 *
 *   A 단독 비트스트림(npu_soc.bit)에서는 0x58/0x5C 가 전부 0 이다.
 *   그건 고장이 아니라 C 논리가 없다는 뜻이다. 그래서 이 STEP 은
 *   값을 못 읽었다고 FAIL 을 내지 않는다. 대신 지금 올라간 비트스트림이
 *   어느 쪽인지 UART 로 알려 준다 — 옛/새 비트스트림을 섞어 굽는 사고를
 *   여기서 잡는다.
 *
 *   딱 하나만 FAIL 로 본다: LASER_EN 이 켜져 있으면 안 된다.
 *   자체시험 중에는 SW1(P15) 을 DOWN 으로 두므로 물리 Arm 이 0 이고,
 *   그러면 laser_en 은 어떤 조건에서도 0 이어야 한다 (spec §17).
 *===================================================================*/
static void step7_c_status(void)
{
    uint32_t is  = npu_input_stat();
    uint32_t cs  = npu_control_stat();
    npu_servo_pos_t sp;

    step_hdr(7, "C 통합 상태 (0x0C / 0x58 / 0x5C)");
    npu_get_servo_pos(&sp);

    PR("  INPUT_STAT     = 0x%08x\r\n", (unsigned)is);
    PR("  SERVO_POS_STAT = 0x%08x\r\n", (unsigned)sp.raw);
    PR("  CONTROL_STAT   = 0x%08x\r\n", (unsigned)cs);

    if (sp.raw == 0u && cs == 0u && is == 0u) {
        PR("  -> C 논리가 없는 비트스트림이다 (A 단독 npu_soc.bit).\r\n");
        PR("     전 기능 시험은 results/npu_soc_cfull.bit 을 구워라.\r\n");
        return;
    }

    PR("  -> C 논리가 있는 비트스트림이다 (npu_soc_cfull.bit 계열).\r\n");
    PR("  Servo pos  카메라 pan=%u tilt=%u / 레이저 pan=%u tilt=%u\r\n",
       (unsigned)sp.pan1, (unsigned)sp.tilt1,
       (unsigned)sp.pan2, (unsigned)sp.tilt2);
    PR("  ACC_READY=%u TENSOR_READY=%u OVERRUN=%u EVENT_EN=%u\r\n",
       (unsigned)((is & NPU_IS_ACC_READY)    ? 1 : 0),
       (unsigned)((is & NPU_IS_TENSOR_READY) ? 1 : 0),
       (unsigned)((is & NPU_IS_OVERRUN)      ? 1 : 0),
       (unsigned)((is & NPU_IS_EVENT_ENABLE) ? 1 : 0));
    PR("  evt=%u drop=%u\r\n",
       (unsigned)NPU_IS_EVT_CNT(is), (unsigned)NPU_IS_DROP_CNT(is));
    PR("  HW_ARM=%u SW_ARM=%u ESTOP=%u SERVO_EN=%u LIMIT_ACTIVE=%u FAULT=%u\r\n",
       (unsigned)((cs & NPU_CST_HW_ARM)         ? 1 : 0),
       (unsigned)((cs & NPU_CST_SW_ARM)         ? 1 : 0),
       (unsigned)((cs & NPU_CST_EMERGENCY_STOP) ? 1 : 0),
       (unsigned)((cs & NPU_CST_SERVO_ENABLE)   ? 1 : 0),
       (unsigned)((cs & NPU_CST_LIMIT_ACTIVE)   ? 1 : 0),
       (unsigned)((cs & NPU_CST_LIMIT_FAULT)    ? 1 : 0));

    chk((cs & NPU_CST_LASER_EN) == 0u,
        "LASER_EN = 0 (SW1 DOWN 이면 항상 0 이어야 한다)");
    chk((cs & NPU_CST_RSVD_MASK) == 0u,
        "CONTROL_STAT [31:17] = 0 (배선/비트스트림 정합)");
}

/*=====================================================================*/
int main(void)
{
    PR("\r\n\r\n");
    PR("=============================================\r\n");
    PR(" NPU 보드 자체시험  (a_soc_v02)\r\n");
    PR(" Zybo Z7-20 / xc7z020clg400-1 / 100 MHz\r\n");
    PR(" AXI Base 0x%08x\r\n", (unsigned)NPU_BASE_ADDR);
    PR(" VERSION 기대 0x%08x  (0x58/0x5C RO + Direct START 반영본)\r\n",
       (unsigned)NPU_VERSION_EXPECT);
    PR(" golden  x=%d y=%d score=%d  (test_vectors/case00)\r\n",
       TEST_EXPECT_X, TEST_EXPECT_Y, TEST_EXPECT_SCORE);
    PR("=============================================\r\n");

    if (step1_link() != 0) goto done;
    step2_regs();
    if (step3_load() != 0)  goto done;
    if (step4_infer() != 0) goto done;
    step5_repeat(32);
    step6_cpu_baseline(16);
    step7_c_status();

done:
    PR("\r\n=============================================\r\n");
    if (g_fail == 0) PR(" 결과: PASS  (실패 0건)\r\n");
    else             PR(" 결과: FAIL  (실패 %d건)\r\n", g_fail);
    PR("=============================================\r\n");

    for (;;) { }      /* bare-metal: 여기서 멈춘다 */
}
