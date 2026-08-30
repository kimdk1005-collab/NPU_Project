`timescale 1ns/1ps
//=====================================================================
// npu_conv_dense : Dense INT8 Conv Engine (Conv1~Conv4 공용)
// 담당: A
// 규격: TEAM_COMMON_AI_INTEGRATION_SPEC v1.2  8 / 9 / 18
//
// 구조: output-stationary, 8 PE = 출력채널 8개 병렬
//   매 cycle activation 1byte를 읽어 8개 PE에 broadcast,
//   각 PE는 자기 bank의 weight를 곱해 INT32 누산.
//   tap 순서 = KX -> KY -> IC  (spec 11 weight 순서와 동일 -> weight 주소는 선형 증가)
//
// 상태:  IDLE -> INIT -> ACC -> DRAIN -> WB -> NEXT -> ... -> DONE
//   ACC   : tap 1개/cycle 발행 (BRAM 1cycle 지연 -> 1 cycle 뒤 누산)
//   DRAIN : 마지막 tap 누산
//   WB    : PE 8개 결과를 requantize 해서 1byte/cycle 기록
//=====================================================================
`include "npu_defs.vh"
module npu_conv_dense #(
    parameter NPE = `NPU_NPE
)(
    input  wire         clk,
    input  wire         rstn,
    input  wire         start,
    output reg          busy,
    output reg          done,

    // ---- layer configuration (controller가 상수로 공급) ----
    input  wire [6:0]   cfg_iw,        // 입력 W(=H) : 64/32/16/8
    input  wire [2:0]   cfg_iw_log2,   //             6/5/4/3
    input  wire [5:0]   cfg_ow,        // 출력 W(=H) : 32/16/8/8
    input  wire [2:0]   cfg_ow_log2,   //             5/4/3/3
    input  wire [5:0]   cfg_cin,       // 2/8/16/32
    input  wire [5:0]   cfg_cout,      // 8/16/32/1
    input  wire [2:0]   cfg_nblk,      // ceil(cout/8) = 1/2/4/1
    input  wire [8:0]   cfg_tap,       // cin*k*k = 18/72/144/32
    input  wire [1:0]   cfg_k,         // 3/3/3/1
    input  wire         cfg_s2,        // 1: stride2+pad1, 0: stride1+pad0
    input  wire         cfg_relu,      // Conv1~3=1, Conv4=0
    input  wire [31:0]  cfg_mult,      // requantize multiplier (Q24)
    input  wire [9:0]   cfg_wbase,     // weight bank base offset

    // ---- activation read port (1 cycle latency) ----
    output wire [12:0]  act_raddr,
    input  wire signed [7:0] act_rdata,
    // ---- weight rom read port (1 cycle latency) ----
    output wire [9:0]   w_raddr,
    input  wire [NPE*8-1:0] w_rdata,
    // ---- output activation write port ----
    output reg          out_we,
    output reg  [12:0]  out_waddr,
    output reg  signed [7:0] out_wdata
);
    localparam S_IDLE  = 3'd0, S_INIT = 3'd1, S_ACC  = 3'd2,
               S_DRAIN = 3'd3, S_WB   = 3'd4, S_NEXT = 3'd5, S_DONE = 3'd6;

    reg [2:0] state;

    // 출력 위치 / 출력채널 블록
    reg [5:0] ox, oy;
    reg [2:0] blk;
    reg [9:0] blk_wofs;          // blk * cfg_tap (곱셈기 대신 누적)

    // tap 카운터 : kx -> ky -> ic 순서
    reg [1:0] kx, ky;
    reg [5:0] ic;
    reg [8:0] t;                 // 선형 tap index (weight 주소용)

    reg [3:0] wbc;               // write-back 카운터 0..12
    reg       dcnt;              // DRAIN 카운터 (PE 파이프라인 2단)

    //-----------------------------------------------------------------
    // activation 주소 + padding(zero) 판정
    //-----------------------------------------------------------------
    wire [7:0] oy_str = cfg_s2 ? {oy, 1'b0} : {2'b0, oy};
    wire [7:0] ox_str = cfg_s2 ? {ox, 1'b0} : {2'b0, ox};
    wire signed [8:0] pad = cfg_s2 ? 9'sd1 : 9'sd0;
    wire signed [8:0] iy  = $signed({1'b0, oy_str}) + $signed({7'b0, ky}) - pad;
    wire signed [8:0] ix  = $signed({1'b0, ox_str}) + $signed({7'b0, kx}) - pad;

    wire oob = iy[8] | ix[8] |
               (iy >= $signed({2'b0, cfg_iw})) | (ix >= $signed({2'b0, cfg_iw}));

    wire [4:0]  ic_sh  = {cfg_iw_log2, 1'b0};          // 2*log2(W)
    wire [17:0] a_ic   = {12'b0, ic} << ic_sh;
    wire [17:0] a_row  = {12'b0, iy[5:0]} << cfg_iw_log2;
    assign act_raddr = a_ic[12:0] + a_row[12:0] + {7'b0, ix[5:0]};

    assign w_raddr = cfg_wbase + blk_wofs + {1'b0, t};

    //-----------------------------------------------------------------
    // MAC 파이프라인 : cycle n 주소 발행 -> cycle n+1 누산
    //-----------------------------------------------------------------
    reg mac_v_d, oob_d;
    always @(posedge clk) begin
        if (!rstn) begin mac_v_d <= 1'b0; oob_d <= 1'b0; end
        else begin
            mac_v_d <= (state == S_ACC);
            oob_d   <= oob;
        end
    end
    wire signed [7:0] mac_a = oob_d ? 8'sd0 : act_rdata;
    wire              mac_en = mac_v_d;
    wire              mac_clr = (state == S_INIT);

    wire signed [31:0] acc [0:NPE-1];
    genvar g;
    generate
        for (g = 0; g < NPE; g = g + 1) begin : PE
            npu_pe u_pe (
                .clk(clk), .rstn(rstn), .clr(mac_clr), .en(mac_en),
                .a(mac_a), .b($signed(w_rdata[g*8 +: 8])), .acc(acc[g])
            );
        end
    endgenerate

    //-----------------------------------------------------------------
    // Write-back : acc[j] -> requantize(4단 파이프라인) -> out buffer
    //   wbc 0..7   : PE 8개 결과 발행
    //   wbc 8..12  : 파이프라인 배출 (REQ_LAT=4 + 출력 레지스터 1)
    //-----------------------------------------------------------------
    localparam REQ_LAT = 4;
    localparam WB_LAST = 4'd12;

    wire [2:0] j       = wbc[2:0];
    wire [5:0] oc      = {blk, 3'b000} + {3'b0, j};
    wire [4:0] oc_sh   = {cfg_ow_log2, 1'b0};
    wire [17:0] o_oc   = {12'b0, oc} << oc_sh;
    wire [17:0] o_row  = {12'b0, oy} << cfg_ow_log2;
    wire [12:0] out_addr_c = o_oc[12:0] + o_row[12:0] + {7'b0, ox};

    reg signed [31:0] acc_sel;
    integer m;
    always @(*) begin
        acc_sel = acc[0];
        for (m = 0; m < NPE; m = m + 1)
            if (j == m[2:0]) acc_sel = acc[m];
    end

    wire rq_v_in = (state == S_WB) && (wbc < 4'd8) && (oc < cfg_cout);

    wire              rq_v_out;
    wire signed [7:0] rq_q;
    npu_requant u_req (
        .clk(clk), .rstn(rstn), .v_in(rq_v_in),
        .acc(acc_sel), .mult(cfg_mult), .relu_en(cfg_relu),
        .v_out(rq_v_out), .q(rq_q)
    );

    // 주소는 requantize 지연만큼 같이 밀어준다
    reg [12:0] addr_pipe [0:REQ_LAT-1];
    integer pi;
    always @(posedge clk) begin
        addr_pipe[0] <= out_addr_c;
        for (pi = 1; pi < REQ_LAT; pi = pi + 1)
            addr_pipe[pi] <= addr_pipe[pi-1];
    end

    always @(posedge clk) begin
        if (!rstn) begin
            out_we <= 1'b0; out_waddr <= 13'd0; out_wdata <= 8'sd0;
        end else begin
            out_we    <= rq_v_out;
            out_waddr <= addr_pipe[REQ_LAT-1];
            out_wdata <= rq_q;
        end
    end

    //-----------------------------------------------------------------
    // 메인 FSM
    //-----------------------------------------------------------------
    wire last_tap = (t == cfg_tap - 9'd1);
    wire last_ox  = (ox == cfg_ow - 6'd1);
    wire last_oy  = (oy == cfg_ow - 6'd1);
    wire last_blk = (blk == cfg_nblk - 3'd1);

    always @(posedge clk) begin
        if (!rstn) begin
            state <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            ox <= 0; oy <= 0; blk <= 0; blk_wofs <= 0;
            kx <= 0; ky <= 0; ic <= 0; t <= 0; wbc <= 0; dcnt <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy <= 1'b1;
                    ox <= 0; oy <= 0; blk <= 0; blk_wofs <= 0;
                    state <= S_INIT;
                end
            end
            S_INIT: begin
                kx <= 0; ky <= 0; ic <= 0; t <= 0; dcnt <= 1'b0;
                state <= S_ACC;
            end
            S_ACC: begin
                t <= t + 9'd1;
                if (kx == cfg_k - 2'd1) begin
                    kx <= 0;
                    if (ky == cfg_k - 2'd1) begin
                        ky <= 0;
                        ic <= ic + 6'd1;
                    end else ky <= ky + 2'd1;
                end else kx <= kx + 2'd1;
                if (last_tap) state <= S_DRAIN;
            end
            S_DRAIN: begin
                // npu_pe 가 곱셈/누산 2단이므로 마지막 tap 반영까지 2 cycle 필요
                wbc <= 0;
                if (dcnt == 1'b1) state <= S_WB;
                else dcnt <= dcnt + 1'b1;
            end
            S_WB: begin
                if (wbc == WB_LAST) state <= S_NEXT;
                else wbc <= wbc + 4'd1;
            end
            S_NEXT: begin
                if (last_ox) begin
                    ox <= 0;
                    if (last_oy) begin
                        oy <= 0;
                        if (last_blk) state <= S_DONE;
                        else begin
                            blk      <= blk + 3'd1;
                            blk_wofs <= blk_wofs + {1'b0, cfg_tap};
                            state    <= S_INIT;
                        end
                    end else begin
                        oy    <= oy + 6'd1;
                        state <= S_INIT;
                    end
                end else begin
                    ox    <= ox + 6'd1;
                    state <= S_INIT;
                end
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
