`timescale 1ns/1ps
//=====================================================================
// tb_top_system_c : A(NPU) + C(Event/Control) 실물 통합 end-to-end TB
// 담당: A
//
//  이 TB 가 증명하려는 것 하나
//    "C 의 Event Stream 을 넣으면 A 의 NPU 가 golden 과 같은 좌표를 낸다"
//
//  경로 :  src_* -> event_adapter -> event_accumulator -> evt_*
//          -> top_system Input Mux(INPUT_SRC=1) -> npu_core -> RESULT_*
//
//  기존 tb_top_system 은 evt_* 를 TB 가 직접 흔들었다. 여기서는 C 모듈이
//  실제로 만들어 낸다. 즉 CHW 주소식·0~127 포화·ping-pong·window 경계까지
//  C 구현이 A golden 과 맞는지가 이 한 TB 로 판정된다.
//
//  파라미터 선택 이유
//    SENSOR_W/H = 64 : Binning 을 항등으로 만들어 src 좌표 = tensor 좌표.
//                      golden(test_vectors/input_event.hex)을 그대로 재생할 수 있다.
//                      Binning 자체의 정확도는 C 의 tb_event_adapter 가 이미 본다.
//    WINDOW_SRC = 1  : Window 경계를 TB 가 정확히 잡는다.
//    laser_arm_hw=0  : 광원 미장착 규약(REPLY_004 §2.2). laser_en 은 항상 0 이어야 한다.
//
//  START 는 두 방식을 다 본다 (CR A-003 변경 2 구현 뒤).
//    FRAME 1/2 : PS-managed. INPUT_STAT.TENSOR_READY(bit1) 폴링 -> CTRL.START
//    FRAME 3   : Direct.     CTRL[5] HW_START_EN=1. PS 는 START 를 안 쓴다.
//  세 프레임 전부 같은 golden 좌표가 나와야 한다.
//=====================================================================
`include "npu_defs.vh"
module tb_top_system_c;
    localparam AW = 12;
    localparam CTRL=12'h00, STATUS=12'h04, EVENT_CFG=12'h08, INPUT_STAT=12'h0C,
               CYCLE_CNT=12'h10, RESULT_X=12'h14, RESULT_Y=12'h18, RESULT_SC=12'h1C,
               LASER_CTRL=12'h28, VERSION=12'h38,
               SERVO_POS=12'h58, CONTROL_ST=12'h5C;

    reg clk = 1'b0, aresetn = 1'b0;
    always #5 clk = ~clk;                        // 100 MHz

    reg  [AW-1:0] awaddr = 0;  reg awvalid = 0;  wire awready;
    reg  [31:0]   wdata  = 0;  reg [3:0] wstrb = 0; reg wvalid = 0; wire wready;
    wire [1:0]    bresp;       wire bvalid;      reg  bready = 0;
    reg  [AW-1:0] araddr = 0;  reg arvalid = 0;  wire arready;
    wire [31:0]   rdata;       wire [1:0] rresp; wire rvalid; reg rready = 0;

    reg         src_valid = 1'b0;
    reg  [10:0] src_x = 11'd0, src_y = 11'd0;
    reg         src_pol = 1'b0;
    reg         src_window_end = 1'b0;
    reg         laser_arm_hw = 1'b0;        // 광원 미장착 : 항상 0
    reg         emergency_stop_hw = 1'b0;

    wire [3:0]  servo_pwm;
    wire        laser_en;
    wire [31:0] servo_pos_stat, control_stat;
    wire        tensor_start, irq;
    wire [3:0]  status_led;

    top_system_c #(
        .C_S_AXI_ADDR_WIDTH(AW),
        .SENSOR_W(64), .SENSOR_H(64), .SRC_COORD_W(11),
        .WINDOW_SRC(1)
    ) dut (
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
        .src_valid(src_valid), .src_x(src_x), .src_y(src_y),
        .src_pol(src_pol), .src_window_end(src_window_end),
        .laser_arm_hw(laser_arm_hw), .emergency_stop_hw(emergency_stop_hw),
        .servo_pwm(servo_pwm), .laser_en(laser_en),
        .servo_pos_stat(servo_pos_stat), .control_stat(control_stat),
        .tensor_start(tensor_start), .irq(irq), .status_led(status_led)
    );

    //---------------- golden ----------------
    reg [7:0] g_in [0:8191];                 // Event Count 0~127 (부호 없음)
    integer exp_hx, exp_hy, exp_tx, exp_ty, exp_score;
    integer errs = 0, checks = 0;
    integer i, k, fd, code, val, ev_total, mism;
    reg [8*32-1:0] key;
    reg [31:0] v, st;
    integer poll;
    reg laser_stuck;                         // laser_en 이 한 번이라도 1 이었나

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

    task chk(input [8*44-1:0] name, input [31:0] got, input [31:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errs = errs + 1;
                $display("  [FAIL] %0s : got 0x%08h exp 0x%08h", name, got, exp);
            end else
                $display("  [PASS] %0s : 0x%08h", name, got);
        end
    endtask

    //---------------- Event Stream 재생 ----------------
    //  golden tensor 를 그대로 만들어 내는 최소 이벤트열.
    //  addr = (pol<<12)|(y<<6)|x 이고 값이 N 이면 그 좌표 이벤트를 N 번 넣는다.
    //  같은 좌표 연속 입력이라 C 의 RMW forwarding 경로도 같이 밟힌다.
    task replay_events;
        begin
            ev_total = 0;
            for (i = 0; i < 8192; i = i + 1) begin
                if (g_in[i] != 8'd0) begin
                    for (k = 0; k < g_in[i]; k = k + 1) begin
                        @(negedge clk);
                        src_valid <= 1'b1;
                        src_pol   <= i[12];
                        src_y     <= {5'd0, i[11:6]};
                        src_x     <= {5'd0, i[5:0]};
                        ev_total  = ev_total + 1;
                    end
                end
            end
            @(negedge clk);
            src_valid <= 1'b0;
            $display("  [TB] Event %0d 개 주입 완료", ev_total);
        end
    endtask

    task pulse_window_end;
        begin
            @(negedge clk); src_window_end <= 1'b1;
            @(negedge clk); src_window_end <= 1'b0;
        end
    endtask

    //  PS 가 하는 그대로 : INPUT_STAT.TENSOR_READY(bit1) 폴링
    task wait_tensor_ready(input [8*16-1:0] tag);
        begin
            poll = 0; v = 32'd0;
            while (v[1] !== 1'b1 && poll < 4000) begin
                repeat (10) @(posedge clk);
                axi_read(INPUT_STAT, v);
                poll = poll + 1;
            end
            checks = checks + 1;
            if (v[1] !== 1'b1) begin
                errs = errs + 1;
                $display("  [FAIL] %0s TENSOR_READY 미도달 (poll=%0d)", tag, poll);
            end else
                $display("  [PASS] %0s TENSOR_READY : INPUT_STAT=0x%08h (evt=%0d drop=%0d)",
                         tag, v, v[19:8], v[31:20]);
        end
    endtask

    task wait_done(input [8*16-1:0] tag);
        begin
            poll = 0; st = 32'd0;
            while (st[0] !== 1'b1 && poll < 5000) begin
                repeat (100) @(posedge clk);
                axi_read(STATUS, st);
                poll = poll + 1;
            end
            checks = checks + 1;
            if (st[0] !== 1'b1) begin
                errs = errs + 1;
                $display("  [FAIL] %0s DONE 미도달 (poll=%0d)", tag, poll);
            end else
                $display("  [PASS] %0s DONE", tag);
        end
    endtask

    //  NPU 입력버퍼(act_buf0)가 golden tensor 와 byte 단위로 같은지
    task check_tensor(input [8*16-1:0] tag);
        begin
            mism = 0;
            for (i = 0; i < 8192; i = i + 1)
                if (dut.u_a.u_npu.u_dp.u_buf0.mem[i] !== $signed(g_in[i])) begin
                    mism = mism + 1;
                    if (mism <= 5)
                        $display("    [MISMATCH] addr=%0d C=%0d golden=%0d",
                                 i, dut.u_a.u_npu.u_dp.u_buf0.mem[i], g_in[i]);
                end
            chk({tag, " TENSOR 8192B"}, mism[31:0], 32'd0);
        end
    endtask

    task check_result(input [8*16-1:0] tag);
        reg [31:0] gx, gy, gs, gc;
        begin
            axi_read(RESULT_X, gx);  chk({tag, " RESULT_X"}, gx, exp_tx[31:0]);
            axi_read(RESULT_Y, gy);  chk({tag, " RESULT_Y"}, gy, exp_ty[31:0]);
            axi_read(RESULT_SC, gs);
            chk({tag, " target_score"}, {24'd0, gs[7:0]}, {24'd0, exp_score[7:0]});
            axi_read(STATUS, st);
            chk({tag, " TARGET_VALID"}, {31'd0, st[3]},
                (exp_score > 0) ? 32'd1 : 32'd0);
            axi_read(CYCLE_CNT, gc);
            $display("  %0s : X=%0d Y=%0d score=%0d cycle=%0d (@100MHz %.3f ms)",
                     tag, gx, gy, $signed(gs[7:0]), gc, gc/100000.0);
        end
    endtask

    //---------------- laser_en 감시 : 한 번이라도 1 이면 안 된다 ----------------
    always @(posedge clk) if (aresetn && laser_en) laser_stuck <= 1'b1;

    //================= 시나리오 =================
    initial begin
        laser_stuck = 1'b0;
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

        axi_read(VERSION, v);
        chk("VERSION", v, 32'h4E50_0101);

        //--------------------------------------------------------------
        // 준비 : C Event 경로 활성화 + Input Source 를 C 로
        //--------------------------------------------------------------
        axi_w(EVENT_CFG,  32'h0000_0001);   // EVENT_ENABLE=1, POLARITY_INVERT=0
        axi_w(LASER_CTRL, 32'h0000_0001);   // SERVO_ENABLE=1, SW_LASER_ARM=0
        axi_w(RESULT_SC,  32'h0000_0000);   // SCORE_TH = 0
        axi_w(CTRL,       32'h0000_0008);   // INPUT_SRC=1 (C 하드웨어 경로)

        // event_accumulator 는 전원 인가 후 8192 cycle 동안 버퍼를 0 으로 채운다
        poll = 0; v = 32'd0;
        while (v[0] !== 1'b1 && poll < 2000) begin
            repeat (100) @(posedge clk);
            axi_read(INPUT_STAT, v);
            poll = poll + 1;
        end
        chk("ACC_READY (INPUT_STAT[0])", {31'd0, v[0]}, 32'd1);

        //--------------------------------------------------------------
        // FRAME 1
        //--------------------------------------------------------------
        $display("");
        $display("=== FRAME 1 : C Event Stream -> NPU ===");
        replay_events;
        pulse_window_end;
        wait_tensor_ready("F1");
        check_tensor("F1");

        axi_w(CTRL, 32'h0000_0009);         // START, INPUT_SRC 유지
        wait_done("F1");
        check_result("F1");
        axi_read(INPUT_STAT, v);
        chk("F1 OVERRUN=0 (INPUT_STAT[2])", {31'd0, v[2]}, 32'd0);
        axi_w(STATUS, 32'h0000_0005);       // W1C DONE + ERROR

        //--------------------------------------------------------------
        // FRAME 2 : ping-pong 버퍼가 정말 다시 0 에서 시작하는지
        //--------------------------------------------------------------
        $display("");
        $display("=== FRAME 2 : 같은 Event 를 다시 넣어 재현성 확인 ===");
        replay_events;
        pulse_window_end;
        wait_tensor_ready("F2");
        check_tensor("F2");
        axi_w(CTRL, 32'h0000_0009);
        wait_done("F2");
        check_result("F2");
        axi_read(INPUT_STAT, v);
        chk("F2 OVERRUN=0", {31'd0, v[2]}, 32'd0);

        //--------------------------------------------------------------
        // FRAME 3 : Direct START (CR A-003 변경 2. C 승인 -> A 구현)
        //   PS 가 CTRL.START 를 한 번도 안 쓴다.
        //   C 의 event_accumulator.tensor_start 가 곧바로 추론을 건다.
        //   PS-managed 의 "TENSOR_READY 를 한 Window 안에 봐야 한다" 는
        //   지연 예산 자체가 사라지는 경로다.
        //--------------------------------------------------------------
        $display("");
        $display("=== FRAME 3 : Direct START (PS 가 START 를 안 쓴다) ===");
        axi_w(STATUS, 32'h0000_0005);       // DONE + ERROR 선클리어
        axi_w(CTRL,   32'h0000_0028);       // INPUT_SRC=1, HW_START_EN=1
        axi_read(CTRL, v);
        chk("F3 CTRL armed", v, 32'h0000_0028);

        replay_events;
        pulse_window_end;
        // TENSOR_READY 를 안 본다. 하드웨어가 알아서 START 한다.
        wait_done("F3");
        //  ** 여기서 check_tensor 를 부르면 안 된다. **
        //  u_buf0 은 입력 전용이 아니라 act_buf ping-pong 의 한쪽이다
        //  (rtl/npu/npu_datapath.v:96  b0_we = ext_we ? 1 : (buf_sel & cv_we)).
        //  추론이 돌면 중간 activation 이 덮어쓴다. F1/F2 는 START 전에 봐서
        //  괜찮지만 Direct START 는 전송 직후 바로 돌기 때문에 볼 틈이 없다.
        //  텐서가 맞았다는 증거는 아래 RESULT 가 golden 과 같다는 것이다.
        check_result("F3");
        axi_read(STATUS, st);
        chk("F3 ERROR=0", {31'd0, st[2]}, 32'd0);
        axi_read(INPUT_STAT, v);
        chk("F3 OVERRUN=0", {31'd0, v[2]}, 32'd0);

        // 무장 해제. INPUT_SRC 는 유지한다.
        axi_w(CTRL, 32'h0000_0008);
        axi_read(CTRL, v);
        chk("F3 disarmed", v, 32'h0000_0008);
        axi_w(STATUS, 32'h0000_0005);

        //--------------------------------------------------------------
        // 안전 : 물리 Arm 이 0 이면 laser_en 은 어떤 조건에서도 0
        //--------------------------------------------------------------
        $display("");
        $display("=== 안전 검사 (REPLY_004 2.2 / SPEC 17) ===");
        axi_w(LASER_CTRL, 32'h0000_0003);   // SERVO_ENABLE=1, SW_LASER_ARM=1
        repeat (200) @(posedge clk);
        chk("laser_en fail-closed (arm_hw=0)", {31'd0, laser_en},  32'd0);
        chk("laser_en never asserted (whole run)", {31'd0, laser_stuck}, 32'd0);
        axi_read(INPUT_STAT, v);
        chk("EVENT_ENABLE (INPUT_STAT[3])",  {31'd0, v[3]},  32'd1);
        chk("CONTROL_STAT HW_ARM=0 (bit9)",  {31'd0, control_stat[9]},  32'd0);
        chk("CONTROL_STAT SW_ARM=1 (bit10)", {31'd0, control_stat[10]}, 32'd1);
        chk("CONTROL_STAT ESTOP=0 (bit11)",  {31'd0, control_stat[11]}, 32'd0);
        chk("CONTROL_STAT LASER_EN=0 (bit0)",{31'd0, control_stat[0]},  32'd0);
        $display("  SERVO_POS_STAT = 0x%08h  {TILT2,PAN2,TILT1,PAN1}", servo_pos_stat);
        $display("  CONTROL_STAT   = 0x%08h", control_stat);

        //--------------------------------------------------------------
        // 0x58 / 0x5C RO — PS 가 AXI 로 읽는 값이 포트와 같은가
        //  CR A-003 변경 1. 같은 FF 에서 나와야 한다 (top_system_c 등록값).
        //  포트로는 맞는데 AXI 로 0 이 나오면 배선이 빠진 것이다.
        //--------------------------------------------------------------
        axi_read(SERVO_POS,  v);
        chk("AXI 0x58 == servo_pos_stat 포트", v, servo_pos_stat);
        axi_read(CONTROL_ST, v);
        chk("AXI 0x5C == control_stat 포트",   v, control_stat);
        chk("CONTROL_STAT [31:17] = 0", v & 32'hFFFE_0000, 32'd0);

        $display("");
        if (errs == 0) $display("[PASS] tb_top_system_c : %0d check 전부 일치", checks);
        else           $display("[FAIL] tb_top_system_c : %0d / %0d 불일치", errs, checks);
        $finish;
    end

    initial begin
        #60000000;
        $display("[FAIL] tb_top_system_c : timeout");
        $finish;
    end
endmodule
