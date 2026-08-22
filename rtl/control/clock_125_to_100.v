// ---------------------------------------------------------------------------
// clock_125_to_100.v -- Zybo Z7 PL 125 MHz 입력을 제어용 100 MHz로 변환
//
//  VCO = 125 MHz * 8 = 1000 MHz
//  CLKOUT0 = 1000 MHz / 10 = 100 MHz
//
//  최종 A 통합의 FCLK_CLK0=100 MHz와 같은 제어 주기로 실물 검증하기 위해
//  C 순수 PL 브링업 Top에서만 사용한다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module clock_125_to_100 (
    input  wire clk_125,
    output wire clk_100,
    output wire locked
);

    wire clkfb_raw;
    wire clkfb_buf;
    wire clk100_raw;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(8.000),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(8.000),
        .CLKOUT0_DIVIDE_F(10.000),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKIN1(clk_125),
        .CLKFBIN(clkfb_buf),
        .RST(1'b0),
        .PWRDWN(1'b0),
        .CLKFBOUT(clkfb_raw),
        .CLKOUT0(clk100_raw),
        .LOCKED(locked)
    );

    BUFG u_clkfb_bufg (
        .I(clkfb_raw),
        .O(clkfb_buf)
    );

    BUFG u_clk100_bufg (
        .I(clk100_raw),
        .O(clk_100)
    );

endmodule

`default_nettype wire
