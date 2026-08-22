// ---------------------------------------------------------------------------
// laser_board_io.v -- Zybo Z7-20 PT#2 레이저 헤드 2축 단독 브링업 Top
//
//  카메라 PT#1에서 검증한 board_io 조작/PWM 로직을 그대로 재사용하고,
//  출력 이름만 PT#2 레이저 헤드에 맞게 고정한다. 최종 자동 추적 Top이 아니라
//  JD3/JD4에 연결한 레이저 PAN/TILT Servo의 방향과 안전 범위를 확인하는 용도다.
//
//  실제 레이저 광원은 이 Top에 연결하지 않는다. LED Interlock과 자동 4축 경로는
//  dual_head_control에서 별도로 검증한다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module laser_board_io #(
    parameter integer CLK_HZ       = 125_000_000,
    parameter integer PWM_HZ       = 50,
    parameter integer PULSE_MIN_US = 500,
    parameter integer PULSE_MAX_US = 2500,
    parameter integer POS_LIMIT_LO = 32,
    parameter integer POS_LIMIT_HI = 224,
    parameter integer POS_SAFE_LO  = 112,
    parameter integer POS_SAFE_HI  = 144,
    parameter integer POS_NEUTRAL  = 128,
    parameter integer JOG_STEP     = 2,
    parameter integer JOG_REPEAT   = 8,
    parameter integer SWEEP_DIV    = 2
)(
    input  wire       sysclk,
    input  wire [3:0] sw,
    input  wire [3:0] btn,
    output wire [3:0] led,
    output wire       laser_pan_pwm,
    output wire       laser_tilt_pwm
);

    board_io #(
        .CLK_HZ       (CLK_HZ),
        .PWM_HZ       (PWM_HZ),
        .PULSE_MIN_US (PULSE_MIN_US),
        .PULSE_MAX_US (PULSE_MAX_US),
        .POS_LIMIT_LO (POS_LIMIT_LO),
        .POS_LIMIT_HI (POS_LIMIT_HI),
        .POS_SAFE_LO  (POS_SAFE_LO),
        .POS_SAFE_HI  (POS_SAFE_HI),
        .POS_NEUTRAL  (POS_NEUTRAL),
        .JOG_STEP     (JOG_STEP),
        .JOG_REPEAT   (JOG_REPEAT),
        .SWEEP_DIV    (SWEEP_DIV)
    ) u_pt2_bringup (
        .sysclk   (sysclk),
        .sw       (sw),
        .btn      (btn),
        .led      (led),
        .pan_pwm  (laser_pan_pwm),
        .tilt_pwm (laser_tilt_pwm)
    );

endmodule

`default_nettype wire
