// ---------------------------------------------------------------------------
// tb_dual_head_control.v -- PT#1/PT#2 4 Servo PWM + LED Interlock 통합 검증
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_dual_head_control;

    localparam integer CLK_HZ = 1_000_000;
    localparam integer PWM_HZ = 50;
    localparam integer PERIOD_CYC = CLK_HZ / PWM_HZ;

    reg               clk = 1'b0;
    reg               rst_n = 1'b0;
    reg               servo_enable = 1'b0;
    reg               target_update = 1'b0;
    reg               target_valid = 1'b0;
    reg  [5:0]        target_x = 6'd32;
    reg  [5:0]        target_y = 6'd32;
    reg signed [7:0]  target_score = 8'sd10;
    reg               laser_arm = 1'b0;
    reg               emergency_stop = 1'b0;
    reg               manual_override = 1'b0;
    reg  [7:0]        manual_camera_pan_pos = 8'd0;
    reg  [7:0]        manual_camera_tilt_pos = 8'd0;
    reg  [7:0]        manual_laser_pan_pos = 8'd0;
    reg  [7:0]        manual_laser_tilt_pos = 8'd0;
    reg               runtime_limits_en = 1'b0;
    reg  [7:0]        runtime_pan1_min = 8'd0;
    reg  [7:0]        runtime_pan1_max = 8'd0;
    reg  [7:0]        runtime_tilt1_min = 8'd0;
    reg  [7:0]        runtime_tilt1_max = 8'd0;
    reg  [7:0]        runtime_pan2_min = 8'd0;
    reg  [7:0]        runtime_pan2_max = 8'd0;
    reg  [7:0]        runtime_tilt2_min = 8'd0;
    reg  [7:0]        runtime_tilt2_max = 8'd0;

    wire camera_pan_pwm, camera_tilt_pwm;
    wire laser_pan_pwm, laser_tilt_pwm;
    wire laser_led, laser_enable_safe, frame_tick;
    wire [7:0] camera_pan_pos, camera_tilt_pos;
    wire [7:0] laser_pan_pos, laser_tilt_pos;
    wire [7:0] laser_pan_target, laser_tilt_target;
    wire laser_aim_ready, laser_lock_qualified;
    wire laser_target_fresh, laser_timeout_fault, laser_rearm_required;
    wire runtime_limits_active, runtime_limit_fault;

    integer errors = 0;
    integer m_cam_pan, m_cam_tilt, m_laser_pan, m_laser_tilt, m_total;

    always #500 clk = ~clk;

    dual_head_control #(
        .CLK_HZ(CLK_HZ),
        .PWM_HZ(PWM_HZ),
        .TARGET_TIMEOUT_FRAMES(20),
        .MAX_ON_FRAMES(0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .servo_enable(servo_enable),
        .target_update(target_update), .target_valid(target_valid),
        .target_x(target_x), .target_y(target_y), .target_score(target_score),
        .laser_arm(laser_arm), .emergency_stop(emergency_stop),
        .manual_override(manual_override), .manual_aim_ready(1'b0),
        .manual_camera_pan_pos(manual_camera_pan_pos),
        .manual_camera_tilt_pos(manual_camera_tilt_pos),
        .manual_laser_pan_pos(manual_laser_pan_pos),
        .manual_laser_tilt_pos(manual_laser_tilt_pos),
        .runtime_limits_en(runtime_limits_en),
        .runtime_pan1_min(runtime_pan1_min), .runtime_pan1_max(runtime_pan1_max),
        .runtime_tilt1_min(runtime_tilt1_min), .runtime_tilt1_max(runtime_tilt1_max),
        .runtime_pan2_min(runtime_pan2_min), .runtime_pan2_max(runtime_pan2_max),
        .runtime_tilt2_min(runtime_tilt2_min), .runtime_tilt2_max(runtime_tilt2_max),
        .runtime_cal_en(1'b0),
        .runtime_pan_offset_pos(16'sd0), .runtime_tilt_offset_pos(16'sd0),
        .camera_pan_pwm(camera_pan_pwm), .camera_tilt_pwm(camera_tilt_pwm),
        .laser_pan_pwm(laser_pan_pwm), .laser_tilt_pwm(laser_tilt_pwm),
        .laser_led(laser_led), .laser_enable_safe(laser_enable_safe),
        .frame_tick(frame_tick),
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

    function integer expect_us(input integer p);
        begin
            expect_us = 500 + ((p * 2000) / 256);
        end
    endfunction

    task check_int(input [8*48-1:0] nm, input integer got, input integer exp_v);
        begin
            if (got === exp_v)
                $display("  [PASS] %0s : %0d", nm, got);
            else begin
                $display("  [FAIL] %0s : %0d (expected %0d)", nm, got, exp_v);
                errors = errors + 1;
            end
        end
    endtask

    task check_tol(input [8*48-1:0] nm, input integer got,
                   input integer exp_v, input integer tol);
        begin
            if (got >= exp_v - tol && got <= exp_v + tol)
                $display("  [PASS] %0s : %0d (expected %0d +/- %0d)",
                         nm, got, exp_v, tol);
            else begin
                $display("  [FAIL] %0s : %0d (expected %0d +/- %0d)",
                         nm, got, exp_v, tol);
                errors = errors + 1;
            end
        end
    endtask

    task wait_frames(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge frame_tick);
            // frame_tick -> Tracking register -> 최종 Servo command register 두 단계 반영
            repeat (4) @(negedge clk);
        end
    endtask

    task pulse_update;
        begin
            @(negedge clk); target_update = 1'b1;
            @(negedge clk); target_update = 1'b0;
            @(negedge clk);
        end
    endtask

    task measure_four;
        begin
            @(posedge frame_tick);
            @(negedge clk);
            m_cam_pan = 0;
            m_cam_tilt = 0;
            m_laser_pan = 0;
            m_laser_tilt = 0;
            m_total = 0;
            forever begin
                @(negedge clk);
                m_total = m_total + 1;
                if (camera_pan_pwm)  m_cam_pan = m_cam_pan + 1;
                if (camera_tilt_pwm) m_cam_tilt = m_cam_tilt + 1;
                if (laser_pan_pwm)   m_laser_pan = m_laser_pan + 1;
                if (laser_tilt_pwm)  m_laser_tilt = m_laser_tilt + 1;
                if (frame_tick) disable measure_four;
            end
        end
    endtask

    initial begin
        $display("=== tb_dual_head_control : 4 Servo + LED integration ===");

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        // Power-on 재무장 조건: Reset 해제 후 Laser Arm LOW를 한 clock 관측한다.
        repeat (2) @(negedge clk);
        servo_enable = 1'b1;
        laser_arm = 1'b1;
        target_valid = 1'b1;

        // Lock 밖 표적으로 PT#1이 한 step 움직이고, PT#2 목표가 그 자세를 포함하는지 확인.
        target_x = 6'd60;
        target_y = 6'd4;
        pulse_update;
        wait_frames(1);
        check_int("T1 camera PAN tracks +1", camera_pan_pos, 129);
        check_int("T1 camera TILT tracks -1", camera_tilt_pos, 127);
        // target_update 시점의 PT#1 자세(128/128)를 기준으로 절대 목표를 고정한다.
        check_int("T1 PT2 PAN target includes camera pose", laser_pan_target, 156);
        check_int("T1 PT2 TILT target includes camera pose", laser_tilt_target, 100);
        check_int("T1 outside Lock Zone -> LED OFF", laser_led, 0);

        // 중앙 양자화 범위로 들어오면 PT#1은 Hold, PT#2는 잔차까지 조준한다.
        target_x = 6'd36;
        target_y = 6'd28;
        pulse_update;
        wait_frames(3);
        check_int("T2 camera PAN dead-zone hold", camera_pan_pos, 129);
        check_int("T2 camera TILT dead-zone hold", camera_tilt_pos, 127);
        check_int("T2 laser PAN = camera +4", laser_pan_pos, 133);
        check_int("T2 laser TILT = camera -4", laser_tilt_pos, 123);
        check_int("T2 PT2 aim ready", laser_aim_ready, 1);

        pulse_update; pulse_update;
        check_int("T3 before 3 confirmations -> LED OFF", laser_led, 0);
        pulse_update;
        check_int("T3 confirmed Lock -> LED ON", laser_led, 1);
        check_int("T3 LED equals safe enable", laser_led, laser_enable_safe);

        // 네 물리 PWM 출력이 각 명령 위치의 펄스폭으로 동시에 나오는지 확인.
        measure_four;
        check_int("T4 common PWM frame period", m_total, PERIOD_CYC);
        check_tol("T4 camera PAN PWM", m_cam_pan, expect_us(129), 2);
        check_tol("T4 camera TILT PWM", m_cam_tilt, expect_us(127), 2);
        check_tol("T4 laser PAN PWM", m_laser_pan, expect_us(133), 2);
        check_tol("T4 laser TILT PWM", m_laser_tilt, expect_us(123), 2);

        emergency_stop = 1'b1;
        repeat (2) @(negedge clk);
        check_int("T5 emergency stop -> LED OFF", laser_led, 0);
        emergency_stop = 1'b0;

        // E-stop 해제만으로는 켜지지 않고 Laser Arm LOW->HIGH가 필요하다.
        pulse_update; pulse_update; pulse_update;
        check_int("T6 E-stop release remains OFF", laser_led, 0);
        check_int("T6 manual rearm requested", laser_rearm_required, 1);
        laser_arm = 1'b0;
        repeat (2) @(negedge clk);
        check_int("T6 Arm LOW clears rearm", laser_rearm_required, 0);
        laser_arm = 1'b1;
        pulse_update; pulse_update; pulse_update;
        check_int("T6 explicit rearm -> LED ON", laser_led, 1);

        // Servo 출력 자체를 끄면 광원도 즉시 Fail-Closed 한다.
        servo_enable = 1'b0;
        repeat (2) @(negedge clk);
        check_int("T6 servo disable -> LED OFF", laser_led, 0);
        measure_four;
        check_int("T6 camera PAN PWM disabled", m_cam_pan, 0);
        check_int("T6 camera TILT PWM disabled", m_cam_tilt, 0);
        check_int("T6 laser PAN PWM disabled", m_laser_pan, 0);
        check_int("T6 laser TILT PWM disabled", m_laser_tilt, 0);

        // Target Lost: 두 헤드 위치 Hold, LED OFF.
        servo_enable = 1'b1;
        target_valid = 1'b0;
        wait_frames(2);
        check_int("T7 target lost camera PAN hold", camera_pan_pos, 129);
        check_int("T7 target lost camera TILT hold", camera_tilt_pos, 127);
        check_int("T7 target lost laser PAN hold", laser_pan_pos, 133);
        check_int("T7 target lost laser TILT hold", laser_tilt_pos, 123);
        check_int("T7 target lost LED OFF", laser_led, 0);

        // Runtime Limit은 8개 값을 원자적으로 등록한다. 유효값 적용 뒤 raw 입력을
        // invalid 범위로 바꿔도 그 값이 한 cycle이라도 Servo로 새면 안 된다.
        manual_override = 1'b1;
        manual_camera_pan_pos = 8'd255;
        manual_camera_tilt_pos = 8'd255;
        manual_laser_pan_pos = 8'd255;
        manual_laser_tilt_pos = 8'd255;
        runtime_pan1_min = 8'd120; runtime_pan1_max = 8'd136;
        runtime_tilt1_min = 8'd121; runtime_tilt1_max = 8'd137;
        runtime_pan2_min = 8'd122; runtime_pan2_max = 8'd138;
        runtime_tilt2_min = 8'd123; runtime_tilt2_max = 8'd139;
        runtime_limits_en = 1'b1;
        repeat (2) @(negedge clk);
        check_int("T8 valid runtime limits active", runtime_limits_active, 1);
        check_int("T8 valid runtime fault clear", runtime_limit_fault, 0);
        check_int("T8 PAN1 registered upper clamp", camera_pan_pos, 136);
        check_int("T8 TILT1 registered upper clamp", camera_tilt_pos, 137);
        check_int("T8 PAN2 registered upper clamp", laser_pan_pos, 138);
        check_int("T8 TILT2 registered upper clamp", laser_tilt_pos, 139);

        // 250~251은 정적 32~224 밖이다. 이전 판정과 새 raw 값이 섞이는 구현은
        // 이 전이 clock에서 251을 출력하지만, 등록된 제한값 구현은 기존 136을 유지한다.
        runtime_pan1_min = 8'd250; runtime_pan1_max = 8'd251;
        @(negedge clk);
        check_int("T9 invalid runtime rejected in one cycle", runtime_limits_active, 0);
        check_int("T9 invalid runtime fault asserted", runtime_limit_fault, 1);
        check_int("T9 invalid raw value never reaches PAN1", camera_pan_pos, 136);
        @(negedge clk);
        check_int("T9 fallback uses static PAN1 max", camera_pan_pos, 224);

        $display("=== 결과 : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_dual_head_control FAILED");
        $finish;
    end

    initial begin
        repeat (2) #500_000_000;
        $fatal(1, "tb_dual_head_control TIMEOUT");
    end

endmodule

`default_nettype wire
