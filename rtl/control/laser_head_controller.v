// ---------------------------------------------------------------------------
// laser_head_controller.v -- PT#1 Camera Pose + 화면 잔차 -> PT#2 Laser Pose
//
//  공통 규격 v1.5 §15.2:
//    target_angle = camera_angle + FOV/64 * (target - center)
//    laser_cmd    = target_angle + laser_offset
//
//  이 모듈은 각도를 Servo pos 단위로 바꿔 같은 식을 구현한다.
//    *_ERR_NUM / *_ERR_DEN = 화면 좌표 1 pixel당 Servo pos step
//
//  FOV와 축 부호는 실측 전 미확정이므로 parameter로만 둔다. 기본 1/1은
//  LED 브링업 시작값이며, 실제 레이저 장착 전 반드시 FOV/방향을 실측한다.
//  출력은 Frame마다 SLEW_LIMIT 이내로 이동해 Servo 명령이 튀지 않게 한다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module laser_head_controller #(
    parameter integer CENTER_X          = 32,
    parameter integer CENTER_Y          = 32,

    parameter integer PAN_ERR_NUM       = 1,
    parameter integer PAN_ERR_DEN       = 1,
    parameter integer TILT_ERR_NUM      = 1,
    parameter integer TILT_ERR_DEN      = 1,
    parameter integer PAN_ERR_INVERT    = 0,
    parameter integer TILT_ERR_INVERT   = 0,

    // LASER_CAL 실측값을 Servo pos step으로 변환해 넣는다.
    parameter integer PAN_OFFSET_POS    = 0,
    parameter integer TILT_OFFSET_POS   = 0,

    parameter integer PAN2_POS_MIN      = 32,
    parameter integer PAN2_POS_MAX      = 224,
    parameter integer TILT2_POS_MIN     = 32,
    parameter integer TILT2_POS_MAX     = 224,
    parameter integer POS_NEUTRAL       = 128,
    parameter integer SLEW_LIMIT        = 2
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       frame_tick,

    input  wire       target_valid,
    input  wire [5:0] target_x,
    input  wire [5:0] target_y,

    // PT#1 Tracking Controller가 현재 출력 중인 절대 위치
    input  wire [7:0] camera_pan_pos,
    input  wire [7:0] camera_tilt_pos,

    // PT#2 실제 Slew 적용 명령
    output reg  [7:0] laser_pan_pos,
    output reg  [7:0] laser_tilt_pos,

    // §15.2 변환식의 Clamp 결과. 캘리브레이션/검증용으로 함께 노출한다.
    output wire [7:0] laser_pan_target,
    output wire [7:0] laser_tilt_target,
    output wire       aim_ready
);

    localparam signed [6:0] CENTER_X_S = CENTER_X;
    localparam signed [6:0] CENTER_Y_S = CENTER_Y;
    localparam        [7:0] PAN2_MIN_U = PAN2_POS_MIN;
    localparam        [7:0] PAN2_MAX_U = PAN2_POS_MAX;
    localparam        [7:0] TILT2_MIN_U = TILT2_POS_MIN;
    localparam        [7:0] TILT2_MAX_U = TILT2_POS_MAX;
    localparam        [7:0] SLEW_U = SLEW_LIMIT;

    initial begin
        if (CENTER_X < 0 || CENTER_X > 63 || CENTER_Y < 0 || CENTER_Y > 63)
            $error("laser_head_controller: CENTER 좌표가 0~63 밖임");
        if (PAN_ERR_NUM < 0 || TILT_ERR_NUM < 0 ||
            PAN_ERR_DEN < 1 || TILT_ERR_DEN < 1)
            $error("laser_head_controller: 화면 오차 변환 비율 parameter 오류");
        if ((PAN_ERR_INVERT != 0 && PAN_ERR_INVERT != 1) ||
            (TILT_ERR_INVERT != 0 && TILT_ERR_INVERT != 1))
            $error("laser_head_controller: *_ERR_INVERT 는 0 또는 1");
        if (PAN2_POS_MIN > PAN2_POS_MAX || TILT2_POS_MIN > TILT2_POS_MAX)
            $error("laser_head_controller: POS_MIN > POS_MAX");
        if (POS_NEUTRAL < PAN2_POS_MIN || POS_NEUTRAL > PAN2_POS_MAX ||
            POS_NEUTRAL < TILT2_POS_MIN || POS_NEUTRAL > TILT2_POS_MAX)
            $error("laser_head_controller: POS_NEUTRAL 이 SAFE_LIMIT2 밖임");
        if (SLEW_LIMIT < 1 || SLEW_LIMIT > 127)
            $error("laser_head_controller: SLEW_LIMIT 는 1~127 이어야 함");
    end

    wire signed [6:0] error_x = $signed({1'b0, target_x}) - CENTER_X_S;
    wire signed [6:0] error_y = $signed({1'b0, target_y}) - CENTER_Y_S;
    wire        [6:0] abs_x = error_x[6] ? (~error_x + 7'd1) : error_x;
    wire        [6:0] abs_y = error_y[6] ? (~error_y + 7'd1) : error_y;

    // 분모는 parameter 상수라 합성 시 고정 나눗셈으로 최적화된다.
    wire [31:0] pan_mag_u  = (abs_x * PAN_ERR_NUM) / PAN_ERR_DEN;
    wire [31:0] tilt_mag_u = (abs_y * TILT_ERR_NUM) / TILT_ERR_DEN;
    wire signed [31:0] pan_mag_s  = $signed(pan_mag_u);
    wire signed [31:0] tilt_mag_s = $signed(tilt_mag_u);

    wire pan_inc  = (error_x > 0) ^ (PAN_ERR_INVERT != 0);
    wire tilt_inc = (error_y > 0) ^ (TILT_ERR_INVERT != 0);

    wire signed [31:0] pan_residual  = pan_inc  ? pan_mag_s  : -pan_mag_s;
    wire signed [31:0] tilt_residual = tilt_inc ? tilt_mag_s : -tilt_mag_s;

    // camera pose를 반드시 더한다. error만으로 PT#2를 구하는 구현은 금지다.
    wire signed [31:0] pan_target_raw =
        $signed({1'b0, camera_pan_pos}) + pan_residual + PAN_OFFSET_POS;
    wire signed [31:0] tilt_target_raw =
        $signed({1'b0, camera_tilt_pos}) + tilt_residual + TILT_OFFSET_POS;

    function [7:0] clamp_pos;
        input signed [31:0] v;
        input        [7:0]  lo;
        input        [7:0]  hi;
        begin
            if (v < $signed({1'b0, lo}))       clamp_pos = lo;
            else if (v > $signed({1'b0, hi}))  clamp_pos = hi;
            else                                clamp_pos = v[7:0];
        end
    endfunction

    assign laser_pan_target  = clamp_pos(pan_target_raw,  PAN2_MIN_U,  PAN2_MAX_U);
    assign laser_tilt_target = clamp_pos(tilt_target_raw, TILT2_MIN_U, TILT2_MAX_U);

    function [7:0] slew_to;
        input [7:0] current;
        input [7:0] desired;
        reg   [8:0] increased;
        begin
            if (desired > current) begin
                increased = {1'b0, current} + {1'b0, SLEW_U};
                if (increased >= {1'b0, desired}) slew_to = desired;
                else                               slew_to = increased[7:0];
            end else if (desired < current) begin
                if ((current - desired) <= SLEW_U) slew_to = desired;
                else                               slew_to = current - SLEW_U;
            end else begin
                slew_to = current;
            end
        end
    endfunction

    // 실제 출력 명령이 계산 목표에 도달하기 전에는 Laser Interlock을 열지 않는다.
    assign aim_ready = target_valid &&
                       (laser_pan_pos == laser_pan_target) &&
                       (laser_tilt_pos == laser_tilt_target);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            laser_pan_pos  <= POS_NEUTRAL[7:0];
            laser_tilt_pos <= POS_NEUTRAL[7:0];
        end else if (frame_tick && target_valid) begin
            laser_pan_pos  <= slew_to(laser_pan_pos,  laser_pan_target);
            laser_tilt_pos <= slew_to(laser_tilt_pos, laser_tilt_target);
        end
        // Target Lost에서는 현재 위치 Hold. Laser 출력은 Interlock이 즉시 차단한다.
    end

endmodule

`default_nettype wire
