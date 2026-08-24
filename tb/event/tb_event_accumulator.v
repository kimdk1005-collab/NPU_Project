// ---------------------------------------------------------------------------
// tb_event_accumulator.v -- event_accumulator 단위 테스트
//
//  상위 권한 : docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md
//  규격     : docs/D3_FREEZE_REQUEST_A_001.md / docs/C_TO_A_DELIVERY_SPEC.md §2
//
//  검증 방식
//    TB 안에 참조 Tensor(ref_mem)를 두고 이벤트를 넣을 때마다 같은 규칙으로
//    갱신한다. window_end 에서 그것을 exp_mem 으로 확정하고, DUT 가 전송한
//    8192 byte 를 got_mem 에 받아 **전량 대조**한다.
//    셀 하나라도 다르면 D3 Golden 비교가 깨지므로 전수 비교가 맞다.
//
//  검증 항목
//    T1  INIT 완료 후 acc_ready
//    T2  주소식 addr = (pol<<12)|(y<<6)|x
//    T3  같은 좌표 누적
//    T4  ** 연속 같은 좌표 (RMW 포워딩) ** -- 이 TB 의 핵심
//    T5  127 포화 (Wrap 금지)
//    T6  Positive / Negative 채널 분리
//    T7  전송 8192 byte 전량 대조 + 주소 순서 0->8191
//    T8  tensor_start 1 cycle pulse
//    T9  npu_busy 동안 tensor_we 금지
//    T10 Ping-Pong -- 전송 중 들어온 이벤트가 다음 Window 에 살아 있는가
//    T11 버퍼 초기화 -- 다음 Window 가 이전 값에 오염되지 않는가
//    T12 무작위 스트림 전량 대조
//
//  샘플링은 경합을 피하려고 전부 negedge 에서 한다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_event_accumulator;

    localparam integer DEPTH   = 8192;
    localparam integer SAT_MAX = 127;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         ev_v = 1'b0;
    reg  [5:0]  ev_x = 6'd0, ev_y = 6'd0;
    reg         ev_p = 1'b0;
    reg         ev_we = 1'b0;          // event_window_end
    reg         npu_busy = 1'b0;

    wire        t_we, t_start, acc_ready, overrun;
    wire [12:0] t_addr;
    wire signed [7:0] t_data;

    integer errors = 0;
    integer i, k;

    always #5 clk = ~clk;              // 100 MHz

    event_accumulator dut (
        .clk(clk), .rst_n(rst_n),
        .event_valid(ev_v), .event_x(ev_x), .event_y(ev_y),
        .event_polarity(ev_p), .event_window_end(ev_we),
        .npu_busy(npu_busy),
        .tensor_we(t_we), .tensor_addr(t_addr),
        .tensor_data(t_data), .tensor_start(t_start),
        .acc_ready(acc_ready), .overrun(overrun)
    );

    // -----------------------------------------------------------------------
    // 참조 모델
    // -----------------------------------------------------------------------
    reg [7:0] ref_mem [0:DEPTH-1];     // 지금 쌓이는 중
    reg [7:0] exp_mem [0:DEPTH-1];     // window_end 에 확정
    reg [7:0] got_mem [0:DEPTH-1];     // DUT 가 보낸 것

    integer cap_n    = 0;              // 전송 byte 수
    integer addr_err = 0;              // 주소 순서 위반
    integer busy_err = 0;              // npu_busy 중 쓰기 위반

    function [7:0] sat_inc(input [7:0] v);
        sat_inc = (v >= SAT_MAX[7:0]) ? SAT_MAX[7:0] : (v + 8'd1);
    endfunction

    // 전송 감시 -- DUT 가 내보내는 것을 그대로 받아 적는다
    always @(negedge clk) begin
        if (t_we) begin
            got_mem[t_addr] = t_data;
            if (t_addr !== cap_n[12:0]) addr_err = addr_err + 1;
            cap_n = cap_n + 1;
        end
        if (npu_busy && t_we) busy_err = busy_err + 1;
    end

    // -----------------------------------------------------------------------
    // 자극 helper -- negedge 에서 호출하고 negedge 에서 반환한다.
    // 연달아 호출하면 back-to-back 이벤트가 된다.
    // -----------------------------------------------------------------------
    task ev_cycle(input v, input [5:0] x, input [5:0] y, input p);
        begin
            ev_v = v; ev_x = x; ev_y = y; ev_p = p;
            if (v) ref_mem[{p, y, x}] = sat_inc(ref_mem[{p, y, x}]);
            @(negedge clk);
            ev_v = 1'b0;
        end
    endtask

    task idle(input integer n);
        begin
            ev_v = 1'b0;
            repeat (n) @(negedge clk);
        end
    endtask

    // window_end. 같은 clock 에 이벤트를 함께 넣을 수 있다 (HANDOFF §1)
    task window_end(input v, input [5:0] x, input [5:0] y, input p);
        integer j;
        begin
            ev_we = 1'b1;
            ev_v  = v; ev_x = x; ev_y = y; ev_p = p;
            if (v) ref_mem[{p, y, x}] = sat_inc(ref_mem[{p, y, x}]);
            // 이 이벤트까지가 현재 Window 다
            for (j = 0; j < DEPTH; j = j + 1) begin
                exp_mem[j] = ref_mem[j];
                ref_mem[j] = 8'd0;
            end
            cap_n    = 0;
            addr_err = 0;
            @(negedge clk);
            ev_we = 1'b0;
            ev_v  = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------------
    task check_int(input [8*44-1:0] nm, input integer got, input integer exp_v);
        begin
            if (got === exp_v) $display("  [PASS] %0s : %0d", nm, got);
            else begin
                $display("  [FAIL] %0s : %0d  (expected %0d)", nm, got, exp_v);
                errors = errors + 1;
            end
        end
    endtask

    // 전송된 8192 byte 를 참조와 전량 대조
    task compare_tensor(input [8*44-1:0] nm);
        integer bad, shown, nz;
        begin
            bad = 0; shown = 0; nz = 0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                if (exp_mem[i] != 8'd0) nz = nz + 1;
                if (got_mem[i] !== exp_mem[i]) begin
                    bad = bad + 1;
                    if (shown < 6) begin
                        $display("      addr %0d : got %0d, expected %0d  (pol=%0d y=%0d x=%0d)",
                                 i, got_mem[i], exp_mem[i], i[12], i[11:6], i[5:0]);
                        shown = shown + 1;
                    end
                end
            end
            $display("      (nonzero cells = %0d)", nz);
            check_int(nm, bad, 0);
        end
    endtask

    // 전송이 끝날 때까지 기다린다
    task wait_xfer;
        integer guard;
        begin
            guard = 0;
            while (!t_start && guard < 40000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (guard >= 40000) begin
                $display("  [FAIL] tensor_start 가 오지 않음");
                errors = errors + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    initial begin
        $display("=== tb_event_accumulator : SPEC v1.2 / D3 Freeze A-001 ===");
        for (i = 0; i < DEPTH; i = i + 1) begin
            ref_mem[i] = 8'd0; exp_mem[i] = 8'd0; got_mem[i] = 8'hFF;
        end

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // ---------------- T1 : INIT ----------------
        check_int("T1 acc_ready after reset", acc_ready, 0);
        i = 0;
        while (!acc_ready && i < 20000) begin @(negedge clk); i = i + 1; end
        check_int("T1 acc_ready after INIT", acc_ready, 1);
        idle(2);

        // ---------------- Window 1 : 지정 자극 ----------------
        // T2 주소식 : (x=5, y=3, pol=0) -> addr 197 / (x=5,y=3,pol=1) -> addr 4293
        ev_cycle(1'b1, 6'd5,  6'd3,  1'b0);
        ev_cycle(1'b1, 6'd5,  6'd3,  1'b1);
        idle(3);

        // T3 같은 좌표 누적 (사이를 띄워서)
        for (k = 0; k < 5; k = k + 1) begin
            ev_cycle(1'b1, 6'd10, 6'd20, 1'b0);
            idle(2);
        end

        // T4 연속 같은 좌표 -- 포워딩이 없으면 여기서 카운트가 모자란다
        for (k = 0; k < 12; k = k + 1)
            ev_cycle(1'b1, 6'd40, 6'd41, 1'b0);
        idle(3);

        // T4b 두 주소를 번갈아 back-to-back
        for (k = 0; k < 10; k = k + 1) begin
            ev_cycle(1'b1, 6'd1, 6'd1, 1'b0);
            ev_cycle(1'b1, 6'd2, 6'd2, 1'b1);
        end
        idle(3);

        // T5 포화 : 140 회 연속 -> 127 에서 멈춰야 한다
        for (k = 0; k < 140; k = k + 1)
            ev_cycle(1'b1, 6'd63, 6'd63, 1'b1);
        idle(3);

        // T6 경계 좌표
        ev_cycle(1'b1, 6'd0,  6'd0,  1'b0);
        ev_cycle(1'b1, 6'd63, 6'd0,  1'b0);
        ev_cycle(1'b1, 6'd0,  6'd63, 1'b1);
        idle(3);

        // ---------------- T9 : npu_busy 게이팅 ----------------
        npu_busy = 1'b1;
        // window_end 와 이벤트를 같은 clock 에 (HANDOFF §1)
        window_end(1'b1, 6'd31, 6'd31, 1'b0);
        idle(50);
        check_int("T9 bytes sent while npu_busy", cap_n, 0);
        npu_busy = 1'b0;

        // ---------------- T10 : 전송 중 다음 Window 이벤트 ----------------
        // 전송이 도는 동안 이벤트를 계속 넣는다. ref_mem 은 이미 비워졌으므로
        // 여기 넣는 것은 전부 Window 2 소속이다.
        for (k = 0; k < 300; k = k + 1) begin
            ev_cycle(1'b1, k[5:0], (k*7)%64, k[0]);
        end

        wait_xfer;
        check_int("T7 W1 bytes transferred", cap_n, DEPTH);
        check_int("T7 W1 addr order 0..8191 violations", addr_err, 0);
        check_int("T9 npu_busy write violations", busy_err, 0);
        compare_tensor("T7 W1 tensor 8192B full compare");

        // T8 : tensor_start 는 1 cycle
        @(negedge clk);
        check_int("T8 tensor_start deasserts", t_start, 0);

        // ---------------- Window 2 ----------------
        // 전송 중에 넣은 300 개가 살아 있어야 하고(T10),
        // 버퍼가 0 으로 초기화되어 Window1 값이 남아 있으면 안 된다(T11).
        for (k = 0; k < 60; k = k + 1) begin
            ev_cycle(1'b1, 6'd40, 6'd41, 1'b0);    // Window1 에서 12 였던 주소
        end
        idle(3);

        window_end(1'b0, 6'd0, 6'd0, 1'b0);
        wait_xfer;
        check_int("T10 W2 bytes transferred", cap_n, DEPTH);
        check_int("T10 W2 addr order violations", addr_err, 0);
        compare_tensor("T11 W2 full compare  ping-pong + clear");

        // ---------------- T12 : 무작위 스트림 ----------------
        for (k = 0; k < 2000; k = k + 1) begin
            if ($random % 4 == 0) idle(1);
            ev_cycle(1'b1, $random, $random, $random);
        end
        idle(5);
        window_end(1'b0, 6'd0, 6'd0, 1'b0);
        wait_xfer;
        check_int("T12 random bytes transferred", cap_n, DEPTH);
        compare_tensor("T12 random stream full compare");

        check_int("overrun flag", overrun, 0);

        $display("=== 결과 : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_event_accumulator FAILED");
        $finish;
    end

    initial begin
        #50_000_000;                    // 50 ms 안전 타임아웃
        $fatal(1, "tb_event_accumulator TIMEOUT");
    end

endmodule

`default_nettype wire
