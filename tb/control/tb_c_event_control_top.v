// ---------------------------------------------------------------------------
// tb_c_event_control_top.v -- A Phase 3 stub <-> C actual RTL contract test
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_c_event_control_top;

    localparam integer CLK_HZ = 1_000_000;

    reg clk = 1'b0;
    reg rstn = 1'b0;

    reg [31:0] event_cfg = 32'd0;
    reg [31:0] pan_cmd = 32'd0;
    reg [31:0] tilt_cmd = 32'd0;
    reg [31:0] laser_ctrl = 32'd0;
    reg [31:0] safe_limit = 32'd0;
    reg [31:0] track_err_x = 32'd0;
    reg [31:0] track_err_y = 32'd0;
    reg [31:0] pan2_cmd = 32'd0;
    reg [31:0] tilt2_cmd = 32'd0;
    reg [31:0] safe_limit2 = 32'd0;
    reg [31:0] laser_cal = 32'd0;

    reg npu_busy = 1'b0;
    reg npu_done = 1'b0;
    reg target_valid = 1'b0;
    reg [5:0] target_x = 6'd36;
    reg [5:0] target_y = 6'd28;
    reg signed [7:0] target_score = 8'sd10;

    reg src_valid = 1'b0;
    reg [5:0] src_x = 6'd0;
    reg [5:0] src_y = 6'd0;
    reg src_pol = 1'b0;
    reg src_window_end = 1'b0;
    reg laser_arm_hw = 1'b0;
    reg emergency_stop_hw = 1'b0;

    wire evt_we;
    wire [12:0] evt_addr;
    wire signed [7:0] evt_data;
    wire tensor_start;
    wire [31:0] input_stat;
    wire [31:0] servo_pos_stat;
    wire [31:0] control_stat;
    wire [3:0] servo_pwm;
    wire laser_en;

    integer errors = 0;
    integer byte_count = 0;
    integer pos_count = -1;
    integer neg_count = -1;
    integer inv_count = -1;
    integer guard;

    always #500 clk = ~clk;

    c_event_control_top #(
        .CLK_HZ(CLK_HZ),
        .SENSOR_W(64), .SENSOR_H(64), .SRC_COORD_W(6),
        .WINDOW_SRC(1), .WINDOW_US(10),
        .PWM_HZ(50), .LOCK_CONFIRM_UPDATES(3),
        .TARGET_TIMEOUT_FRAMES(20), .MAX_ON_FRAMES(0)
    ) dut (
        .clk(clk), .rstn(rstn),
        .event_cfg(event_cfg), .pan_cmd(pan_cmd), .tilt_cmd(tilt_cmd),
        .laser_ctrl(laser_ctrl), .safe_limit(safe_limit),
        .track_err_x(track_err_x), .track_err_y(track_err_y),
        .pan2_cmd(pan2_cmd), .tilt2_cmd(tilt2_cmd),
        .safe_limit2(safe_limit2), .laser_cal(laser_cal),
        .npu_busy(npu_busy), .npu_done(npu_done),
        .target_valid(target_valid), .target_x(target_x), .target_y(target_y),
        .target_score(target_score),
        .src_valid(src_valid), .src_x(src_x), .src_y(src_y), .src_pol(src_pol),
        .src_window_end(src_window_end),
        .laser_arm_hw(laser_arm_hw), .emergency_stop_hw(emergency_stop_hw),
        .evt_we(evt_we), .evt_addr(evt_addr), .evt_data(evt_data),
        .tensor_start(tensor_start), .input_stat(input_stat),
        .servo_pos_stat(servo_pos_stat), .control_stat(control_stat),
        .servo_pwm(servo_pwm), .laser_en(laser_en)
    );

    always @(posedge clk) begin
        if (evt_we) begin
            byte_count = byte_count + 1;
            if (evt_addr == 13'd259)  pos_count = $signed(evt_data); // y=4,x=3
            if (evt_addr == 13'd4485) neg_count = $signed(evt_data); // pol=1,y=6,x=5
            if (evt_addr == 13'd4615) inv_count = $signed(evt_data); // pol=1,y=8,x=7
        end
    end

    task check_int(input [8*56-1:0] name, input integer got, input integer exp_v);
        begin
            if (got === exp_v)
                $display("  [PASS] %0s : %0d", name, got);
            else begin
                $display("  [FAIL] %0s : %0d (expected %0d)", name, got, exp_v);
                errors = errors + 1;
            end
        end
    endtask

    task send_event(input [5:0] x, input [5:0] y, input pol);
        begin
            @(negedge clk);
            src_valid = 1'b1; src_x = x; src_y = y; src_pol = pol;
            @(negedge clk);
            src_valid = 1'b0;
        end
    endtask

    task pulse_window;
        begin
            @(negedge clk); src_window_end = 1'b1;
            @(negedge clk); src_window_end = 1'b0;
        end
    endtask

    task pulse_done;
        begin
            @(negedge clk); npu_done = 1'b1;
            @(negedge clk); npu_done = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        $display("=== tb_c_event_control_top : latest A/C integration contract ===");

        repeat (4) @(negedge clk);
        rstn = 1'b1;

        guard = 0;
        while (!input_stat[0] && guard < 20000) begin
            @(negedge clk); guard = guard + 1;
        end
        check_int("T1 accumulator ready", input_stat[0], 1);
        check_int("T1 fail-closed reset laser", laser_en, 0);

        // EVENT_CFG bit0이 0이면 외부 Window가 와도 Tensor를 확정하지 않는다.
        pulse_window;
        repeat (20) @(negedge clk);
        check_int("T2 event disabled -> no start", tensor_start, 0);
        check_int("T2 tensor_ready remains clear", input_stat[1], 0);

        event_cfg = 32'h0000_0001; // EVENT_ENABLE
        send_event(6'd3, 6'd4, 1'b0);
        send_event(6'd3, 6'd4, 1'b0);
        send_event(6'd5, 6'd6, 1'b1);
        pulse_window;

        guard = 0;
        while (!tensor_start && guard < 20000) begin
            @(negedge clk); guard = guard + 1;
        end
        check_int("T3 tensor_start pulse arrives", tensor_start, 1);
        @(negedge clk);
        check_int("T3 exactly 8192 bytes", byte_count, 8192);
        check_int("T3 positive cell count", pos_count, 2);
        check_int("T3 negative cell count", neg_count, 1);
        check_int("T3 TENSOR_READY sticky", input_stat[1], 1);

        npu_busy = 1'b1;
        @(negedge clk);
        check_int("T4 NPU busy clears TENSOR_READY", input_stat[1], 0);
        npu_busy = 1'b0;

        // EVENT_CFG bit1은 Source polarity를 NPU 채널 앞에서 뒤집는다.
        byte_count = 0;
        event_cfg = 32'h0000_0003;
        send_event(6'd7, 6'd8, 1'b0);
        pulse_window;
        guard = 0;
        while (!tensor_start && guard < 20000) begin
            @(negedge clk); guard = guard + 1;
        end
        check_int("T5 polarity invert start", tensor_start, 1);
        @(negedge clk);
        check_int("T5 polarity invert 8192 bytes", byte_count, 8192);
        check_int("T5 polarity 0 mapped to Ch1", inv_count, 1);
        npu_busy = 1'b1;
        @(negedge clk);
        npu_busy = 1'b0;

        // A RW Command Register를 Manual Override로 쓰고 동적 Safe Limit을 적용한다.
        pan_cmd = 32'd80;
        tilt_cmd = 32'd160;
        pan2_cmd = 32'd160;
        tilt2_cmd = 32'd90;
        safe_limit  = {8'd150, 8'd90, 8'd140, 8'd100};
        safe_limit2 = {8'd140, 8'd100, 8'd150, 8'd110};
        // runtime_limit + manual_aim + manual + SW arm + servo enable
        laser_ctrl = (32'h1 << 8) | (32'h1 << 4) | (32'h1 << 3) |
                     (32'h1 << 1) | 32'h1;
        laser_arm_hw = 1'b1;
        target_valid = 1'b1;
        repeat (2) @(negedge clk);
        check_int("T6 PAN1 runtime lower clamp", servo_pos_stat[7:0], 100);
        check_int("T6 TILT1 runtime upper clamp", servo_pos_stat[15:8], 150);
        check_int("T6 PAN2 runtime upper clamp", servo_pos_stat[23:16], 150);
        check_int("T6 TILT2 runtime lower clamp", servo_pos_stat[31:24], 100);
        check_int("T6 runtime limits active", control_stat[6], 1);
        check_int("T6 runtime limit fault clear", control_stat[7], 0);

        pulse_done; pulse_done;
        check_int("T7 before third confirmation laser OFF", laser_en, 0);
        pulse_done;
        check_int("T7 NPU done drives target_update", laser_en, 1);

        emergency_stop_hw = 1'b1;
        repeat (2) @(negedge clk);
        check_int("T8 hardware E-stop fail-closed", laser_en, 0);
        emergency_stop_hw = 1'b0;

        // 잘못된 runtime 범위는 적용하지 않고 fault를 세운다.
        safe_limit = {8'd150, 8'd90, 8'd100, 8'd200};
        repeat (2) @(negedge clk);
        check_int("T9 invalid limit fault", control_stat[7], 1);
        check_int("T9 invalid runtime limit rejected", control_stat[6], 0);
        check_int("T9 fallback static limit", servo_pos_stat[7:0], 80);

        $display("=== 결과 : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_c_event_control_top FAILED");
        $finish;
    end

    initial begin
        #100_000_000;
        $fatal(1, "tb_c_event_control_top TIMEOUT");
    end

endmodule

`default_nettype wire
