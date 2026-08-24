// ---------------------------------------------------------------------------
// tb_event_adapter.v -- event_adapter 단위 테스트
//
//  상위 권한 : docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md
//
//  CLK_HZ = 1 MHz 로 축소한다. 1 cycle = 1 us 라 Window 길이를 눈으로 읽을 수 있다.
//
//  검증 항목
//    T1  Binning X -- SPEC §14.1 min(63, floor(x*64/W)) 와 완전 일치
//                     64 / 346 / 640 / 1280 네 해상도의 x 전 좌표를 훑는다
//    T2  Binning Y -- 같은 방식으로 y 전 좌표 (64 / 260 / 480 / 720)
//    T3  범위 밖 이벤트  OOR_POLICY=0 폐기 / OOR_POLICY=1 은 63 으로 물림
//    T4  파이프라인 지연 = 2 cycle
//    T5  Polarity 통과
//    T6  내부 Window 주기 = WINDOW_US
//    T7  Window 당 이벤트 계수 (연속 입력 1 event/clock)
//    T8  외부 Window (WINDOW_SRC=1) -- Level 입력의 상승엣지만 잡는다
//    T9  HANDOFF §1 -- src_valid 와 Window 경계가 같은 clock 이면
//                      그 이벤트는 현재 Window 에 포함된다
//
//  T1/T2 를 "조건식 검사" 대신 전 좌표 훑기로 하는 이유
//    event_adapter 는 나눗셈 대신 역수 곱셈을 쓴다. 정확성 조건을 모듈 안
//    initial 블록이 검사하지만, 그 조건식 자체가 틀렸을 가능성은 조건식으로
//    잡을 수 없다. 실제 정수 나눗셈과 대조하는 것만이 근거가 된다.
//
//  샘플링은 경합을 피하려고 전부 negedge 에서 한다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_event_adapter;

    localparam integer CLK_HZ      = 1_000_000;   // 1 cycle = 1 us
    localparam integer SRC_W       = 11;          // 최대 2047
    localparam integer WIN_SHORT   = 100;         // us -> 100 cycle
    localparam integer WIN_LONG    = 10_000;
    localparam integer CNT_W       = 20;

    reg              clk   = 1'b0;
    reg              rst_n = 1'b0;
    reg              src_valid = 1'b0;
    reg  [SRC_W-1:0] src_x = 0;
    reg  [SRC_W-1:0] src_y = 0;
    reg              src_pol = 1'b0;
    reg              src_wend = 1'b0;

    integer errors    = 0;   // 최종 판정. 절대 0 으로 되돌리지 않는다
    integer sweep_err = 0;   // T1/T2 훑기 전용. 구간마다 초기화한다
    integer shown     = 0;
    integer i, m_cyc;

    always #500 clk = ~clk;      // 1 MHz

    // -----------------------------------------------------------------------
    // DUT -- Binning 검증용 4 해상도. 전부 내부 Window, 긴 주기 (Binning 과 무관)
    // -----------------------------------------------------------------------
    wire       v64,  v346,  v640,  v720,  vclp;
    wire [5:0] x64,  x346,  x640,  x720,  xclp;
    wire [5:0] y64,  y346,  y640,  y720,  yclp;

    event_adapter #(.SENSOR_W(64),   .SENSOR_H(64),  .SRC_COORD_W(SRC_W),
                    .CLK_HZ(CLK_HZ), .WINDOW_US(WIN_LONG))
      d64  (.clk(clk), .rst_n(rst_n), .src_valid(src_valid), .src_x(src_x),
            .src_y(src_y), .src_pol(src_pol), .src_window_end(1'b0),
            .event_valid(v64), .event_x(x64), .event_y(y64),
            .event_polarity(), .event_window_end(),
            .win_evt_count(), .win_drop_count());

    event_adapter #(.SENSOR_W(346),  .SENSOR_H(260), .SRC_COORD_W(SRC_W),
                    .CLK_HZ(CLK_HZ), .WINDOW_US(WIN_LONG))
      d346 (.clk(clk), .rst_n(rst_n), .src_valid(src_valid), .src_x(src_x),
            .src_y(src_y), .src_pol(src_pol), .src_window_end(1'b0),
            .event_valid(v346), .event_x(x346), .event_y(y346),
            .event_polarity(), .event_window_end(),
            .win_evt_count(), .win_drop_count());

    event_adapter #(.SENSOR_W(640),  .SENSOR_H(480), .SRC_COORD_W(SRC_W),
                    .CLK_HZ(CLK_HZ), .WINDOW_US(WIN_LONG))
      d640 (.clk(clk), .rst_n(rst_n), .src_valid(src_valid), .src_x(src_x),
            .src_y(src_y), .src_pol(src_pol), .src_window_end(1'b0),
            .event_valid(v640), .event_x(x640), .event_y(y640),
            .event_polarity(), .event_window_end(),
            .win_evt_count(), .win_drop_count());

    event_adapter #(.SENSOR_W(1280), .SENSOR_H(720), .SRC_COORD_W(SRC_W),
                    .CLK_HZ(CLK_HZ), .WINDOW_US(WIN_LONG))
      d720 (.clk(clk), .rst_n(rst_n), .src_valid(src_valid), .src_x(src_x),
            .src_y(src_y), .src_pol(src_pol), .src_window_end(1'b0),
            .event_valid(v720), .event_x(x720), .event_y(y720),
            .event_polarity(), .event_window_end(),
            .win_evt_count(), .win_drop_count());

    // OOR_POLICY = 1 (SPEC §14.1 의 min(63,.) 를 문자 그대로 적용)
    event_adapter #(.SENSOR_W(640),  .SENSOR_H(480), .SRC_COORD_W(SRC_W),
                    .CLK_HZ(CLK_HZ), .WINDOW_US(WIN_LONG), .OOR_POLICY(1))
      dclp (.clk(clk), .rst_n(rst_n), .src_valid(src_valid), .src_x(src_x),
            .src_y(src_y), .src_pol(src_pol), .src_window_end(1'b0),
            .event_valid(vclp), .event_x(xclp), .event_y(yclp),
            .event_polarity(), .event_window_end(),
            .win_evt_count(), .win_drop_count());

    // -----------------------------------------------------------------------
    // DUT -- Window 검증용. 짧은 주기로 시뮬 시간을 줄인다
    // -----------------------------------------------------------------------
    wire             vw, ww, pw;
    wire [CNT_W-1:0] cw, dw;

    event_adapter #(.SENSOR_W(640), .SENSOR_H(480), .SRC_COORD_W(SRC_W),
                    .CLK_HZ(CLK_HZ), .WINDOW_US(WIN_SHORT), .EVT_CNT_W(CNT_W))
      dwin (.clk(clk), .rst_n(rst_n), .src_valid(src_valid), .src_x(src_x),
            .src_y(src_y), .src_pol(src_pol), .src_window_end(1'b0),
            .event_valid(vw), .event_x(), .event_y(),
            .event_polarity(pw), .event_window_end(ww),
            .win_evt_count(cw), .win_drop_count(dw));

    // 외부 Window
    wire             ve, we;
    wire [CNT_W-1:0] ce;

    event_adapter #(.SENSOR_W(640), .SENSOR_H(480), .SRC_COORD_W(SRC_W),
                    .CLK_HZ(CLK_HZ), .WINDOW_SRC(1), .EVT_CNT_W(CNT_W))
      dext (.clk(clk), .rst_n(rst_n), .src_valid(src_valid), .src_x(src_x),
            .src_y(src_y), .src_pol(src_pol), .src_window_end(src_wend),
            .event_valid(ve), .event_x(), .event_y(),
            .event_polarity(), .event_window_end(we),
            .win_evt_count(ce), .win_drop_count());

    // -----------------------------------------------------------------------
    // 참조 모델 -- SPEC §14.1
    // -----------------------------------------------------------------------
    function integer ref_bin(input integer raw, input integer sensor);
        integer v;
        begin
            v = (raw * 64) / sensor;
            ref_bin = (v > 63) ? 63 : v;
        end
    endfunction

    // -----------------------------------------------------------------------
    // 검사 helper
    // -----------------------------------------------------------------------
    // 축 하나에 대해 DUT 하나를 검사. drop 정책(OOR_POLICY=0) 기준
    task chk_axis(input [8*8-1:0] nm, input integer sensor, input integer raw,
                  input gotv, input [5:0] gotb);
        reg       expv;
        reg [5:0] expb;
        begin
            expv = (raw < sensor);
            expb = ref_bin(raw, sensor);
            if (gotv !== expv) begin
                sweep_err = sweep_err + 1;
                if (shown < 10) begin
                    $display("  [FAIL] %0s raw=%0d -> valid=%b (기대 %b)",
                             nm, raw, gotv, expv);
                    shown = shown + 1;
                end
            end else if (expv && gotb !== expb) begin
                sweep_err = sweep_err + 1;
                if (shown < 10) begin
                    $display("  [FAIL] %0s raw=%0d -> bin=%0d (기대 %0d)",
                             nm, raw, gotb, expb);
                    shown = shown + 1;
                end
            end
        end
    endtask

    task check_int(input [8*40-1:0] nm, input integer got, input integer exp_v);
        begin
            if (got === exp_v)
                $display("  [PASS] %0s : %0d", nm, got);
            else begin
                $display("  [FAIL] %0s : %0d  (기대 %0d)", nm, got, exp_v);
                errors = errors + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // 자극 helper
    // -----------------------------------------------------------------------
    // 이벤트 1 개를 1 cycle 동안 넣는다. 복귀 시점에 이벤트는 stage0 에 있다
    task send_one(input [SRC_W-1:0] x, input [SRC_W-1:0] y, input pol);
        begin
            @(negedge clk);
            src_x = x; src_y = y; src_pol = pol; src_valid = 1'b1;
            @(negedge clk);
            src_valid = 1'b0;
        end
    endtask

    // 연속 n cycle 동안 이벤트를 넣는다 (1 event/clock, backpressure 없음 확인)
    task send_burst(input integer n, input [SRC_W-1:0] x, input [SRC_W-1:0] y);
        integer k;
        begin
            @(negedge clk);
            src_x = x; src_y = y; src_pol = 1'b1;
            for (k = 0; k < n; k = k + 1) begin
                src_valid = 1'b1;
                @(negedge clk);
            end
            src_valid = 1'b0;
        end
    endtask

    // 다음 Window 경계까지 기다린다.
    // 반드시 1 negedge 를 먼저 소비한다. 직전 루프가 ww=1 인 지점에서 끝났으면
    // 그냥 while(!ww) 로는 즉시 통과해 같은 Window 를 두 번 보게 된다.
    task wait_wend;
        begin
            @(negedge clk);
            while (!ww) @(negedge clk);
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    initial begin
        $display("=== tb_event_adapter : SPEC v1.2 §6.1 / §14.1 ===");
        do_reset;

        // ---------------------------------------------------------------
        // T1  Binning X -- 네 해상도의 x 전 좌표
        // ---------------------------------------------------------------
        shown = 0; sweep_err = 0;
        for (i = 0; i < 1280; i = i + 1) begin
            send_one(i[SRC_W-1:0], 11'd0, 1'b1);
            @(negedge clk);                     // stage1 에 도달
            chk_axis("d64  x",   64, i, v64,  x64);
            chk_axis("d346 x",  346, i, v346, x346);
            chk_axis("d640 x",  640, i, v640, x640);
            chk_axis("d720 x", 1280, i, v720, x720);
        end
        check_int("T1 Binning X  0..1279  x 4 sensors", sweep_err, 0);

        // ---------------------------------------------------------------
        // T2  Binning Y
        // ---------------------------------------------------------------
        shown = 0; sweep_err = 0;
        for (i = 0; i < 720; i = i + 1) begin
            send_one(11'd0, i[SRC_W-1:0], 1'b0);
            @(negedge clk);
            chk_axis("d64  y",  64, i, v64,  y64);
            chk_axis("d346 y", 260, i, v346, y346);
            chk_axis("d640 y", 480, i, v640, y640);
            chk_axis("d720 y", 720, i, v720, y720);
        end
        check_int("T2 Binning Y  0..719   x 4 sensors", sweep_err, 0);

        // ---------------------------------------------------------------
        // T3  범위 밖 정책. x=700 은 640x480 기준 범위 밖이다
        // ---------------------------------------------------------------
        send_one(11'd700, 11'd10, 1'b1);
        @(negedge clk);
        check_int("T3 OOR  DROP  : event_valid", v640, 0);
        check_int("T3 OOR  CLAMP : event_valid", vclp, 1);
        check_int("T3 OOR  CLAMP : x = min(63,..)", xclp, 63);
        check_int("T3 OOR  CLAMP : y passthrough", yclp, ref_bin(10, 480));

        // 범위 안이면 두 정책이 같은 값을 낸다
        send_one(11'd639, 11'd479, 1'b1);
        @(negedge clk);
        check_int("T3 in-range DROP  : x", x640, 63);
        check_int("T3 in-range CLAMP : x", xclp, 63);

        // ---------------------------------------------------------------
        // T4  파이프라인 지연 = 2 cycle
        // ---------------------------------------------------------------
        send_one(11'd320, 11'd240, 1'b1);       // 복귀 시점 = 입력 1 cycle 뒤
        check_int("T4 latency  1 cycle : valid", v640, 0);
        @(negedge clk);
        check_int("T4 latency  2 cycle : valid", v640, 1);
        check_int("T4 x = floor(320*64/640)", x640, ref_bin(320, 640));
        check_int("T4 y = floor(240*64/480)", y640, ref_bin(240, 480));
        @(negedge clk);
        check_int("T4 latency  3 cycle : deassert", v640, 0);

        // ---------------------------------------------------------------
        // T5  Polarity 통과
        // ---------------------------------------------------------------
        send_one(11'd100, 11'd100, 1'b1);
        @(negedge clk);
        check_int("T5 polarity = 1", pw, 1);
        send_one(11'd100, 11'd100, 1'b0);
        @(negedge clk);
        check_int("T5 polarity = 0", pw, 0);

        // ---------------------------------------------------------------
        // T6  내부 Window 주기
        // ---------------------------------------------------------------
        do_reset;
        @(negedge clk);
        while (!ww) @(negedge clk);             // Window 경계 정렬
        m_cyc = 0;
        @(negedge clk); m_cyc = 1;
        while (!ww) begin
            @(negedge clk);
            m_cyc = m_cyc + 1;
        end
        check_int("T6 window period [cycle]", m_cyc, WIN_SHORT);

        // ---------------------------------------------------------------
        // T7  Window 당 이벤트 계수 (연속 1 event/clock)
        // ---------------------------------------------------------------
        do_reset;
        @(negedge clk);
        wait_wend;                              // 새 Window 시작 직후
        send_burst(50, 11'd320, 11'd240);       // 범위 안 50 개 연속
        send_burst(7,  11'd999, 11'd240);       // 범위 밖 7 개 연속
        wait_wend;                              // 이 Window 가 끝날 때까지
        check_int("T7 win_evt_count",  cw, 50);
        check_int("T7 win_drop_count", dw, 7);

        // 다음 Window 는 비어 있어야 한다 (계수기 초기화 확인)
        wait_wend;
        check_int("T7 next window : counter cleared", cw, 0);

        // ---------------------------------------------------------------
        // T8  외부 Window -- Level 입력이어도 상승엣지 1 회만 잡는다
        // ---------------------------------------------------------------
        do_reset;
        send_one(11'd320, 11'd240, 1'b1);       // 이벤트 1 개
        @(negedge clk);
        src_wend = 1'b1;                        // Level 로 3 cycle 유지
        repeat (3) @(negedge clk);
        src_wend = 1'b0;
        @(negedge clk);
        check_int("T8 external window : count", ce, 1);

        // ---------------------------------------------------------------
        // T9  HANDOFF §1 -- 같은 clock 의 이벤트는 현재 Window 에 포함
        // ---------------------------------------------------------------
        do_reset;
        send_one(11'd320, 11'd240, 1'b1);       // 먼저 1 개

        @(negedge clk);
        src_x = 11'd320; src_y = 11'd240; src_pol = 1'b1;
        src_valid = 1'b1;                       // 이벤트와 Window 경계를
        src_wend  = 1'b1;                       //   같은 clock 에 준다
        @(negedge clk);
        src_valid = 1'b0;
        src_wend  = 1'b0;

        @(negedge clk);                         // stage1 도달
        check_int("T9 event_valid     w/ wend",      ve, 1);
        check_int("T9 event_window_end w/ wend", we, 1);
        check_int("T9 counted in current win",     ce, 2);

        // ---------------------------------------------------------------
        $display("=== 결과 : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_event_adapter FAILED");
        $finish;
    end

    initial begin
        #200_000_000;                           // 200 ms 안전 타임아웃
        $fatal(1, "tb_event_adapter TIMEOUT");
    end

endmodule

`default_nettype wire
