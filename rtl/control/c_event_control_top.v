// ---------------------------------------------------------------------------
// c_event_control_top.v -- C Event/Tracking/2-Head Control integration wrapper
//
// A Phase 4 문서의 c_module_stub 포트 골격과 C의 검증 완료 RTL을 연결한다.
// PWM_W는 A stub named-parameter 교체 호환용이며 실제 PWM 폭은 CLK_HZ/PWM_HZ로 정한다.
// A 골격에 없던 실제 Event Source 입력과 tensor_start를 명시적으로 추가했다.
// tensor_start는 다음 두 통합 방식 중 하나에서만 사용한다.
//   1) Direct: tensor_start -> NPU start
//   2) PS-managed: INPUT_STAT.TENSOR_READY 폴링 -> PS가 CTRL.START 기록
// 두 방식을 동시에 활성화하면 중복 START가 되므로 A top에서 하나만 선택한다.
//
// AXI C 소유 Register bit 계약
//   EVENT_CFG(0x08)
//     bit0 EVENT_ENABLE, bit1 POLARITY_INVERT
//   LASER_CTRL(0x28)
//     bit0 SERVO_ENABLE, bit1 SW_LASER_ARM, bit2 SW_ESTOP
//     bit3 MANUAL_OVERRIDE, bit4 MANUAL_AIM_READY
//     bit8 RUNTIME_LIMIT_EN, bit9 RUNTIME_CAL_EN
//   PAN/TILT/PAN2/TILT2_CMD: [7:0] unsigned Servo pos (Manual Override)
//   SAFE_LIMIT / SAFE_LIMIT2:
//     [7:0] PAN_MIN, [15:8] PAN_MAX, [23:16] TILT_MIN, [31:24] TILT_MAX
//   LASER_CAL: [15:0] PAN offset, [31:16] TILT offset (signed Servo pos step)
//
// INPUT_STAT(0x0C)
//   [0] ACC_READY, [1] TENSOR_READY(sticky until NPU busy), [2] OVERRUN
//   [3] EVENT_ENABLE, [4] NPU_BUSY, [5] TARGET_VALID
//   [6] LASER_LOCK, [7] LASER_TIMEOUT
//   [19:8] last accepted event count (12-bit saturation)
//   [31:20] last dropped event count (12-bit saturation)
//
// A가 0x58 이후에 RO 상태 Register를 추가할 때:
//   0x58 SERVO_POS_STAT <- servo_pos_stat
//   0x5C CONTROL_STAT   <- control_stat
//     [0] LASER_EN, [1] LASER_LOCK, [2] TARGET_FRESH, [3] LASER_TIMEOUT
//     [4] AIM_READY, [5] MANUAL_OVERRIDE, [6] LIMIT_ACTIVE, [7] LIMIT_FAULT
//     [8] SERVO_ENABLE, [9] HW_ARM, [10] SW_ARM, [11] EMERGENCY_STOP
//     [12] TENSOR_READY, [13] ACC_READY, [14] OVERRUN, [15] TARGET_VALID
//     [16] LASER_REARM_REQUIRED
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module c_event_control_top #(
    parameter integer PWM_W                 = 20,
    parameter integer CLK_HZ                 = 100_000_000,
    parameter integer SENSOR_W               = 640,
    parameter integer SENSOR_H               = 480,
    parameter integer SRC_COORD_W            = 11,
    parameter integer OOR_POLICY             = 0,
    parameter integer WINDOW_US              = 10_000,
    parameter integer WINDOW_SRC             = 0,
    parameter integer EVT_CNT_W              = 20,

    parameter integer PAN1_POS_MIN           = 32,
    parameter integer PAN1_POS_MAX           = 224,
    parameter integer TILT1_POS_MIN          = 32,
    parameter integer TILT1_POS_MAX          = 224,
    parameter integer PAN2_POS_MIN           = 32,
    parameter integer PAN2_POS_MAX           = 224,
    parameter integer TILT2_POS_MIN          = 32,
    parameter integer TILT2_POS_MAX          = 224,
    parameter integer POS_NEUTRAL            = 128,

    parameter integer PWM_HZ                 = 50,
    parameter integer PULSE_MIN_US           = 500,
    parameter integer PULSE_MAX_US           = 2500,
    parameter integer CAMERA_SLEW_LIMIT      = 1,
    parameter integer CAMERA_PAN_INVERT      = 0,
    parameter integer CAMERA_TILT_INVERT     = 0,
    parameter integer LASER_SLEW_LIMIT       = 2,
    parameter integer PAN_ERR_NUM            = 1,
    parameter integer PAN_ERR_DEN            = 1,
    parameter integer TILT_ERR_NUM           = 1,
    parameter integer TILT_ERR_DEN           = 1,
    parameter integer PAN_ERR_INVERT         = 0,
    parameter integer TILT_ERR_INVERT        = 0,
    parameter integer PAN_OFFSET_POS         = 0,
    parameter integer TILT_OFFSET_POS        = 0,
    parameter integer SCORE_THRESHOLD        = 0,
    parameter integer LOCK_CONFIRM_UPDATES   = 3,
    parameter integer TARGET_TIMEOUT_FRAMES  = 3,
    parameter integer MAX_ON_FRAMES          = 25
)(
    input  wire                         clk,
    input  wire                         rstn,

    // A AXI Register 출력 (0x08, 0x20~0x34, 0x48~0x54)
    input  wire [31:0]                  event_cfg,
    input  wire [31:0]                  pan_cmd,
    input  wire [31:0]                  tilt_cmd,
    input  wire [31:0]                  laser_ctrl,
    input  wire [31:0]                  safe_limit,
    input  wire [31:0]                  track_err_x,
    input  wire [31:0]                  track_err_y,
    input  wire [31:0]                  pan2_cmd,
    input  wire [31:0]                  tilt2_cmd,
    input  wire [31:0]                  safe_limit2,
    input  wire [31:0]                  laser_cal,

    // A NPU 결과
    input  wire                         npu_busy,
    input  wire                         npu_done,
    input  wire                         target_valid,
    input  wire [5:0]                   target_x,
    input  wire [5:0]                   target_y,
    input  wire signed [7:0]            target_score,

    // 실제 Event Source. A Phase 3 stub에는 없으므로 top_system에 추가해야 한다.
    input  wire                         src_valid,
    input  wire [SRC_COORD_W-1:0]       src_x,
    input  wire [SRC_COORD_W-1:0]       src_y,
    input  wire                         src_pol,
    input  wire                         src_window_end,

    // 물리 안전 입력. SW Arm과 HW Arm이 모두 1이어야 하며 E-stop은 OR 조건이다.
    input  wire                         laser_arm_hw,
    input  wire                         emergency_stop_hw,

    // C -> A NPU Input Buffer
    output wire                         evt_we,
    output wire [12:0]                  evt_addr,
    output wire signed [7:0]            evt_data,
    output wire                         tensor_start,
    output wire [31:0]                  input_stat,

    // A가 0x58/0x5C RO Register 또는 ILA에 연결할 상태
    output wire [31:0]                  servo_pos_stat,
    output wire [31:0]                  control_stat,

    // 외부 핀. bit 순서는 A Phase 3 stub와 동일하다.
    output wire [3:0]                   servo_pwm,
    output wire                         laser_en
);

    initial begin
        if (PWM_W < 1)
            $error("c_event_control_top: PWM_W compatibility parameter 오류");
    end

    wire event_enable = event_cfg[0];
    wire event_pol = src_pol ^ event_cfg[1];

    wire event_valid;
    wire [5:0] event_x;
    wire [5:0] event_y;
    wire event_polarity;
    wire event_window_end;
    wire [EVT_CNT_W-1:0] win_evt_count;
    wire [EVT_CNT_W-1:0] win_drop_count;

    event_adapter #(
        .SENSOR_W(SENSOR_W), .SENSOR_H(SENSOR_H),
        .SRC_COORD_W(SRC_COORD_W), .OOR_POLICY(OOR_POLICY),
        .CLK_HZ(CLK_HZ), .WINDOW_US(WINDOW_US), .WINDOW_SRC(WINDOW_SRC),
        .EVT_CNT_W(EVT_CNT_W)
    ) u_event_adapter (
        .clk(clk), .rst_n(rstn),
        .src_valid(src_valid && event_enable),
        .src_x(src_x), .src_y(src_y), .src_pol(event_pol),
        .src_window_end(src_window_end),
        .event_valid(event_valid), .event_x(event_x), .event_y(event_y),
        .event_polarity(event_polarity), .event_window_end(event_window_end),
        .win_evt_count(win_evt_count), .win_drop_count(win_drop_count)
    );

    wire acc_ready;
    wire overrun;

    event_accumulator u_event_accumulator (
        .clk(clk), .rst_n(rstn),
        .event_valid(event_valid && event_enable),
        .event_x(event_x), .event_y(event_y), .event_polarity(event_polarity),
        .event_window_end(event_window_end && event_enable),
        .npu_busy(npu_busy),
        .tensor_we(evt_we), .tensor_addr(evt_addr), .tensor_data(evt_data),
        .tensor_start(tensor_start), .acc_ready(acc_ready), .overrun(overrun)
    );

    // PS-managed START가 pulse를 놓치지 않도록 tensor_ready를 sticky로 만든다.
    // Direct START 연결 시에도 다음 cycle의 npu_busy가 동일하게 clear한다.
    reg tensor_ready;
    always @(posedge clk or negedge rstn) begin
        if (!rstn)              tensor_ready <= 1'b0;
        else if (npu_busy)      tensor_ready <= 1'b0;
        else if (tensor_start)  tensor_ready <= 1'b1;
    end

    wire camera_pan_pwm;
    wire camera_tilt_pwm;
    wire laser_pan_pwm;
    wire laser_tilt_pwm;
    wire frame_tick;
    wire [7:0] camera_pan_pos;
    wire [7:0] camera_tilt_pos;
    wire [7:0] laser_pan_pos;
    wire [7:0] laser_tilt_pos;
    wire [7:0] laser_pan_target;
    wire [7:0] laser_tilt_target;
    wire laser_aim_ready;
    wire laser_lock_qualified;
    wire laser_target_fresh;
    wire laser_timeout_fault;
    wire laser_rearm_required;
    wire runtime_limits_active;
    wire runtime_limit_fault;

    wire servo_enable = laser_ctrl[0];
    wire laser_arm = laser_arm_hw && laser_ctrl[1];
    wire emergency_stop = emergency_stop_hw || laser_ctrl[2];
    wire manual_override = laser_ctrl[3];
    wire manual_aim_ready = laser_ctrl[4];

    dual_head_control #(
        .CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
        .PULSE_MIN_US(PULSE_MIN_US), .PULSE_MAX_US(PULSE_MAX_US),
        .PAN1_POS_MIN(PAN1_POS_MIN), .PAN1_POS_MAX(PAN1_POS_MAX),
        .TILT1_POS_MIN(TILT1_POS_MIN), .TILT1_POS_MAX(TILT1_POS_MAX),
        .PAN2_POS_MIN(PAN2_POS_MIN), .PAN2_POS_MAX(PAN2_POS_MAX),
        .TILT2_POS_MIN(TILT2_POS_MIN), .TILT2_POS_MAX(TILT2_POS_MAX),
        .POS_NEUTRAL(POS_NEUTRAL),
        .CAMERA_SLEW_LIMIT(CAMERA_SLEW_LIMIT),
        .CAMERA_PAN_INVERT(CAMERA_PAN_INVERT),
        .CAMERA_TILT_INVERT(CAMERA_TILT_INVERT),
        .LASER_SLEW_LIMIT(LASER_SLEW_LIMIT),
        .PAN_ERR_NUM(PAN_ERR_NUM), .PAN_ERR_DEN(PAN_ERR_DEN),
        .TILT_ERR_NUM(TILT_ERR_NUM), .TILT_ERR_DEN(TILT_ERR_DEN),
        .PAN_ERR_INVERT(PAN_ERR_INVERT), .TILT_ERR_INVERT(TILT_ERR_INVERT),
        .PAN_OFFSET_POS(PAN_OFFSET_POS), .TILT_OFFSET_POS(TILT_OFFSET_POS),
        .SCORE_THRESHOLD(SCORE_THRESHOLD),
        .LOCK_CONFIRM_UPDATES(LOCK_CONFIRM_UPDATES),
        .TARGET_TIMEOUT_FRAMES(TARGET_TIMEOUT_FRAMES),
        .MAX_ON_FRAMES(MAX_ON_FRAMES)
    ) u_dual_head_control (
        .clk(clk), .rst_n(rstn), .servo_enable(servo_enable),
        .target_update(npu_done), .target_valid(target_valid),
        .target_x(target_x), .target_y(target_y), .target_score(target_score),
        .laser_arm(laser_arm), .emergency_stop(emergency_stop),
        .manual_override(manual_override), .manual_aim_ready(manual_aim_ready),
        .manual_camera_pan_pos(pan_cmd[7:0]),
        .manual_camera_tilt_pos(tilt_cmd[7:0]),
        .manual_laser_pan_pos(pan2_cmd[7:0]),
        .manual_laser_tilt_pos(tilt2_cmd[7:0]),
        .runtime_limits_en(laser_ctrl[8]),
        .runtime_pan1_min(safe_limit[7:0]), .runtime_pan1_max(safe_limit[15:8]),
        .runtime_tilt1_min(safe_limit[23:16]), .runtime_tilt1_max(safe_limit[31:24]),
        .runtime_pan2_min(safe_limit2[7:0]), .runtime_pan2_max(safe_limit2[15:8]),
        .runtime_tilt2_min(safe_limit2[23:16]), .runtime_tilt2_max(safe_limit2[31:24]),
        .runtime_cal_en(laser_ctrl[9]),
        .runtime_pan_offset_pos(laser_cal[15:0]),
        .runtime_tilt_offset_pos(laser_cal[31:16]),
        .camera_pan_pwm(camera_pan_pwm), .camera_tilt_pwm(camera_tilt_pwm),
        .laser_pan_pwm(laser_pan_pwm), .laser_tilt_pwm(laser_tilt_pwm),
        .laser_led(), .laser_enable_safe(laser_en), .frame_tick(frame_tick),
        .camera_pan_pos(camera_pan_pos), .camera_tilt_pos(camera_tilt_pos),
        .laser_pan_pos(laser_pan_pos), .laser_tilt_pos(laser_tilt_pos),
        .laser_pan_target(laser_pan_target), .laser_tilt_target(laser_tilt_target),
        .laser_aim_ready(laser_aim_ready),
        .laser_lock_qualified(laser_lock_qualified),
        .laser_target_fresh(laser_target_fresh),
        .laser_timeout_fault(laser_timeout_fault),
        .laser_rearm_required(laser_rearm_required),
        .runtime_limits_active(runtime_limits_active),
        .runtime_limit_fault(runtime_limit_fault)
    );

    assign servo_pwm = {laser_tilt_pwm, laser_pan_pwm,
                        camera_tilt_pwm, camera_pan_pwm};

    function [11:0] sat12;
        input [EVT_CNT_W-1:0] value;
        begin
            if (value > 12'hfff) sat12 = 12'hfff;
            else                 sat12 = value;
        end
    endfunction

    assign input_stat = {
        sat12(win_drop_count),
        sat12(win_evt_count),
        laser_timeout_fault,
        laser_lock_qualified,
        target_valid,
        npu_busy,
        event_enable,
        overrun,
        tensor_ready,
        acc_ready
    };

    assign servo_pos_stat = {
        laser_tilt_pos, laser_pan_pos, camera_tilt_pos, camera_pan_pos
    };

    assign control_stat = {
        15'd0,
        laser_rearm_required,
        target_valid,
        overrun,
        acc_ready,
        tensor_ready,
        emergency_stop,
        laser_ctrl[1],
        laser_arm_hw,
        servo_enable,
        runtime_limit_fault,
        runtime_limits_active,
        manual_override,
        laser_aim_ready,
        laser_timeout_fault,
        laser_target_fresh,
        laser_lock_qualified,
        laser_en
    };

    // 최신 A stub의 입력 포트 호환을 위해 유지한다. C는 하드웨어 Tracking을 쓰므로
    // TRACK_ERR_X/Y는 소비하지 않고 A가 0x58/0x5C RO 상태로 교체하는 안을 요청한다.
    wire unused_ok = &{1'b0, track_err_x, track_err_y, frame_tick,
                       laser_pan_target, laser_tilt_target};

endmodule

`default_nettype wire
