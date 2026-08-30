`timescale 1ns/1ps
//=====================================================================
// top_system : NPU SoC 통합 Top (npu_axi + npu_core + Input Source Mux)
// 담당: A
// 기준: TEAM_COMMON_AI_INTEGRATION_SPEC v1.3 §7.3 / §20
//
//  Vivado Block Design 에서 Module Reference 로 사용한다.
//   PS7 M_AXI_GP0 --(SmartConnect)--> S_AXI
//   FCLK_CLK0     --> s_axi_aclk (= NPU clk, 단일 도메인)
//
//  Pan/Tilt 는 2개다.
//   PT#1 (0x20 PAN_CMD / 0x24 TILT_CMD)  = 이벤트 카메라 헤드, closed-loop 중앙 유지
//   PT#2 (0x48 PAN2_CMD / 0x4C TILT2_CMD) = 레이저 헤드, 표적 절대방향 조준
//   좌표 변환은 C 의 Tracking Controller 담당 (공통 지침 §15.2).
//
//  Event Tensor 입력 경로는 CTRL.INPUT_SRC 로 선택한다.
//   INPUT_SRC = 0 : PS 가 AXI INBUF_DATA(0x40) 로 기록  (bring-up / 시험용)
//   INPUT_SRC = 1 : C 의 Event Accumulator 가 evt_* 로 직접 기록 (spec §7.3)
//
//  START 소유권은 CTRL.HW_START_EN 으로 선택한다 (CR A-003 변경 2, 승인됨).
//   HW_START_EN = 0 : PS-managed. PS 가 INPUT_STAT.TENSOR_READY 를 보고
//                     CTRL.START 를 쓴다. reset 기본값이라 예전과 같다.
//   HW_START_EN = 1 : Direct. C 의 tensor_start 가 곧바로 추론을 건다.
//                     INPUT_SRC=1 도 같이 켜져 있어야 한다.
//   둘을 동시에 쓰지 마라. 무장 중 PS START 는 거부되고 ERROR 가 선다.
//
//  C 모듈이 아직 없는 단계에서는 evt_* / hw_start / *_stat 을 0 으로 묶으면 된다.
//=====================================================================
module top_system #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 12
)(
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

    //--- C : Event Accumulator -> NPU Input Buffer (spec 7.3) ---------
    input  wire                              evt_we,
    input  wire [12:0]                       evt_addr,
    input  wire signed [7:0]                 evt_data,
    input  wire [31:0]                       input_stat,

    //--- C : Direct START (CR A-003 변경 2, 승인 2026-08-27) -----------
    //  event_accumulator.tensor_start (1 cycle pulse) 를 그대로 받는다.
    //  CTRL[5] HW_START_EN & CTRL[3] INPUT_SRC 가 둘 다 1 일 때만 먹는다.
    //  reset 값 0 이라 안 쓰면 예전과 완전히 같다. 안 붙이면 0 으로 묶어라.
    input  wire                              hw_start,

    //--- C : 상태 RO Register (CR A-003 변경 1, 승인 2026-08-27) -------
    //  0x58 SERVO_POS_STAT / 0x5C CONTROL_STAT 로 그대로 읽힌다.
    //  bit 배치는 C 정의 (rtl/control/c_event_control_top.v 머리주석).
    //  C 가 없는 A 단독 빌드에서는 0 으로 묶는다.
    input  wire [31:0]                       servo_pos_stat,
    input  wire [31:0]                       control_stat,

    //--- C : Tracking / Servo Register (bit 의미는 C 정의) -------------
    output wire [31:0]                       event_cfg,
    output wire [31:0]                       pan_cmd,
    output wire [31:0]                       tilt_cmd,
    output wire [31:0]                       laser_ctrl,
    output wire [31:0]                       safe_limit,
    output wire [31:0]                       track_err_x,
    output wire [31:0]                       track_err_y,

    //--- C : Pan/Tilt 2호기 = 레이저 전용 헤드 (0x20/0x24 는 카메라 헤드) ---
    output wire [31:0]                       pan2_cmd,
    output wire [31:0]                       tilt2_cmd,
    output wire [31:0]                       safe_limit2,
    output wire [31:0]                       laser_cal,

    //--- C : NPU 결과 직결 (AXI 우회 경로, spec 14) --------------------
    output wire                              npu_target_valid,
    output wire [5:0]                        npu_target_x,
    output wire [5:0]                        npu_target_y,
    output wire signed [7:0]                 npu_target_score,
    output wire                              npu_done,
    output wire                              npu_busy,

    output wire                              irq,

    //--- 보드 bring-up 표시등 (Zybo LD0..LD3) --------------------------
    //  [0] heartbeat : FCLK 이 살아있고 bitstream 이 올라갔음을 눈으로 확인
    //  [1] npu_busy  [2] target_valid  [3] irq
    output wire [3:0]                        status_led
);
    wire        npu_rstn, npu_start;
    wire [31:0] npu_cycle_cnt;
    wire signed [7:0] npu_score_th;

    wire        axi_ext_we;
    wire [12:0] axi_ext_addr;
    wire signed [7:0] axi_ext_data;
    wire        input_src;

    // Input Source Mux : CTRL.INPUT_SRC
    wire        ext_we   = input_src ? evt_we   : axi_ext_we;
    wire [12:0] ext_addr = input_src ? evt_addr : axi_ext_addr;
    wire signed [7:0] ext_data = input_src ? evt_data : axi_ext_data;

    npu_axi #(
        .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
    ) u_axi (
        .s_axi_aclk(s_axi_aclk), .s_axi_aresetn(s_axi_aresetn),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),

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

    // heartbeat : 100 MHz / 2^26 = 약 1.5 Hz
    reg [25:0] hb_cnt;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) hb_cnt <= 26'd0;
        else                hb_cnt <= hb_cnt + 26'd1;
    end
    assign status_led = {irq, npu_target_valid, npu_busy, hb_cnt[25]};

    npu_core u_npu (
        .clk(s_axi_aclk), .rstn(npu_rstn),
        .start(npu_start), .busy(npu_busy), .done(npu_done),
        .cycle_cnt(npu_cycle_cnt), .score_th(npu_score_th),
        .target_valid(npu_target_valid),
        .target_x(npu_target_x), .target_y(npu_target_y),
        .target_score(npu_target_score),
        .ext_we(ext_we), .ext_addr(ext_addr), .ext_data(ext_data)
    );
endmodule
