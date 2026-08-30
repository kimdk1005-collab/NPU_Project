`timescale 1ns/1ps
//=====================================================================
// npu_controller : Layer Sequencer + Cycle Counter
// 담당: A
// Conv1 -> Conv2 -> Conv3 -> Conv4 -> Argmax -> DONE
// 레이어 상수는 spec 8 의 고정 CNN 구조에서 그대로 유도한 값이다.
// (padding=1 은 3x3/stride2 로 64->32,32->16,16->8 이 나오는 유일한 값)
//=====================================================================
`include "npu_defs.vh"
module npu_controller (
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    output reg         busy,
    output reg         done,
    output reg  [31:0] cycle_cnt,

    // conv engine handshake
    output reg         conv_start,
    input  wire        conv_done,
    output reg         buf_sel,

    output reg  [6:0]  cfg_iw,
    output reg  [2:0]  cfg_iw_log2,
    output reg  [5:0]  cfg_ow,
    output reg  [2:0]  cfg_ow_log2,
    output reg  [5:0]  cfg_cin,
    output reg  [5:0]  cfg_cout,
    output reg  [2:0]  cfg_nblk,
    output reg  [8:0]  cfg_tap,
    output reg  [1:0]  cfg_k,
    output reg         cfg_s2,
    output reg         cfg_relu,
    output reg  [31:0] cfg_mult,
    output reg  [9:0]  cfg_wbase,

    // argmax handshake
    output reg         am_start,
    input  wire        am_done
);
    localparam S_IDLE = 3'd0, S_CFG = 3'd1, S_CONV = 3'd2,
               S_AM   = 3'd3, S_DONE = 3'd4;

    reg [2:0] state;
    reg [1:0] layer;

    // 레이어별 requantize multiplier (B 산출물)
    reg [31:0] mult_rom [0:3];
    initial $readmemh({`NPU_WEIGHT_DIR, "requant_M.mem"}, mult_rom);

    always @(posedge clk) begin
        if (!rstn) begin
            state <= S_IDLE; busy <= 1'b0; done <= 1'b0; cycle_cnt <= 32'd0;
            conv_start <= 1'b0; am_start <= 1'b0; layer <= 2'd0; buf_sel <= 1'b0;
            cfg_iw <= 0; cfg_iw_log2 <= 0; cfg_ow <= 0; cfg_ow_log2 <= 0;
            cfg_cin <= 0; cfg_cout <= 0; cfg_nblk <= 0; cfg_tap <= 0;
            cfg_k <= 0; cfg_s2 <= 0; cfg_relu <= 0; cfg_mult <= 0; cfg_wbase <= 0;
        end else begin
            done       <= 1'b0;
            conv_start <= 1'b0;
            am_start   <= 1'b0;
            if (busy) cycle_cnt <= cycle_cnt + 32'd1;

            case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy      <= 1'b1;
                    cycle_cnt <= 32'd0;
                    layer     <= 2'd0;
                    state     <= S_CFG;
                end
            end
            S_CFG: begin
                buf_sel  <= layer[0];
                cfg_mult <= mult_rom[layer];
                case (layer)
                2'd0: begin // Conv1 : 64x64x2 -> 32x32x8, 3x3/s2/p1, ReLU
                    cfg_iw <= 7'd64; cfg_iw_log2 <= 3'd6;
                    cfg_ow <= 6'd32; cfg_ow_log2 <= 3'd5;
                    cfg_cin <= 6'd2; cfg_cout <= 6'd8;  cfg_nblk <= 3'd1;
                    cfg_tap <= 9'd18;  cfg_k <= 2'd3; cfg_s2 <= 1'b1;
                    cfg_relu <= 1'b1;  cfg_wbase <= 10'd0;
                end
                2'd1: begin // Conv2 : 32x32x8 -> 16x16x16
                    cfg_iw <= 7'd32; cfg_iw_log2 <= 3'd5;
                    cfg_ow <= 6'd16; cfg_ow_log2 <= 3'd4;
                    cfg_cin <= 6'd8; cfg_cout <= 6'd16; cfg_nblk <= 3'd2;
                    cfg_tap <= 9'd72;  cfg_k <= 2'd3; cfg_s2 <= 1'b1;
                    cfg_relu <= 1'b1;  cfg_wbase <= 10'd18;
                end
                2'd2: begin // Conv3 : 16x16x16 -> 8x8x32
                    cfg_iw <= 7'd16; cfg_iw_log2 <= 3'd4;
                    cfg_ow <= 6'd8;  cfg_ow_log2 <= 3'd3;
                    cfg_cin <= 6'd16; cfg_cout <= 6'd32; cfg_nblk <= 3'd4;
                    cfg_tap <= 9'd144; cfg_k <= 2'd3; cfg_s2 <= 1'b1;
                    cfg_relu <= 1'b1;  cfg_wbase <= 10'd162;
                end
                2'd3: begin // Conv4 : 8x8x32 -> 8x8x1, 1x1/s1/p0, ReLU 없음
                    cfg_iw <= 7'd8;  cfg_iw_log2 <= 3'd3;
                    cfg_ow <= 6'd8;  cfg_ow_log2 <= 3'd3;
                    cfg_cin <= 6'd32; cfg_cout <= 6'd1;  cfg_nblk <= 3'd1;
                    cfg_tap <= 9'd32;  cfg_k <= 2'd1; cfg_s2 <= 1'b0;
                    cfg_relu <= 1'b0;  cfg_wbase <= 10'd738;
                end
                endcase
                conv_start <= 1'b1;
                state      <= S_CONV;
            end
            S_CONV: begin
                if (conv_done) begin
                    if (layer == 2'd3) begin
                        am_start <= 1'b1;
                        state    <= S_AM;
                    end else begin
                        layer <= layer + 2'd1;
                        state <= S_CFG;
                    end
                end
            end
            S_AM: begin
                if (am_done) state <= S_DONE;
            end
            S_DONE: begin
                done  <= 1'b1;
                busy  <= 1'b0;
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
