// ---------------------------------------------------------------------------
// dual_head_board_io.v -- Zybo Z7-20 4-Servo + RED LED 최종 구동 테스트 Top
//
//  NPU 없이 보드 버튼으로 가상 Target 좌표를 움직여 다음 경로를 실물 검증한다.
//    Camera PT#1  : JD1 PAN / JD2 TILT
//    Laser PT#2   : JD3 PAN / JD4 TILT
//    RED LED 모듈 : JD7, laser_enable_safe가 1일 때만 점등
//
//  조작
//    sw[0] Servo Enable
//    sw[1] RED LED Arm
//    sw[2] Target Valid
//    sw[3] Emergency Stop (1=즉시 RED OFF)
//
//    btn[0] Target X-     btn[1] Target X+
//    btn[2] Target Y-     btn[3] Target Y+
//    btn[0]+btn[1] X=32   btn[2]+btn[3] Y=32
//
//  안전 정책
//    - Servo 출력 위치는 기본 112~144의 좁은 범위로 제한한다.
//    - 실제 Laser 광원 출력은 없다. JD7에는 저항 내장 RED LED 모듈만 연결한다.
//    - RED는 dual_head_control의 Fail-Closed Interlock 출력을 그대로 사용한다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module dual_head_board_io #(
    parameter integer CLK_HZ                = 100_000_000,
    parameter integer USE_CLK_CONVERTER      = 1,
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
    parameter integer MAX_ON_FRAMES         = 25
)(
    input  wire       sysclk,
    input  wire [3:0] sw,
    input  wire [3:0] btn,
    output wire [3:0] led,
    output wire       camera_pan_pwm,
    output wire       camera_tilt_pwm,
    output wire       laser_pan_pwm,
    output wire       laser_tilt_pwm,
    output wire       laser_red
);

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
            // Testbench용: 입력 clock을 그대로 사용한다.
            assign control_clk = sysclk;
            assign clock_locked = 1'b1;
        end
    endgenerate

    initial begin
        if (TARGET_STEP < 1 || TARGET_STEP > 31)
            $error("dual_head_board_io: TARGET_STEP은 1~31 이어야 함");
        if (TARGET_MIN < 4 || TARGET_MAX > 60 || TARGET_MIN >= TARGET_MAX)
            $error("dual_head_board_io: Target 범위는 Interlock Safe Zone 안이어야 함");
        if (POS_SAFE_LO > POS_NEUTRAL || POS_SAFE_HI < POS_NEUTRAL)
            $error("dual_head_board_io: POS_NEUTRAL이 좁은 안전 범위 밖임");
    end

    // Power-On Reset. 버튼 네 개는 Target 조작에 모두 사용하므로 별도 Reset 버튼은 없다.
    reg [7:0] por_cnt = 8'd0;
    reg       por_n   = 1'b0;

    always @(posedge control_clk) begin
        if (!clock_locked) begin
            por_cnt <= 8'd0;
            por_n <= 1'b0;
        end else if (por_cnt != 8'hFF) begin
            por_cnt <= por_cnt + 1'b1;
            por_n   <= 1'b0;
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

    wire servo_enable_i  = sw_sync[0];
    wire laser_arm_i     = sw_sync[1];
    wire target_valid_i  = sw_sync[2];
    wire emergency_stop_i = sw_sync[3];

    wire frame_tick;
    wire laser_enable_safe;
    wire laser_aim_ready;
    wire laser_lock_qualified;
    wire laser_target_fresh;
    wire laser_timeout_fault;
    wire laser_rearm_required;
    wire [7:0] camera_pan_pos;
    wire [7:0] camera_tilt_pos;
    wire [7:0] laser_pan_pos;
    wire [7:0] laser_tilt_pos;
    wire [7:0] laser_pan_target;
    wire [7:0] laser_tilt_target;

    // Frame 단위 Button edge. 길게 눌러도 한 번만 8 pixel 이동한다.
    reg [3:0] btn_fr   = 4'b0000;
    reg [3:0] btn_fr_d = 4'b0000;
    wire [3:0] btn_rise = btn_fr & ~btn_fr_d;

    reg [5:0] target_x = 6'd32;
    reg [5:0] target_y = 6'd32;

    always @(posedge control_clk or negedge rst_n) begin
        if (!rst_n) begin
            btn_fr   <= 4'b0000;
            btn_fr_d <= 4'b0000;
            target_x <= 6'd32;
            target_y <= 6'd32;
        end else if (frame_tick) begin
            btn_fr   <= btn_sync;
            btn_fr_d <= btn_fr;

            if (&btn_fr[1:0]) begin
                target_x <= 6'd32;
            end else if (btn_rise[0]) begin
                target_x <= (target_x <= TARGET_MIN + TARGET_STEP) ?
                            TARGET_MIN[5:0] : target_x - TARGET_STEP[5:0];
            end else if (btn_rise[1]) begin
                target_x <= (target_x >= TARGET_MAX - TARGET_STEP) ?
                            TARGET_MAX[5:0] : target_x + TARGET_STEP[5:0];
            end

            if (&btn_fr[3:2]) begin
                target_y <= 6'd32;
            end else if (btn_rise[2]) begin
                target_y <= (target_y <= TARGET_MIN + TARGET_STEP) ?
                            TARGET_MIN[5:0] : target_y - TARGET_STEP[5:0];
            end else if (btn_rise[3]) begin
                target_y <= (target_y >= TARGET_MAX - TARGET_STEP) ?
                            TARGET_MAX[5:0] : target_y + TARGET_STEP[5:0];
            end
        end
    end

    // 보드 테스트에서는 Target Valid 동안 매 Frame 새 NPU 결과가 온 것으로 자극한다.
    wire target_update = frame_tick && target_valid_i;

    dual_head_control #(
        .CLK_HZ              (CLK_HZ),
        .PWM_HZ              (PWM_HZ),
        .PULSE_MIN_US        (PULSE_MIN_US),
        .PULSE_MAX_US        (PULSE_MAX_US),
        .PAN1_POS_MIN        (POS_SAFE_LO),
        .PAN1_POS_MAX        (POS_SAFE_HI),
        .TILT1_POS_MIN       (POS_SAFE_LO),
        .TILT1_POS_MAX       (POS_SAFE_HI),
        .PAN2_POS_MIN        (POS_SAFE_LO),
        .PAN2_POS_MAX        (POS_SAFE_HI),
        .TILT2_POS_MIN       (POS_SAFE_LO),
        .TILT2_POS_MAX       (POS_SAFE_HI),
        .POS_NEUTRAL         (POS_NEUTRAL),
        .CAMERA_PAN_INVERT   (CAMERA_PAN_INVERT),
        .CAMERA_TILT_INVERT  (CAMERA_TILT_INVERT),
        .PAN_ERR_INVERT      (LASER_PAN_INVERT),
        .TILT_ERR_INVERT     (LASER_TILT_INVERT),
        .MAX_ON_FRAMES       (MAX_ON_FRAMES)
    ) u_dual_head (
        .clk                  (control_clk),
        .rst_n                (rst_n),
        .servo_enable         (servo_enable_i),
        .target_update        (target_update),
        .target_valid         (target_valid_i),
        .target_x             (target_x),
        .target_y             (target_y),
        .target_score         (8'sd127),
        .laser_arm            (laser_arm_i),
        .emergency_stop       (emergency_stop_i),
        .manual_override      (1'b0),
        .manual_aim_ready     (1'b0),
        .manual_camera_pan_pos(8'd0),
        .manual_camera_tilt_pos(8'd0),
        .manual_laser_pan_pos (8'd0),
        .manual_laser_tilt_pos(8'd0),
        .runtime_limits_en    (1'b0),
        .runtime_pan1_min     (8'd0), .runtime_pan1_max(8'd0),
        .runtime_tilt1_min    (8'd0), .runtime_tilt1_max(8'd0),
        .runtime_pan2_min     (8'd0), .runtime_pan2_max(8'd0),
        .runtime_tilt2_min    (8'd0), .runtime_tilt2_max(8'd0),
        .runtime_cal_en       (1'b0),
        .runtime_pan_offset_pos (16'sd0),
        .runtime_tilt_offset_pos(16'sd0),
        .camera_pan_pwm       (camera_pan_pwm),
        .camera_tilt_pwm      (camera_tilt_pwm),
        .laser_pan_pwm        (laser_pan_pwm),
        .laser_tilt_pwm       (laser_tilt_pwm),
        .laser_led            (laser_red),
        .laser_enable_safe    (laser_enable_safe),
        .frame_tick           (frame_tick),
        .camera_pan_pos       (camera_pan_pos),
        .camera_tilt_pos      (camera_tilt_pos),
        .laser_pan_pos        (laser_pan_pos),
        .laser_tilt_pos       (laser_tilt_pos),
        .laser_pan_target     (laser_pan_target),
        .laser_tilt_target    (laser_tilt_target),
        .laser_aim_ready      (laser_aim_ready),
        .laser_lock_qualified (laser_lock_qualified),
        .laser_target_fresh   (laser_target_fresh),
        .laser_timeout_fault  (laser_timeout_fault),
        .laser_rearm_required (laser_rearm_required),
        .runtime_limits_active(),
        .runtime_limit_fault  ()
    );

    // 1 Hz heartbeat: 50 Hz frame_tick 25회마다 toggle
    localparam integer HB_DIV = PWM_HZ / 2;
    reg [5:0] hb_cnt = 6'd0;
    reg       hb = 1'b0;

    always @(posedge control_clk or negedge rst_n) begin
        if (!rst_n) begin
            hb_cnt <= 6'd0;
            hb <= 1'b0;
        end else if (frame_tick) begin
            if (hb_cnt == HB_DIV - 1) begin
                hb_cnt <= 6'd0;
                hb <= ~hb;
            end else begin
                hb_cnt <= hb_cnt + 1'b1;
            end
        end
    end

    // led[3]은 외부 RED와 같은 Interlock 결과다.
    assign led = {laser_enable_safe, target_valid_i, servo_enable_i, hb};

endmodule

`default_nettype wire
