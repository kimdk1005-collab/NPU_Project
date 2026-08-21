// ---------------------------------------------------------------------------
// tb_board_io.v -- board_io 브링업 Top 단위 테스트
//
//  실제 서보에 물리기 전에 조작 로직이 의도대로 도는지 확인한다.
//  비트스트림을 만들기 전에 반드시 통과해야 한다.
//
//  CLK_HZ = 1 MHz 로 축소 -> 1 cycle = 1 us -> High cycle 수 = 펄스폭 us
//  JOG_REPEAT / SWEEP_DIV 는 시뮬 시간을 줄이려고 1 로 덮어쓴다.
//
//  검증 항목
//    1. 전원 인가 직후 en=0 -> 펄스 없음        (서보 무부하로 시작)
//    2. en=1 -> 중립 1500 us  (500 + 2000/2)
//    3. btn[1] 유지 -> 좁은 범위 상한 144 에서 멈춤   (1625 us)
//    4. btn[0] 유지 -> 좁은 범위 하한 112 에서 멈춤   (1375 us)
//    5. sw[2]=1 넓은 범위 -> 상한 224 까지          (2250 us)
//    6. 넓은 범위에서 좁은 범위로 되돌리면 다시 144 로 끌려온다 (안전 방향)
//    7. btn[2] -> 중립 복귀
//    8. led[0] 심장박동 반주기 = 25 frame = 500 ms   (CLK_HZ 검증 수단)
//    9. sweep -> 상한에서 방향이 뒤집힌다
//   10. 선택 안 된 축(TILT)은 중립을 유지한다
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_board_io;

    localparam integer CLK_HZ     = 1_000_000;   // 1 cycle = 1 us
    localparam integer PWM_HZ     = 50;
    localparam integer PERIOD_CYC = CLK_HZ / PWM_HZ;   // 20000
    localparam integer HB_HALF_NS = 25 * 20_000_000;   // 25 frame x 20 ms [ns]

    reg        sysclk = 1'b0;
    reg  [3:0] sw     = 4'b0000;
    reg  [3:0] btn    = 4'b0000;
    wire [3:0] led;
    wire       pan_pwm, tilt_pwm;

    integer errors  = 0;
    integer m_high  = 0;
    integer m_hilt  = 0;
    integer m_total = 0;

    always #500 sysclk = ~sysclk;    // 1 MHz

    board_io #(
        .CLK_HZ     (CLK_HZ),
        .PWM_HZ     (PWM_HZ),
        .JOG_REPEAT (1),             // 시뮬 단축
        .SWEEP_DIV  (1)
    ) dut (
        .sysclk   (sysclk),
        .sw       (sw),
        .btn      (btn),
        .led      (led),
        .pan_pwm  (pan_pwm),
        .tilt_pwm (tilt_pwm)
    );

    // 기대 펄스폭 : servo_pwm 의 스케일링 식과 동일해야 한다
    //  board_io 의 PULSE_MIN_US=500 / PULSE_MAX_US=2500 과 일치해야 한다
    function integer expect_us(input integer p);
        begin
            expect_us = 500 + ((p * 2000) / 256);
        end
    endfunction

    // -----------------------------------------------------------------------
    // Frame 하나를 통째로 측정 (PAN / TILT 동시)
    // -----------------------------------------------------------------------
    task measure;
        begin
            @(posedge dut.frame_tick);
            @(negedge sysclk);
            m_high = 0; m_hilt = 0; m_total = 0;
            forever begin
                @(negedge sysclk);
                m_total = m_total + 1;
                if (pan_pwm)  m_high = m_high + 1;
                if (tilt_pwm) m_hilt = m_hilt + 1;
                if (dut.frame_tick) disable measure;
            end
        end
    endtask

    task run_frames(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge dut.frame_tick);
            @(negedge sysclk);
        end
    endtask

    task check(input [8*36-1:0] name, input integer got, input integer exp_v,
               input integer tol);
        begin
            if (got >= exp_v - tol && got <= exp_v + tol)
                $display("  [PASS] %0s : %0d  (기대 %0d +/- %0d)", name, got, exp_v, tol);
            else begin
                $display("  [FAIL] %0s : %0d  (기대 %0d +/- %0d)", name, got, exp_v, tol);
                errors = errors + 1;
            end
        end
    endtask

    // 4 초를 넘는 시뮬이라 32 bit integer 로는 $time 이 넘친다
    time t0, t1;

    initial begin
        $display("=== tb_board_io : 서보 브링업 Top ===");
        $display("    CLK=%0d Hz  PWM=%0d Hz  좁은범위 112~144  넓은범위 32~224",
                 CLK_HZ, PWM_HZ);

        // 1) 전원 인가 직후 -- en=0
        sw = 4'b0000;
        run_frames(3);
        measure;
        check("en=0 pulse                ", m_high, 0, 0);
        check("frame period              ", m_total, PERIOD_CYC, 0);

        // 2) en=1 -> 중립
        sw[0] = 1'b1;
        measure; measure;
        check("en=1 neutral pos=128      ", m_high, expect_us(128), 2);
        check("led[1] = en               ", led[1], 1, 0);

        // 10) 선택 안 된 TILT 는 중립 유지
        check("TILT holds neutral        ", m_hilt, expect_us(128), 2);

        // 3) btn[1] 유지 -> 좁은 범위 상한 144
        btn[1] = 1'b1;
        run_frames(14);
        btn[1] = 1'b0;
        measure; measure;
        check("jog up -> narrow hi 144   ", m_high, expect_us(144), 2);

        // 4) btn[0] 유지 -> 좁은 범위 하한 112
        btn[0] = 1'b1;
        run_frames(24);
        btn[0] = 1'b0;
        measure; measure;
        check("jog down -> narrow lo 112 ", m_high, expect_us(112), 2);

        // 5) 넓은 범위로 전환 후 상한 224
        sw[2] = 1'b1;
        btn[1] = 1'b1;
        run_frames(64);
        btn[1] = 1'b0;
        measure; measure;
        check("wide -> hi 224            ", m_high, expect_us(224), 2);

        // 6) 좁은 범위로 되돌리면 안전 방향으로 끌려온다
        sw[2] = 1'b0;
        measure; measure;
        check("wide->narrow pulls to 144 ", m_high, expect_us(144), 2);

        // 7) btn[2] -> 중립 복귀
        btn[2] = 1'b1;
        run_frames(3);
        btn[2] = 1'b0;
        measure; measure;
        check("btn[2] -> neutral 128     ", m_high, expect_us(128), 2);

        // 8) 심장박동 반주기 = 25 frame = 500 ms
        @(posedge led[0]);  t0 = $time;
        @(negedge led[0]);  t1 = $time;
        check("heartbeat half period [ms]", (t1 - t0) / 1_000_000, HB_HALF_NS / 1_000_000, 0);

        // 9) sweep -> 상한에서 방향 반전
        sw[1] = 1'b1;
        run_frames(40);
        if (dut.sweep_up === 1'b0)
            $display("  [PASS] sweep reverses at limit      : sweep_up=0");
        else begin
            $display("  [FAIL] sweep reverses at limit      : sweep_up=%b (기대 0)", dut.sweep_up);
            errors = errors + 1;
        end
        measure;
        if (m_high <= expect_us(144) + 2 && m_high >= expect_us(112) - 2)
            $display("  [PASS] sweep stays inside narrow    : %0d us", m_high);
        else begin
            $display("  [FAIL] sweep left narrow range      : %0d us", m_high);
            errors = errors + 1;
        end

        $display("=== 결과 : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_board_io FAILED");
        $finish;
    end

    initial begin
        // 딜레이 리터럴은 32 bit 라 6_000_000_000 을 그대로 쓰면 랩된다.
        // 1e9 씩 나눠서 쌓는다.
        repeat (10) #1_000_000_000;        // 10 s 안전 타임아웃
        $fatal(1, "tb_board_io TIMEOUT");
    end

endmodule

`default_nettype wire
