`timescale 1ns/1ps
//=====================================================================
// tb_npu_axi : AXI4-Lite Register Bridge self-checking TB
// NPU 는 동작 가능한 stub 으로 대체하여 busy/done/error 경로까지 강제 검증한다.
//=====================================================================
module tb_npu_axi;
    localparam AW = 12;

    // Register offsets
    localparam CTRL=12'h00, STATUS=12'h04, EVENT_CFG=12'h08, INPUT_STAT=12'h0C,
               CYCLE_CNT=12'h10, RESULT_X=12'h14, RESULT_Y=12'h18, RESULT_SC=12'h1C,
               PAN_CMD=12'h20, TILT_CMD=12'h24, LASER_CTRL=12'h28, SAFE_LIMIT=12'h2C,
               TRACK_ERRX=12'h30, TRACK_ERRY=12'h34, VERSION=12'h38,
               INBUF_ADDR=12'h3C, INBUF_DATA=12'h40, SCRATCH=12'h44,
               PAN2_CMD=12'h48, TILT2_CMD=12'h4C, SAFE_LIMIT2=12'h50,
               LASER_CAL=12'h54,
               // CR A-003 변경 1 로 0x58/0x5C 가 실제 Register 가 됐다.
               // 미정의 Offset 시험은 그 뒤로 옮긴다.
               //
               // ** CR A-004 (0x60 EVENT_IN) 를 구현하는 날 UNKNOWN 을 0x64 로 옮겨라. **
               // 안 옮기면 0x60 이 WO Register 가 돼서 read 가 어차피 0 이고,
               // "미정의 Offset" 시험이 조용히 무의미해진다.
               // 같은 주소가 sw/npu_test.c STEP 2 에도 있다. 둘 다 옮겨야 한다.
               SERVO_POS=12'h58, CONTROL_ST=12'h5C, UNKNOWN=12'h60;

    reg clk = 1'b0, aresetn = 1'b0;
    always #5 clk = ~clk;

    reg  [AW-1:0] awaddr = 0;  reg awvalid = 0;  wire awready;
    reg  [31:0]   wdata  = 0;  reg [3:0] wstrb = 0; reg wvalid = 0; wire wready;
    wire [1:0]    bresp;       wire bvalid;      reg  bready = 0;
    reg  [AW-1:0] araddr = 0;  reg arvalid = 0;  wire arready;
    wire [31:0]   rdata;       wire [1:0] rresp; wire rvalid; reg rready = 0;

    wire        npu_rstn, npu_start;
    reg         npu_busy = 1'b0, npu_done = 1'b0;
    reg  [31:0] npu_cycle_cnt = 32'd0;
    wire signed [7:0] npu_score_th;
    reg         npu_target_valid = 1'b0;
    reg  [5:0]  npu_target_x = 6'd0, npu_target_y = 6'd0;
    reg  signed [7:0] npu_target_score = 8'sd0;

    wire        axi_ext_we;
    wire [12:0] axi_ext_addr;
    wire signed [7:0] axi_ext_data;
    wire        input_src;
    wire [31:0] event_cfg, pan_cmd, tilt_cmd, laser_ctrl, safe_limit;
    wire [31:0] track_err_x, track_err_y;
    wire [31:0] pan2_cmd, tilt2_cmd, safe_limit2, laser_cal;
    reg  [31:0] input_stat = 32'd0;
    // CR A-003 : Direct START + 0x58/0x5C RO
    reg         hw_start = 1'b0;
    reg  [31:0] servo_pos_stat = 32'd0, control_stat = 32'd0;
    wire        irq;

    npu_axi #(.C_S_AXI_ADDR_WIDTH(AW)) dut (
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
        .npu_rstn(npu_rstn), .npu_start(npu_start), .hw_start(hw_start),
        .npu_busy(npu_busy), .npu_done(npu_done),
        .npu_cycle_cnt(npu_cycle_cnt), .npu_score_th(npu_score_th),
        .npu_target_valid(npu_target_valid),
        .npu_target_x(npu_target_x), .npu_target_y(npu_target_y),
        .npu_target_score(npu_target_score),
        .axi_ext_we(axi_ext_we), .axi_ext_addr(axi_ext_addr),
        .axi_ext_data(axi_ext_data), .input_src(input_src),
        .event_cfg(event_cfg), .input_stat(input_stat),
        .pan_cmd(pan_cmd), .tilt_cmd(tilt_cmd),
        .laser_ctrl(laser_ctrl), .safe_limit(safe_limit),
        .track_err_x(track_err_x), .track_err_y(track_err_y),
        .pan2_cmd(pan2_cmd), .tilt2_cmd(tilt2_cmd),
        .safe_limit2(safe_limit2), .laser_cal(laser_cal),
        .servo_pos_stat(servo_pos_stat), .control_stat(control_stat),
        .irq(irq)
    );

    //---------------- ext write shadow memory ----------------
    reg  signed [7:0] shadow [0:8191];
    integer wr_hits = 0;
    always @(posedge clk) begin
        if (axi_ext_we) begin
            shadow[axi_ext_addr] <= axi_ext_data;
            wr_hits <= wr_hits + 1;
        end
    end

    //---------------- start pulse counter ----------------
    integer start_cnt = 0;
    always @(posedge clk) if (npu_start) start_cnt = start_cnt + 1;

    //---------------- 두 START 배타성 감시 (CR A-003 변경 2) ----------------
    //  npu_start 는 OR 라 밖에서 보면 늘 pulse 1 개다. 그것만으로는
    //  "두 경로가 배타적" 임을 증명하지 못한다. 내부 pulse 를 따로 센다.
    //  both_cnt 가 한 번이라도 오르면 같은 cycle 에 둘 다 성립한 것이다.
    integer ps_pulse_cnt = 0, hw_pulse_cnt = 0, both_cnt = 0;
    always @(posedge clk) begin
        if (dut.start_pulse)    ps_pulse_cnt = ps_pulse_cnt + 1;
        if (dut.hw_start_pulse) hw_pulse_cnt = hw_pulse_cnt + 1;
        if (dut.start_pulse && dut.hw_start_pulse) both_cnt = both_cnt + 1;
    end

    //  충돌이 실제로 만들어졌는지 세는 계수기.
    //  "HW pulse 요구" 와 "PS 가 START 를 쓰는 W_WRITE cycle" 이 겹친 횟수다.
    //  누가 이겼는지와 무관하다. 이게 0 이면 19h/19i 는 정렬에 실패한 것이고
    //  아무것도 시험하지 않은 셈이 된다.
    integer collide_cnt = 0;
    always @(posedge clk)
        if (dut.hw_start_req && (dut.wst === 2'd1) && dut.wstrb_q[0]
            && (dut.waddr_idx === 5'h00) && dut.wdata_q[0])
            collide_cnt = collide_cnt + 1;

    //---------------- AXI-Lite master BFM ----------------
    integer errs = 0, checks = 0;

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
                if (bvalid) begin
                    b_ok = 1'b1;
                    if (bresp !== 2'b00) begin
                        $display("[FAIL] BRESP != OKAY @0x%02h", addr); errs = errs + 1;
                    end
                end
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
                if (rvalid) begin
                    r_ok = 1'b1; data = rdata;
                    if (rresp !== 2'b00) begin
                        $display("[FAIL] RRESP != OKAY @0x%02h", addr); errs = errs + 1;
                    end
                end
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
                $display("[FAIL] %0s : got 0x%08h exp 0x%08h", name, got, exp);
            end
        end
    endtask

    task rd_chk(input [8*40-1:0] name, input [31:0] addr, input [31:0] exp);
        reg [31:0] v;
        begin axi_read(addr, v); chk(name, v, exp); end
    endtask

    // C 의 event_accumulator.tensor_start 를 흉내낸다. 정확히 1 cycle.
    task pulse_hw_start;
        begin
            @(negedge clk); hw_start = 1'b1;
            @(negedge clk); hw_start = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    //-----------------------------------------------------------------
    // CTRL write 의 W_WRITE 실행 cycle 과 **정확히 같은 cycle** 에 hw_start 를 준다.
    //
    //  wst 는 posedge 에 갱신된다. 어떤 negedge 에서 wst == W_WRITE 로 읽히면
    //  ** 바로 다음 posedge ** 가 W_WRITE 본문이 도는 edge 다. 그 negedge 에
    //  hw_start 를 올리면 두 START 경로가 같은 cycle 에 성립한다.
    //  이 정렬을 손으로 맞출 방법이 없어서 DUT 내부 상태를 본다.
    //-----------------------------------------------------------------
    localparam [1:0] DUT_W_WRITE = 2'd1;      // npu_axi.v 의 localparam W_WRITE
    integer hunt_guard;
    task ctrl_write_with_hw_start(input [31:0] data);
        begin
            fork
                begin : hunt
                    hunt_guard = 0;
                    @(negedge clk);
                    while (dut.wst !== DUT_W_WRITE && hunt_guard < 200) begin
                        @(negedge clk);
                        hunt_guard = hunt_guard + 1;
                    end
                    hw_start = 1'b1;
                    @(negedge clk);
                    hw_start = 1'b0;
                end
                axi_w(CTRL, data);
            join
            repeat (3) @(posedge clk);
        end
    endtask

    //================= 시나리오 =================
    reg [31:0] v;
    integer i;
    integer rstn_low;

    initial begin
        aresetn = 1'b0;
        repeat (10) @(posedge clk);
        @(negedge clk) aresetn = 1'b1;
        repeat (2) @(posedge clk);

        //---- 1. VERSION ----
        //  0x4E50_0101 = 0x58/0x5C RO + CTRL[5] HW_START_EN 반영본 (CR A-003)
        rd_chk("VERSION", VERSION, 32'h4E50_0101);

        //---- 2. SCRATCH full / byte-strobe ----
        axi_w(SCRATCH, 32'hDEAD_BEEF);
        rd_chk("SCRATCH full", SCRATCH, 32'hDEAD_BEEF);
        axi_write(SCRATCH, 32'h1122_3344, 4'b0010);   // byte1 만
        rd_chk("SCRATCH wstrb", SCRATCH, 32'hDEAD_33EF);

        //---- 3. 리셋 직후 기본값 ----
        rd_chk("CTRL reset", CTRL, 32'h0000_0000);
        rd_chk("STATUS reset", STATUS, 32'h0000_0000);
        rd_chk("INBUF_ADDR reset", INBUF_ADDR, 32'h0000_0000);

        //---- 4. C 소유 Register R/W ----
        axi_w(EVENT_CFG , 32'h0000_1F40);
        axi_w(PAN_CMD   , 32'h0000_0090);
        axi_w(TILT_CMD  , 32'hFFFF_FF80);
        axi_w(LASER_CTRL, 32'h0000_0001);
        axi_w(SAFE_LIMIT, 32'h00B4_002D);
        axi_w(TRACK_ERRX, 32'hFFFF_FFF8);
        axi_w(TRACK_ERRY, 32'h0000_0004);
        rd_chk("EVENT_CFG" , EVENT_CFG , 32'h0000_1F40);
        rd_chk("PAN_CMD"   , PAN_CMD   , 32'h0000_0090);
        rd_chk("TILT_CMD"  , TILT_CMD  , 32'hFFFF_FF80);
        rd_chk("LASER_CTRL", LASER_CTRL, 32'h0000_0001);
        rd_chk("SAFE_LIMIT", SAFE_LIMIT, 32'h00B4_002D);
        rd_chk("TRACK_ERRX", TRACK_ERRX, 32'hFFFF_FFF8);
        rd_chk("TRACK_ERRY", TRACK_ERRY, 32'h0000_0004);
        chk("event_cfg port" , event_cfg  , 32'h0000_1F40);
        chk("pan_cmd port"   , pan_cmd    , 32'h0000_0090);
        chk("tilt_cmd port"  , tilt_cmd   , 32'hFFFF_FF80);
        chk("laser_ctrl port", laser_ctrl , 32'h0000_0001);
        chk("safe_limit port", safe_limit , 32'h00B4_002D);
        chk("track_err_x port", track_err_x, 32'hFFFF_FFF8);
        chk("track_err_y port", track_err_y, 32'h0000_0004);

        //---- 4b. Pan/Tilt 2호기 (레이저 헤드) Register ----
        axi_w(PAN2_CMD   , 32'h0000_00A5);
        axi_w(TILT2_CMD  , 32'hFFFF_FFC4);
        axi_w(SAFE_LIMIT2, 32'h00C8_0032);
        axi_w(LASER_CAL  , 32'h0040_0080);
        rd_chk("PAN2_CMD"   , PAN2_CMD   , 32'h0000_00A5);
        rd_chk("TILT2_CMD"  , TILT2_CMD  , 32'hFFFF_FFC4);
        rd_chk("SAFE_LIMIT2", SAFE_LIMIT2, 32'h00C8_0032);
        rd_chk("LASER_CAL"  , LASER_CAL  , 32'h0040_0080);
        chk("pan2_cmd port"   , pan2_cmd   , 32'h0000_00A5);
        chk("tilt2_cmd port"  , tilt2_cmd  , 32'hFFFF_FFC4);
        chk("safe_limit2 port", safe_limit2, 32'h00C8_0032);
        chk("laser_cal port"  , laser_cal  , 32'h0040_0080);
        // PT#1 이 PT#2 write 에 오염되지 않는가 (독립성)
        rd_chk("PAN_CMD  intact", PAN_CMD  , 32'h0000_0090);
        rd_chk("TILT_CMD intact", TILT_CMD , 32'hFFFF_FF80);

        //---- 5. RO Register 가 입력 포트를 반영하는가 ----
        @(negedge clk);
        npu_cycle_cnt    = 32'd125845;
        npu_target_x     = 6'd52 >> 3;          // 6'd6
        npu_target_y     = 6'd28 >> 3;          // 6'd3
        npu_target_x     = 6'd52;
        npu_target_y     = 6'd28;
        npu_target_score = -8'sd7;
        npu_target_valid = 1'b1;
        input_stat       = 32'h0000_2A00;
        @(posedge clk);
        rd_chk("CYCLE_CNT", CYCLE_CNT, 32'd125845);
        rd_chk("RESULT_X" , RESULT_X , 32'd52);
        rd_chk("RESULT_Y" , RESULT_Y , 32'd28);
        rd_chk("INPUT_STAT", INPUT_STAT, 32'h0000_2A00);
        rd_chk("STATUS tvalid", STATUS, 32'h0000_0008);

        //---- 6. SCORE_TH R/W + target_score RO 혼합 ----
        rd_chk("RESULT_SC ro", RESULT_SC, 32'h0000_00F9);        // score = -7
        axi_w(RESULT_SC, 32'hFF14_FF33);                          // [23:16]=0x14 만 반영
        rd_chk("RESULT_SC th", RESULT_SC, 32'h0014_00F9);
        chk("score_th port", {24'd0, npu_score_th}, 32'h0000_0014);
        axi_w(RESULT_SC, 32'h0000_0000);
        chk("score_th clr", {24'd0, npu_score_th}, 32'h0000_0000);

        //---- 7. CTRL bit : INPUT_SRC / IRQ_EN, START·SOFT_RESET 는 read 0 ----
        axi_w(CTRL, 32'h0000_0018);              // INPUT_SRC=1, IRQ_EN=1
        rd_chk("CTRL rw bits", CTRL, 32'h0000_0018);
        chk("input_src port", {31'd0, input_src}, 32'h0000_0001);
        axi_w(CTRL, 32'h0000_0000);
        rd_chk("CTRL cleared", CTRL, 32'h0000_0000);

        //---- 8. START pulse + DONE sticky ----
        start_cnt = 0;
        axi_w(CTRL, 32'h0000_0001);              // START
        repeat (3) @(posedge clk);
        chk("start pulse x1", start_cnt[31:0], 32'd1);
        rd_chk("STATUS after start", STATUS, 32'h0000_0008);   // busy=0(stub), tvalid=1

        @(negedge clk) npu_done = 1'b1;          // 1-cycle done pulse
        @(negedge clk) npu_done = 1'b0;
        rd_chk("DONE sticky", STATUS, 32'h0000_0009);
        axi_w(STATUS, 32'h0000_0001);            // W1C DONE
        rd_chk("DONE cleared", STATUS, 32'h0000_0008);

        //---- 9. IRQ = IRQ_EN & DONE ----
        @(negedge clk) npu_done = 1'b1;
        @(negedge clk) npu_done = 1'b0;
        chk("irq masked", {31'd0, irq}, 32'd0);
        axi_w(CTRL, 32'h0000_0010);              // IRQ_EN=1
        repeat (2) @(posedge clk);
        chk("irq asserted", {31'd0, irq}, 32'd1);
        axi_w(STATUS, 32'h0000_0001);
        repeat (2) @(posedge clk);
        chk("irq deasserted", {31'd0, irq}, 32'd0);
        axi_w(CTRL, 32'h0000_0000);

        //---- 10. START while BUSY -> ERROR sticky, pulse 없음 ----
        @(negedge clk) npu_busy = 1'b1;
        start_cnt = 0;
        axi_w(CTRL, 32'h0000_0001);
        repeat (3) @(posedge clk);
        chk("no start when busy", start_cnt[31:0], 32'd0);
        rd_chk("ERROR sticky", STATUS, 32'h0000_000E);   // tvalid|err|busy
        //---- 11. BUSY 중 INBUF write 는 drop ----
        wr_hits = 0;
        axi_w(INBUF_DATA, 32'h1234_5678);
        repeat (6) @(posedge clk);
        chk("inbuf drop when busy", wr_hits[31:0], 32'd0);
        @(negedge clk) npu_busy = 1'b0;
        axi_w(STATUS, 32'h0000_0004);            // W1C ERROR
        rd_chk("ERROR cleared", STATUS, 32'h0000_0008);

        //---- 12. INPUT_SRC=1 이면 AXI INBUF write drop ----
        axi_w(CTRL, 32'h0000_0008);
        wr_hits = 0;
        axi_w(INBUF_DATA, 32'hAAAA_AAAA);
        repeat (6) @(posedge clk);
        chk("inbuf drop when hw src", wr_hits[31:0], 32'd0);
        rd_chk("ERROR on hw src", STATUS, 32'h0000_000C);
        axi_w(CTRL, 32'h0000_0000);
        axi_w(STATUS, 32'h0000_0004);

        //---- 13. INBUF 정상 write + 포인터 자동 증가 ----
        axi_w(INBUF_ADDR, 32'd100);
        rd_chk("INBUF_ADDR set", INBUF_ADDR, 32'd100);
        wr_hits = 0;
        axi_w(INBUF_DATA, 32'h44332211);
        axi_w(INBUF_DATA, 32'h88776655);
        repeat (4) @(posedge clk);
        chk("inbuf 8 bytes", wr_hits[31:0], 32'd8);
        rd_chk("INBUF_ADDR +8", INBUF_ADDR, 32'd108);
        chk("byte100", {24'd0, shadow[100]}, 32'h11);
        chk("byte101", {24'd0, shadow[101]}, 32'h22);
        chk("byte102", {24'd0, shadow[102]}, 32'h33);
        chk("byte103", {24'd0, shadow[103]}, 32'h44);
        chk("byte104", {24'd0, shadow[104]}, 32'h55);
        chk("byte105", {24'd0, shadow[105]}, 32'h66);
        chk("byte106", {24'd0, shadow[106]}, 32'h77);
        chk("byte107", {24'd0, shadow[107]}, 32'h88);

        //---- 14. INBUF wstrb 로 일부 byte 만 ----
        axi_w(INBUF_ADDR, 32'd200);
        for (i = 200; i < 204; i = i + 1) shadow[i] = 8'h00;
        wr_hits = 0;
        axi_write(INBUF_DATA, 32'hFFEEDDCC, 4'b1010);   // byte1, byte3
        repeat (4) @(posedge clk);
        chk("inbuf strb hits", wr_hits[31:0], 32'd2);
        chk("byte200 keep", {24'd0, shadow[200]}, 32'h00);
        chk("byte201 wr"  , {24'd0, shadow[201]}, 32'hDD);
        chk("byte202 keep", {24'd0, shadow[202]}, 32'h00);
        chk("byte203 wr"  , {24'd0, shadow[203]}, 32'hFF);
        rd_chk("INBUF_ADDR +4 strb", INBUF_ADDR, 32'd204);

        //---- 14b. INBUF 포인터 4정렬 강제 / 8192 overflow -> ERROR ----
        axi_w(INBUF_ADDR, 32'd8190);
        rd_chk("INBUF_ADDR align", INBUF_ADDR, 32'd8188);
        axi_w(STATUS, 32'h0000_0004);            // ERROR 선클리어
        wr_hits = 0;
        axi_w(INBUF_DATA, 32'h0F0E0D0C);         // 마지막 word : 8188..8191
        repeat (4) @(posedge clk);
        chk("last word 4 bytes", wr_hits[31:0], 32'd4);
        rd_chk("INBUF_ADDR = 8192", INBUF_ADDR, 32'd8192);
        rd_chk("no error at 8192", STATUS, 32'h0000_0008);
        wr_hits = 0;
        axi_w(INBUF_DATA, 32'hCAFEBABE);         // overflow
        repeat (6) @(posedge clk);
        chk("overflow dropped", wr_hits[31:0], 32'd0);
        rd_chk("overflow -> ERROR", STATUS, 32'h0000_000C);
        axi_w(STATUS, 32'h0000_0004);

        //---- 15. SOFT_RESET : npu_rstn low, 포인터 0 ----
        rstn_low = 0;
        fork
            begin : mon
                for (i = 0; i < 40; i = i + 1) begin
                    @(posedge clk);
                    if (!npu_rstn) rstn_low = rstn_low + 1;
                end
            end
            axi_w(CTRL, 32'h0000_0002);          // SOFT_RESET
        join
        if (rstn_low < 8) begin
            $display("[FAIL] soft reset : npu_rstn low %0d cycle (>=8 기대)", rstn_low);
            errs = errs + 1;
        end
        checks = checks + 1;
        rd_chk("INBUF_ADDR after softrst", INBUF_ADDR, 32'd0);
        chk("npu_rstn released", {31'd0, npu_rstn}, 32'd1);

        //---- 16. 미정의 Offset : read 0 / write 무시 / 응답 정상 ----
        axi_w(UNKNOWN, 32'hFFFF_FFFF);
        rd_chk("unknown offset", UNKNOWN, 32'h0000_0000);
        rd_chk("SCRATCH intact", SCRATCH, 32'hDEAD_33EF);

        //---- 17. 연속 write/read burst 무결성 ----
        for (i = 0; i < 16; i = i + 1) axi_w(SCRATCH, 32'h1000_0000 + i);
        rd_chk("SCRATCH burst", SCRATCH, 32'h1000_000F);

        //================================================================
        // 18. CR A-003 변경 1 : 0x58 SERVO_POS_STAT / 0x5C CONTROL_STAT (RO)
        //     C 가 만든 값이 그대로 읽히고, write 는 무시돼야 한다.
        //================================================================
        @(negedge clk);
        servo_pos_stat = 32'h5A_3C_78_96;    // {TILT2,PAN2,TILT1,PAN1}
        control_stat   = 32'h0001_ABCD;
        @(posedge clk);
        rd_chk("SERVO_POS_STAT", SERVO_POS , 32'h5A3C_7896);
        rd_chk("CONTROL_STAT"  , CONTROL_ST, 32'h0001_ABCD);
        // RO 니까 write 해도 안 바뀌고, RESP 는 OKAY 여야 한다
        axi_w(SERVO_POS , 32'hFFFF_FFFF);
        axi_w(CONTROL_ST, 32'hFFFF_FFFF);
        rd_chk("SERVO_POS_STAT RO", SERVO_POS , 32'h5A3C_7896);
        rd_chk("CONTROL_STAT RO"  , CONTROL_ST, 32'h0001_ABCD);
        // 입력이 바뀌면 따라와야 한다 (레지스터에 갇히면 안 된다)
        @(negedge clk);
        servo_pos_stat = 32'h0000_0020;
        control_stat   = 32'h0000_0800;      // EMERGENCY_STOP(bit11)
        @(posedge clk);
        rd_chk("SERVO_POS_STAT 갱신", SERVO_POS , 32'h0000_0020);
        rd_chk("CONTROL_STAT 갱신"  , CONTROL_ST, 32'h0000_0800);

        //================================================================
        // 19. CR A-003 변경 2 : Direct START (CTRL[5] HW_START_EN)
        //================================================================
        axi_w(STATUS, 32'h0000_0005);            // DONE/ERROR 선클리어
        axi_w(CTRL,   32'h0000_0000);            // 전부 해제

        //-- 19a. 무장 전에는 hw_start 를 무시한다 (예전 동작 보존) --
        start_cnt = 0;
        pulse_hw_start;
        chk("hw_start ignored (unarmed)", start_cnt[31:0], 32'd0);
        rd_chk("no error when unarmed", STATUS, 32'h0000_0008);   // tvalid 만

        //-- 19b. HW_START_EN 만 켜도 INPUT_SRC=0 이면 여전히 무시 --
        axi_w(CTRL, 32'h0000_0020);              // HW_START_EN=1, INPUT_SRC=0
        rd_chk("CTRL HW_START_EN", CTRL, 32'h0000_0020);
        start_cnt = 0;
        pulse_hw_start;
        chk("hw_start ignored (INPUT_SRC=0)", start_cnt[31:0], 32'd0);

        //-- 19c. 무장 (HW_START_EN & INPUT_SRC) 후에는 pulse 가 START --
        axi_w(CTRL, 32'h0000_0028);              // HW_START_EN=1, INPUT_SRC=1
        rd_chk("CTRL armed", CTRL, 32'h0000_0028);
        @(negedge clk) npu_done = 1'b1;          // DONE sticky 를 미리 세운다
        @(negedge clk) npu_done = 1'b0;
        rd_chk("DONE sticky before hw start", STATUS, 32'h0000_0009);
        start_cnt = 0;
        pulse_hw_start;
        chk("hw_start -> start pulse x1", start_cnt[31:0], 32'd1);
        // START 는 DONE sticky 를 지운다. AXI START 와 같은 규칙.
        rd_chk("DONE cleared by hw start", STATUS, 32'h0000_0008);

        //-- 19d. 무장 중 PS START 는 거부 + ERROR (두 START 동시 금지) --
        axi_w(STATUS, 32'h0000_0004);            // ERROR 선클리어
        start_cnt = 0;
        axi_w(CTRL, 32'h0000_0029);              // START | INPUT_SRC | HW_START_EN
        repeat (3) @(posedge clk);
        chk("PS START rejected while armed", start_cnt[31:0], 32'd0);
        rd_chk("armed START -> ERROR", STATUS, 32'h0000_000C);   // tvalid|err

        //-- 19e. BUSY 중 hw_start 는 유실. ERROR 로 남긴다 --
        axi_w(STATUS, 32'h0000_0004);
        @(negedge clk) npu_busy = 1'b1;
        start_cnt = 0;
        pulse_hw_start;
        chk("hw_start dropped when busy", start_cnt[31:0], 32'd0);
        rd_chk("busy hw_start -> ERROR", STATUS, 32'h0000_000E); // tvalid|err|busy
        @(negedge clk) npu_busy = 1'b0;
        axi_w(STATUS, 32'h0000_0004);

        //-- 19f. 무장 해제와 동시에 START 를 쓰면 정상 수락 --
        //   PS 가 CTRL 에 START|INPUT_SRC 만 쓰면 그 write 가 곧 무장 해제다.
        start_cnt = 0;
        axi_w(CTRL, 32'h0000_0009);              // START | INPUT_SRC (HW_START_EN=0)
        repeat (3) @(posedge clk);
        chk("PS START ok after disarm", start_cnt[31:0], 32'd1);
        rd_chk("CTRL disarmed", CTRL, 32'h0000_0008);
        rd_chk("no error after disarm", STATUS, 32'h0000_0008);

        //-- 19g. 해제 뒤 hw_start 는 다시 무시된다 --
        axi_w(CTRL, 32'h0000_0000);
        start_cnt = 0;
        pulse_hw_start;
        chk("hw_start ignored after disarm", start_cnt[31:0], 32'd0);

        //================================================================
        // 19h/19i. 같은 cycle 충돌 — 인수인계 cycle
        //   PS 의 CTRL write 가 도는 바로 그 cycle 에 C 의 tensor_start 가 오면?
        //   npu_start 가 OR 라 밖에서는 늘 pulse 1 개로 보인다. 그래서
        //   내부 start_pulse / hw_start_pulse 를 따로 세서 배타성을 직접 본다.
        //================================================================
        axi_w(STATUS, 32'h0000_0005);
        axi_w(CTRL,   32'h0000_0028);            // 무장 (HW_START_EN | INPUT_SRC)
        rd_chk("19h 준비: 무장 확인", CTRL, 32'h0000_0028);

        //-- 19h. 무장 해제 + START (0x09) 와 hw_start 가 같은 cycle --
        //   PS 가 소유권을 가져가는 write 다. PS 가 이기고 HW pulse 는 유실 -> ERROR.
        axi_w(STATUS, 32'h0000_0004);            // ERROR 선클리어
        start_cnt = 0; ps_pulse_cnt = 0; hw_pulse_cnt = 0; collide_cnt = 0;
        ctrl_write_with_hw_start(32'h0000_0009);
        chk("19h 충돌이 실제로 발생했다", collide_cnt[31:0], 32'd1);
        chk("19h npu_start pulse 1 개",  start_cnt[31:0],    32'd1);
        chk("19h PS 쪽이 이긴다",        ps_pulse_cnt[31:0], 32'd1);
        chk("19h HW pulse 는 눌린다",    hw_pulse_cnt[31:0], 32'd0);
        rd_chk("19h 유실은 ERROR 로", STATUS, 32'h0000_000C);   // tvalid|err
        rd_chk("19h 무장 해제됨",     CTRL,   32'h0000_0008);

        //-- 19i. 무장 유지 + START (0x29) 와 hw_start 가 같은 cycle --
        //   소유권을 안 넘겼으므로 PS 쪽이 거부되고 HW 가 이긴다.
        axi_w(STATUS, 32'h0000_0004);
        axi_w(CTRL,   32'h0000_0028);            // 다시 무장
        start_cnt = 0; ps_pulse_cnt = 0; hw_pulse_cnt = 0; collide_cnt = 0;
        ctrl_write_with_hw_start(32'h0000_0029);
        chk("19i 충돌이 실제로 발생했다", collide_cnt[31:0], 32'd1);
        chk("19i npu_start pulse 1 개",  start_cnt[31:0],    32'd1);
        chk("19i HW 쪽이 이긴다",        hw_pulse_cnt[31:0], 32'd1);
        chk("19i PS pulse 는 거부",      ps_pulse_cnt[31:0], 32'd0);
        rd_chk("19i 거부는 ERROR 로", STATUS, 32'h0000_000C);
        rd_chk("19i 무장 유지됨",     CTRL,   32'h0000_0028);

        //-- 19j. 전 구간 배타성 : 두 pulse 가 같은 cycle 에 뜬 적이 없다 --
        axi_w(CTRL,   32'h0000_0000);
        axi_w(STATUS, 32'h0000_0005);
        chk("두 START 가 같은 cycle 에 뜬 적 없다", both_cnt[31:0], 32'd0);

        $display("");
        if (errs == 0) $display("[PASS] tb_npu_axi : %0d check 전부 일치", checks);
        else           $display("[FAIL] tb_npu_axi : %0d / %0d 불일치", errs, checks);
        $finish;
    end

    initial begin
        #2000000;
        $display("[FAIL] tb_npu_axi : timeout");
        $finish;
    end
endmodule
