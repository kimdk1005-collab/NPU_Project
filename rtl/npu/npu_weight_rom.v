`timescale 1ns/1ps
//=====================================================================
// npu_weight_rom : INT8 weight ROM, 8 bank
// 담당: A
// bank j = (out_channel % 8 == j) 인 weight만 모아둔 것.
// PE 8개가 "같은 주소"를 동시에 읽으면 8개 출력채널 weight가 나온다.
// 주소 = wbase[layer] + oc_blk*(CIN*K*K) + (ic*K*K + ky*K + kx)
//      -> spec 11 의 OIHW 순서를 tools/pack_weights.py 가 변환해 둔 것
// 읽기 지연 1 cycle
//=====================================================================
`include "npu_defs.vh"
module npu_weight_rom #(
    parameter NPE   = `NPU_NPE,
    parameter DEPTH = `NPU_WROM_DEPTH,
    parameter AW    = `NPU_WROM_AW
)(
    input  wire            clk,
    input  wire [AW-1:0]   addr,
    output wire [NPE*8-1:0] dout      // {bank7, ..., bank0}
);
    genvar g;
    generate
        for (g = 0; g < NPE; g = g + 1) begin : BANK
            (* rom_style = "block" *) reg signed [7:0] mem [0:DEPTH-1];
            reg signed [7:0] q;
            initial begin : LOAD
                case (g)
                    0: $readmemh({`NPU_WEIGHT_DIR, "w_bank0.mem"}, mem);
                    1: $readmemh({`NPU_WEIGHT_DIR, "w_bank1.mem"}, mem);
                    2: $readmemh({`NPU_WEIGHT_DIR, "w_bank2.mem"}, mem);
                    3: $readmemh({`NPU_WEIGHT_DIR, "w_bank3.mem"}, mem);
                    4: $readmemh({`NPU_WEIGHT_DIR, "w_bank4.mem"}, mem);
                    5: $readmemh({`NPU_WEIGHT_DIR, "w_bank5.mem"}, mem);
                    6: $readmemh({`NPU_WEIGHT_DIR, "w_bank6.mem"}, mem);
                    7: $readmemh({`NPU_WEIGHT_DIR, "w_bank7.mem"}, mem);
                endcase
            end
            always @(posedge clk) q <= mem[addr];
            assign dout[g*8 +: 8] = q;
        end
    endgenerate
endmodule
