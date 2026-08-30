`timescale 1ns/1ps
//=====================================================================
// tb_npu_full : NPU 전체 추론 self-checking TB
// 검증 순서 (spec 9.3): Conv1 -> Conv2 -> Conv3 -> Conv4 -> Argmax
// golden: test_vectors/*.hex (tools/gen_dummy.py, B 산출물과 동일 형식)
//=====================================================================
`include "npu_defs.vh"
module tb_npu_full;
    localparam integer N1 = 32*32*8;    // 8192
    localparam integer N2 = 16*16*16;   // 4096
    localparam integer N3 = 8*8*32;     // 2048
    localparam integer N4 = 8*8*1;      // 64

    reg clk = 1'b0, rstn = 1'b0, start = 1'b0;
    wire busy, done;
    wire [31:0] cycle_cnt;
    reg  signed [7:0] score_th = 8'sd0;
    wire target_valid;
    wire [5:0] target_x, target_y;
    wire signed [7:0] target_score;

    reg         ext_we   = 1'b0;
    reg  [12:0] ext_addr = 13'd0;
    reg  signed [7:0] ext_data = 8'sd0;

    npu_core dut (
        .clk(clk), .rstn(rstn), .start(start), .busy(busy), .done(done),
        .cycle_cnt(cycle_cnt), .score_th(score_th),
        .target_valid(target_valid), .target_x(target_x),
        .target_y(target_y), .target_score(target_score),
        .ext_we(ext_we), .ext_addr(ext_addr), .ext_data(ext_data)
    );

    always #5 clk = ~clk;    // 100 MHz

    // ---------------- golden ----------------
    reg signed [7:0] g_in [0:8191];
    reg signed [7:0] g1 [0:N1-1];
    reg signed [7:0] g2 [0:N2-1];
    reg signed [7:0] g3 [0:N3-1];
    reg signed [7:0] g4 [0:N4-1];
    integer exp_hx, exp_hy, exp_tx, exp_ty, exp_score;
    reg     exp_valid;

    integer errs = 0;
    integer layer_err;
    integer i, fd, code;
    reg [8*32-1:0] key;
    integer val;

    // ---------------- 레이어별 비교 ----------------
    task check_layer(input integer li);
        integer k, n, e;
        reg signed [7:0] got, exp;
        begin
            e = 0;
            n = (li == 0) ? N1 : (li == 1) ? N2 : (li == 2) ? N3 : N4;
            for (k = 0; k < n; k = k + 1) begin
                // buf_sel=0 -> buf1 에 기록, buf_sel=1 -> buf0 에 기록
                got = (li[0]) ? dut.u_dp.u_buf0.mem[k] : dut.u_dp.u_buf1.mem[k];
                exp = (li == 0) ? g1[k] : (li == 1) ? g2[k] : (li == 2) ? g3[k] : g4[k];
                if (got !== exp) begin
                    e = e + 1;
                    if (e <= 5)
                        $display("  [MISMATCH] conv%0d idx=%0d rtl=%0d exp=%0d",
                                 li + 1, k, got, exp);
                end
            end
            if (e == 0)
                $display("  [PASS] Conv%0d  %0d bytes 전부 일치 (cycle=%0d)",
                         li + 1, n, cycle_cnt);
            else begin
                $display("  [FAIL] Conv%0d  %0d / %0d mismatch", li + 1, e, n);
                errs = errs + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rstn && dut.u_dp.conv_done)
            check_layer(dut.u_ctrl.layer);
    end

    // ---------------- 메인 ----------------
    initial begin
        $readmemh({`NPU_TV_DIR, "input_event.hex"}, g_in);
        $readmemh({`NPU_TV_DIR, "conv1_out.hex"},   g1);
        $readmemh({`NPU_TV_DIR, "conv2_out.hex"},   g2);
        $readmemh({`NPU_TV_DIR, "conv3_out.hex"},   g3);
        $readmemh({`NPU_TV_DIR, "conv4_out.hex"},   g4);

        fd = $fopen({`NPU_TV_DIR, "result_xy.txt"}, "r");
        if (fd == 0) begin $display("[FAIL] result_xy.txt 없음"); $finish; end
        for (i = 0; i < 5; i = i + 1) begin
            code = $fscanf(fd, "%s %d\n", key, val);
            case (i)
                0: exp_hx = val;  1: exp_hy = val;
                2: exp_tx = val;  3: exp_ty = val;
                4: exp_score = val;
            endcase
        end
        $fclose(fd);

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);

        // Event Tensor 적재 (spec 7: C -> A, NPU idle 일 때만)
        $display("[TB] Event Tensor 8192 byte 적재");
        for (i = 0; i < 8192; i = i + 1) begin
            @(posedge clk);
            ext_we   <= 1'b1;
            ext_addr <= i[12:0];
            ext_data <= g_in[i];
        end
        @(posedge clk);
        ext_we <= 1'b0;
        @(posedge clk);

        $display("[TB] NPU 추론 시작");
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        wait (done == 1'b1);
        @(posedge clk);

        $display("--------------------------------------------------");
        $display("[TB] Argmax 결과");
        $display("  target_x=%0d (exp %0d)  target_y=%0d (exp %0d)",
                 target_x, exp_tx, target_y, exp_ty);
        $display("  target_score=%0d (exp %0d)  target_valid=%0d",
                 target_score, exp_score, target_valid);
        if (target_x !== exp_tx[5:0]) begin errs = errs + 1; $display("  [FAIL] target_x"); end
        if (target_y !== exp_ty[5:0]) begin errs = errs + 1; $display("  [FAIL] target_y"); end
        if (target_score !== exp_score[7:0]) begin errs = errs + 1; $display("  [FAIL] target_score"); end
        exp_valid = (exp_score > $signed(score_th));
        if (target_valid !== exp_valid) begin errs = errs + 1;
            $display("  [FAIL] target_valid (exp %0d)", exp_valid); end

        $display("--------------------------------------------------");
        $display("[TB] NPU Latency = %0d cycle  (@100MHz = %0.3f ms)",
                 cycle_cnt, cycle_cnt / 100000.0);
        if (errs == 0) $display("[PASS] tb_npu_full : Golden Model 완전 일치");
        else           $display("[FAIL] tb_npu_full : %0d 항목 실패", errs);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("[FAIL] tb_npu_full : timeout");
        $finish;
    end
endmodule
