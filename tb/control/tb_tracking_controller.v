// ---------------------------------------------------------------------------
// tb_tracking_controller.v -- Tracking Controller 자동 판정 TB
//
//  검증 항목
//    T1  Reset -> PAN/TILT Neutral 128
//    T2  frame_tick 없이는 target_valid 이 유지돼도 Hold
//    T3  target_valid=0 -> 즉시 Hold
//    T4  SPEC §15 Dead Zone ±4 포함
//    T5  PAN Left/Right, TILT Up/Down, 두 축 독립/동시 동작
//    T6  target_valid Level 을 Servo Frame 당 한 번만 처리
//    T7  P Gain 및 Slew Limit
//    T8  PAN/TILT 방향 반전 parameter
//    T9  Soft Limit 32~224 및 Limit 에서 추가 명령 차단
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_tracking_controller;

    reg               clk = 1'b0;
    reg               rst_n = 1'b0;
    reg               frame_tick = 1'b0;
    reg               target_valid = 1'b0;
    reg  [5:0]        target_x = 6'd28;
    reg  [5:0]        target_y = 6'd28;
    reg signed [7:0]  target_score = 8'sd1;

    wire [7:0] pan_pos, tilt_pos;
    wire [7:0] pan_fast, tilt_fast;
    wire [7:0] pan_inv, tilt_inv;

    integer errors = 0;
    integer i;

    always #5 clk = ~clk;              // 100 MHz

    // 실제 D4 시작값 -- 부드러운 구동을 위해 Frame 당 1 step
    tracking_controller dut (
        .clk(clk), .rst_n(rst_n), .frame_tick(frame_tick),
        .target_valid(target_valid), .target_x(target_x), .target_y(target_y),
        .target_score(target_score), .pan_pos(pan_pos), .tilt_pos(tilt_pos)
    );

    // P Gain 과 Slew Clamp 를 분리해 확인하는 인스턴스
    tracking_controller #(
        .P_GAIN(1), .P_GAIN_SHIFT(2), .SLEW_LIMIT(4)
    ) dut_fast (
        .clk(clk), .rst_n(rst_n), .frame_tick(frame_tick),
        .target_valid(target_valid), .target_x(target_x), .target_y(target_y),
        .target_score(target_score), .pan_pos(pan_fast), .tilt_pos(tilt_fast)
    );

    // 기구 장착 방향 반전 parameter 확인
    tracking_controller #(
        .P_GAIN(1), .P_GAIN_SHIFT(2), .SLEW_LIMIT(4),
        .PAN_INVERT(1), .TILT_INVERT(1)
    ) dut_inv (
        .clk(clk), .rst_n(rst_n), .frame_tick(frame_tick),
        .target_valid(target_valid), .target_x(target_x), .target_y(target_y),
        .target_score(target_score), .pan_pos(pan_inv), .tilt_pos(tilt_inv)
    );

    task check_int(input [8*44-1:0] nm, input integer got, input integer exp_v);
        begin
            if (got === exp_v)
                $display("  [PASS] %0s : %0d", nm, got);
            else begin
                $display("  [FAIL] %0s : %0d  (expected %0d)", nm, got, exp_v);
                errors = errors + 1;
            end
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            frame_tick = 1'b0;
            target_valid = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task tick;
        begin
            @(negedge clk);
            frame_tick = 1'b1;
            @(negedge clk);
            frame_tick = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        $display("=== tb_tracking_controller : SPEC §14~§16 / D4 ===");

        // T1 Reset
        do_reset;
        check_int("T1 reset PAN neutral",  pan_pos,  128);
        check_int("T1 reset TILT neutral", tilt_pos, 128);

        // T2 target_valid 은 Level 이지만 frame_tick 전에는 절대 움직이지 않는다
        target_valid = 1'b1;
        target_x = 6'd60; target_y = 6'd60;
        repeat (20) @(negedge clk);
        check_int("T2 no frame_tick -> PAN hold",  pan_pos,  128);
        check_int("T2 no frame_tick -> TILT hold", tilt_pos, 128);

        // T3 Target Lost Hold
        target_valid = 1'b0;
        tick;
        check_int("T3 invalid -> PAN hold",  pan_pos,  128);
        check_int("T3 invalid -> TILT hold", tilt_pos, 128);

        // T4 양자화 중심값 28/36, 즉 ±4 를 Dead Zone 에 포함해야 한다
        target_valid = 1'b1;
        target_x = 6'd36; target_y = 6'd28;
        tick;
        check_int("T4 +4 PAN dead zone",  pan_pos,  128);
        check_int("T4 -4 TILT dead zone", tilt_pos, 128);

        // T5/T6 PAN Right. valid 가 유지돼도 Frame 당 정확히 1 step
        target_x = 6'd60; target_y = 6'd28;
        tick;
        check_int("T5 PAN right +1",    pan_pos,  129);
        check_int("T5 TILT holds",      tilt_pos, 128);
        tick;
        check_int("T6 valid level next frame +1", pan_pos, 130);

        // PAN Left 로 즉시 방향 전환, Overshoot 없이 1 step
        target_x = 6'd4;
        tick;
        check_int("T5 PAN left -1", pan_pos, 129);

        // TILT Down / Up, PAN 독립 유지
        target_x = 6'd28; target_y = 6'd60;
        tick;
        check_int("T5 TILT down +1", tilt_pos, 129);
        check_int("T5 PAN holds during TILT", pan_pos, 129);
        target_y = 6'd4;
        tick;
        check_int("T5 TILT up -1", tilt_pos, 128);

        // 두 축 동시 이동
        target_x = 6'd60; target_y = 6'd60;
        tick;
        check_int("T5 simultaneous PAN",  pan_pos,  130);
        check_int("T5 simultaneous TILT", tilt_pos, 129);

        // 이동 중 valid 가 사라지면 이전 목표를 계속 추종하지 않는다
        target_valid = 1'b0;
        tick;
        check_int("T3 lost mid-move PAN hold",  pan_pos,  130);
        check_int("T3 lost mid-move TILT hold", tilt_pos, 129);

        // T7 P Gain: error 12 -> 3 step, error 20 -> 5 이지만 Slew=4 로 제한
        do_reset;
        target_valid = 1'b1;
        target_x = 6'd44; target_y = 6'd28;
        tick;
        check_int("T7 proportional error12 -> +3", pan_fast, 131);
        target_x = 6'd52;
        tick;
        check_int("T7 slew clamps error20 to +4", pan_fast, 135);

        // target_score 는 valid 생성 주체 A의 정보다. 음수여도 valid=1 이 권위다.
        target_score = -8'sd128;
        target_x = 6'd60;
        tick;
        check_int("T7 target_valid overrides score", pan_pos, 131);
        target_score = 8'sd1;

        // T8 기구 방향 반전
        do_reset;
        target_valid = 1'b1;
        target_x = 6'd44; target_y = 6'd44;
        tick;
        check_int("T8 PAN_INVERT",  pan_inv,  125);
        check_int("T8 TILT_INVERT", tilt_inv, 125);

        // T9 Soft Limit. 멀리 있는 Target 을 계속 유지해도 32~224 밖으로 못 간다
        do_reset;
        target_valid = 1'b1;
        target_x = 6'd60; target_y = 6'd60;
        for (i = 0; i < 110; i = i + 1) tick;
        check_int("T9 PAN upper soft limit",  pan_pos,  224);
        check_int("T9 TILT upper soft limit", tilt_pos, 224);
        tick;
        check_int("T9 PAN stays at upper limit", pan_pos, 224);

        target_x = 6'd4; target_y = 6'd4;
        for (i = 0; i < 210; i = i + 1) tick;
        check_int("T9 PAN lower soft limit",  pan_pos,  32);
        check_int("T9 TILT lower soft limit", tilt_pos, 32);

        // Limit 에서도 frame_tick 이 없으면 변화 없음
        target_x = 6'd60; target_y = 6'd60;
        repeat (20) @(negedge clk);
        check_int("T2 no tick at limit", pan_pos, 32);

        $display("=== 결과 : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_tracking_controller FAILED");
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "tb_tracking_controller TIMEOUT");
    end

endmodule

`default_nettype wire
