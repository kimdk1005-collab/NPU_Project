// ---------------------------------------------------------------------------
// board_io.v -- Zybo Z7-20 서보 브링업 Top  (순수 PL, PS 미사용)
//
//  담당 : C   (SPEC §5.3 이 rtl/control/ 아래 board_io.v 를 C 소유로 명시)
//  상위 권한 : docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md
//
//  목적
//    MG996R 이 실제로 도는지 확인하고, 물리 가동 범위를 실측해
//    HANDOFF §5 의 PAN/TILT_POS_MIN/MAX 를 채우는 것.
//
//  PS 를 쓰지 않는다
//    PL sysclk (K17, 125 MHz) 을 직접 받는다. Block Design / Vitis / AXI 가
//    전부 필요 없고, "C 모듈 구동 클럭이 무엇이냐" 는 A 대기 항목이
//    이 설계에서는 발생하지 않는다. K17 은 확실히 125 MHz 다.
//
//  조작
//    sw[0]  en        0 = 펄스 없음 (서보 무부하). 전원 인가 시 반드시 0 에서 시작
//    sw[1]  sweep     1 = 자동 왕복. 0 = 버튼 수동
//    sw[2]  range     0 = 좁은 범위, 1 = 실측 안전 범위 약 90 도
//    sw[3]  axis      0 = PAN(JD1), 1 = TILT(JD2). 선택 안 된 축은 현재 위치 유지
//    btn[0] pos 감소     btn[1] pos 증가     btn[2] 중립(128)     btn[3] reset
//
//    led[0] 1 Hz 심장박동   led[1] en   led[2] sweep   led[3] axis
//
//  led[0] 이 클럭 검증 수단이다
//    frame_tick 을 25 번 셀 때마다 토글하므로 정확히 1 초 주기다.
//    CLK_HZ 가 실제 클럭과 다르면 그 비율만큼 주기가 어긋난다.
//    스톱워치로 10 초에 10 번인지 세면 서보를 붙이기 전에 잡을 수 있다.
//
//  안전장치가 2 단이다
//    Layer 1 (runtime)   : 여기서 sw[2] 로 고른 범위. 측정하며 넓힐 때 쓴다
//    Layer 2 (parameter) : servo_pwm 출력단 clamp = POS_LIMIT_LO/HI. 최후 방어선
//    Layer 1 을 아무리 넓혀도 Layer 2 를 넘지 못한다. 재합성 없이 범위를
//    넓히더라도 기구가 물리적 한계를 넘지 않도록 하기 위한 구성이다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module board_io #(
    // ** 여기만 125 MHz 다. 통합 설계(100 MHz)와 다른 것이 정상이다. **
    //   board_io 는 브링업 전용 top 이고 PL sysclk K17 을 직결한다.
    //   top_system 에 들어가지 않으므로 CR C-003 의 100 MHz 확정과 무관하다.
    //   여기를 100 MHz 로 "고치면" led[0] 심장박동이 1 초가 아니게 되고
    //   서보 펄스가 전부 어긋난다. 건드리지 말 것.
    parameter integer CLK_HZ       = 125_000_000,  // Zybo Z7 PL sysclk (K17)
    parameter integer PWM_HZ       = 50,
    // MG996R 확장 펄스 범위. 1000~2000 은 약 120 도 밖에 못 쓴다.
    // 180 도 부근까지 쓰려면 500~2500 이 필요하다.
    parameter integer PULSE_MIN_US = 500,
    parameter integer PULSE_MAX_US = 2500,

    // Layer 2 : 최후 방어선. 기구 실측 전에는 이 밖으로 나가지 않는다
    //   pos  32 ->  750 us      pos 224 -> 2250 us    (실측 약 90 도)
    //   양 끝을 완전히 개방하지 않고 여유를 남긴다. 0/255 는 서보의
    //   내부 기계적 스톱을 넘겨 스톨시킬 수 있다.
    parameter integer POS_LIMIT_LO = 32,
    parameter integer POS_LIMIT_HI = 224,

    // Layer 1 : 첫 전원 인가용 좁은 범위
    //   pos 112 -> 1375 us      pos 144 -> 1625 us    (약 30 도)
    parameter integer POS_SAFE_LO  = 112,
    parameter integer POS_SAFE_HI  = 144,

    parameter integer POS_NEUTRAL  = 128,
    parameter integer JOG_STEP     = 2,   // 1 step = 7.81 us. dead band 5 us 를 넘으므로 1 도 반응한다
    parameter integer JOG_REPEAT   = 8,   // 8 frame  = 160 ms 마다 반복
    parameter integer SWEEP_DIV    = 2    // 2 frame  = 40 ms 마다 1 step
)(
    input  wire       sysclk,
    input  wire [3:0] sw,
    input  wire [3:0] btn,
    output wire [3:0] led,
    output wire       pan_pwm,
    output wire       tilt_pwm
);

    localparam integer HB_DIV = PWM_HZ / 2;   // 25 tick = 0.5 s -> 토글 -> 1 s 주기

    // -----------------------------------------------------------------------
    // Reset -- Power-On Reset + btn[3]
    // -----------------------------------------------------------------------
    reg [7:0] por_cnt = 8'd0;
    reg       por_n   = 1'b0;

    always @(posedge sysclk) begin
        if (por_cnt != 8'hFF) begin
            por_cnt <= por_cnt + 1'b1;
            por_n   <= 1'b0;
        end else begin
            por_n <= 1'b1;
        end
    end

    // 비동기 입력이므로 2 단 동기화. 등록된 신호라 reset 에 글리치가 실리지 않는다
    reg [1:0] btn3_sync = 2'b00;
    always @(posedge sysclk) btn3_sync <= {btn3_sync[0], btn[3]};

    wire rst_n = por_n & ~btn3_sync[1];

    // -----------------------------------------------------------------------
    // 입력 동기화
    // -----------------------------------------------------------------------
    reg [2:0] btn_meta = 3'b000, btn_sync = 3'b000;
    reg [3:0] sw_meta  = 4'b0000, sw_sync = 4'b0000;

    always @(posedge sysclk) begin
        btn_meta <= btn[2:0];
        btn_sync <= btn_meta;
        sw_meta  <= sw;
        sw_sync  <= sw_meta;
    end

    wire en_i    = sw_sync[0];
    wire sweep_i = sw_sync[1];
    wire wide_i  = sw_sync[2];
    wire axis_i  = sw_sync[3];

    wire [7:0] lim_lo = wide_i ? POS_LIMIT_LO[7:0] : POS_SAFE_LO[7:0];
    wire [7:0] lim_hi = wide_i ? POS_LIMIT_HI[7:0] : POS_SAFE_HI[7:0];

    // -----------------------------------------------------------------------
    // Frame 단위 처리 -- frame_tick(50 Hz, 20 ms) 이 버튼 디바운스도 겸한다
    // -----------------------------------------------------------------------
    wire frame_tick;

    reg [2:0] btn_fr = 3'b000, btn_fr_d = 3'b000;
    wire [2:0] btn_rise = btn_fr & ~btn_fr_d;

    reg [3:0] jog_cnt = 4'd0;
    reg [3:0] swp_cnt = 4'd0;
    reg [5:0] hb_cnt  = 6'd0;
    reg       hb      = 1'b0;
    reg       sweep_up = 1'b1;

    reg [7:0] pos_pan  = POS_NEUTRAL[7:0];
    reg [7:0] pos_tilt = POS_NEUTRAL[7:0];

    wire [7:0] cur = axis_i ? pos_tilt : pos_pan;

    // 언더/오버플로우를 signed 로 흡수한 뒤 범위로 자른다
    function [7:0] clamp_to;
        input signed [10:0] v;
        input        [7:0]  lo;
        input        [7:0]  hi;
        begin
            if (v < $signed({3'b000, lo}))      clamp_to = lo;
            else if (v > $signed({3'b000, hi})) clamp_to = hi;
            else                                 clamp_to = v[7:0];
        end
    endfunction

    wire jog_now   = (jog_cnt == 4'd0);
    wire sweep_now = (swp_cnt == 4'd0);

    reg signed [10:0] raw;
    reg        [7:0]  nxt;

    always @(*) begin
        raw = $signed({3'b000, cur});

        if (btn_rise[2]) begin
            raw = $signed({3'b000, POS_NEUTRAL[7:0]});   // 중립 복귀
        end else if (sweep_i) begin
            if (sweep_now)
                raw = sweep_up ? raw + 11'sd1 : raw - 11'sd1;
        end else begin
            if (btn_fr[1] && jog_now) raw = raw + JOG_STEP;
            if (btn_fr[0] && jog_now) raw = raw - JOG_STEP;
        end

        nxt = clamp_to(raw, lim_lo, lim_hi);
    end

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            pos_pan  <= POS_NEUTRAL[7:0];
            pos_tilt <= POS_NEUTRAL[7:0];
            btn_fr   <= 3'b000;
            btn_fr_d <= 3'b000;
            jog_cnt  <= 4'd0;
            swp_cnt  <= 4'd0;
            hb_cnt   <= 6'd0;
            hb       <= 1'b0;
            sweep_up <= 1'b1;
        end else if (frame_tick) begin
            btn_fr   <= btn_sync;
            btn_fr_d <= btn_fr;

            jog_cnt <= (jog_cnt == JOG_REPEAT[3:0] - 4'd1) ? 4'd0 : jog_cnt + 4'd1;
            swp_cnt <= (swp_cnt == SWEEP_DIV[3:0]  - 4'd1) ? 4'd0 : swp_cnt + 4'd1;

            // 자동 왕복은 범위 끝에서 방향을 뒤집는다
            if (sweep_i && sweep_now) begin
                if (sweep_up  && nxt >= lim_hi) sweep_up <= 1'b0;
                if (!sweep_up && nxt <= lim_lo) sweep_up <= 1'b1;
            end

            if (axis_i) pos_tilt <= nxt;
            else        pos_pan  <= nxt;

            // 1 Hz 심장박동 -- CLK_HZ 검증용
            if (hb_cnt == HB_DIV[5:0] - 6'd1) begin
                hb_cnt <= 6'd0;
                hb     <= ~hb;
            end else begin
                hb_cnt <= hb_cnt + 6'd1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Servo -- 두 축 모두 동일 parameter. frame_tick 은 lockstep 이라 PAN 것을 쓴다
    // -----------------------------------------------------------------------
    servo_pwm #(
        .CLK_HZ       (CLK_HZ),
        .PWM_HZ       (PWM_HZ),
        .PULSE_MIN_US (PULSE_MIN_US),
        .PULSE_MAX_US (PULSE_MAX_US),
        .POS_MIN      (POS_LIMIT_LO),
        .POS_MAX      (POS_LIMIT_HI)
    ) u_pan (
        .clk        (sysclk),
        .rst_n      (rst_n),
        .en         (en_i),
        .pos        (pos_pan),
        .pwm_out    (pan_pwm),
        .frame_tick (frame_tick)
    );

    servo_pwm #(
        .CLK_HZ       (CLK_HZ),
        .PWM_HZ       (PWM_HZ),
        .PULSE_MIN_US (PULSE_MIN_US),
        .PULSE_MAX_US (PULSE_MAX_US),
        .POS_MIN      (POS_LIMIT_LO),
        .POS_MAX      (POS_LIMIT_HI)
    ) u_tilt (
        .clk        (sysclk),
        .rst_n      (rst_n),
        .en         (en_i),
        .pos        (pos_tilt),
        .pwm_out    (tilt_pwm),
        .frame_tick (/* unused - PAN 과 동일 위상 */)
    );

    assign led = {axis_i, sweep_i, en_i, hb};

endmodule

`default_nettype wire
