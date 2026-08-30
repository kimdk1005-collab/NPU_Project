`timescale 1ns/1ps
//=====================================================================
// tb_top_system : SoC 통합 end-to-end TB
//  PS 시나리오를 AXI4-Lite 로 그대로 재현한다.
//   (1) INPUT_SRC=0 : PS 가 INBUF_DATA 로 Event Tensor 8192 B 기록 -> 추론
//   (2) INPUT_SRC=1 : C 의 Event Accumulator 가 evt_* 로 직접 기록 -> 추론
//   (3) INPUT_SRC=1 + HW_START_EN=1 : Direct START.
//       PS 가 CTRL.START 를 한 번도 안 쓰고 hw_start pulse 만으로 추론이 돈다.
//       (CR A-003 변경 2. C 승인 2026-08-27, A 구현 2026-08-28)
//  세 경로 모두 golden(test_vectors/result_xy.txt) 과 일치해야 한다.
//=====================================================================
`include "npu_defs.vh"
module tb_top_system;
    localparam AW = 12;
    localparam CTRL=12'h00, STATUS=12'h04, CYCLE_CNT=12'h10,
               RESULT_X=12'h14, RESULT_Y=12'h18, RESULT_SC=12'h1C,
               VERSION=12'h38, INBUF_ADDR=12'h3C, INBUF_DATA=12'h40,
               SERVO_POS=12'h58, CONTROL_ST=12'h5C;

    reg clk = 1'b0, aresetn = 1'b0;
    always #5 clk = ~clk;                        // 100 MHz

    reg  [AW-1:0] awaddr = 0;  reg awvalid = 0;  wire awready;
    reg  [31:0]   wdata  = 0;  reg [3:0] wstrb = 0; reg wvalid = 0; wire wready;
    wire [1:0]    bresp;       wire bvalid;      reg  bready = 0;
    reg  [AW-1:0] araddr = 0;  reg arvalid = 0;  wire arready;
    wire [31:0]   rdata;       wire [1:0] rresp; wire rvalid; reg rready = 0;

    reg         evt_we   = 1'b0;
    reg  [12:0] evt_addr = 13'd0;
    reg  signed [7:0] evt_data = 8'sd0;
    reg  [31:0] input_stat = 32'd0;
    // CR A-003 : C 가 주는 Direct START pulse 와 상태 2 종
    reg         hw_start = 1'b0;
    reg  [31:0] servo_pos_stat = 32'd0, control_stat = 32'd0;

    wire [31:0] event_cfg, pan_cmd, tilt_cmd, laser_ctrl, safe_limit;
    wire [31:0] track_err_x, track_err_y;
    wire [31:0] pan2_cmd, tilt2_cmd, safe_limit2, laser_cal;
    wire        npu_target_valid, npu_done, npu_busy, irq;
    wire [3:0]  status_led;
    wire [5:0]  npu_target_x, npu_target_y;
    wire signed [7:0] npu_target_score;

    top_system #(.C_S_AXI_ADDR_WIDTH(AW)) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b000),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .evt_we(evt_we), .evt_addr(evt_addr), .evt_data(evt_data),
        .input_stat(input_stat),
        .hw_start(hw_start),
        .servo_pos_stat(servo_pos_stat), .control_stat(control_stat),
        .event_cfg(event_cfg), .pan_cmd(pan_cmd), .tilt_cmd(tilt_cmd),
        .laser_ctrl(laser_ctrl), .safe_limit(safe_limit),
        .track_err_x(track_err_x), .track_err_y(track_err_y),
        .pan2_cmd(pan2_cmd), .tilt2_cmd(tilt2_cmd),
        .safe_limit2(safe_limit2), .laser_cal(laser_cal),
        .npu_target_valid(npu_target_valid),
        .npu_target_x(npu_target_x), .npu_target_y(npu_target_y),
        .npu_target_score(npu_target_score),
        .npu_done(npu_done), .npu_busy(npu_busy), .irq(irq),
        .status_led(status_led)
    );

    //---------------- golden ----------------
    reg signed [7:0] g_in [0:8191];
    integer exp_hx, exp_hy, exp_tx, exp_ty, exp_score;
    integer errs = 0, checks = 0;
    integer i, fd, code, val;
    reg [8*32-1:0] key;
    reg [31:0] v, st;
    integer poll;

    //---------------- AXI-Lite master BFM ----------------
    task axi_write(input [31:0] addr, input [31:0] data, input [3:0] strb);
        reg aw_ok, w_ok, b_ok;
        begin
            @(negedge clk);
            awaddr <= addr[AW-1:0]; awvalid <= 1'b1;
            wdata  <= data; wstrb <= strb; wvalid <= 1'b1; bready <= 1'b1;
            aw_ok = 1'b0; w_ok = 1'b0; b_ok = 1'b0;
            while (!(aw_ok && w_ok)) begin
                @(posedge clk);
                if (awvalid && awready) aw_ok = 1'b1;
                if (wvalid  && wready ) w_ok  = 1'b1;
                @(negedge clk);
                if (aw_ok) awvalid <= 1'b0;
                if (w_ok ) wvalid  <= 1'b0;
            end
            while (!b_ok) begin
                @(posedge clk);
                if (bvalid) b_ok = 1'b1;
                @(negedge clk);
            end
            bready <= 1'b0;
        end
    endtask

    task axi_w(input [31:0] addr, input [31:0] data);
        begin axi_write(addr, data, 4'hF); end
    endtask

    task axi_read(input [31:0] addr, output [31:0] data);
        reg ar_ok, r_ok;
        begin
            @(negedge clk);
            araddr <= addr[AW-1:0]; arvalid <= 1'b1; rready <= 1'b1;
            ar_ok = 1'b0; r_ok = 1'b0;
            while (!ar_ok) begin
                @(posedge clk);
                if (arvalid && arready) ar_ok = 1'b1;
                @(negedge clk);
                if (ar_ok) arvalid <= 1'b0;
            end
            while (!r_ok) begin
                @(posedge clk);
                if (rvalid) begin r_ok = 1'b1; data = rdata; end
                @(negedge clk);
            end
            rready <= 1'b0;
        end
    endtask

    task chk(input [8*40-1:0] name, input [31:0] got, input [31:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errs = errs + 1;
                $display("  [FAIL] %0s : got 0x%08h exp 0x%08h", name, got, exp);
            end
        end
    endtask

    //---------------- PS 시나리오 : 결과 확인 ----------------
    task check_result(input [8*16-1:0] tag);
        reg [31:0] gx, gy, gs, gc;
        begin
            axi_read(RESULT_X, gx);  chk({tag, " RESULT_X"}, gx, exp_tx[31:0]);
            axi_read(RESULT_Y, gy);  chk({tag, " RESULT_Y"}, gy, exp_ty[31:0]);
            axi_read(RESULT_SC, gs);
            chk({tag, " target_score"}, {24'd0, gs[7:0]}, {24'd0, exp_score[7:0]});
            axi_read(STATUS, st);
            /* SCORE_TH = 0 (line 200 에서 AXI 로 씀). RTL: valid = (score > SCORE_TH) */
            chk({tag, " TARGET_VALID"}, {31'd0, st[3]},
                (exp_score > 0) ? 32'd1 : 32'd0);
            chk({tag, " BUSY=0"},       {31'd0, st[1]}, 32'd0);
            axi_read(CYCLE_CNT, gc);
            $display("  %0s AXI readback : X=%0d Y=%0d score=%0d SCORE_TH=%0d cycle=%0d (@100MHz %.3f ms)",
                     tag, gx, gy, $signed(gs[7:0]), $signed(gs[23:16]), gc, gc/100000.0);
            $display("  %0s golden       : X=%0d Y=%0d score=%0d",
                     tag, exp_tx, exp_ty, exp_score);
        end
    endtask

    //---------------- DONE polling (PS 와 동일) ----------------
    task wait_done(input [8*16-1:0] tag);
        begin
            poll = 0;
            st = 32'd0;
            // PS 폴링 재현 : STATUS 를 100 cycle 간격으로 읽는다.
            while (st[0] !== 1'b1 && poll < 5000) begin
                repeat (100) @(posedge clk);
                axi_read(STATUS, st);
                poll = poll + 1;
            end
            if (st[0] !== 1'b1) begin
                $display("  [FAIL] %0s : DONE 미도달 (poll=%0d)", tag, poll);
                errs = errs + 1;
            end
            checks = checks + 1;
        end
    endtask

    //================= 시나리오 =================
    initial begin
        $readmemh({`NPU_TV_DIR, "input_event.hex"}, g_in);
        fd = $fopen({`NPU_TV_DIR, "result_xy.txt"}, "r");
        if (fd == 0) begin $display("[FAIL] result_xy.txt 없음"); $finish; end
        for (i = 0; i < 5; i = i + 1) begin
            code = $fscanf(fd, "%s %d\n", key, val);
            case (i)
              0: exp_hx = val;  1: exp_hy = val;
              2: exp_tx = val;  3: exp_ty = val;
              4: exp_score = val;
            endcase
        end
        $fclose(fd);

        aresetn = 1'b0;
        repeat (20) @(posedge clk);
        @(negedge clk) aresetn = 1'b1;
        repeat (5) @(posedge clk);

        //---- AXI 링크 확인 ----
        axi_read(VERSION, v);
        chk("VERSION", v, 32'h4E50_0101);

        //---- 0x58 / 0x5C RO 통과 확인 (CR A-003 변경 1) ----
        //  top_system 이 두 입력을 npu_axi 까지 그대로 실어 나르는가.
        @(negedge clk);
        servo_pos_stat = 32'h6E_5A_46_32;    // {TILT2,PAN2,TILT1,PAN1}
        control_stat   = 32'h0001_0141;
        @(posedge clk);
        axi_read(SERVO_POS,  v);  chk("SERVO_POS_STAT", v, 32'h6E5A_4632);
        axi_read(CONTROL_ST, v);  chk("CONTROL_STAT"  , v, 32'h0001_0141);

        //================================================================
        // CASE 1 : INPUT_SRC = 0  (PS 가 AXI 로 Event Tensor 적재)
        //================================================================
        $display("");
        $display("=== CASE 1 : PS/AXI 경로 (INPUT_SRC=0) ===");
        axi_w(CTRL, 32'h0000_0000);              // INPUT_SRC=0
        axi_w(RESULT_SC, 32'h0000_0000);         // SCORE_TH = 0
        axi_w(INBUF_ADDR, 32'd0);
        for (i = 0; i < 8192; i = i + 4)
            axi_w(INBUF_DATA, {g_in[i+3], g_in[i+2], g_in[i+1], g_in[i]});
        axi_read(INBUF_ADDR, v);
        chk("INBUF_ADDR = 8192", v, 32'd8192);

        axi_w(CTRL, 32'h0000_0001);              // START
        wait_done("CASE1");
        check_result("CASE1");
        axi_w(STATUS, 32'h0000_0005);            // W1C DONE + ERROR
        axi_read(STATUS, st);
        /* DONE/ERROR W1C 후 남는 건 level 신호인 TARGET_VALID(bit3) 뿐 */
        chk("CASE1 STATUS clean", st, (exp_score > 0) ? 32'h0000_0008 : 32'h0000_0000);

        //================================================================
        // CASE 2 : INPUT_SRC = 1  (C Event Accumulator 직결 경로)
        //================================================================
        $display("");
        $display("=== CASE 2 : C 하드웨어 경로 (INPUT_SRC=1) ===");
        axi_w(CTRL, 32'h0000_0008);              // INPUT_SRC=1
        // C 모듈이 하듯 8192 byte 를 직접 기록
        @(negedge clk);
        for (i = 0; i < 8192; i = i + 1) begin
            evt_we   = 1'b1;
            evt_addr = i[12:0];
            evt_data = g_in[i];
            @(negedge clk);
        end
        evt_we = 1'b0;
        axi_w(CTRL, 32'h0000_0009);              // START (INPUT_SRC 유지)
        wait_done("CASE2");
        check_result("CASE2");

        //---- IRQ 경로 확인 ----
        axi_w(CTRL, 32'h0000_0018);              // IRQ_EN=1, INPUT_SRC=1
        repeat (3) @(posedge clk);
        chk("irq level", {31'd0, irq}, 32'd1);   // DONE sticky 아직 1
        axi_w(STATUS, 32'h0000_0001);
        repeat (3) @(posedge clk);
        chk("irq cleared", {31'd0, irq}, 32'd0);

        //================================================================
        // CASE 3 : Direct START (INPUT_SRC=1 + HW_START_EN=1)
        //   PS 가 CTRL.START 를 한 번도 안 쓴다. hw_start pulse 만으로 돈다.
        //   CR A-003 변경 2. C 승인 2026-08-27 -> A 구현 2026-08-28
        //================================================================
        $display("");
        $display("=== CASE 3 : Direct START (PS 가 START 를 안 쓴다) ===");
        axi_w(STATUS, 32'h0000_0005);            // DONE + ERROR 선클리어
        axi_w(CTRL, 32'h0000_0028);              // INPUT_SRC=1, HW_START_EN=1
        axi_read(CTRL, v);
        chk("CASE3 CTRL armed", v, 32'h0000_0028);

        // C 가 하듯 8192 byte 를 다시 기록
        @(negedge clk);
        for (i = 0; i < 8192; i = i + 1) begin
            evt_we   = 1'b1;
            evt_addr = i[12:0];
            evt_data = g_in[i];
            @(negedge clk);
        end
        evt_we = 1'b0;

        // event_accumulator 의 tensor_start 1 cycle pulse
        @(negedge clk) hw_start = 1'b1;
        @(negedge clk) hw_start = 1'b0;

        wait_done("CASE3");
        check_result("CASE3");
        axi_read(STATUS, st);
        chk("CASE3 ERROR=0", {31'd0, st[2]}, 32'd0);

        $display("");
        if (errs == 0) $display("[PASS] tb_top_system : %0d check 전부 일치", checks);
        else           $display("[FAIL] tb_top_system : %0d / %0d 불일치", errs, checks);
        $finish;
    end

    initial begin
        #40000000;
        $display("[FAIL] tb_top_system : timeout");
        $finish;
    end
endmodule
