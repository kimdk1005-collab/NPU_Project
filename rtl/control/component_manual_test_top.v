// ---------------------------------------------------------------------------
// component_manual_test_top.v -- Zybo Z7-20 연결 부품 수동 점검 Top
//
//  실제 보드에는 SW0~SW3과 BTN0~BTN3만 있다. 두 조합 입력을 논리 버튼으로
//  정의해 총 여섯 가지 버튼 동작을 제공한다.
//
//    SW0       : 네 Servo PWM Enable
//    SW1       : Laser Arm (LOW에서 위치 조정, LOW->HIGH 뒤 발광 가능)
//    SW3:SW2   : 00 Camera PAN(JD1), 01 Camera TILT(JD2),
//                10 Laser PAN(JD3),  11 Laser TILT(JD4)
//    BTN0      : 선택 축 -8
//    BTN1      : 선택 축 +8
//    BTN2      : 선택 축 Neutral
//    BTN3      : 누르는 동안 Laser 요청, 떼면 즉시 OFF
//    BTN4(논리): BTN0+BTN1, 네 축 모두 Neutral
//    BTN5(논리): BTN2+BTN3, 논리 E-stop(Servo PWM/Laser 즉시 OFF)
//
//  안전 제한:
//    - Servo 위치는 112~144로 고정한다.
//    - SW1=HIGH 동안 위치 명령을 받지 않는다.
//    - Laser는 네 축 Neutral, Servo Enable, 명시적 Arm/Trigger일 때만 켜진다.
//    - Laser Gate는 누르는 동안 유지되지만 최대 50 frame = 약 1 s로 제한한다.
//      1 s timeout 뒤 재발광에는 SW1 LOW->HIGH가 필요하다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module component_manual_test_top #(
    parameter integer CLK_HZ            = 100_000_000,
    parameter integer USE_CLK_CONVERTER = 1,
    parameter integer PWM_HZ            = 50,
    parameter integer PULSE_MIN_US      = 500,
    parameter integer PULSE_MAX_US      = 2500,
    parameter integer POS_SAFE_LO       = 112,
    parameter integer POS_SAFE_HI       = 144,
    parameter integer POS_NEUTRAL       = 128,
    parameter integer POS_STEP          = 8,
    parameter integer MAX_ON_FRAMES     = 50
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
        if (POS_SAFE_LO < 0 || POS_SAFE_HI > 255 ||
            POS_SAFE_LO > POS_NEUTRAL || POS_SAFE_HI < POS_NEUTRAL)
            $error("component_manual_test_top: Servo safe range 오류");
        if (POS_STEP < 1 || POS_STEP > (POS_SAFE_HI - POS_SAFE_LO))
            $error("component_manual_test_top: POS_STEP 오류");
        if (MAX_ON_FRAMES < 1 || MAX_ON_FRAMES > 50)
            $error("component_manual_test_top: MAX_ON_FRAMES는 1~50만 허용");
    end

    wire control_clk;
    wire clock_locked;

    generate
        if (USE_CLK_CONVERTER != 0) begin : g_board_clock
            clock_125_to_100 u_board_clock (
                .clk_125(sysclk),
                .clk_100(control_clk),
                .locked(clock_locked)
            );
        end else begin : g_direct_clock
            assign control_clk = sysclk;
            assign clock_locked = 1'b1;
        end
    endgenerate

    // Power-on reset
    reg [7:0] por_cnt = 8'd0;
    reg       por_n   = 1'b0;

    always @(posedge control_clk) begin
        if (!clock_locked) begin
            por_cnt <= 8'd0;
            por_n <= 1'b0;
        end else if (por_cnt != 8'hFF) begin
            por_cnt <= por_cnt + 1'b1;
            por_n <= 1'b0;
        end else begin
            por_n <= 1'b1;
        end
    end

    wire rst_n = por_n;

    // 비동기 Switch/Button 2단 동기화
    reg [3:0] sw_meta  = 4'b0000;
    reg [3:0] sw_sync  = 4'b0000;
    reg [3:0] btn_meta = 4'b0000;
    reg [3:0] btn_sync = 4'b0000;

    always @(posedge control_clk) begin
        sw_meta  <= sw;
        sw_sync  <= sw_meta;
        btn_meta <= btn;
        btn_sync <= btn_meta;
    end

    wire       servo_enable_i  = sw_sync[0];
    wire       laser_arm_i     = sw_sync[1];
    wire [1:0] selected_axis_i = sw_sync[3:2];
    wire       virtual_btn4    = btn_sync[0] && btn_sync[1];
    wire       virtual_btn5    = btn_sync[2] && btn_sync[3];
    wire       emergency_stop_i = virtual_btn5;
    wire       servo_output_en  = servo_enable_i && !emergency_stop_i;

    // 네 축 독립 수동 위치. 좁은 112~144 범위 밖으로 나가지 않는다.
    reg [7:0] camera_pan_pos  = POS_NEUTRAL[7:0];
    reg [7:0] camera_tilt_pos = POS_NEUTRAL[7:0];
    reg [7:0] laser_pan_pos   = POS_NEUTRAL[7:0];
    reg [7:0] laser_tilt_pos  = POS_NEUTRAL[7:0];

    function [7:0] step_down;
        input [7:0] value;
        begin
            step_down = (value <= POS_SAFE_LO + POS_STEP) ?
                        POS_SAFE_LO[7:0] : value - POS_STEP[7:0];
        end
    endfunction

    function [7:0] step_up;
        input [7:0] value;
        begin
            step_up = (value >= POS_SAFE_HI - POS_STEP) ?
                      POS_SAFE_HI[7:0] : value + POS_STEP[7:0];
        end
    endfunction

    wire frame_tick;
    wire camera_tilt_tick;
    wire laser_pan_tick;
    wire laser_tilt_tick;

    servo_pwm #(
        .CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
        .PULSE_MIN_US(PULSE_MIN_US), .PULSE_MAX_US(PULSE_MAX_US),
        .POS_MIN(POS_SAFE_LO), .POS_MAX(POS_SAFE_HI)
    ) u_camera_pan_pwm (
        .clk(control_clk), .rst_n(rst_n), .en(servo_output_en),
        .pos(camera_pan_pos), .pwm_out(camera_pan_pwm), .frame_tick(frame_tick)
    );

    servo_pwm #(
        .CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
        .PULSE_MIN_US(PULSE_MIN_US), .PULSE_MAX_US(PULSE_MAX_US),
        .POS_MIN(POS_SAFE_LO), .POS_MAX(POS_SAFE_HI)
    ) u_camera_tilt_pwm (
        .clk(control_clk), .rst_n(rst_n), .en(servo_output_en),
        .pos(camera_tilt_pos), .pwm_out(camera_tilt_pwm), .frame_tick(camera_tilt_tick)
    );

    servo_pwm #(
        .CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
        .PULSE_MIN_US(PULSE_MIN_US), .PULSE_MAX_US(PULSE_MAX_US),
        .POS_MIN(POS_SAFE_LO), .POS_MAX(POS_SAFE_HI)
    ) u_laser_pan_pwm (
        .clk(control_clk), .rst_n(rst_n), .en(servo_output_en),
        .pos(laser_pan_pos), .pwm_out(laser_pan_pwm), .frame_tick(laser_pan_tick)
    );

    servo_pwm #(
        .CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
        .PULSE_MIN_US(PULSE_MIN_US), .PULSE_MAX_US(PULSE_MAX_US),
        .POS_MIN(POS_SAFE_LO), .POS_MAX(POS_SAFE_HI)
    ) u_laser_tilt_pwm (
        .clk(control_clk), .rst_n(rst_n), .en(servo_output_en),
        .pos(laser_tilt_pos), .pwm_out(laser_tilt_pwm), .frame_tick(laser_tilt_tick)
    );

    // Frame 단위 버튼 edge. 조합 버튼은 단일 버튼보다 우선한다.
    reg [3:0] btn_fr   = 4'b0000;
    reg [3:0] btn_fr_d = 4'b0000;
    wire [3:0] btn_rise = btn_fr & ~btn_fr_d;

    always @(posedge control_clk or negedge rst_n) begin
        if (!rst_n) begin
            btn_fr <= 4'b0000;
            btn_fr_d <= 4'b0000;
            camera_pan_pos <= POS_NEUTRAL[7:0];
            camera_tilt_pos <= POS_NEUTRAL[7:0];
            laser_pan_pos <= POS_NEUTRAL[7:0];
            laser_tilt_pos <= POS_NEUTRAL[7:0];
        end else if (frame_tick) begin
            btn_fr <= btn_sync;
            btn_fr_d <= btn_fr;

            // Arm 중에는 어떤 위치 명령도 받지 않는다.
            if (!laser_arm_i && !emergency_stop_i) begin
                if (&btn_fr[1:0]) begin
                    camera_pan_pos <= POS_NEUTRAL[7:0];
                    camera_tilt_pos <= POS_NEUTRAL[7:0];
                    laser_pan_pos <= POS_NEUTRAL[7:0];
                    laser_tilt_pos <= POS_NEUTRAL[7:0];
                end else if (btn_rise[2] && !btn_fr[3]) begin
                    case (selected_axis_i)
                        2'b00: camera_pan_pos <= POS_NEUTRAL[7:0];
                        2'b01: camera_tilt_pos <= POS_NEUTRAL[7:0];
                        2'b10: laser_pan_pos <= POS_NEUTRAL[7:0];
                        2'b11: laser_tilt_pos <= POS_NEUTRAL[7:0];
                    endcase
                end else if (btn_rise[0] && !btn_fr[1]) begin
                    case (selected_axis_i)
                        2'b00: camera_pan_pos <= step_down(camera_pan_pos);
                        2'b01: camera_tilt_pos <= step_down(camera_tilt_pos);
                        2'b10: laser_pan_pos <= step_down(laser_pan_pos);
                        2'b11: laser_tilt_pos <= step_down(laser_tilt_pos);
                    endcase
                end else if (btn_rise[1] && !btn_fr[0]) begin
                    case (selected_axis_i)
                        2'b00: camera_pan_pos <= step_up(camera_pan_pos);
                        2'b01: camera_tilt_pos <= step_up(camera_tilt_pos);
                        2'b10: laser_pan_pos <= step_up(laser_pan_pos);
                        2'b11: laser_tilt_pos <= step_up(laser_tilt_pos);
                    endcase
                end
            end
        end
    end

    wire all_neutral = (camera_pan_pos  == POS_NEUTRAL[7:0]) &&
                       (camera_tilt_pos == POS_NEUTRAL[7:0]) &&
                       (laser_pan_pos   == POS_NEUTRAL[7:0]) &&
                       (laser_tilt_pos  == POS_NEUTRAL[7:0]);

    // Hold-to-fire: BTN3을 누르는 동안만 요청을 유지한다. BTN2와 함께 누르면
    // virtual BTN5 E-stop이므로 요청보다 차단이 우선한다.
    wire fire_active = btn_sync[3] && !btn_sync[2];

    wire laser_enable_safe;
    wire laser_lock_qualified;
    wire laser_target_fresh;
    wire laser_timeout_fault;
    wire laser_rearm_required;

    laser_interlock #(
        .SCORE_THRESHOLD(0),
        .PAN1_POS_MIN(POS_SAFE_LO), .PAN1_POS_MAX(POS_SAFE_HI),
        .TILT1_POS_MIN(POS_SAFE_LO), .TILT1_POS_MAX(POS_SAFE_HI),
        .PAN2_POS_MIN(POS_SAFE_LO), .PAN2_POS_MAX(POS_SAFE_HI),
        .TILT2_POS_MIN(POS_SAFE_LO), .TILT2_POS_MAX(POS_SAFE_HI),
        .LOCK_CONFIRM_UPDATES(3), .TARGET_TIMEOUT_FRAMES(3),
        .MAX_ON_FRAMES(MAX_ON_FRAMES)
    ) u_laser_interlock (
        .clk(control_clk), .rst_n(rst_n),
        .frame_tick(frame_tick),
        .target_update(frame_tick && fire_active),
        .system_arm(laser_arm_i),
        .actuator_ready(servo_output_en),
        .emergency_stop(emergency_stop_i),
        .target_valid(fire_active),
        .target_x(6'd32), .target_y(6'd32), .target_score(8'sd127),
        .camera_pan_pos(camera_pan_pos), .camera_tilt_pos(camera_tilt_pos),
        .laser_pan_pos(laser_pan_pos), .laser_tilt_pos(laser_tilt_pos),
        .aim_ready(all_neutral),
        .laser_enable(laser_enable_safe),
        .lock_qualified(laser_lock_qualified),
        .target_fresh(laser_target_fresh),
        .timeout_fault(laser_timeout_fault),
        .rearm_required(laser_rearm_required)
    );

    assign laser_gate_cmd = laser_enable_safe;

    // LED0 heartbeat / LED1 Servo PWM / LED2 Laser Ready / LED3 Laser Gate
    localparam integer HB_DIV = (PWM_HZ < 2) ? 1 : PWM_HZ / 2;
    localparam integer HB_W = (HB_DIV <= 1) ? 1 : $clog2(HB_DIV);
    reg [HB_W-1:0] hb_cnt = {HB_W{1'b0}};
    reg hb = 1'b0;

    always @(posedge control_clk or negedge rst_n) begin
        if (!rst_n) begin
            hb_cnt <= {HB_W{1'b0}};
            hb <= 1'b0;
        end else if (frame_tick) begin
            if (hb_cnt == HB_DIV - 1) begin
                hb_cnt <= {HB_W{1'b0}};
                hb <= ~hb;
            end else begin
                hb_cnt <= hb_cnt + 1'b1;
            end
        end
    end

    assign led[0] = hb;
    assign led[1] = servo_output_en;
    assign led[2] = laser_arm_i && !laser_rearm_required &&
                    all_neutral && servo_output_en;
    assign led[3] = laser_enable_safe;

endmodule

`default_nettype wire
