`timescale 1ns/1ps
//=====================================================================
// tb_npu_pe : INT8 MAC 단위 TB (부호 있는 곱셈 + 누산 + clr/en)
// 자극은 negedge 에서만 인가한다 (posedge 레이스 방지)
//=====================================================================
module tb_npu_pe;
    reg clk = 0, rstn = 0, clr = 0, en = 0;
    reg signed [7:0] a = 0, b = 0;
    wire signed [31:0] acc;

    npu_pe dut (.clk(clk), .rstn(rstn), .clr(clr), .en(en), .a(a), .b(b), .acc(acc));
    always #5 clk = ~clk;

    integer i, errs;
    reg signed [31:0] model, prev;

    initial begin
        errs = 0;
        repeat (3) @(negedge clk);
        rstn = 1;

        // 1) clr 동작
        @(negedge clk); clr = 1;
        @(negedge clk); clr = 0;
        if (acc !== 32'sd0) begin errs = errs + 1; $display("[FAIL] clr 후 acc=%0d", acc); end

        // 2) 누산 : 최대 음수(-128) 경계 포함
        //    npu_pe 는 2단 파이프라인이라 acc 는 1 cycle 지연된 합과 같다
        model = 0; prev = 0;
        @(negedge clk); en = 1;
        for (i = 0; i < 300; i = i + 1) begin
            a = (i % 7 == 0) ? -8'sd128 : $signed($random);
            b = (i % 5 == 0) ? -8'sd128 : $signed($random);
            prev  = model;
            model = model + a * b;
            @(posedge clk);
            @(negedge clk);
            if (acc !== prev) begin
                errs = errs + 1;
                if (errs <= 5) $display("[MISMATCH] i=%0d rtl=%0d exp=%0d", i, acc, prev);
            end
        end

        // 3) en=0 이면 파이프라인 배출 후 정지
        en = 0; a = 8'sd100; b = 8'sd100;
        repeat (3) begin @(posedge clk); @(negedge clk); end
        if (acc !== model) begin
            errs = errs + 1;
            $display("[FAIL] 배출 후 총합 불일치 rtl=%0d exp=%0d", acc, model);
        end
        repeat (3) begin @(posedge clk); @(negedge clk); end
        if (acc !== model) begin errs = errs + 1; $display("[FAIL] en=0 인데 값 변함"); end

        // 4) 누산 도중 clr
        @(negedge clk); clr = 1;
        @(posedge clk); @(negedge clk); clr = 0;
        if (acc !== 32'sd0) begin errs = errs + 1; $display("[FAIL] 재-clr 실패"); end

        $display("--------------------------------------------------");
        if (errs == 0) $display("[PASS] tb_npu_pe : 300 MAC + clr/en 전부 일치");
        else           $display("[FAIL] tb_npu_pe : %0d errors", errs);
        $display("--------------------------------------------------");
        $finish;
    end
endmodule
