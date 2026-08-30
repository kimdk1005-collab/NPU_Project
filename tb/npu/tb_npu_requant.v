`timescale 1ns/1ps
//=====================================================================
// tb_npu_requant : Requantize 파이프라인 self-checking TB
// golden: tools/gen_requant_tv.py (spec 9.3/9.4/9.5 Python 구현)
// 연속 입력 + 중간 bubble 을 섞어 valid 파이프라인까지 검증한다.
//=====================================================================
`include "npu_defs.vh"
module tb_npu_requant;
    localparam MAXN = 4096;

    reg clk = 1'b0, rstn = 1'b0;
    reg v_in = 1'b0;
    reg signed [31:0] acc  = 32'sd0;
    reg        [31:0] mult = 32'd0;
    reg               relu_en = 1'b0;
    wire              v_out;
    wire signed [7:0] q;

    npu_requant dut (.clk(clk), .rstn(rstn), .v_in(v_in),
                     .acc(acc), .mult(mult), .relu_en(relu_en),
                     .v_out(v_out), .q(q));
    always #5 clk = ~clk;

    reg [31:0] a_arr [0:MAXN-1];
    reg [31:0] m_arr [0:MAXN-1];
    reg        r_arr [0:MAXN-1];
    reg signed [7:0] e_arr [0:MAXN-1];

    integer N, n, k, errs, fd, code;
    reg [31:0] a_h, m_h, r_h, e_h;

    // ---------------- checker ----------------
    always @(negedge clk) begin
        if (rstn && v_out) begin
            if (q !== e_arr[k]) begin
                errs = errs + 1;
                if (errs <= 10)
                    $display("[MISMATCH] #%0d acc=%0d M=%0d relu=%0d rtl=%0d exp=%0d",
                             k, $signed(a_arr[k]), m_arr[k], r_arr[k], q, e_arr[k]);
            end
            k = k + 1;
        end
    end

    // ---------------- driver ----------------
    initial begin
        N = 0; k = 0; errs = 0;
        fd = $fopen({`NPU_TV_DIR, "requant_tv.txt"}, "r");
        if (fd == 0) begin $display("[FAIL] requant_tv.txt 열기 실패"); $finish; end
        while (!$feof(fd) && N < MAXN) begin
            code = $fscanf(fd, "%h %h %d %h\n", a_h, m_h, r_h, e_h);
            if (code == 4) begin
                a_arr[N] = a_h; m_arr[N] = m_h;
                r_arr[N] = r_h[0]; e_arr[N] = $signed(e_h[7:0]);
                N = N + 1;
            end
        end
        $fclose(fd);

        repeat (3) @(negedge clk);
        rstn = 1'b1;

        for (n = 0; n < N; n = n + 1) begin
            @(negedge clk);
            v_in = 1'b1; acc = a_arr[n]; mult = m_arr[n]; relu_en = r_arr[n];
            if (n % 97 == 96) begin          // bubble 삽입
                @(negedge clk);
                v_in = 1'b0; acc = 32'sdx; mult = 32'dx; relu_en = 1'bx;
            end
        end
        @(negedge clk); v_in = 1'b0;
        repeat (10) @(negedge clk);

        $display("--------------------------------------------------");
        if (k !== N)
            $display("[FAIL] tb_npu_requant : v_out %0d개, 기대 %0d개", k, N);
        else if (errs == 0)
            $display("[PASS] tb_npu_requant : %0d cases 전부 일치", N);
        else
            $display("[FAIL] tb_npu_requant : %0d / %0d mismatch", errs, N);
        $display("--------------------------------------------------");
        $finish;
    end
endmodule
