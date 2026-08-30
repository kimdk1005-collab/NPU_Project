`timescale 1ns/1ps
//=====================================================================
// npu_pe : INT8 x INT8 -> INT32 누산 MAC 1개 (2단 파이프라인)
// 담당: A
// PE 8개가 같은 activation을 broadcast 받고 각자 다른 출력채널 weight를
// 곱한다 (output-stationary).
//
// 곱셈과 32bit 누산을 한 cycle에 다 하면
//   BRAM -> mux -> 8x8 mult -> 32bit adder -> FF
// 경로가 10.3ns 라 100MHz 를 못 맞춘다. 곱셈 결과를 한 번 끊는다.
//   S1 : p   <= a * b
//   S2 : acc <= acc + p
// en 을 준 cycle 기준으로 acc 는 2 cycle 뒤에 반영된다.
//
// use_dsp="yes" : 이 속성이 없으면 Vivado 가 PE 8개 중 4개만 DSP48 로 뽑고
// 나머지 4개를 LUT/CARRY4 곱셈기로 만들어 그쪽이 critical path 가 된다.
// DSP 는 220개 중 8개만 쓰므로 전부 DSP 로 강제하는 것이 이득이다.
//=====================================================================
(* use_dsp = "yes" *)
module npu_pe (
    input  wire               clk,
    input  wire               rstn,
    input  wire               clr,      // 누산기 초기화
    input  wire               en,       // 이번 cycle a/b 가 유효
    input  wire signed  [7:0] a,        // activation
    input  wire signed  [7:0] b,        // weight
    output reg  signed [31:0] acc
);
    reg signed [15:0] p;
    reg               p_v;

    always @(posedge clk) begin
        if (!rstn) begin
            p <= 16'sd0; p_v <= 1'b0; acc <= 32'sd0;
        end else begin
            p   <= a * b;
            p_v <= en;
            if (p_v) acc <= acc + p;
            if (clr) begin              // clr 이 가장 우선
                acc <= 32'sd0;
                p_v <= 1'b0;
            end
        end
    end
endmodule
