`timescale 1ns/1ps
//=====================================================================
// tb_npu_conv_dense : Conv 엔진 단독 TB (Conv1 형상)
// 64x64x2 -> 32x32x8, 3x3 / stride2 / pad1 / ReLU
//=====================================================================
`include "npu_defs.vh"
module tb_npu_conv_dense;
    localparam integer NOUT = 32*32*8;

    reg clk = 1'b0, rstn = 1'b0, start = 1'b0;
    wire busy, done;
    always #5 clk = ~clk;

    wire [12:0] act_raddr;  wire signed [7:0] act_rdata;
    wire [9:0]  w_raddr;    wire [`NPU_NPE*8-1:0] w_rdata;
    wire        out_we;     wire [12:0] out_waddr;  wire signed [7:0] out_wdata;

    reg [31:0] mult_rom [0:3];
    initial $readmemh({`NPU_WEIGHT_DIR, "requant_M.mem"}, mult_rom);

    npu_conv_dense dut (
        .clk(clk), .rstn(rstn), .start(start), .busy(busy), .done(done),
        .cfg_iw(7'd64), .cfg_iw_log2(3'd6),
        .cfg_ow(6'd32), .cfg_ow_log2(3'd5),
        .cfg_cin(6'd2), .cfg_cout(6'd8), .cfg_nblk(3'd1),
        .cfg_tap(9'd18), .cfg_k(2'd3), .cfg_s2(1'b1),
        .cfg_relu(1'b1), .cfg_mult(mult_rom[0]), .cfg_wbase(10'd0),
        .act_raddr(act_raddr), .act_rdata(act_rdata),
        .w_raddr(w_raddr), .w_rdata(w_rdata),
        .out_we(out_we), .out_waddr(out_waddr), .out_wdata(out_wdata)
    );

    npu_act_buf u_bufin  (.clk(clk), .we(1'b0), .waddr(13'd0), .wdata(8'sd0),
                          .raddr(act_raddr), .rdata(act_rdata));
    npu_act_buf u_bufout (.clk(clk), .we(out_we), .waddr(out_waddr), .wdata(out_wdata),
                          .raddr(13'd0), .rdata());
    npu_weight_rom u_wrom (.clk(clk), .addr(w_raddr), .dout(w_rdata));

    reg signed [7:0] golden [0:NOUT-1];
    integer i, errs;

    initial begin
        $readmemh({`NPU_TV_DIR, "input_event.hex"}, u_bufin.mem);
        $readmemh({`NPU_TV_DIR, "conv1_out.hex"}, golden);
        errs = 0;
        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);
        start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done == 1'b1);
        @(posedge clk);

        for (i = 0; i < NOUT; i = i + 1)
            if (u_bufout.mem[i] !== golden[i]) begin
                errs = errs + 1;
                if (errs <= 5)
                    $display("  [MISMATCH] idx=%0d rtl=%0d exp=%0d",
                             i, u_bufout.mem[i], golden[i]);
            end

        $display("--------------------------------------------------");
        if (errs == 0) $display("[PASS] tb_npu_conv_dense : Conv1 %0d bytes 일치", NOUT);
        else           $display("[FAIL] tb_npu_conv_dense : %0d / %0d mismatch", errs, NOUT);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("[FAIL] tb_npu_conv_dense : timeout");
        $finish;
    end
endmodule
