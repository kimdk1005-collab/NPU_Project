`timescale 1ns/1ps
//=====================================================================
// npu_act_buf : Activation Buffer (simple dual-port, 1 write / 1 read)
// 담당: A
// Tensor Memory Order = CHW,  addr = (c << 2*log2(W)) + (y << log2(W)) + x
// 읽기 지연 1 cycle (BRAM 추론)
//=====================================================================
`include "npu_defs.vh"
module npu_act_buf #(
    parameter DEPTH = `NPU_ACT_DEPTH,
    parameter AW    = `NPU_ACT_AW
)(
    input  wire                 clk,
    input  wire                 we,
    input  wire [AW-1:0]        waddr,
    input  wire signed [7:0]    wdata,
    input  wire [AW-1:0]        raddr,
    output reg  signed [7:0]    rdata
);
    (* ram_style = "block" *) reg signed [7:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
