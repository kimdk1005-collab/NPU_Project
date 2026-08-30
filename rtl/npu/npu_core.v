`timescale 1ns/1ps
//=====================================================================
// npu_core : NPU 최상위 (controller + datapath)
// 담당: A
// 외부 인터페이스
//   start / busy / done / cycle_cnt
//   target_valid, target_x[5:0], target_y[5:0], target_score  (spec 14, A -> C)
//   ext_* : Event Tensor 쓰기 포트 (spec 7, C -> A)  busy=0 일 때만 사용
//=====================================================================
`include "npu_defs.vh"
module npu_core #(
    parameter NPE = `NPU_NPE
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    output wire        busy,
    output wire        done,
    output wire [31:0] cycle_cnt,

    input  wire signed [7:0] score_th,
    output wire        target_valid,
    output wire [5:0]  target_x,
    output wire [5:0]  target_y,
    output wire signed [7:0] target_score,

    input  wire        ext_we,
    input  wire [12:0] ext_addr,
    input  wire signed [7:0] ext_data
);
    wire        conv_start, conv_busy, conv_done, buf_sel;
    wire [6:0]  cfg_iw;   wire [2:0] cfg_iw_log2;
    wire [5:0]  cfg_ow;   wire [2:0] cfg_ow_log2;
    wire [5:0]  cfg_cin, cfg_cout;
    wire [2:0]  cfg_nblk; wire [8:0] cfg_tap;
    wire [1:0]  cfg_k;    wire cfg_s2, cfg_relu;
    wire [31:0] cfg_mult; wire [9:0] cfg_wbase;
    wire        am_start, am_busy, am_done;

    npu_controller u_ctrl (
        .clk(clk), .rstn(rstn), .start(start), .busy(busy), .done(done),
        .cycle_cnt(cycle_cnt),
        .conv_start(conv_start), .conv_done(conv_done), .buf_sel(buf_sel),
        .cfg_iw(cfg_iw), .cfg_iw_log2(cfg_iw_log2),
        .cfg_ow(cfg_ow), .cfg_ow_log2(cfg_ow_log2),
        .cfg_cin(cfg_cin), .cfg_cout(cfg_cout), .cfg_nblk(cfg_nblk),
        .cfg_tap(cfg_tap), .cfg_k(cfg_k), .cfg_s2(cfg_s2),
        .cfg_relu(cfg_relu), .cfg_mult(cfg_mult), .cfg_wbase(cfg_wbase),
        .am_start(am_start), .am_done(am_done)
    );

    npu_datapath #(.NPE(NPE)) u_dp (
        .clk(clk), .rstn(rstn),
        .conv_start(conv_start), .conv_busy(conv_busy), .conv_done(conv_done),
        .buf_sel(buf_sel),
        .cfg_iw(cfg_iw), .cfg_iw_log2(cfg_iw_log2),
        .cfg_ow(cfg_ow), .cfg_ow_log2(cfg_ow_log2),
        .cfg_cin(cfg_cin), .cfg_cout(cfg_cout), .cfg_nblk(cfg_nblk),
        .cfg_tap(cfg_tap), .cfg_k(cfg_k), .cfg_s2(cfg_s2),
        .cfg_relu(cfg_relu), .cfg_mult(cfg_mult), .cfg_wbase(cfg_wbase),
        .am_start(am_start), .am_busy(am_busy), .am_done(am_done),
        .score_th(score_th),
        .target_valid(target_valid), .target_x(target_x),
        .target_y(target_y), .target_score(target_score),
        .ext_we(ext_we), .ext_addr(ext_addr), .ext_data(ext_data)
    );
endmodule
