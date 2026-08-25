// ---------------------------------------------------------------------------
// laser_interlock.v -- LED/Laser 공용 Fail-Closed 안전 인터록
//
//  공통 규격 v1.5 §17 조건:
//    target_valid, score threshold, Target Safe/Lock Zone,
//    PT#1 SAFE_LIMIT, PT#2 SAFE_LIMIT2, Emergency Stop 해제
//
//  추가 보수 조건:
//    system_arm, actuator_ready, PT#2 aim_ready, 연속 LOCK_CONFIRM_UPDATES,
//    Target Update watchdog, 연속 출력 시간 제한
//    Power-on 또는 E-stop 해제 후에는 Arm LOW를 한 번 관측해야 재무장 가능
//
//  laser_enable은 우선 LED에만 연결한다. 실제 레이저 전환 시에도 이 신호 뒤에
//  별도 물리 Arm/E-stop과 트랜지스터 구동단을 둔다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module laser_interlock #(
    parameter integer SCORE_THRESHOLD       = 0,

    parameter integer TARGET_SAFE_X_MIN      = 4,
    parameter integer TARGET_SAFE_X_MAX      = 60,
    parameter integer TARGET_SAFE_Y_MIN      = 4,
    parameter integer TARGET_SAFE_Y_MAX      = 60,
    parameter integer LOCK_ZONE_X            = 4,
    parameter integer LOCK_ZONE_Y            = 4,
    parameter integer CENTER_X               = 32,
    parameter integer CENTER_Y               = 32,

    parameter integer PAN1_POS_MIN           = 32,
    parameter integer PAN1_POS_MAX           = 224,
    parameter integer TILT1_POS_MIN          = 32,
    parameter integer TILT1_POS_MAX          = 224,
    parameter integer PAN2_POS_MIN           = 32,
    parameter integer PAN2_POS_MAX           = 224,
    parameter integer TILT2_POS_MIN          = 32,
    parameter integer TILT2_POS_MAX          = 224,

    parameter integer LOCK_CONFIRM_UPDATES   = 3,
    parameter integer TARGET_TIMEOUT_FRAMES  = 3,
    // 0이면 연속 출력 시간 제한을 끈다. 기본 25 frame = 500 ms @ 50 Hz.
    parameter integer MAX_ON_FRAMES          = 25
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    frame_tick,
    input  wire                    target_update,

    input  wire                    system_arm,
    input  wire                    actuator_ready,
    input  wire                    emergency_stop,
    input  wire                    target_valid,
    input  wire [5:0]              target_x,
    input  wire [5:0]              target_y,
    input  wire signed [7:0]       target_score,

    input  wire [7:0]              camera_pan_pos,
    input  wire [7:0]              camera_tilt_pos,
    input  wire [7:0]              laser_pan_pos,
    input  wire [7:0]              laser_tilt_pos,
    input  wire                    aim_ready,

    output reg                     laser_enable,
    output wire                    lock_qualified,
    output reg                     target_fresh,
    output reg                     timeout_fault,
    output wire                    rearm_required
);

    localparam integer CONFIRM_W = (LOCK_CONFIRM_UPDATES <= 1) ? 1 :
                                   $clog2(LOCK_CONFIRM_UPDATES + 1);
    localparam integer AGE_W = (TARGET_TIMEOUT_FRAMES <= 1) ? 1 :
                               $clog2(TARGET_TIMEOUT_FRAMES + 1);
    localparam integer ON_W = (MAX_ON_FRAMES <= 1) ? 1 :
                              $clog2(MAX_ON_FRAMES + 1);
    localparam signed [7:0] SCORE_TH_S = SCORE_THRESHOLD;
    localparam signed [6:0] CENTER_X_S = CENTER_X;
    localparam signed [6:0] CENTER_Y_S = CENTER_Y;

    reg [CONFIRM_W-1:0] confirm_count;
    reg [AGE_W-1:0]     target_age;
    reg [ON_W-1:0]      on_count;
    reg                  arm_seen_low;
    reg                  estop_latched;

    initial begin
        if (SCORE_THRESHOLD < -128 || SCORE_THRESHOLD > 127)
            $error("laser_interlock: SCORE_THRESHOLD 는 signed INT8 범위여야 함");
        if (CENTER_X < 0 || CENTER_X > 63 || CENTER_Y < 0 || CENTER_Y > 63)
            $error("laser_interlock: CENTER 좌표가 0~63 밖임");
        if (LOCK_ZONE_X < 4 || LOCK_ZONE_Y < 4)
            $error("laser_interlock: LOCK_ZONE은 양자화 오차 때문에 최소 +/-4");
        if (TARGET_SAFE_X_MIN > TARGET_SAFE_X_MAX ||
            TARGET_SAFE_Y_MIN > TARGET_SAFE_Y_MAX)
            $error("laser_interlock: Target Safe Zone MIN > MAX");
        if (PAN1_POS_MIN > PAN1_POS_MAX || TILT1_POS_MIN > TILT1_POS_MAX ||
            PAN2_POS_MIN > PAN2_POS_MAX || TILT2_POS_MIN > TILT2_POS_MAX)
            $error("laser_interlock: Servo Safe Limit MIN > MAX");
        if (LOCK_CONFIRM_UPDATES < 1 || TARGET_TIMEOUT_FRAMES < 1 ||
            MAX_ON_FRAMES < 0)
            $error("laser_interlock: confirm/watchdog/max-on parameter 오류");
    end

    wire signed [6:0] error_x = $signed({1'b0, target_x}) - CENTER_X_S;
    wire signed [6:0] error_y = $signed({1'b0, target_y}) - CENTER_Y_S;
    wire        [6:0] abs_x = error_x[6] ? (~error_x + 7'd1) : error_x;
    wire        [6:0] abs_y = error_y[6] ? (~error_y + 7'd1) : error_y;

    wire score_ok = ($signed(target_score) >= SCORE_TH_S);
    wire target_safe = (target_x >= TARGET_SAFE_X_MIN) &&
                       (target_x <= TARGET_SAFE_X_MAX) &&
                       (target_y >= TARGET_SAFE_Y_MIN) &&
                       (target_y <= TARGET_SAFE_Y_MAX);
    wire target_locked = (abs_x <= LOCK_ZONE_X) && (abs_y <= LOCK_ZONE_Y);

    wire pt1_safe = (camera_pan_pos  >= PAN1_POS_MIN) &&
                    (camera_pan_pos  <= PAN1_POS_MAX) &&
                    (camera_tilt_pos >= TILT1_POS_MIN) &&
                    (camera_tilt_pos <= TILT1_POS_MAX);
    wire pt2_safe = (laser_pan_pos  >= PAN2_POS_MIN) &&
                    (laser_pan_pos  <= PAN2_POS_MAX) &&
                    (laser_tilt_pos >= TILT2_POS_MIN) &&
                    (laser_tilt_pos <= TILT2_POS_MAX);

    // 첫 유효 Update도 확인 횟수에 포함한다.
    wire fresh_for_check = target_fresh || target_update;
    // Power-on 시 Arm이 이미 HIGH여도 자동 점등하지 않는다. Arm LOW를 최소 한
    // clock 관측해야 arm_seen_low가 서고, E-stop도 Arm LOW에서만 해제된다.
    assign rearm_required = !arm_seen_low || estop_latched || timeout_fault;

    wire qualification_inputs_ok = system_arm && actuator_ready &&
                                   arm_seen_low && !estop_latched &&
                                   !emergency_stop &&
                                   target_valid && score_ok && target_safe &&
                                   pt1_safe && pt2_safe && target_locked &&
                                   aim_ready && fresh_for_check;

    wire watchdog_expires = frame_tick && !target_update && target_fresh &&
                            (target_age >= TARGET_TIMEOUT_FRAMES - 1);
    wire max_on_expires = (MAX_ON_FRAMES != 0) && laser_enable && frame_tick &&
                          (on_count >= MAX_ON_FRAMES - 1);

    assign lock_qualified = qualification_inputs_ok &&
                            !watchdog_expires && !timeout_fault;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            laser_enable <= 1'b0;
            target_fresh <= 1'b0;
            timeout_fault <= 1'b0;
            confirm_count <= {CONFIRM_W{1'b0}};
            target_age <= {AGE_W{1'b0}};
            on_count <= {ON_W{1'b0}};
            arm_seen_low <= 1'b0;
            estop_latched <= 1'b0;
        end else begin
            // 레이저 Arm 자체가 LOW였던 이력이 있어야 Power-on 재무장이 가능하다.
            if (!system_arm)
                arm_seen_low <= 1'b1;

            // E-stop은 해제만으로 복귀하지 않는다. E-stop을 놓은 뒤에도 Arm을
            // 명시적으로 LOW로 내려야 latch가 풀린다.
            if (emergency_stop)
                estop_latched <= 1'b1;
            else if (!system_arm)
                estop_latched <= 1'b0;

            // NPU 결과 freshness watchdog
            if (target_update) begin
                target_fresh <= target_valid;
                target_age <= {AGE_W{1'b0}};
            end else if (frame_tick && target_fresh) begin
                if (watchdog_expires) begin
                    target_fresh <= 1'b0;
                    target_age <= {AGE_W{1'b0}};
                end else begin
                    target_age <= target_age + 1'b1;
                end
            end

            // 연속 출력 시간 초과도 Arm LOW 전까지 유지해 자동 재점등을 막는다.
            if (!system_arm) begin
                timeout_fault <= 1'b0;
            end else if (max_on_expires) begin
                timeout_fault <= 1'b1;
            end

            // 하나라도 어긋나면 Fail-Closed. Emergency Stop도 1 clock 내 차단한다.
            if (!qualification_inputs_ok || watchdog_expires || timeout_fault ||
                max_on_expires) begin
                laser_enable <= 1'b0;
                confirm_count <= {CONFIRM_W{1'b0}};
                on_count <= {ON_W{1'b0}};
            end else begin
                if (target_update && !laser_enable) begin
                    if (confirm_count >= LOCK_CONFIRM_UPDATES - 1) begin
                        laser_enable <= 1'b1;
                        confirm_count <= confirm_count;
                    end else begin
                        confirm_count <= confirm_count + 1'b1;
                    end
                end

                if (laser_enable && frame_tick && (MAX_ON_FRAMES != 0))
                    on_count <= on_count + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
