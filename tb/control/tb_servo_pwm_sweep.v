// ---------------------------------------------------------------------------
// tb_servo_pwm_sweep.v -- servo_pwm 동작 범위 관찰용 (파형 확인 목적)
//
//  판정(PASS/FAIL)이 목적인 tb_servo_pwm.v 와 달리, 이 TB 는
//  pos 를 0 -> 255 로 훑으면서 펄스폭이 어떻게 변하는지 눈으로 보기 위한 것이다.
//
//  DUT 를 두 개 둔다.
//    dut_free : POS_MIN=0,  POS_MAX=255   (Clamp 없음, 전체 범위)
//    dut_lim  : POS_MIN=64, POS_MAX=192   (Safe Angle Limit 적용)
//
//  같은 pos 를 넣으므로 파형에서 양끝 구간의 펄스폭 차이가 그대로 보인다.
//  이것이 Safe Angle Limit 이 기구를 지키는 방식이다.
//
//  CLK_HZ = 1 MHz 로 축소 -> 1 cycle = 1 us -> High cycle 수 = 펄스폭 us
//
//  MG996R 기준 참고값
//    Dead band 약 5 us  -> pos 1 단계(약 3.9 us)는 서보가 구분하지 못한다
//    가동 각 약 120도    -> 1000~2000 us 범위
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_servo_pwm_sweep;

    localparam integer CLK_HZ       = 1_000_000;   // 1 cycle = 1 us
    localparam integer PWM_HZ       = 50;
    localparam integer PULSE_MIN_US = 1000;
    localparam integer PULSE_MAX_US = 2000;
    localparam integer PERIOD_CYC   = CLK_HZ / PWM_HZ;   // 20000
    localparam integer LIM_LO       = 64;
    localparam integer LIM_HI       = 192;

    reg        clk   = 1'b0;
    reg        rst_n = 1'b0;
    reg        en    = 1'b1;
    reg  [7:0] pos   = 8'd128;

    wire pwm_free, tick_free;
    wire pwm_lim,  tick_lim;

    // 관찰용 - 파형에서 각도 감각을 잡기 위해 표시
    reg [15:0] pulse_free_us = 0;
    reg [15:0] pulse_lim_us  = 0;

    always #500 clk = ~clk;      // 1 MHz

    servo_pwm #(
        .CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
        .PULSE_MIN_US(PULSE_MIN_US), .PULSE_MAX_US(PULSE_MAX_US),
        .POS_MIN(0), .POS_MAX(255)
    ) dut_free (
        .clk(clk), .rst_n(rst_n), .en(en), .pos(pos),
        .pwm_out(pwm_free), .frame_tick(tick_free)
    );

    servo_pwm #(
        .CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
        .PULSE_MIN_US(PULSE_MIN_US), .PULSE_MAX_US(PULSE_MAX_US),
        .POS_MIN(LIM_LO), .POS_MAX(LIM_HI)
    ) dut_lim (
        .clk(clk), .rst_n(rst_n), .en(en), .pos(pos),
        .pwm_out(pwm_lim), .frame_tick(tick_lim)
    );

    // -----------------------------------------------------------------------
    // 한 Frame 동안 두 DUT 의 High cycle 수를 동시에 센다
    // -----------------------------------------------------------------------
    integer hf, hl, t;

    task measure_both;
        begin
            @(posedge tick_free);
            @(negedge clk);          // tick 사이클 소비
            hf = 0; hl = 0; t = 0;
            forever begin
                @(negedge clk);
                t = t + 1;
                if (pwm_free) hf = hf + 1;
                if (pwm_lim)  hl = hl + 1;
                if (tick_free) disable measure_both;
            end
        end
    endtask

    // pos 변경 후 Frame 경계에서 latch 되므로 한 Frame 버린다
    task step(input [7:0] p);
        begin
            pos = p;
            measure_both;            // 이전 설정이 남은 Frame - 버림
            measure_both;            // 새 pos 가 반영된 Frame
            pulse_free_us = hf[15:0];
            pulse_lim_us  = hl[15:0];
            $display("  %3d  |  %5d us  |  %5d us  |  %s",
                     p, hf, hl, (hf == hl) ? "                         " : "<-- CLAMPED by Safe Limit");
        end
    endtask

    initial begin
        $display("");
        $display("=== servo_pwm 동작 범위 스윕 ===");
        $display("    PWM 50 Hz / 펄스 %0d~%0d us", PULSE_MIN_US, PULSE_MAX_US);
        $display("    dut_free : Clamp 없음 (pos 0~255)");
        $display("    dut_lim  : Safe Angle Limit pos %0d~%0d", LIM_LO, LIM_HI);
        $display("");
        $display("  pos  |  free      |  limited   |");
        $display("  -----+------------+------------+------------------");

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        step(8'd0);
        step(8'd32);
        step(8'd64);
        step(8'd96);
        step(8'd128);
        step(8'd160);
        step(8'd192);
        step(8'd224);
        step(8'd255);

        // en = 0 : 펄스 정지 확인
        $display("");
        $display("  en = 0 (서보 무부하)");
        en = 1'b0;
        step(8'd128);

        en = 1'b1;
        $display("");
        $display("  en = 1 복귀");
        step(8'd128);

        $display("");
        $display("=== 스윕 완료 ===");
        $display("");
        $finish;
    end

    initial begin
        #900_000_000;                 // 900 ms 안전 타임아웃
        $fatal(1, "tb_servo_pwm_sweep TIMEOUT");
    end

endmodule

`default_nettype wire
