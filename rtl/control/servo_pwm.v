// ---------------------------------------------------------------------------
// servo_pwm.v  -- Hobby Servo PWM Generator + Safe Angle Limit
//
//  담당 : C
//  규격 : handoff/C_EVENT_CONTROL_HANDOFF.md  §3 Servo Command Format
//         (상위 권한: docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md)
//
//  pos[7:0] 를 표준 하비 서보 펄스폭으로 변환한다.
//
//  pulse_cyc = PULSE_MIN_CYC + ((pos * SPAN_CYC) >> 8)
//
//    pos = 0    -> PULSE_MIN_US                  (최소각)
//    pos = 128  -> PULSE_MIN_US + SPAN/2         (중립, 1500 us)
//    pos = 255  -> PULSE_MAX_US - SPAN/256       (최대각 - 1 LSB)
//
//  주의 : >>8 은 255 가 아니라 256 으로 나눈다. 따라서 pos=255 가
//  PULSE_MAX_US 에 정확히 닿지 않는다. 기본값 500~2500 us 기준으로
//  2492.19 us 이며 7.81 us 모자란다.
//
//  D1 에는 "1 step 이 dead band 보다 작아 어차피 구분되지 않는다" 를 근거로
//  들었는데, 그것은 펄스 범위가 1000~2000 이던 때의 이야기다 (1 step = 3.91 us).
//  D2 에 범위를 500~2500 으로 넓히면서 1 step = 7.81 us 가 되어
//  MG996R dead band 약 5 us 를 넘는다. 즉 지금은 물리적으로 구분된다.
//
//  그래도 >>8 을 유지하는 이유는 POS_MAX 가 224 라서 pos=255 가 애초에
//  출력단 clamp 에 걸려 나가지 않기 때문이다. 상한 근처의 1 LSB 는
//  실제로 사용되지 않는다. 나눗셈을 붙일 이유가 없다.
//
//  안전 설계
//    - POS_MIN / POS_MAX 로 출력단에서 Clamp 한다. 최후 방어선이므로
//      상위 모듈이 잘못된 값을 줘도 기구가 물리적 한계를 넘지 않는다.
//    - en = 0 이면 펄스를 내보내지 않는다 (서보 무부하).
//    - 펄스폭은 Frame 시작 시점에만 갱신한다. Frame 도중 pos 가 바뀌어도
//      현재 펄스는 흔들리지 않는다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module servo_pwm #(
    // 기본값은 D2 에 실물로 검증된 구성이다 (HANDOFF §3.3, §5).
    // 덮어쓰지 않고 그대로 인스턴스해도 기구가 다치지 않도록 잡았다.
    parameter integer CLK_HZ       = 100_000_000,  // CR C-003 확정. A 의 npu_core 와
                                                   //   단일 clock domain (PS FCLK_CLK0)
    parameter integer PWM_HZ       = 50,           // 20 ms Frame
    parameter integer PULSE_MIN_US = 500,          // D2 실측 확정 (구 1000)
    parameter integer PULSE_MAX_US = 2500,         // D2 실측 확정 (구 2000)
    parameter integer POS_MIN      = 32,           // D2 실측 확정. pos 32 -> 750 us
    parameter integer POS_MAX      = 224           //   pos 224 -> 2250 us, 약 90 도
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,          // 0 = 펄스 정지
    input  wire [7:0]  pos,         // 목표 위치
    output reg         pwm_out,
    output reg         frame_tick   // Frame 시작 1-cycle pulse (상위 Slew Limit 용)
);

    // -----------------------------------------------------------------------
    // 상수
    // -----------------------------------------------------------------------
    localparam integer CYC_PER_US    = CLK_HZ / 1_000_000;
    localparam integer PERIOD_CYC    = CLK_HZ / PWM_HZ;
    localparam integer PULSE_MIN_CYC = CYC_PER_US * PULSE_MIN_US;
    localparam integer PULSE_MAX_CYC = CYC_PER_US * PULSE_MAX_US;
    localparam integer SPAN_CYC      = PULSE_MAX_CYC - PULSE_MIN_CYC;
    localparam integer CNT_W         = $clog2(PERIOD_CYC);

    initial begin
        if (PULSE_MAX_CYC >= PERIOD_CYC)
            $error("servo_pwm: PULSE_MAX_US(%0d) 가 Frame 주기를 넘음", PULSE_MAX_US);
        if (POS_MIN > POS_MAX)
            $error("servo_pwm: POS_MIN(%0d) > POS_MAX(%0d)", POS_MIN, POS_MAX);
    end

    // -----------------------------------------------------------------------
    // Safe Angle Limit -- 출력단 Clamp
    // -----------------------------------------------------------------------
    wire [7:0] pos_clamped = (pos < POS_MIN[7:0]) ? POS_MIN[7:0] :
                             (pos > POS_MAX[7:0]) ? POS_MAX[7:0] : pos;

    // pos * SPAN_CYC : 255 * 125000 = 31,875,000 -> 25 bit. 32 bit 로 여유 확보
    // 곱셈 결과를 먼저 등록한다. Servo pos는 Frame 단위로만 바뀌므로 다음
    // Frame까지 20 ms의 여유가 있고, 이 1-cycle 파이프라인은 PWM 응답 지연을
    // 늘리지 않으면서 pos -> DSP -> adder -> pulse_cyc 장경로를 끊는다.
    wire [31:0] scaled_next = pos_clamped * SPAN_CYC;
    reg  [31:0] scaled_reg;
    wire [31:0] pulse_nx = PULSE_MIN_CYC + (scaled_reg >> 8);

    always @(posedge clk) begin
        if (!rst_n)
            scaled_reg <= 128 * SPAN_CYC;
        else
            scaled_reg <= scaled_next;
    end

    // -----------------------------------------------------------------------
    // Frame Counter
    // -----------------------------------------------------------------------
    reg [CNT_W-1:0] cnt;
    reg [31:0]      pulse_cyc;   // Frame 시작 시 latch

    wire frame_end = (cnt == PERIOD_CYC - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt        <= {CNT_W{1'b0}};
            pulse_cyc  <= PULSE_MIN_CYC + (SPAN_CYC >> 1);  // 중립에서 시작
            pwm_out    <= 1'b0;
            frame_tick <= 1'b0;
        end else begin
            frame_tick <= 1'b0;

            if (frame_end) begin
                cnt        <= {CNT_W{1'b0}};
                pulse_cyc  <= pulse_nx;      // Frame 경계에서만 갱신
                frame_tick <= 1'b1;
            end else begin
                cnt <= cnt + 1'b1;
            end

            pwm_out <= en && ({{(32-CNT_W){1'b0}}, cnt} < pulse_cyc);
        end
    end

endmodule

`default_nettype wire
