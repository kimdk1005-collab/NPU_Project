// ---------------------------------------------------------------------------
// tb_servo_pwm.v -- servo_pwm 단위 테스트
//
//  시뮬레이션 시간을 줄이기 위해 CLK_HZ = 1 MHz 로 축소한다.
//  이때 1 cycle = 1 us 이므로 "펄스폭 cycle 수 = 펄스폭 us" 가 된다.
//
//  검증 항목 (handoff/C_EVENT_CONTROL_HANDOFF.md §3)
//    1. Frame 주기 = 20 ms (50 Hz)
//    2. pos = 128 -> 1500 us (중립)
//    3. Safe Angle Limit Clamp (하한/상한)
//    4. Clamp 범위 안의 값은 그대로 통과
//    5. en = 0 이면 펄스 없음
//
//  샘플링은 경합을 피하려고 전부 negedge 에서 한다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_servo_pwm;

    localparam integer CLK_HZ       = 1_000_000;   // 1 cycle = 1 us
    localparam integer PWM_HZ       = 50;
    localparam integer PULSE_MIN_US = 1000;
    localparam integer PULSE_MAX_US = 2000;
    localparam integer SPAN_US      = PULSE_MAX_US - PULSE_MIN_US;
    localparam integer PERIOD_CYC   = CLK_HZ / PWM_HZ;   // 20000
    localparam integer LIM_LO       = 32;
    localparam integer LIM_HI       = 224;

    reg        clk   = 1'b0;
    reg        rst_n = 1'b0;
    reg        en    = 1'b1;
    reg  [7:0] pos   = 8'd128;
    wire       pwm_out, frame_tick;

    integer errors  = 0;
    integer m_high  = 0;   // 측정된 High cycle 수
    integer m_total = 0;   // 측정된 Frame cycle 수

    always #500 clk = ~clk;      // 1 MHz

    servo_pwm #(
        .CLK_HZ       (CLK_HZ),
        .PWM_HZ       (PWM_HZ),
        .PULSE_MIN_US (PULSE_MIN_US),
        .PULSE_MAX_US (PULSE_MAX_US),
        .POS_MIN      (LIM_LO),
        .POS_MAX      (LIM_HI)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (en),
        .pos        (pos),
        .pwm_out    (pwm_out),
        .frame_tick (frame_tick)
    );

    // 기대 펄스폭 : HANDOFF §3.3 의 스케일링 식과 동일해야 한다
    function integer expect_us(input integer p);
        integer c;
        begin
            c = (p < LIM_LO) ? LIM_LO : (p > LIM_HI) ? LIM_HI : p;
            expect_us = PULSE_MIN_US + ((c * SPAN_US) / 256);
        end
    endfunction

    // -----------------------------------------------------------------------
    // Frame 하나를 통째로 측정한다
    // -----------------------------------------------------------------------
    task measure;
        begin
            @(posedge frame_tick);   // Frame 경계 정렬
            @(negedge clk);          // tick 이 떠 있는 사이클 소비
            m_high  = 0;
            m_total = 0;
            forever begin
                @(negedge clk);
                m_total = m_total + 1;
                if (pwm_out) m_high = m_high + 1;
                if (frame_tick) disable measure;
            end
        end
    endtask

    // pos 변경 후 Frame 경계에서 latch 되므로 한 Frame 버리고 다음 것을 본다
    task settle_measure;
        begin
            measure;
            measure;
        end
    endtask

    task check(input [8*32-1:0] name, input integer got, input integer exp_v,
               input integer tol);
        begin
            if (got >= exp_v - tol && got <= exp_v + tol)
                $display("  [PASS] %0s : %0d us  (기대 %0d +/- %0d)", name, got, exp_v, tol);
            else begin
                $display("  [FAIL] %0s : %0d us  (기대 %0d +/- %0d)", name, got, exp_v, tol);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("=== tb_servo_pwm : C HANDOFF §3 Servo Command Format ===");
        $display("    CLK=%0d Hz  PWM=%0d Hz  pulse %0d~%0d us  limit pos %0d~%0d",
                 CLK_HZ, PWM_HZ, PULSE_MIN_US, PULSE_MAX_US, LIM_LO, LIM_HI);
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        // 1) Frame 주기
        pos = 8'd128;
        settle_measure;
        check("frame period    ", m_total, PERIOD_CYC, 0);

        // 2) 중립
        check("pos=128 (neutral)", m_high, expect_us(128), 2);

        // 3) 하한 Clamp : pos=0 -> LIM_LO
        pos = 8'd0;
        settle_measure;
        check("pos=0   -> clamp lo", m_high, expect_us(0), 2);

        // 4) 상한 Clamp : pos=255 -> LIM_HI
        pos = 8'd255;
        settle_measure;
        check("pos=255 -> clamp hi", m_high, expect_us(255), 2);

        // 5) 범위 안의 값은 그대로
        pos = 8'd192;
        settle_measure;
        check("pos=192 (in range)", m_high, expect_us(192), 2);

        // 6) en = 0 -> 펄스 없음
        en = 1'b0;
        settle_measure;
        check("en=0  (no pulse)", m_high, 0, 0);

        $display("=== 결과 : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_servo_pwm FAILED");
        $finish;
    end

    initial begin
        #600_000_000;                      // 600 ms 안전 타임아웃
        $fatal(1, "tb_servo_pwm TIMEOUT");
    end

endmodule

`default_nettype wire
