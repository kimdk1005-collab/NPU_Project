// ---------------------------------------------------------------------------
// tracking_controller.v -- NPU Target 좌표 -> PAN/TILT Servo Position
//
//  담당 : C
//  상위 권한 : docs/NPU_EVENT_CAMERA_TEAM_COMMON_AI_INTEGRATION_SPEC_v1.2.md
//  규격 : SPEC §14  A -> C Target Interface
//         SPEC §15  Center=(32,32), P Control + Dead Zone
//         SPEC §16  target_valid=0 이면 현재 위치 Hold
//         handoff/C_EVENT_CONTROL_HANDOFF.md §4~§6
//
//  제어 주기
//    target_valid 은 NPU done 이후 다음 start 까지 유지되는 Level 신호다.
//    따라서 target_valid 동안 매 clock 위치를 바꾸면 즉시 Limit 에 닿는다.
//    위치 갱신은 servo_pwm 의 frame_tick(50 Hz, 20 ms) 에서만 수행한다.
//
//  P Control + Slew Limit
//    error = target - 32
//    |error| <= DEAD_ZONE 이면 Hold
//    prop_step = (|error| * P_GAIN) >> P_GAIN_SHIFT
//    0 이면 1 로 올린 뒤 SLEW_LIMIT 으로 제한한다.
//
//    기본 SLEW_LIMIT=1 이므로 실측 0.469 degree/step 기준 20 ms 마다
//    최대 약 0.469 degree 만 이동한다. D4 의 부드러운 구동 시작값이며,
//    실제 하중을 붙인 D10 에서 parameter 만 조정한다.
//
//  축 방향
//    기본은 화면 X/Y 증가가 Servo pos 증가다. 기구 조립 방향이 반대이면
//    PAN_INVERT / TILT_INVERT parameter 만 1 로 바꾼다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tracking_controller #(
    parameter integer CENTER_X       = 32,
    parameter integer CENTER_Y       = 32,
    parameter integer DEAD_ZONE      = 4,
    parameter integer P_GAIN         = 1,
    parameter integer P_GAIN_SHIFT   = 2,
    parameter integer SLEW_LIMIT     = 1,

    parameter integer PAN_POS_MIN    = 32,
    parameter integer PAN_POS_MAX    = 224,
    parameter integer TILT_POS_MIN   = 32,
    parameter integer TILT_POS_MAX   = 224,
    parameter integer POS_NEUTRAL    = 128,

    parameter integer PAN_INVERT     = 0,
    parameter integer TILT_INVERT    = 0
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    frame_tick,

    // SPEC §14 -- 이름/폭/의미 변경 금지
    input  wire                    target_valid,
    input  wire [5:0]              target_x,
    input  wire [5:0]              target_y,
    input  wire signed [7:0]       target_score,

    output reg  [7:0]              pan_pos,
    output reg  [7:0]              tilt_pos
);

    localparam signed [6:0] CENTER_X_S = CENTER_X;
    localparam signed [6:0] CENTER_Y_S = CENTER_Y;
    localparam        [7:0] SLEW_U     = SLEW_LIMIT;
    localparam        [7:0] PAN_MIN_U  = PAN_POS_MIN;
    localparam        [7:0] PAN_MAX_U  = PAN_POS_MAX;
    localparam        [7:0] TILT_MIN_U = TILT_POS_MIN;
    localparam        [7:0] TILT_MAX_U = TILT_POS_MAX;

    initial begin
        if (CENTER_X < 0 || CENTER_X > 63 || CENTER_Y < 0 || CENTER_Y > 63)
            $error("tracking_controller: CENTER 좌표가 0~63 밖임");
        if (DEAD_ZONE < 4)
            $error("tracking_controller: DEAD_ZONE(%0d) < SPEC §15 최소값 4", DEAD_ZONE);
        if (P_GAIN < 1 || P_GAIN_SHIFT < 0 || P_GAIN_SHIFT > 16)
            $error("tracking_controller: P_GAIN/P_GAIN_SHIFT parameter 오류");
        if (SLEW_LIMIT < 1 || SLEW_LIMIT > 127)
            $error("tracking_controller: SLEW_LIMIT(%0d) 는 1~127 이어야 함", SLEW_LIMIT);
        if (PAN_POS_MIN > PAN_POS_MAX || TILT_POS_MIN > TILT_POS_MAX)
            $error("tracking_controller: POS_MIN > POS_MAX");
        if (POS_NEUTRAL < PAN_POS_MIN || POS_NEUTRAL > PAN_POS_MAX ||
            POS_NEUTRAL < TILT_POS_MIN || POS_NEUTRAL > TILT_POS_MAX)
            $error("tracking_controller: POS_NEUTRAL 이 Safe Limit 밖임");
        if ((PAN_INVERT != 0 && PAN_INVERT != 1) ||
            (TILT_INVERT != 0 && TILT_INVERT != 1))
            $error("tracking_controller: *_INVERT 는 0 또는 1");
    end

    // target_score 는 Laser Interlock(D6)이 사용한다. Tracking 이동 판단은
    // A가 생성한 target_valid 를 단일 권위로 사용한다.
    wire _unused_target_score = &{1'b0, target_score};

    wire signed [6:0] error_x = $signed({1'b0, target_x}) - CENTER_X_S;
    wire signed [6:0] error_y = $signed({1'b0, target_y}) - CENTER_Y_S;

    wire [6:0] abs_x = error_x[6] ? (~error_x + 7'd1) : error_x;
    wire [6:0] abs_y = error_y[6] ? (~error_y + 7'd1) : error_y;

    wire x_move = (abs_x > DEAD_ZONE);
    wire y_move = (abs_y > DEAD_ZONE);

    wire [31:0] x_scaled = abs_x * P_GAIN;
    wire [31:0] y_scaled = abs_y * P_GAIN;
    wire [31:0] x_prop   = x_scaled >> P_GAIN_SHIFT;
    wire [31:0] y_prop   = y_scaled >> P_GAIN_SHIFT;

    // Dead Zone 밖인데 작은 Gain 때문에 0 이 되면 최소 1 step 은 움직인다.
    wire [7:0] x_prop_u = (x_prop == 0) ? 8'd1 :
                           (x_prop > 255) ? 8'd255 : x_prop[7:0];
    wire [7:0] y_prop_u = (y_prop == 0) ? 8'd1 :
                           (y_prop > 255) ? 8'd255 : y_prop[7:0];

    wire [7:0] x_step = !x_move ? 8'd0 :
                        (x_prop_u > SLEW_U) ? SLEW_U : x_prop_u;
    wire [7:0] y_step = !y_move ? 8'd0 :
                        (y_prop_u > SLEW_U) ? SLEW_U : y_prop_u;

    wire pan_inc  = (error_x > 0) ^ (PAN_INVERT  != 0);
    wire tilt_inc = (error_y > 0) ^ (TILT_INVERT != 0);

    wire signed [9:0] pan_cur_s  = $signed({2'b00, pan_pos});
    wire signed [9:0] tilt_cur_s = $signed({2'b00, tilt_pos});
    wire signed [9:0] x_step_s   = $signed({2'b00, x_step});
    wire signed [9:0] y_step_s   = $signed({2'b00, y_step});

    wire signed [9:0] pan_raw  = pan_inc  ? (pan_cur_s  + x_step_s) :
                                           (pan_cur_s  - x_step_s);
    wire signed [9:0] tilt_raw = tilt_inc ? (tilt_cur_s + y_step_s) :
                                           (tilt_cur_s - y_step_s);

    function [7:0] clamp_pos;
        input signed [9:0] v;
        input        [7:0] lo;
        input        [7:0] hi;
        begin
            if (v < $signed({2'b00, lo}))       clamp_pos = lo;
            else if (v > $signed({2'b00, hi}))  clamp_pos = hi;
            else                                 clamp_pos = v[7:0];
        end
    endfunction

    wire [7:0] pan_next  = clamp_pos(pan_raw,  PAN_MIN_U,  PAN_MAX_U);
    wire [7:0] tilt_next = clamp_pos(tilt_raw, TILT_MIN_U, TILT_MAX_U);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pan_pos  <= POS_NEUTRAL[7:0];
            tilt_pos <= POS_NEUTRAL[7:0];
        end else if (frame_tick) begin
            if (target_valid) begin
                pan_pos  <= pan_next;
                tilt_pos <= tilt_next;
            end
            // target_valid=0 : SPEC §16 / C 정책에 따라 현재 위치 Hold
        end
    end

endmodule

`default_nettype wire
