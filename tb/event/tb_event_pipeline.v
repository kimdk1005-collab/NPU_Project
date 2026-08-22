// ---------------------------------------------------------------------------
// tb_event_pipeline.v -- Event Adapter -> Accumulator D4 통합 판정 TB
//
//  Raw 640x480 Event 를 Adapter 에 넣고 Accumulator 가 전송한 CHW Tensor
//  8192 byte 를 독립 Reference Model 과 전수 비교한다.
//
//  검증 항목
//    T1  Accumulator INIT / Ready
//    T2  640x480 -> 64x64 Binning + Positive/Negative CHW 주소
//    T3  같은 좌표 누적 + 127 포화
//    T4  범위 밖 Raw 좌표 폐기와 Window Count
//    T5  Window End 와 같은 Cycle 의 Event 를 현재 Window 에 포함
//    T6  npu_busy 동안 전송 금지
//    T7  Window별 8192 byte 전수 비교 / 주소 순서
//    T8  전송 중 다음 Window Event 보존 (Adapter 포함 Ping-Pong)
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_event_pipeline;

    localparam integer DEPTH = 8192;
    localparam integer SRC_W = 11;

    reg                  clk = 1'b0;
    reg                  rst_n = 1'b0;
    reg                  src_valid = 1'b0;
    reg  [SRC_W-1:0]     src_x = {SRC_W{1'b0}};
    reg  [SRC_W-1:0]     src_y = {SRC_W{1'b0}};
    reg                  src_pol = 1'b0;
    reg                  src_wend = 1'b0;
    reg                  npu_busy = 1'b0;

    wire                 event_valid;
    wire [5:0]           event_x, event_y;
    wire                 event_pol, event_wend;
    wire [19:0]          win_evt_count, win_drop_count;

    wire                 tensor_we, tensor_start, acc_ready, overrun;
    wire [12:0]          tensor_addr;
    wire signed [7:0]    tensor_data;

    reg [7:0] ref_mem [0:DEPTH-1];
    reg [7:0] exp_mem [0:DEPTH-1];
    reg [7:0] got_mem [0:DEPTH-1];

    integer errors = 0;
    integer cap_n = 0;
    integer addr_err = 0;
    integer busy_err = 0;
    integer i, k;

    always #5 clk = ~clk;              // 100 MHz

    event_adapter #(
        .SENSOR_W(640), .SENSOR_H(480), .SRC_COORD_W(SRC_W),
        .CLK_HZ(100_000_000), .WINDOW_SRC(1), .OOR_POLICY(0)
    ) u_adapter (
        .clk(clk), .rst_n(rst_n),
        .src_valid(src_valid), .src_x(src_x), .src_y(src_y),
        .src_pol(src_pol), .src_window_end(src_wend),
        .event_valid(event_valid), .event_x(event_x), .event_y(event_y),
        .event_polarity(event_pol), .event_window_end(event_wend),
        .win_evt_count(win_evt_count), .win_drop_count(win_drop_count)
    );

    event_accumulator u_accumulator (
        .clk(clk), .rst_n(rst_n),
        .event_valid(event_valid), .event_x(event_x), .event_y(event_y),
        .event_polarity(event_pol), .event_window_end(event_wend),
        .npu_busy(npu_busy),
        .tensor_we(tensor_we), .tensor_addr(tensor_addr),
        .tensor_data(tensor_data), .tensor_start(tensor_start),
        .acc_ready(acc_ready), .overrun(overrun)
    );

    always @(negedge clk) begin
        if (tensor_we) begin
            got_mem[tensor_addr] = tensor_data;
            if (tensor_addr !== cap_n[12:0]) addr_err = addr_err + 1;
            cap_n = cap_n + 1;
        end
        if (npu_busy && tensor_we) busy_err = busy_err + 1;
    end

    function integer ref_bin(input integer raw, input integer sensor);
        ref_bin = (raw * 64) / sensor;
    endfunction

    task ref_add(input integer x, input integer y, input p);
        integer bx, by, ad;
        begin
            if (x < 640 && y < 480) begin
                bx = ref_bin(x, 640);
                by = ref_bin(y, 480);
                ad = (p << 12) | (by << 6) | bx;
                if (ref_mem[ad] < 127) ref_mem[ad] = ref_mem[ad] + 1'b1;
            end
        end
    endtask

    task send_one(input integer x, input integer y, input p);
        begin
            @(negedge clk);
            src_x = x[SRC_W-1:0]; src_y = y[SRC_W-1:0]; src_pol = p;
            src_valid = 1'b1;
            ref_add(x, y, p);
            @(negedge clk);
            src_valid = 1'b0;
        end
    endtask

    task send_repeat(input integer n, input integer x, input integer y, input p);
        integer j;
        begin
            @(negedge clk);
            src_x = x[SRC_W-1:0]; src_y = y[SRC_W-1:0]; src_pol = p;
            for (j = 0; j < n; j = j + 1) begin
                src_valid = 1'b1;
                ref_add(x, y, p);
                @(negedge clk);
            end
            src_valid = 1'b0;
        end
    endtask

    task close_window(input with_event, input integer x, input integer y, input p);
        integer j;
        begin
            @(negedge clk);
            src_x = x[SRC_W-1:0]; src_y = y[SRC_W-1:0]; src_pol = p;
            src_valid = with_event;
            src_wend = 1'b1;
            if (with_event) ref_add(x, y, p);

            for (j = 0; j < DEPTH; j = j + 1) begin
                exp_mem[j] = ref_mem[j];
                ref_mem[j] = 8'd0;
            end
            cap_n = 0;
            addr_err = 0;

            @(negedge clk);
            src_valid = 1'b0;
            src_wend = 1'b0;
        end
    endtask

    task idle_src(input integer n);
        begin
            src_valid = 1'b0;
            src_wend = 1'b0;
            repeat (n) @(negedge clk);
        end
    endtask

    task check_int(input [8*48-1:0] nm, input integer got, input integer exp_v);
        begin
            if (got === exp_v)
                $display("  [PASS] %0s : %0d", nm, got);
            else begin
                $display("  [FAIL] %0s : %0d  (expected %0d)", nm, got, exp_v);
                errors = errors + 1;
            end
        end
    endtask

    task compare_tensor(input [8*48-1:0] nm);
        integer bad, shown, nz;
        begin
            bad = 0; shown = 0; nz = 0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                if (exp_mem[i] != 0) nz = nz + 1;
                if (got_mem[i] !== exp_mem[i]) begin
                    bad = bad + 1;
                    if (shown < 6) begin
                        $display("      addr %0d: got %0d expected %0d", i, got_mem[i], exp_mem[i]);
                        shown = shown + 1;
                    end
                end
            end
            $display("      (nonzero cells = %0d)", nz);
            check_int(nm, bad, 0);
        end
    endtask

    task wait_xfer;
        integer guard;
        begin
            guard = 0;
            while (!tensor_start && guard < 40000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (guard >= 40000) begin
                $display("  [FAIL] tensor_start timeout");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("=== tb_event_pipeline : Adapter -> Accumulator D4 ===");
        for (i = 0; i < DEPTH; i = i + 1) begin
            ref_mem[i] = 8'd0; exp_mem[i] = 8'd0; got_mem[i] = 8'hFF;
        end

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        i = 0;
        while (!acc_ready && i < 20000) begin
            @(negedge clk); i = i + 1;
        end
        check_int("T1 accumulator ready after INIT", acc_ready, 1);
        idle_src(3);

        // Window 1: Binning, 채널 분리, 연속 누적, 포화, OOR, 경계 Event
        send_one(0,   0,   1'b0);       // addr 0
        send_one(639, 479, 1'b1);       // addr 8191
        send_repeat(5,   320, 240, 1'b0);
        send_repeat(140, 100, 100, 1'b1);  // 같은 Binned Cell 127 포화
        send_repeat(7,   700, 100, 1'b0);  // OOR -> 전부 폐기

        npu_busy = 1'b1;
        close_window(1'b1, 320, 240, 1'b0); // 경계와 같은 Cycle Event 포함
        idle_src(5);                         // Adapter pipeline 배수
        check_int("T4 W1 accepted event count", win_evt_count, 148);
        check_int("T4 W1 dropped OOR count",   win_drop_count, 7);
        idle_src(45);
        check_int("T6 bytes sent while npu_busy", cap_n, 0);

        // W1 전송을 기다리는 동안 W2 이벤트를 Adapter 부터 통과시킨다.
        send_repeat(20, 400, 100, 1'b0);
        npu_busy = 1'b0;
        for (k = 0; k < 300; k = k + 1)
            send_one((k * 17) % 640, (k * 11) % 480, k[0]);

        wait_xfer;
        check_int("T7 W1 bytes transferred", cap_n, DEPTH);
        check_int("T7 W1 address order violations", addr_err, 0);
        check_int("T6 busy write violations", busy_err, 0);
        compare_tensor("T7 W1 8192-byte full compare");
        @(negedge clk);
        check_int("T7 tensor_start one-cycle pulse", tensor_start, 0);

        // Window 2: W1 전송 중 들어온 320개가 모두 살아 있어야 한다.
        close_window(1'b0, 0, 0, 1'b0);
        idle_src(5);
        check_int("T8 W2 accepted during W1 transfer", win_evt_count, 320);
        check_int("T8 W2 dropped event count", win_drop_count, 0);
        wait_xfer;
        check_int("T8 W2 bytes transferred", cap_n, DEPTH);
        check_int("T8 W2 address order violations", addr_err, 0);
        compare_tensor("T8 W2 ping-pong 8192-byte compare");
        check_int("T8 overrun flag", overrun, 0);

        $display("=== 결과 : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_event_pipeline FAILED");
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "tb_event_pipeline TIMEOUT");
    end

endmodule

`default_nettype wire
