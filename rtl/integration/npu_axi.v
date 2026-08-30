`timescale 1ns/1ps
//=====================================================================
// npu_axi : AXI4-Lite Slave <-> npu_core Register Bridge
// 담당: A
// 기준: TEAM_COMMON_AI_INTEGRATION_SPEC v1.3 §20 (Offset 예약 맵)
//       docs/freeze/D3_FREEZE_REQUEST_A_002.md (Bit Field 제안)
//
//  - Offset 0x00 ~ 0x34 는 공통 지침 §20 예약 맵 그대로. 순서/의미 변경 없음.
//  - 0x38 이후는 뒤에 추가한 확장 Register (§20 규칙 준수).
//      0x38~0x44  A 소유 (VERSION / INBUF / SCRATCH)
//      0x48~0x54  C 소유 — Pan/Tilt 2호기(레이저 헤드). 0x20/0x24 는 카메라 헤드.
//      0x58~0x5C  C 소유 RO 상태 (SERVO_POS_STAT / CONTROL_STAT)
//                 -> CHANGE_REQUEST_A_003 변경 1. C 승인 2026-08-27
//                    (docs/from_c/C_TO_A_REPLY_005.md §4)
//  - 단일 클럭 도메인: s_axi_aclk == NPU clk (FCLK_CLK0 100 MHz). CDC 없음.
//  - Unknown Offset : read 0 / write ignore / RESP 는 항상 OKAY (PS Bus Error 방지)
//
//  VERSION 이력
//    0x4E50_0100  초판. 0x00~0x54.
//    0x4E50_0101  0x58/0x5C RO 추가 + CTRL[5] HW_START_EN 추가 (CR A-003).
//                 뒤에만 붙였으므로 기존 offset 동작은 한 비트도 안 바뀐다.
//                 그런데도 minor 를 올린 이유: 새 ELF 가 옛 비트스트림 위에서
//                 0x58 을 읽으면 조용히 0 이 나오고, Direct START 도 조용히
//                 안 걸린다. 그 조합을 STEP 1 에서 바로 잡으려고 올렸다.
//=====================================================================
module npu_axi #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 12,
    parameter [31:0]  VERSION_ID         = 32'h4E50_0101  // "NP" v1.1
)(
    //-----------------------------------------------------------------
    // AXI4-Lite Slave
    //-----------------------------------------------------------------
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire                              s_axi_aclk,
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                              s_axi_aresetn,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire [2:0]                        s_axi_awprot,
    input  wire                              s_axi_awvalid,
    output wire                              s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                              s_axi_wvalid,
    output wire                              s_axi_wready,
    output wire [1:0]                        s_axi_bresp,
    output wire                              s_axi_bvalid,
    input  wire                              s_axi_bready,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire [2:0]                        s_axi_arprot,
    input  wire                              s_axi_arvalid,
    output wire                              s_axi_arready,
    output wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    output wire [1:0]                        s_axi_rresp,
    output wire                              s_axi_rvalid,
    input  wire                              s_axi_rready,

    //-----------------------------------------------------------------
    // NPU Core (A)
    //-----------------------------------------------------------------
    output wire                              npu_rstn,      // aresetn & ~SOFT_RESET
    output wire                              npu_start,     // 1-cycle pulse
    //-----------------------------------------------------------------
    // Direct START (CR A-003 변경 2, C 승인 2026-08-27)
    //  C 의 event_accumulator 가 Tensor 전송을 끝내면 tensor_start 를
    //  1 cycle 올린다. 그것을 여기로 받는다.
    //  CTRL[5] HW_START_EN & CTRL[3] INPUT_SRC 가 둘 다 1 일 때만 먹는다.
    //  reset 값이 0 이므로 아무것도 안 하면 예전과 완전히 같다.
    //-----------------------------------------------------------------
    input  wire                              hw_start,
    input  wire                              npu_busy,
    input  wire                              npu_done,      // 1-cycle pulse
    input  wire [31:0]                       npu_cycle_cnt,
    output wire signed [7:0]                 npu_score_th,
    input  wire                              npu_target_valid,
    input  wire [5:0]                        npu_target_x,
    input  wire [5:0]                        npu_target_y,
    input  wire signed [7:0]                 npu_target_score,

    //-----------------------------------------------------------------
    // Input Buffer Write (PS 경로).  C 하드웨어 경로와의 mux 는 top_system 에서.
    //-----------------------------------------------------------------
    output wire                              axi_ext_we,
    output wire [12:0]                       axi_ext_addr,
    output wire signed [7:0]                 axi_ext_data,
    output wire                              input_src,     // 0=PS/AXI, 1=C HW

    //-----------------------------------------------------------------
    // C 모듈 (Event / Tracking / Servo) 용 Register.  Bit 의미는 C 가 정의.
    //-----------------------------------------------------------------
    output wire [31:0]                       event_cfg,     // 0x08
    input  wire [31:0]                       input_stat,    // 0x0C (C -> PS)
    output wire [31:0]                       pan_cmd,       // 0x20
    output wire [31:0]                       tilt_cmd,      // 0x24
    output wire [31:0]                       laser_ctrl,    // 0x28
    output wire [31:0]                       safe_limit,    // 0x2C
    output wire [31:0]                       track_err_x,   // 0x30
    output wire [31:0]                       track_err_y,   // 0x34

    //-----------------------------------------------------------------
    // Pan/Tilt 2호기 = 레이저 전용 헤드 (C 소유). 카메라 헤드는 0x20/0x24.
    //-----------------------------------------------------------------
    output wire [31:0]                       pan2_cmd,      // 0x48
    output wire [31:0]                       tilt2_cmd,     // 0x4C
    output wire [31:0]                       safe_limit2,   // 0x50
    output wire [31:0]                       laser_cal,     // 0x54

    //-----------------------------------------------------------------
    // C 상태 RO (CR A-003 변경 1, C 승인 2026-08-27)
    //  bit 배치는 C 가 정의한 것을 그대로 쓴다
    //  (rtl/control/c_event_control_top.v 머리주석).
    //  여기서는 조합 없이 통째로 read mux 에만 태운다.
    //  top_system_c 가 이미 1 cycle 등록해서 준다 (§13.3 / OOC critical path).
    //-----------------------------------------------------------------
    input  wire [31:0]                       servo_pos_stat, // 0x58 RO
    input  wire [31:0]                       control_stat,   // 0x5C RO

    output wire                              irq            // level, IRQ_EN & DONE
);
    localparam [1:0] RESP_OKAY = 2'b00;

    // Register word index (byte offset >> 2). 상위 주소 비트는 alias.
    localparam [4:0] A_CTRL       = 5'h00; // 0x00
    localparam [4:0] A_STATUS     = 5'h01; // 0x04
    localparam [4:0] A_EVENT_CFG  = 5'h02; // 0x08
    localparam [4:0] A_INPUT_STAT = 5'h03; // 0x0C
    localparam [4:0] A_CYCLE_CNT  = 5'h04; // 0x10
    localparam [4:0] A_RESULT_X   = 5'h05; // 0x14
    localparam [4:0] A_RESULT_Y   = 5'h06; // 0x18
    localparam [4:0] A_RESULT_SC  = 5'h07; // 0x1C
    localparam [4:0] A_PAN_CMD    = 5'h08; // 0x20
    localparam [4:0] A_TILT_CMD   = 5'h09; // 0x24
    localparam [4:0] A_LASER_CTRL = 5'h0A; // 0x28
    localparam [4:0] A_SAFE_LIMIT = 5'h0B; // 0x2C
    localparam [4:0] A_TRACK_ERRX = 5'h0C; // 0x30
    localparam [4:0] A_TRACK_ERRY = 5'h0D; // 0x34
    localparam [4:0] A_VERSION    = 5'h0E; // 0x38
    localparam [4:0] A_INBUF_ADDR = 5'h0F; // 0x3C
    localparam [4:0] A_INBUF_DATA = 5'h10; // 0x40
    localparam [4:0] A_SCRATCH    = 5'h11; // 0x44
    // --- Pan/Tilt 2호기 (레이저 전용 헤드). C 소유. v1.5 §20.1 ---
    localparam [4:0] A_PAN2_CMD   = 5'h12; // 0x48
    localparam [4:0] A_TILT2_CMD  = 5'h13; // 0x4C
    localparam [4:0] A_SAFE_LIM2  = 5'h14; // 0x50
    localparam [4:0] A_LASER_CAL  = 5'h15; // 0x54
    // --- C 상태 RO. CR A-003 변경 1 ---
    localparam [4:0] A_SERVO_POS  = 5'h16; // 0x58
    localparam [4:0] A_CONTROL_ST = 5'h17; // 0x5C

    //=================================================================
    // Register file
    //=================================================================
    reg         ctrl_input_src;
    reg         ctrl_irq_en;
    reg         ctrl_hw_start_en;
    reg  [31:0] r_event_cfg;
    reg  signed [7:0] r_score_th;
    reg  [31:0] r_pan_cmd, r_tilt_cmd, r_laser_ctrl, r_safe_limit;
    reg  [31:0] r_track_err_x, r_track_err_y;
    reg  [31:0] r_scratch;
    reg  [31:0] r_pan2_cmd, r_tilt2_cmd, r_safe_limit2, r_laser_cal;
    reg  [13:0] r_inbuf_ptr;   // byte 단위, 4 정렬. 8192 도달 = 1 frame 적재 완료

    reg         done_sticky;
    reg         err_sticky;

    reg         start_pulse;
    reg         hw_start_pulse;
    reg  [3:0]  soft_rst_cnt;   // SOFT_RESET 시 npu_rstn 를 16 cycle low 유지

    //=================================================================
    // Write channel FSM
    //   W_IDLE  : AW / W 수집
    //   W_WRITE : 1 cycle, 레지스터 갱신 / INBUF 확장기 기동
    //   W_WAIT  : INBUF 확장기(4 byte) 완료 대기
    //   W_RESP  : BVALID
    //=================================================================
    localparam [1:0] W_IDLE = 2'd0, W_WRITE = 2'd1, W_WAIT = 2'd2, W_RESP = 2'd3;

    reg  [1:0]  wst;
    reg         aw_got, w_got;
    reg  [C_S_AXI_ADDR_WIDTH-1:0] awaddr_q;
    reg  [31:0] wdata_q;
    reg  [3:0]  wstrb_q;
    reg         bvalid_r;

    wire [4:0]  waddr_idx = awaddr_q[6:2];
    wire [31:0] bmask = {{8{wstrb_q[3]}}, {8{wstrb_q[2]}},
                         {8{wstrb_q[1]}}, {8{wstrb_q[0]}}};
    wire [31:0] wupd_ev  = (r_event_cfg   & ~bmask) | (wdata_q & bmask);
    wire [31:0] wupd_pan = (r_pan_cmd     & ~bmask) | (wdata_q & bmask);
    wire [31:0] wupd_tlt = (r_tilt_cmd    & ~bmask) | (wdata_q & bmask);
    wire [31:0] wupd_lsr = (r_laser_ctrl  & ~bmask) | (wdata_q & bmask);
    wire [31:0] wupd_saf = (r_safe_limit  & ~bmask) | (wdata_q & bmask);
    wire [31:0] wupd_tex = (r_track_err_x & ~bmask) | (wdata_q & bmask);
    wire [31:0] wupd_tey = (r_track_err_y & ~bmask) | (wdata_q & bmask);
    wire [31:0] wupd_scr = (r_scratch     & ~bmask) | (wdata_q & bmask);
    wire [31:0] wupd_pn2 = (r_pan2_cmd    & ~bmask) | (wdata_q & bmask);
    wire [31:0] wupd_tl2 = (r_tilt2_cmd   & ~bmask) | (wdata_q & bmask);
    wire [31:0] wupd_sl2 = (r_safe_limit2 & ~bmask) | (wdata_q & bmask);
    wire [31:0] wupd_cal = (r_laser_cal   & ~bmask) | (wdata_q & bmask);

    assign s_axi_awready = (wst == W_IDLE) & ~aw_got;
    assign s_axi_wready  = (wst == W_IDLE) & ~w_got;
    assign s_axi_bvalid  = bvalid_r;
    assign s_axi_bresp   = RESP_OKAY;

    //=================================================================
    // INBUF byte expander : AXI 32bit 1회 -> act_buf 8bit 4회
    //=================================================================
    reg        ib_run;
    reg  [1:0] ib_cnt;
    reg [31:0] ib_data;
    reg  [3:0] ib_strb;
    reg [13:0] ib_base;

    wire [7:0] ib_byte = (ib_cnt == 2'd0) ? ib_data[7:0]   :
                         (ib_cnt == 2'd1) ? ib_data[15:8]  :
                         (ib_cnt == 2'd2) ? ib_data[23:16] : ib_data[31:24];

    assign axi_ext_we   = ib_run & ib_strb[ib_cnt];
    assign axi_ext_addr = ib_base[12:0] + {11'd0, ib_cnt};
    assign axi_ext_data = ib_byte;

    // INBUF_DATA write 허용 조건 : NPU idle 이고 PS 가 입력 소스일 때만
    wire ib_write_req = (waddr_idx == A_INBUF_DATA);
    // NPU idle + PS 가 입력 소스 + 포인터가 buffer 범위 안(<8192) 일 때만 허용
    wire ib_allowed   = ~npu_busy & ~ctrl_input_src & ~r_inbuf_ptr[13];

    //=================================================================
    // Direct START 무장 조건 (CR A-003 변경 2)
    //
    //  hw_start_armed : 지금 등록돼 있는 CTRL 값 기준. HW 펄스를 받을지 판정
    //  w_arm_after    : "이번 CTRL write 를 반영한 뒤" 의 무장 상태.
    //                   PS 의 START 를 받을지 판정할 때 이걸 쓴다.
    //
    //  왜 두 개가 필요한가. CTRL 은 wstrb[0] write 한 번에 통째로 바뀐다.
    //  START 와 HW_START_EN 을 같은 word 에 쓰면 "직전 무장 상태"로 판정할지
    //  "이 write 로 만들어질 무장 상태"로 판정할지 애매해진다. PS 가 그 word 를
    //  쓴 순간의 의도는 write 값 자체에 다 들어 있으므로 write 값으로 판정한다.
    //  덕분에 순서 의존이 사라진다.
    //
    //  C 지시 (C_TO_A_REPLY_005.md §4) : "두 START 를 동시에 활성화하지 마라."
    //  그래서 무장 상태에서 들어온 PS START 는 먹이지 않고 ERROR 로 남긴다.
    //  거꾸로 PS 가 CTRL 에 START 만 쓰면 (HW_START_EN=0 이 같이 쓰이므로)
    //  그 write 가 곧 무장 해제라 START 는 정상 수락된다.
    //
    //  ## 같은 cycle 충돌 (인수인계 cycle)
    //  무장 상태에서 PS 가 CTRL 에 START|INPUT_SRC (= 무장 해제 + START) 를 쓰는
    //  바로 그 cycle 에 C 의 tensor_start 가 오면 두 경로가 동시에 성립한다.
    //    - PS 쪽 : w_arm_after = 0 이므로 START 수락
    //    - HW 쪽 : hw_start_armed 는 아직 등록된 옛 값이라 1
    //  npu_start 가 OR 라 core 에는 pulse 가 한 번만 가서 이중 추론은 없다.
    //  하지만 그러면 "두 START 가 배타적" 이라는 말이 레지스터 수준에서 거짓이 되고,
    //  ** HW 프레임 시작 1 건이 아무 흔적 없이 사라진다. **
    //  그래서 ps_start_accept 로 HW 쪽을 눌러 배타성을 실제로 강제하고,
    //  잃어버린 pulse 는 다른 유실과 똑같이 ERROR 로 남긴다.
    //  우선권을 PS 에 준 이유: 그 cycle 의 write 가 곧 "이제부터 내가 START 를
    //  소유한다" 는 명시적 선언이기 때문이다. 반대로 무장을 유지한 채(0x29)
    //  START 를 쓰면 PS 쪽이 거부되고 HW 가 이긴다 — 소유권을 안 넘겼으니까.
    //=================================================================
    wire hw_start_armed = ctrl_hw_start_en & ctrl_input_src;
    wire w_arm_after    = wdata_q[5] & wdata_q[3];
    // 이번 cycle 에 PS START 가 실제로 수락되는가. W_WRITE 의 A_CTRL 분기와
    // 조건이 완전히 같아야 한다. 한쪽만 고치면 배타성이 깨진다.
    wire ps_start_accept = (wst == W_WRITE) & (waddr_idx == A_CTRL)
                         & wstrb_q[0] & wdata_q[0]
                         & ~npu_busy & ~w_arm_after;
    // SOFT_RESET 중에는 npu_rstn 이 low 라 core 가 start 를 못 본다.
    // 자유 구동인 HW 펄스가 그 구간에 들어오면 조용히 한 프레임을 잃는다.
    // 받지 않고 ERROR 로 남겨 PS 가 알아채게 한다.
    wire hw_start_req   = hw_start_armed & hw_start;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            wst <= W_IDLE; aw_got <= 1'b0; w_got <= 1'b0;
            awaddr_q <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            wdata_q <= 32'd0; wstrb_q <= 4'd0; bvalid_r <= 1'b0;
            ctrl_input_src <= 1'b0; ctrl_irq_en <= 1'b0;
            ctrl_hw_start_en <= 1'b0;
            r_event_cfg <= 32'd0; r_score_th <= 8'sd0;
            r_pan_cmd <= 32'd0; r_tilt_cmd <= 32'd0;
            r_laser_ctrl <= 32'd0; r_safe_limit <= 32'd0;
            r_track_err_x <= 32'd0; r_track_err_y <= 32'd0;
            r_scratch <= 32'd0; r_inbuf_ptr <= 14'd0;
            r_pan2_cmd <= 32'd0; r_tilt2_cmd <= 32'd0;
            r_safe_limit2 <= 32'd0; r_laser_cal <= 32'd0;
            done_sticky <= 1'b0; err_sticky <= 1'b0;
            start_pulse <= 1'b0; hw_start_pulse <= 1'b0; soft_rst_cnt <= 4'd0;
            ib_run <= 1'b0; ib_cnt <= 2'd0; ib_data <= 32'd0;
            ib_strb <= 4'd0; ib_base <= 14'd0;
        end else begin
            start_pulse    <= 1'b0;
            hw_start_pulse <= 1'b0;

            // ---- sticky status ----
            if (npu_done) done_sticky <= 1'b1;

            // ---- soft reset timer ----
            if (soft_rst_cnt != 4'd0) soft_rst_cnt <= soft_rst_cnt - 4'd1;

            //-------------------------------------------------------------
            // Direct START (CR A-003 변경 2)
            //  AXI FSM 과 무관하게 매 cycle 본다. tensor_start 는 1 cycle 이라
            //  W_WRITE 안에서 보면 놓친다.
            //
            //  받지 않는 3 가지. 전부 프레임 1 장 유실이라 ERROR 로 남긴다.
            //    npu_busy          추론 중
            //    soft_rst_cnt != 0 core 가 reset 중이라 start 를 못 본다
            //    ps_start_accept   같은 cycle 에 PS 가 START 소유권을 가져갔다
            //-------------------------------------------------------------
            if (hw_start_req) begin
                if (npu_busy | (soft_rst_cnt != 4'd0) | ps_start_accept) begin
                    err_sticky <= 1'b1;      // 프레임 1 장 유실. PS 가 알게 한다
                end else begin
                    hw_start_pulse <= 1'b1;
                    done_sticky    <= 1'b0;
                end
            end

            // ---- INBUF expander ----
            if (ib_run) begin
                if (ib_cnt == 2'd3) begin
                    ib_run      <= 1'b0;
                    r_inbuf_ptr <= ib_base + 14'd4;
                end
                ib_cnt <= ib_cnt + 2'd1;
            end

            case (wst)
            //-------------------------------------------------------------
            W_IDLE: begin
                if (s_axi_awvalid & s_axi_awready) begin
                    awaddr_q <= s_axi_awaddr; aw_got <= 1'b1;
                end
                if (s_axi_wvalid & s_axi_wready) begin
                    wdata_q <= s_axi_wdata; wstrb_q <= s_axi_wstrb; w_got <= 1'b1;
                end
                if ((aw_got | (s_axi_awvalid & s_axi_awready)) &
                    (w_got  | (s_axi_wvalid  & s_axi_wready ))) wst <= W_WRITE;
            end
            //-------------------------------------------------------------
            W_WRITE: begin
                wst <= W_WAIT;
                case (waddr_idx)
                A_CTRL: begin
                    if (wstrb_q[0]) begin
                        if (wdata_q[0]) begin           // START
                            // Direct START 무장 중이면 PS START 는 거부 (C 지시)
                            if (npu_busy | w_arm_after) err_sticky <= 1'b1;
                            else begin
                                start_pulse <= 1'b1;
                                done_sticky <= 1'b0;
                            end
                        end
                        if (wdata_q[1]) begin           // SOFT_RESET
                            soft_rst_cnt <= 4'hF;
                            done_sticky  <= 1'b0;
                            r_inbuf_ptr  <= 14'd0;
                        end
                        ctrl_input_src   <= wdata_q[3];
                        ctrl_irq_en      <= wdata_q[4];
                        ctrl_hw_start_en <= wdata_q[5];
                    end
                end
                A_STATUS: begin                          // W1C
                    if (wstrb_q[0]) begin
                        if (wdata_q[0]) done_sticky <= 1'b0;
                        if (wdata_q[2]) err_sticky  <= 1'b0;
                    end
                end
                A_EVENT_CFG : r_event_cfg   <= wupd_ev;
                A_RESULT_SC : if (wstrb_q[2]) r_score_th <= wdata_q[23:16];
                A_PAN_CMD   : r_pan_cmd     <= wupd_pan;
                A_TILT_CMD  : r_tilt_cmd    <= wupd_tlt;
                A_LASER_CTRL: r_laser_ctrl  <= wupd_lsr;
                A_SAFE_LIMIT: r_safe_limit  <= wupd_saf;
                A_TRACK_ERRX: r_track_err_x <= wupd_tex;
                A_TRACK_ERRY: r_track_err_y <= wupd_tey;
                A_SCRATCH   : r_scratch     <= wupd_scr;
                A_PAN2_CMD  : r_pan2_cmd    <= wupd_pn2;
                A_TILT2_CMD : r_tilt2_cmd   <= wupd_tl2;
                A_SAFE_LIM2 : r_safe_limit2 <= wupd_sl2;
                A_LASER_CAL : r_laser_cal   <= wupd_cal;
                // 4 byte 정렬 강제 : word 경계를 넘는 부분 기록을 막는다
                A_INBUF_ADDR: if (wstrb_q[0] & wstrb_q[1])
                                  r_inbuf_ptr <= {wdata_q[13:2], 2'b00};
                A_INBUF_DATA: begin
                    if (ib_allowed) begin
                        ib_run  <= 1'b1;
                        ib_cnt  <= 2'd0;
                        ib_data <= wdata_q;
                        ib_strb <= wstrb_q;
                        ib_base <= r_inbuf_ptr;
                    end else begin
                        err_sticky <= 1'b1;
                    end
                end
                default: ;   // unknown offset : ignore, RESP=OKAY
                endcase
            end
            //-------------------------------------------------------------
            W_WAIT: begin
                // INBUF 확장 중이면 대기. 그 외에는 즉시 응답.
                if (!(ib_write_req & ib_run)) begin
                    bvalid_r <= 1'b1;
                    wst      <= W_RESP;
                end
            end
            //-------------------------------------------------------------
            W_RESP: begin
                if (s_axi_bready) begin
                    bvalid_r <= 1'b0;
                    aw_got   <= 1'b0;
                    w_got    <= 1'b0;
                    wst      <= W_IDLE;
                end
            end
            endcase
        end
    end

    //=================================================================
    // Read channel
    //=================================================================
    reg        arready_r, rvalid_r;
    reg [31:0] rdata_r;
    wire [4:0] raddr_idx = s_axi_araddr[6:2];

    assign s_axi_arready = arready_r;
    assign s_axi_rvalid  = rvalid_r;
    assign s_axi_rdata   = rdata_r;
    assign s_axi_rresp   = RESP_OKAY;

    reg [31:0] rmux;
    always @* begin
        case (raddr_idx)
        A_CTRL       : rmux = {26'd0, ctrl_hw_start_en, ctrl_irq_en,
                                      ctrl_input_src, 1'b0, 2'b00};
        A_STATUS     : rmux = {28'd0, npu_target_valid, err_sticky,
                                      npu_busy, done_sticky};
        A_EVENT_CFG  : rmux = r_event_cfg;
        A_INPUT_STAT : rmux = input_stat;
        A_CYCLE_CNT  : rmux = npu_cycle_cnt;
        A_RESULT_X   : rmux = {26'd0, npu_target_x};
        A_RESULT_Y   : rmux = {26'd0, npu_target_y};
        A_RESULT_SC  : rmux = {8'd0, r_score_th, 8'd0, npu_target_score};
        A_PAN_CMD    : rmux = r_pan_cmd;
        A_TILT_CMD   : rmux = r_tilt_cmd;
        A_LASER_CTRL : rmux = r_laser_ctrl;
        A_SAFE_LIMIT : rmux = r_safe_limit;
        A_TRACK_ERRX : rmux = r_track_err_x;
        A_TRACK_ERRY : rmux = r_track_err_y;
        A_VERSION    : rmux = VERSION_ID;
        A_INBUF_ADDR : rmux = {18'd0, r_inbuf_ptr};
        A_INBUF_DATA : rmux = 32'd0;          // write only
        A_SCRATCH    : rmux = r_scratch;
        A_PAN2_CMD   : rmux = r_pan2_cmd;
        A_TILT2_CMD  : rmux = r_tilt2_cmd;
        A_SAFE_LIM2  : rmux = r_safe_limit2;
        A_LASER_CAL  : rmux = r_laser_cal;
        A_SERVO_POS  : rmux = servo_pos_stat;
        A_CONTROL_ST : rmux = control_stat;
        default      : rmux = 32'd0;
        endcase
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            arready_r <= 1'b1; rvalid_r <= 1'b0; rdata_r <= 32'd0;
        end else begin
            if (arready_r & s_axi_arvalid) begin
                rdata_r   <= rmux;
                rvalid_r  <= 1'b1;
                arready_r <= 1'b0;
            end else if (rvalid_r & s_axi_rready) begin
                rvalid_r  <= 1'b0;
                arready_r <= 1'b1;
            end
        end
    end

    //=================================================================
    // Outputs
    //=================================================================
    assign npu_rstn     = s_axi_aresetn & (soft_rst_cnt == 4'd0);
    //  두 START 는 서로 배타적이다. `start_pulse` 와 `hw_start_pulse` 가 같은
    //  cycle 에 1 이 되는 경우는 없다 — w_arm_after 가 PS 쪽을, ps_start_accept
    //  가 HW 쪽을 서로 눌러 준다. 그래도 OR 로 두는 이유는 둘 다 1 cycle pulse 라
    //  합치는 게 mux 보다 싸고, 배타성이 깨져도 core 에는 pulse 가 1 번만
    //  가서 이중 추론이 안 나는 fail-safe 가 되기 때문이다.
    assign npu_start    = start_pulse | hw_start_pulse;
    assign npu_score_th = r_score_th;
    assign input_src    = ctrl_input_src;
    assign event_cfg    = r_event_cfg;
    assign pan_cmd      = r_pan_cmd;
    assign tilt_cmd     = r_tilt_cmd;
    assign laser_ctrl   = r_laser_ctrl;
    assign safe_limit   = r_safe_limit;
    assign track_err_x  = r_track_err_x;
    assign track_err_y  = r_track_err_y;
    assign pan2_cmd     = r_pan2_cmd;
    assign tilt2_cmd    = r_tilt2_cmd;
    assign safe_limit2  = r_safe_limit2;
    assign laser_cal    = r_laser_cal;
    assign irq          = ctrl_irq_en & done_sticky;

endmodule
