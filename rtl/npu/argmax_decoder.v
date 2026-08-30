`timescale 1ns/1ps
//=====================================================================
// argmax_decoder : 8x8 Heatmap -> Target (x, y)
// 담당: A
// 규격: TEAM_COMMON_AI_INTEGRATION_SPEC v1.2  14 / 14.1
//   Heatmap 인덱스 순서 = [Y][X], addr = y*8 + x
//   동점 처리 = raster 순서 first-max 우선 (strict '>') -> numpy argmax와 동일
//   target_x = heatmap_x*8 + 4,  target_y = heatmap_y*8 + 4
//=====================================================================
module argmax_decoder (
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    output reg         busy,
    output reg         done,

    output wire [12:0] rd_addr,
    input  wire signed [7:0] rd_data,

    input  wire signed [7:0] score_th,        // target_valid 판정 임계값
    output reg         target_valid,
    output reg  [5:0]  target_x,
    output reg  [5:0]  target_y,
    output reg  signed [7:0] target_score
);
    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_DRAIN = 2'd2, S_DONE = 2'd3;

    reg [1:0] state;
    reg [6:0] i;                       // 0..63 발행 카운터
    reg [6:0] i_d;
    reg       v_d;
    reg signed [8:0] best;             // -129 초기화로 첫 값이 무조건 선택되게
    reg [5:0] best_idx;

    assign rd_addr = {6'b0, i};

    always @(posedge clk) begin
        if (!rstn) begin
            state <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            i <= 0; i_d <= 0; v_d <= 1'b0;
            best <= -9'sd129; best_idx <= 6'd0;
            target_valid <= 1'b0; target_x <= 0; target_y <= 0; target_score <= 0;
        end else begin
            done <= 1'b0;
            v_d  <= (state == S_RUN);
            i_d  <= i;

            if (v_d) begin
                if ($signed({rd_data[7], rd_data}) > best) begin
                    best     <= $signed({rd_data[7], rd_data});
                    best_idx <= i_d[5:0];
                end
            end

            case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy <= 1'b1;
                    i <= 0;
                    best <= -9'sd129;
                    best_idx <= 6'd0;
                    state <= S_RUN;
                end
            end
            S_RUN: begin
                if (i == 7'd63) state <= S_DRAIN;
                else i <= i + 7'd1;
            end
            S_DRAIN: state <= S_DONE;
            S_DONE: begin
                // spec 14.1 : cell 중심 좌표
                target_x     <= {best_idx[2:0], 3'b100};
                target_y     <= {best_idx[5:3], 3'b100};
                target_score <= best[7:0];
                target_valid <= (best > $signed({score_th[7], score_th}));
                done  <= 1'b1;
                busy  <= 1'b0;
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
