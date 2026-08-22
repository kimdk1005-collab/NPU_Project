// ---------------------------------------------------------------------------
// dual_head_control.v -- Camera PT#1 + LED/Laser PT#2 4축 제어 통합 경로
//
//  PT#1: tracking_controller -> camera PAN/TILT Servo PWM
//  PT#2: laser_head_controller -> laser PAN/TILT Servo PWM
//  LED : laser_interlock의 fail-closed laser_enable을 그대로 표시
//
//  실제 Laser 출력은 아직 만들지 않는다. LED 검증과 FOV/축 방향/Offset 실측이
//  끝난 뒤에도 laser_enable_safe 뒤에 물리 Arm/E-stop 구동단을 추가해야 한다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module dual_head_control #(
    parameter integer CLK_HZ                  = 100_000_000,
    parameter integer PWM_HZ                  = 50,
    parameter integer PULSE_MIN_US            = 500,
    parameter integer PULSE_MAX_US            = 2500,

    parameter integer PAN1_POS_MIN            = 32,
    parameter integer PAN1_POS_MAX            = 224,
    parameter integer TILT1_POS_MIN           = 32,
    parameter integer TILT1_POS_MAX           = 224,
    parameter integer PAN2_POS_MIN            = 32,
    parameter integer PAN2_POS_MAX            = 224,
    parameter integer TILT2_POS_MIN           = 32,
    parameter integer TILT2_POS_MAX           = 224,
    parameter integer POS_NEUTRAL             = 128,

    parameter integer CAMERA_SLEW_LIMIT       = 1,
    parameter integer CAMERA_PAN_INVERT       = 0,
    parameter integer CAMERA_TILT_INVERT      = 0,
    parameter integer LASER_SLEW_LIMIT        = 2,
    parameter integer PAN_ERR_NUM             = 1,
    parameter integer PAN_ERR_DEN             = 1,
    parameter integer TILT_ERR_NUM            = 1,
    parameter integer TILT_ERR_DEN            = 1,
    parameter integer PAN_ERR_INVERT          = 0,
    parameter integer TILT_ERR_INVERT         = 0,
    parameter integer PAN_OFFSET_POS          = 0,
    parameter integer TILT_OFFSET_POS         = 0,

    parameter integer SCORE_THRESHOLD         = 0,
    parameter integer LOCK_CONFIRM_UPDATES    = 3,
    parameter integer TARGET_TIMEOUT_FRAMES   = 3,
    parameter integer MAX_ON_FRAMES           = 25
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    servo_enable,

    input  wire                    target_update,
    input  wire                    target_valid,
    input  wire [5:0]              target_x,
    input  wire [5:0]              target_y,
    input  wire signed [7:0]       target_score,

    input  wire                    laser_arm,
    input  wire                    emergency_stop,

    output wire                    camera_pan_pwm,
    output wire                    camera_tilt_pwm,
    output wire                    laser_pan_pwm,
    output wire                    laser_tilt_pwm,
    output wire                    laser_led,
    output wire                    laser_enable_safe,
    output wire                    frame_tick,

    output wire [7:0]              camera_pan_pos,
    output wire [7:0]              camera_tilt_pos,
    output wire [7:0]              laser_pan_pos,
    output wire [7:0]              laser_tilt_pos,
    output wire [7:0]              laser_pan_target,
    output wire [7:0]              laser_tilt_target,
    output wire                    laser_aim_ready,
    output wire                    laser_lock_qualified,
    output wire                    laser_target_fresh,
    output wire                    laser_timeout_fault
);

    tracking_controller #(
        .SLEW_LIMIT   (CAMERA_SLEW_LIMIT),
        .PAN_POS_MIN  (PAN1_POS_MIN),
        .PAN_POS_MAX  (PAN1_POS_MAX),
        .TILT_POS_MIN (TILT1_POS_MIN),
        .TILT_POS_MAX (TILT1_POS_MAX),
        .POS_NEUTRAL  (POS_NEUTRAL),
        .PAN_INVERT   (CAMERA_PAN_INVERT),
        .TILT_INVERT  (CAMERA_TILT_INVERT)
    ) u_camera_tracking (
        .clk          (clk),
        .rst_n        (rst_n),
        .frame_tick   (frame_tick),
        .target_valid (target_valid),
        .target_x     (target_x),
        .target_y     (target_y),
        .target_score (target_score),
        .pan_pos      (camera_pan_pos),
        .tilt_pos     (camera_tilt_pos)
    );

    laser_head_controller #(
        .PAN_ERR_NUM     (PAN_ERR_NUM),
        .PAN_ERR_DEN     (PAN_ERR_DEN),
        .TILT_ERR_NUM    (TILT_ERR_NUM),
        .TILT_ERR_DEN    (TILT_ERR_DEN),
        .PAN_ERR_INVERT  (PAN_ERR_INVERT),
        .TILT_ERR_INVERT (TILT_ERR_INVERT),
        .PAN_OFFSET_POS  (PAN_OFFSET_POS),
        .TILT_OFFSET_POS (TILT_OFFSET_POS),
        .PAN2_POS_MIN    (PAN2_POS_MIN),
        .PAN2_POS_MAX    (PAN2_POS_MAX),
        .TILT2_POS_MIN   (TILT2_POS_MIN),
        .TILT2_POS_MAX   (TILT2_POS_MAX),
        .POS_NEUTRAL     (POS_NEUTRAL),
        .SLEW_LIMIT      (LASER_SLEW_LIMIT)
    ) u_laser_head (
        .clk               (clk),
        .rst_n             (rst_n),
        .frame_tick        (frame_tick),
        .target_valid      (target_valid),
        .target_x          (target_x),
        .target_y          (target_y),
        .camera_pan_pos    (camera_pan_pos),
        .camera_tilt_pos   (camera_tilt_pos),
        .laser_pan_pos     (laser_pan_pos),
        .laser_tilt_pos    (laser_tilt_pos),
        .laser_pan_target  (laser_pan_target),
        .laser_tilt_target (laser_tilt_target),
        .aim_ready         (laser_aim_ready)
    );

    laser_interlock #(
        .SCORE_THRESHOLD      (SCORE_THRESHOLD),
        .PAN1_POS_MIN         (PAN1_POS_MIN),
        .PAN1_POS_MAX         (PAN1_POS_MAX),
        .TILT1_POS_MIN        (TILT1_POS_MIN),
        .TILT1_POS_MAX        (TILT1_POS_MAX),
        .PAN2_POS_MIN         (PAN2_POS_MIN),
        .PAN2_POS_MAX         (PAN2_POS_MAX),
        .TILT2_POS_MIN        (TILT2_POS_MIN),
        .TILT2_POS_MAX        (TILT2_POS_MAX),
        .LOCK_CONFIRM_UPDATES (LOCK_CONFIRM_UPDATES),
        .TARGET_TIMEOUT_FRAMES(TARGET_TIMEOUT_FRAMES),
        .MAX_ON_FRAMES        (MAX_ON_FRAMES)
    ) u_laser_interlock (
        .clk             (clk),
        .rst_n           (rst_n),
        .frame_tick      (frame_tick),
        .target_update   (target_update),
        // Servo가 꺼진 상태에서 광원만 켜지는 경로를 만들지 않는다.
        .system_arm      (laser_arm && servo_enable),
        .emergency_stop  (emergency_stop),
        .target_valid    (target_valid),
        .target_x        (target_x),
        .target_y        (target_y),
        .target_score    (target_score),
        .camera_pan_pos  (camera_pan_pos),
        .camera_tilt_pos (camera_tilt_pos),
        .laser_pan_pos   (laser_pan_pos),
        .laser_tilt_pos  (laser_tilt_pos),
        .aim_ready       (laser_aim_ready),
        .laser_enable    (laser_enable_safe),
        .lock_qualified  (laser_lock_qualified),
        .target_fresh    (laser_target_fresh),
        .timeout_fault   (laser_timeout_fault)
    );

    // LED가 실제 레이저 출력과 동일한 논리 신호를 미리 보여준다.
    assign laser_led = laser_enable_safe;

    // 네 Servo PWM은 하나의 frame_tick 기준으로 같은 Frame 위상에서 동작한다.
    servo_pwm #(
        .CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
        .PULSE_MIN_US(PULSE_MIN_US), .PULSE_MAX_US(PULSE_MAX_US),
        .POS_MIN(PAN1_POS_MIN), .POS_MAX(PAN1_POS_MAX)
    ) u_camera_pan_pwm (
        .clk(clk), .rst_n(rst_n), .en(servo_enable),
        .pos(camera_pan_pos), .pwm_out(camera_pan_pwm), .frame_tick(frame_tick)
    );

    servo_pwm #(
        .CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
        .PULSE_MIN_US(PULSE_MIN_US), .PULSE_MAX_US(PULSE_MAX_US),
        .POS_MIN(TILT1_POS_MIN), .POS_MAX(TILT1_POS_MAX)
    ) u_camera_tilt_pwm (
        .clk(clk), .rst_n(rst_n), .en(servo_enable),
        .pos(camera_tilt_pos), .pwm_out(camera_tilt_pwm), .frame_tick()
    );

    servo_pwm #(
        .CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
        .PULSE_MIN_US(PULSE_MIN_US), .PULSE_MAX_US(PULSE_MAX_US),
        .POS_MIN(PAN2_POS_MIN), .POS_MAX(PAN2_POS_MAX)
    ) u_laser_pan_pwm (
        .clk(clk), .rst_n(rst_n), .en(servo_enable),
        .pos(laser_pan_pos), .pwm_out(laser_pan_pwm), .frame_tick()
    );

    servo_pwm #(
        .CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
        .PULSE_MIN_US(PULSE_MIN_US), .PULSE_MAX_US(PULSE_MAX_US),
        .POS_MIN(TILT2_POS_MIN), .POS_MAX(TILT2_POS_MAX)
    ) u_laser_tilt_pwm (
        .clk(clk), .rst_n(rst_n), .en(servo_enable),
        .pos(laser_tilt_pos), .pwm_out(laser_tilt_pwm), .frame_tick()
    );

endmodule

`default_nettype wire
