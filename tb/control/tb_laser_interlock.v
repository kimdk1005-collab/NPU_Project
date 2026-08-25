// ---------------------------------------------------------------------------
// tb_laser_interlock.v -- SPEC v1.5 §17 Fail-Closed 안전 조건 자동 판정
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_laser_interlock;

    reg               clk = 1'b0;
    reg               rst_n = 1'b0;
    reg               frame_tick = 1'b0;
    reg               target_update = 1'b0;
    reg               system_arm = 1'b0;
    reg               actuator_ready = 1'b1;
    reg               emergency_stop = 1'b0;
    reg               target_valid = 1'b0;
    reg  [5:0]        target_x = 6'd36;
    reg  [5:0]        target_y = 6'd28;
    reg signed [7:0]  target_score = 8'sd10;
    reg  [7:0]        camera_pan_pos = 8'd128;
    reg  [7:0]        camera_tilt_pos = 8'd128;
    reg  [7:0]        laser_pan_pos = 8'd132;
    reg  [7:0]        laser_tilt_pos = 8'd124;
    reg               aim_ready = 1'b1;

    wire laser_enable, lock_qualified, target_fresh, timeout_fault;
    wire rearm_required;
    wire wd_enable, wd_qualified, wd_fresh, wd_timeout_fault;
    wire wd_rearm_required;
    integer errors = 0;

    always #5 clk = ~clk;

    laser_interlock #(
        .SCORE_THRESHOLD(5),
        .LOCK_CONFIRM_UPDATES(3),
        .TARGET_TIMEOUT_FRAMES(4),
        .MAX_ON_FRAMES(3)
    ) dut (
        .clk(clk), .rst_n(rst_n), .frame_tick(frame_tick),
        .target_update(target_update), .system_arm(system_arm),
        .actuator_ready(actuator_ready),
        .emergency_stop(emergency_stop), .target_valid(target_valid),
        .target_x(target_x), .target_y(target_y), .target_score(target_score),
        .camera_pan_pos(camera_pan_pos), .camera_tilt_pos(camera_tilt_pos),
        .laser_pan_pos(laser_pan_pos), .laser_tilt_pos(laser_tilt_pos),
        .aim_ready(aim_ready), .laser_enable(laser_enable),
        .lock_qualified(lock_qualified), .target_fresh(target_fresh),
        .timeout_fault(timeout_fault), .rearm_required(rearm_required)
    );

    // Max-on을 끈 별도 인스턴스로 freshness watchdog만 독립 검증한다.
    laser_interlock #(
        .SCORE_THRESHOLD(5),
        .LOCK_CONFIRM_UPDATES(3),
        .TARGET_TIMEOUT_FRAMES(4),
        .MAX_ON_FRAMES(0)
    ) dut_watchdog (
        .clk(clk), .rst_n(rst_n), .frame_tick(frame_tick),
        .target_update(target_update), .system_arm(system_arm),
        .actuator_ready(actuator_ready),
        .emergency_stop(emergency_stop), .target_valid(target_valid),
        .target_x(target_x), .target_y(target_y), .target_score(target_score),
        .camera_pan_pos(camera_pan_pos), .camera_tilt_pos(camera_tilt_pos),
        .laser_pan_pos(laser_pan_pos), .laser_tilt_pos(laser_tilt_pos),
        .aim_ready(aim_ready), .laser_enable(wd_enable),
        .lock_qualified(wd_qualified), .target_fresh(wd_fresh),
        .timeout_fault(wd_timeout_fault), .rearm_required(wd_rearm_required)
    );

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

    task idle_cycle;
        begin
            @(negedge clk);
            @(negedge clk);
        end
    endtask

    task pulse_update;
        begin
            @(negedge clk); target_update = 1'b1;
            @(negedge clk); target_update = 1'b0;
            @(negedge clk);
        end
    endtask

    task pulse_frame;
        begin
            @(negedge clk); frame_tick = 1'b1;
            @(negedge clk); frame_tick = 1'b0;
            @(negedge clk);
        end
    endtask

    task pulse_frame_with_update;
        begin
            @(negedge clk); frame_tick = 1'b1; target_update = 1'b1;
            @(negedge clk); frame_tick = 1'b0; target_update = 1'b0;
            @(negedge clk);
        end
    endtask

    task restore_good;
        begin
            system_arm = 1'b1;
            actuator_ready = 1'b1;
            emergency_stop = 1'b0;
            target_valid = 1'b1;
            target_x = 6'd36;
            target_y = 6'd28;
            target_score = 8'sd10;
            camera_pan_pos = 8'd128;
            camera_tilt_pos = 8'd128;
            laser_pan_pos = 8'd132;
            laser_tilt_pos = 8'd124;
            aim_ready = 1'b1;
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            frame_tick = 1'b0;
            target_update = 1'b0;
            restore_good;
            system_arm = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
            system_arm = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task confirm_lock;
        begin
            pulse_update;
            pulse_update;
            pulse_update;
        end
    endtask

    initial begin
        $display("=== tb_laser_interlock : SPEC v1.5 §17 / LED first ===");

        // Power-on 시 Arm이 이미 HIGH면 유효 Target이 있어도 자동 점등하지 않는다.
        @(negedge clk);
        rst_n = 1'b0;
        restore_good;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        confirm_lock;
        check_int("T0 boot with Arm HIGH stays OFF", laser_enable, 0);
        check_int("T0 boot requires manual rearm", rearm_required, 1);
        system_arm = 1'b0; idle_cycle;
        check_int("T0 Arm LOW acknowledges rearm", rearm_required, 0);

        do_reset;
        check_int("T1 reset -> laser OFF", laser_enable, 0);
        check_int("T1 reset -> target stale", target_fresh, 0);
        check_int("T1 reset -> no timeout fault", timeout_fault, 0);
        check_int("T1 valid Arm cycle clears rearm", rearm_required, 0);

        // 연속 3개의 새 NPU 결과가 Lock 조건을 만족해야 켜진다.
        pulse_update;
        check_int("T2 first lock update -> OFF", laser_enable, 0);
        check_int("T2 first update -> fresh", target_fresh, 1);
        pulse_update;
        check_int("T2 second lock update -> OFF", laser_enable, 0);
        pulse_update;
        check_int("T2 third lock update -> ON", laser_enable, 1);
        check_int("T2 qualified conditions", lock_qualified, 1);

        // 모든 조건은 동기식 1 clock 이내 Fail-Closed 한다.
        emergency_stop = 1'b1; idle_cycle;
        check_int("T3 emergency stop -> OFF", laser_enable, 0);
        check_int("T3 emergency stop latches rearm", rearm_required, 1);
        emergency_stop = 1'b0; confirm_lock;
        check_int("T3 E-stop release stays OFF", laser_enable, 0);
        system_arm = 1'b0; idle_cycle;
        check_int("T3 Arm LOW clears E-stop latch", rearm_required, 0);
        system_arm = 1'b1; confirm_lock;
        check_int("T3 explicit rearm restores output", laser_enable, 1);

        system_arm = 1'b0; idle_cycle;
        check_int("T4 arm removed -> OFF", laser_enable, 0);
        system_arm = 1'b1; confirm_lock;

        actuator_ready = 1'b0; idle_cycle;
        check_int("T4 actuator not ready -> OFF", laser_enable, 0);
        actuator_ready = 1'b1; confirm_lock;

        target_score = -8'sd1; idle_cycle;
        check_int("T5 signed score below threshold -> OFF", laser_enable, 0);
        target_score = 8'sd10; confirm_lock;

        target_x = 6'd61; idle_cycle;
        check_int("T6 target outside Safe Zone -> OFF", laser_enable, 0);
        target_x = 6'd36; confirm_lock;

        target_x = 6'd44; idle_cycle;
        check_int("T7 target outside Lock Zone -> OFF", laser_enable, 0);
        target_x = 6'd36; confirm_lock;

        camera_pan_pos = 8'd31; idle_cycle;
        check_int("T8 PT1 outside SAFE_LIMIT -> OFF", laser_enable, 0);
        camera_pan_pos = 8'd128; confirm_lock;

        laser_tilt_pos = 8'd225; idle_cycle;
        check_int("T9 PT2 outside SAFE_LIMIT2 -> OFF", laser_enable, 0);
        laser_tilt_pos = 8'd124; confirm_lock;

        aim_ready = 1'b0; idle_cycle;
        check_int("T10 PT2 not aimed -> OFF", laser_enable, 0);
        aim_ready = 1'b1; confirm_lock;

        target_valid = 1'b0; idle_cycle;
        check_int("T11 target lost -> OFF", laser_enable, 0);
        check_int("T11 target lost clears timeout fault", timeout_fault, 0);

        // 새 결과가 끊기면 Level target_valid가 남아 있어도 꺼진다.
        do_reset;
        confirm_lock;
        check_int("T12 watchdog setup -> ON", wd_enable, 1);
        pulse_frame; pulse_frame; pulse_frame;
        check_int("T12 before watchdog deadline", wd_enable, 1);
        pulse_frame;
        check_int("T12 stale target watchdog -> OFF", wd_enable, 0);
        check_int("T12 stale target freshness cleared", wd_fresh, 0);

        // 연속 ON 3 frame 뒤에는 latch되어 자동 재점등하지 않는다.
        do_reset;
        confirm_lock;
        pulse_frame_with_update;
        pulse_frame_with_update;
        check_int("T13 before max-on deadline", laser_enable, 1);
        pulse_frame_with_update;
        check_int("T13 max-on -> OFF", laser_enable, 0);
        check_int("T13 timeout fault latched", timeout_fault, 1);
        confirm_lock;
        check_int("T13 locked fault blocks re-enable", laser_enable, 0);
        target_valid = 1'b0; idle_cycle;
        check_int("T13 target lost keeps timeout latched", timeout_fault, 1);
        system_arm = 1'b0; idle_cycle;
        check_int("T13 Arm LOW clears timeout fault", timeout_fault, 0);
        check_int("T13 Arm LOW clears rearm request", rearm_required, 0);

        $display("=== 결과 : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_laser_interlock FAILED");
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "tb_laser_interlock TIMEOUT");
    end

endmodule

`default_nettype wire
