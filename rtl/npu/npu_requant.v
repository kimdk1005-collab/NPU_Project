`timescale 1ns/1ps
//=====================================================================
// npu_requant : INT32 accumulator -> INT8 activation  (4-stage pipeline)
// 담당: A
// 규격: TEAM_COMMON_AI_INTEGRATION_SPEC v1.2  9.3 / 9.4 / 9.5
//
//   부호 분리 -> |acc| * M -> +2^23 -> >>24 -> 부호 복원 -> ReLU -> Clamp
//   (단순 산술 시프트를 쓰지 않는 이유: 음수 반올림이 Python golden과 달라짐)
//
// 조합으로 만들면 32x32 곱셈 경로가 20.6ns 라 100MHz 를 못 맞춘다.
// 곱셈을 32x16 두 개로 쪼개고 4단으로 나눈다.
//   S1 : abs / 입력 래치
//   S2 : 부분곱 2개 (DSP MREG 흡수)
//   S3 : 부분곱 합 + 반올림 상수
//   S4 : shift / 부호복원 / ReLU / Clamp
// LAT = 4 cycle.  v_in 을 넣으면 4 cycle 뒤 v_out 과 함께 q 가 나온다.
//=====================================================================
module npu_requant (
    input  wire               clk,
    input  wire               rstn,
    input  wire               v_in,
    input  wire signed [31:0] acc,        // INT32 accumulator
    input  wire        [31:0] mult,       // unsigned Q24 multiplier (spec 9.4)
    input  wire               relu_en,    // 1: Conv1~3, 0: Conv4
    output reg                v_out,
    output reg  signed  [7:0] q           // INT8 activation
);
    localparam LAT = 4;

    // ---------------- S1 : abs ----------------
    wire [31:0] mag_c = acc[31] ? (~acc + 32'd1) : acc;
    reg         v1, neg1, relu1;
    reg  [31:0] mag1, mult1;

    // ---------------- S2 : 부분곱 ----------------
    reg         v2, neg2, relu2;
    reg  [47:0] p_lo2, p_hi2;

    // ---------------- S3 : 합 + 반올림 ----------------
    reg         v3, neg3, relu3;
    reg  [63:0] sum3;

    // ---------------- S4 : shift / clamp ----------------
    wire [39:0]       sh4  = sum3[63:24];
    wire signed [40:0] val4 = neg3 ? -$signed({1'b0, sh4}) : $signed({1'b0, sh4});
    wire signed [40:0] r4   = (relu3 && val4[40]) ? 41'sd0 : val4;
    wire signed  [7:0] q4   = (r4 >  41'sd127) ?  8'sd127 :
                              (r4 < -41'sd128) ? -8'sd128 : r4[7:0];

    always @(posedge clk) begin
        if (!rstn) begin
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v_out <= 1'b0; q <= 8'sd0;
        end else begin
            // S1
            v1    <= v_in;
            neg1  <= acc[31];
            relu1 <= relu_en;
            mag1  <= mag_c;
            mult1 <= mult;
            // S2
            v2    <= v1;
            neg2  <= neg1;
            relu2 <= relu1;
            p_lo2 <= mag1 * mult1[15:0];
            p_hi2 <= mag1 * mult1[31:16];
            // S3
            v3    <= v2;
            neg3  <= neg2;
            relu3 <= relu2;
            sum3  <= {16'd0, p_lo2} + {p_hi2, 16'd0} + 64'h0000_0000_0080_0000;
            // S4
            v_out <= v3;
            q     <= q4;
        end
    end
endmodule
