// ---------------------------------------------------------------------------
// tb_laser_head_controller.v -- PT#2 절대 방향 변환 / Slew / SAFE_LIMIT2 검증
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_laser_head_controller;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg        frame_tick = 1'b0;
    reg        target_valid = 1'b0;
    reg  [5:0] target_x = 6'd32;
    reg  [5:0] target_y = 6'd32;
    reg  [7:0] camera_pan_pos = 8'd128;
    reg  [7:0] camera_tilt_pos = 8'd128;

    wire [7:0] laser_pan_pos, laser_tilt_pos;
    wire [7:0] laser_pan_target, laser_tilt_target;
    wire       aim_ready;
    wire [7:0] cal_pan_pos, cal_tilt_pos;
    wire [7:0] cal_pan_target, cal_tilt_target;
    wire       cal_aim_ready;

    integer errors = 0;

    always #5 clk = ~clk;

    laser_head_controller #(
        .SLEW_LIMIT(4)
    ) dut (
        .clk(clk), .rst_n(rst_n), .frame_tick(frame_tick),
        .target_valid(target_valid), .target_x(target_x), .target_y(target_y),
        .camera_pan_pos(camera_pan_pos), .camera_tilt_pos(camera_tilt_pos),
        .laser_pan_pos(laser_pan_pos), .laser_tilt_pos(laser_tilt_pos),
        .laser_pan_target(laser_pan_target), .laser_tilt_target(laser_tilt_target),
        .aim_ready(aim_ready)
    );

    // 분수 Scale, 축 반전, LASER_OFFSET을 한 번에 확인한다.
    laser_head_controller #(
        .PAN_ERR_NUM(1), .PAN_ERR_DEN(2),
        .TILT_ERR_NUM(3), .TILT_ERR_DEN(2),
        .PAN_ERR_INVERT(1), .TILT_ERR_INVERT(1),
        .PAN_OFFSET_POS(3), .TILT_OFFSET_POS(-5),
        .SLEW_LIMIT(127)
    ) dut_cal (
        .clk(clk), .rst_n(rst_n), .frame_tick(frame_tick),
        .target_valid(target_valid), .target_x(target_x), .target_y(target_y),
        .camera_pan_pos(camera_pan_pos), .camera_tilt_pos(camera_tilt_pos),
        .laser_pan_pos(cal_pan_pos), .laser_tilt_pos(cal_tilt_pos),
        .laser_pan_target(cal_pan_target), .laser_tilt_target(cal_tilt_target),
        .aim_ready(cal_aim_ready)
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

    task tick;
        begin
            @(negedge clk); frame_tick = 1'b1;
            @(negedge clk); frame_tick = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        $display("=== tb_laser_head_controller : SPEC v1.5 §15.2 ===");

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        check_int("T1 reset PAN neutral", laser_pan_pos, 128);
        check_int("T1 reset TILT neutral", laser_tilt_pos, 128);
        check_int("T1 invalid -> aim not ready", aim_ready, 0);

        // camera pose + residual이어야 한다. error만 쓴 12/-12가 나오면 실패한다.
        target_valid = 1'b1;
        camera_pan_pos = 8'd140;
        camera_tilt_pos = 8'd120;
        target_x = 6'd44;
        target_y = 6'd20;
        #1;
        check_int("T2 absolute PAN target = camera + residual", laser_pan_target, 152);
        check_int("T2 absolute TILT target = camera + residual", laser_tilt_target, 108);
        check_int("T2 before slew -> aim not ready", aim_ready, 0);

        repeat (20) @(negedge clk);
        check_int("T3 no frame_tick -> PAN hold", laser_pan_pos, 128);
        check_int("T3 no frame_tick -> TILT hold", laser_tilt_pos, 128);

        tick;
        check_int("T4 PAN slew +4", laser_pan_pos, 132);
        check_int("T4 TILT slew -4", laser_tilt_pos, 124);
        repeat (5) tick;
        check_int("T4 PAN reaches absolute target", laser_pan_pos, 152);
        check_int("T4 TILT reaches absolute target", laser_tilt_pos, 108);
        check_int("T4 aim_ready after both axes arrive", aim_ready, 1);

        // 분수 scale + 반전 + offset
        check_int("T5 calibrated PAN target", cal_pan_target, 137);
        check_int("T5 calibrated TILT target", cal_tilt_target, 133);
        tick;
        check_int("T5 calibrated PAN command", cal_pan_pos, 137);
        check_int("T5 calibrated TILT command", cal_tilt_pos, 133);
        check_int("T5 calibrated aim_ready", cal_aim_ready, 1);

        // PT#2 SAFE_LIMIT2 최종 Clamp
        camera_pan_pos = 8'd220;
        camera_tilt_pos = 8'd36;
        target_x = 6'd60;
        target_y = 6'd4;
        #1;
        check_int("T6 PAN2 upper clamp", laser_pan_target, 224);
        check_int("T6 TILT2 lower clamp", laser_tilt_target, 32);

        // Target Lost에서는 위치를 유지한다.
        target_valid = 1'b0;
        tick;
        check_int("T7 invalid -> PAN hold", laser_pan_pos, 152);
        check_int("T7 invalid -> TILT hold", laser_tilt_pos, 108);
        check_int("T7 invalid -> aim false", aim_ready, 0);

        $display("=== 결과 : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_laser_head_controller FAILED");
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "tb_laser_head_controller TIMEOUT");
    end

endmodule

`default_nettype wire
