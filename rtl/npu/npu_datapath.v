`timescale 1ns/1ps
//=====================================================================
// npu_datapath : Activation Buffer(ping-pong) + Weight ROM + Conv + Argmax
// 담당: A
//
// 버퍼 배치 (Tensor Memory Order = CHW)
//   L1 : buf0(64x64x2 입력) -> buf1(32x32x8)
//   L2 : buf1              -> buf0(16x16x16)
//   L3 : buf0              -> buf1(8x8x32)
//   L4 : buf1              -> buf0(8x8x1 heatmap)
//   Argmax : buf0
//   외부(C/TB) Event Tensor 쓰기 : buf0, NPU idle 일 때만
//=====================================================================
`include "npu_defs.vh"
module npu_datapath #(
    parameter NPE = `NPU_NPE
)(
    input  wire        clk,
    input  wire        rstn,

    // conv engine control (controller -> )
    input  wire        conv_start,
    output wire        conv_busy,
    output wire        conv_done,
    input  wire        buf_sel,          // 0: rd buf0/wr buf1, 1: rd buf1/wr buf0

    input  wire [6:0]  cfg_iw,
    input  wire [2:0]  cfg_iw_log2,
    input  wire [5:0]  cfg_ow,
    input  wire [2:0]  cfg_ow_log2,
    input  wire [5:0]  cfg_cin,
    input  wire [5:0]  cfg_cout,
    input  wire [2:0]  cfg_nblk,
    input  wire [8:0]  cfg_tap,
    input  wire [1:0]  cfg_k,
    input  wire        cfg_s2,
    input  wire        cfg_relu,
    input  wire [31:0] cfg_mult,
    input  wire [9:0]  cfg_wbase,

    // argmax control
    input  wire        am_start,
    output wire        am_busy,
    output wire        am_done,
    input  wire signed [7:0] score_th,
    output wire        target_valid,
    output wire [5:0]  target_x,
    output wire [5:0]  target_y,
    output wire signed [7:0] target_score,

    // 외부 Event Tensor write port (C / TB)
    input  wire        ext_we,
    input  wire [12:0] ext_addr,
    input  wire signed [7:0] ext_data
);
    //---------------- conv engine ----------------
    wire [12:0] act_raddr;
    wire signed [7:0] act_rdata;
    wire [9:0]  w_raddr;
    wire [NPE*8-1:0] w_rdata;
    wire        cv_we;
    wire [12:0] cv_waddr;
    wire signed [7:0] cv_wdata;

    npu_conv_dense #(.NPE(NPE)) u_conv (
        .clk(clk), .rstn(rstn), .start(conv_start),
        .busy(conv_busy), .done(conv_done),
        .cfg_iw(cfg_iw), .cfg_iw_log2(cfg_iw_log2),
        .cfg_ow(cfg_ow), .cfg_ow_log2(cfg_ow_log2),
        .cfg_cin(cfg_cin), .cfg_cout(cfg_cout), .cfg_nblk(cfg_nblk),
        .cfg_tap(cfg_tap), .cfg_k(cfg_k), .cfg_s2(cfg_s2),
        .cfg_relu(cfg_relu), .cfg_mult(cfg_mult), .cfg_wbase(cfg_wbase),
        .act_raddr(act_raddr), .act_rdata(act_rdata),
        .w_raddr(w_raddr), .w_rdata(w_rdata),
        .out_we(cv_we), .out_waddr(cv_waddr), .out_wdata(cv_wdata)
    );

    npu_weight_rom #(.NPE(NPE)) u_wrom (
        .clk(clk), .addr(w_raddr), .dout(w_rdata)
    );

    //---------------- argmax ----------------
    wire [12:0] am_addr;
    wire signed [7:0] buf0_rdata, buf1_rdata;

    argmax_decoder u_am (
        .clk(clk), .rstn(rstn), .start(am_start),
        .busy(am_busy), .done(am_done),
        .rd_addr(am_addr), .rd_data(buf0_rdata),
        .score_th(score_th),
        .target_valid(target_valid), .target_x(target_x),
        .target_y(target_y), .target_score(target_score)
    );

    //---------------- buffer 라우팅 ----------------
    wire b0_we    = ext_we ? 1'b1 : (buf_sel & cv_we);
    wire [12:0] b0_waddr = ext_we ? ext_addr : cv_waddr;
    wire signed [7:0] b0_wdata = ext_we ? ext_data : cv_wdata;
    wire [12:0] b0_raddr = am_busy ? am_addr : act_raddr;

    wire b1_we    = (~buf_sel) & cv_we;
    wire [12:0] b1_waddr = cv_waddr;
    wire signed [7:0] b1_wdata = cv_wdata;
    wire [12:0] b1_raddr = act_raddr;

    npu_act_buf u_buf0 (
        .clk(clk), .we(b0_we), .waddr(b0_waddr), .wdata(b0_wdata),
        .raddr(b0_raddr), .rdata(buf0_rdata)
    );
    npu_act_buf u_buf1 (
        .clk(clk), .we(b1_we), .waddr(b1_waddr), .wdata(b1_wdata),
        .raddr(b1_raddr), .rdata(buf1_rdata)
    );

    assign act_rdata = buf_sel ? buf1_rdata : buf0_rdata;
endmodule
