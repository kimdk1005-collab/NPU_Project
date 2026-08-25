// ---------------------------------------------------------------------------
// ky008_laser_board_io.v -- KY-008 실제 광원 사전 브링업 전용 Top
//
//  KY-008 사양(구매처): S=+5 V supply, middle=NC, -=GND, 650 nm, 30 mA.
//  laser_gate_cmd는 광원 전원선이 아니다. JD7/U14의 3.3 V 논리 출력이며,
//  반드시 default-OFF High-side load switch의 Enable만 구동한다.
//
//  외부 필수 경로:
//    5 V -> fuse/current limit -> Key Arm -> NC E-stop -> load switch -> KY-008 S
//    JD7 laser_gate_cmd ---------------------------> load switch Enable
//
//  Bring-up 제한:
//    - PT#1/PT#2 Servo pos 112~144
//    - MAX_ON_FRAMES 1~5만 허용 (기본 5 = 100 ms @ 50 Hz)
//    - sw[1] Arm은 Power-on/E-stop 뒤 반드시 LOW->HIGH cycle
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module ky008_laser_board_io #(
    parameter integer CLK_HZ                = 100_000_000,
    parameter integer USE_CLK_CONVERTER     = 1,
    parameter integer PWM_HZ                = 50,
    parameter integer PULSE_MIN_US          = 500,
    parameter integer PULSE_MAX_US          = 2500,
    parameter integer POS_SAFE_LO           = 112,
    parameter integer POS_SAFE_HI           = 144,
    parameter integer POS_NEUTRAL           = 128,
    parameter integer TARGET_STEP           = 8,
    parameter integer TARGET_MIN            = 8,
    parameter integer TARGET_MAX            = 56,
    parameter integer CAMERA_PAN_INVERT     = 0,
    parameter integer CAMERA_TILT_INVERT    = 0,
    parameter integer LASER_PAN_INVERT      = 0,
    parameter integer LASER_TILT_INVERT     = 0,
    parameter integer MAX_ON_FRAMES         = 5
)(
    input  wire       sysclk,
    input  wire [3:0] sw,
    input  wire [3:0] btn,
    output wire [3:0] led,
    output wire       camera_pan_pwm,
    output wire       camera_tilt_pwm,
    output wire       laser_pan_pwm,
    output wire       laser_tilt_pwm,
    output wire       laser_gate_cmd
);

    initial begin
        if (MAX_ON_FRAMES < 1 || MAX_ON_FRAMES > 5)
            $error("ky008_laser_board_io: MAX_ON_FRAMES는 bring-up에서 1~5만 허용");
        if (POS_SAFE_LO < 0 || POS_SAFE_HI > 255 ||
            POS_SAFE_LO > POS_NEUTRAL || POS_SAFE_HI < POS_NEUTRAL)
            $error("ky008_laser_board_io: narrow Servo safe range 오류");
    end

    dual_head_board_io #(
        .CLK_HZ             (CLK_HZ),
        .USE_CLK_CONVERTER  (USE_CLK_CONVERTER),
        .PWM_HZ             (PWM_HZ),
        .PULSE_MIN_US       (PULSE_MIN_US),
        .PULSE_MAX_US       (PULSE_MAX_US),
        .POS_SAFE_LO        (POS_SAFE_LO),
        .POS_SAFE_HI        (POS_SAFE_HI),
        .POS_NEUTRAL        (POS_NEUTRAL),
        .TARGET_STEP        (TARGET_STEP),
        .TARGET_MIN         (TARGET_MIN),
        .TARGET_MAX         (TARGET_MAX),
        .CAMERA_PAN_INVERT  (CAMERA_PAN_INVERT),
        .CAMERA_TILT_INVERT (CAMERA_TILT_INVERT),
        .LASER_PAN_INVERT   (LASER_PAN_INVERT),
        .LASER_TILT_INVERT  (LASER_TILT_INVERT),
        .MAX_ON_FRAMES      (MAX_ON_FRAMES)
    ) u_board (
        .sysclk          (sysclk),
        .sw              (sw),
        .btn             (btn),
        .led             (led),
        .camera_pan_pwm  (camera_pan_pwm),
        .camera_tilt_pwm (camera_tilt_pwm),
        .laser_pan_pwm   (laser_pan_pwm),
        .laser_tilt_pwm  (laser_tilt_pwm),
        .laser_red       (laser_gate_cmd)
    );

endmodule

`default_nettype wire
