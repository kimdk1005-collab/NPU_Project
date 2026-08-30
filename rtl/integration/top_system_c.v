`timescale 1ns/1ps
//=====================================================================
// top_system_c : A(NPU SoC) + C(Event/Tracking/Servo/Laser) 통합 Top
// 담당: A   (§5.4 — 통합 top 은 A 가 작성한다. C 모듈은 인스턴스만 한다)
// 기준: TEAM_COMMON_AI_INTEGRATION_SPEC v1.5 §7.3 / §15.2 / §17 / §20
//       docs/from_c/C_TO_A_REPLY_004.md §2 / §3 / §5
//       handoff/C_EVENT_CONTROL_HANDOFF.md §11
//
//  왜 top_system 을 고치지 않고 감싸는가
//   1. `top_system` 은 A 단독 bring-up 경로(비트스트림/XSA/ELF)의 기준이다.
//      포트를 바꾸면 Block Design 과 tb_top_system 이 같이 깨진다.
//   2. C 실물이 붙어도 A 단독 회귀(18/18)가 그대로 남아 있어야
//      문제가 생겼을 때 A 쪽인지 C 쪽인지 가른다.
//   3. §5.4 — C 소유 파일(rtl/event, rtl/control)은 손대지 않는다.
//      여기서 인스턴스만 하고 배선은 전부 이 파일 안에서 한다.
//
//  구조
//        ┌──────────────────── top_system_c (A) ────────────────────┐
//        │                                                          │
//   S_AXI├─►┌─ top_system (A) ─┐   event_cfg/pan_cmd/...            │
//        │  │  npu_axi         │──────────────┐                     │
//        │  │  npu_core        │              ▼                     │
//        │  │       ▲ evt_*    │   ┌─ c_event_control_top (C) ─┐    │
//        │  └───────┼──────────┘   │  event_adapter            │    │
//        │          └──────────────┤  event_accumulator        │◄───┼── src_*
//        │            input_stat   │  dual_head_control        │    │
//        │          ◄──────────────┤   ├ tracking_controller   │────┼─► servo_pwm[3:0]
//        │                         │   ├ laser_head_controller │────┼─► laser_en
//        │                         │   └ laser_interlock       │◄───┼── laser_arm_hw
//        │                         └───────────────────────────┘    │  emergency_stop_hw
//        └──────────────────────────────────────────────────────────┘
//
//  START 소유권 — [구현 완료 2026-08-28] 둘 다 배선돼 있고 CTRL 로 고른다
//   C 가 제시한 두 가지 (REPLY_004 §3) 를 전부 붙였다.
//     (a) Direct     : tensor_start -> npu_axi.hw_start
//                      CTRL[5] HW_START_EN=1 & CTRL[3] INPUT_SRC=1 일 때만 먹는다
//     (b) PS-managed : PS 가 INPUT_STAT.TENSOR_READY(bit1) 를 폴링 -> CTRL.START
//                      HW_START_EN=0 (reset 기본값) 일 때. 예전과 동일 동작.
//   두 방식을 동시에 켜지 마라. C 지시다 (REPLY_005 §4). npu_axi 가 강제한다 —
//   무장 중 들어온 PS START 는 pulse 를 안 내고 STATUS.ERROR 만 세운다.
//   근거: docs/CHANGE_REQUEST_A_003_c_integration.md 변경 2 [승인 -> 구현]
//
//   (b) 의 PS 지연 예산 : TENSOR_READY 를 본 뒤 한 Event Window(기본 33.333 ms)
//   안에 CTRL.START 를 써야 한다. 그보다 늦으면 다음 Window 의 전송이 추론 중에
//   겹칠 수 있다. 실제 PS 폴링 주기는 us 단위라 여유는 4 자리 수다.
//   (a) 에는 이 예산 자체가 없다. PS 가 START 경로에서 빠지기 때문이다.
//
//  Event Window
//   B 의 학습 데이터가 30 FPS 연속 프레임 차분으로 만들어졌다
//   (b_to_a_no_target_v03_001/results/no_target_v03_manifest.json : frame_rate 30).
//   따라서 기본값을 33_333 us 로 둔다. C 기본값 10_000 us 는 B 학습 조건과 다르다.
//   실제 이벤트 소스가 프레임 경계를 직접 주면 WINDOW_SRC=1 로 바꾼다.
//   ** 2026-08-27 C 승인 완료 (docs/from_c/C_TO_A_REPLY_005.md §3.3/§4).
//      WINDOW_US=33333 · WINDOW_SRC=1 · SENSOR 640x480 YUYV 30 FPS 가 승인값이다.
//      그런데 WINDOW_SRC 기본값은 아직 0 이다. 이유는 아래. **
//
//  WINDOW_SRC 기본값을 왜 아직 0 으로 두나
//   WINDOW_SRC=1 이면 Window 가 src_window_end 로만 끝난다. 지금 Block Design 은
//   실제 Event Source 가 없어 src_* 를 전부 상수 0 으로 묶는다. 그 상태에서
//   1 로 바꾸면 Window 가 영원히 안 끝나고 Tensor 가 한 장도 안 나온다.
//   PS->PL Event Bridge (A 소유, 미구현) 가 붙는 날 1 로 바꾼다.
//   TB 는 이미 WINDOW_SRC=1 로 물려서 검증한다 (tb/integration/tb_top_system_c.v).
//=====================================================================
module top_system_c #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 12,

    // --- C 모듈 파라미터 (기본값 근거는 위 주석) ---
    parameter integer SENSOR_W    = 640,
    parameter integer SENSOR_H    = 480,
    parameter integer SRC_COORD_W = 11,
    parameter integer OOR_POLICY  = 0,        // 0 = 범위 밖 이벤트 폐기
    parameter integer WINDOW_US   = 33_333,   // 30 FPS. C 기본값 10_000 에서 A 가 바꿈
    parameter integer WINDOW_SRC  = 0,        // 0 = 내부 타이머, 1 = src_window_end
    parameter integer SCORE_THRESHOLD      = 0,
    parameter integer LOCK_CONFIRM_UPDATES = 3,
    parameter integer TARGET_TIMEOUT_FRAMES= 3,
    parameter integer MAX_ON_FRAMES        = 25,

    // --- 기능 격리 디버그 스위치. 아래 "Runtime Safe Limit 과 100 MHz" 참고 ---
    //  1 = C 의 SAFE_LIMIT/SAFE_LIMIT2 런타임 덮어쓰기 기능을 그대로 쓴다 (정상 경로)
    //  0 = LASER_CTRL bit 8 (RUNTIME_LIMIT_EN) 을 0 으로 묶어 그 기능을 끈다.
    //      정적 parameter 범위(PAN/TILT 32~224)는 그대로 강제되므로
    //      안전 한계 자체는 없어지지 않는다. PS 에서 좁히는 기능만 사라진다.
    //  ** c_control_v08 시절엔 이게 100 MHz 를 닫는 유일한 수단이었다.
    //     v09 에서 C 가 고쳐서 이제 1 로도 MET 다. 0 은 디버그용으로만 남긴다. **
    parameter integer RUNTIME_LIMIT_SUPPORT = 1
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

    //--- 실제 Event Source (C 입력). 아직 실물이 없으면 0 으로 묶는다 -------
    input  wire                              src_valid,
    input  wire [SRC_COORD_W-1:0]            src_x,
    input  wire [SRC_COORD_W-1:0]            src_y,
    input  wire                              src_pol,        // 0=Positive 1=Negative
    input  wire                              src_window_end, // WINDOW_SRC=1 일 때만

    //--- 물리 Fail-Closed 입력 (REPLY_004 §2.2) ----------------------------
    //  laser_arm_hw      : 물리 Arm 스위치. SW Arm(LASER_CTRL[1]) 과 AND
    //  emergency_stop_hw : 물리 E-stop.     SW E-stop(LASER_CTRL[2]) 과 OR
    //  ** 광원 미장착 시험에서는 laser_arm_hw = 0 으로 묶어 laser_en 을 항상 OFF 로 둔다 **
    input  wire                              laser_arm_hw,
    input  wire                              emergency_stop_hw,

    //--- 외부 핀 ----------------------------------------------------------
    output wire [3:0]                        servo_pwm,   // {TILT2,PAN2,TILT1,PAN1}
    output wire                              laser_en,

    //--- 상태 관찰 포트. 같은 값이 0x58 / 0x5C RO 로도 읽힌다 -----------
    //  ** 1 cycle 등록해서 낸다. ** 아래 "왜 등록하나" 참고.
    //  BD 에서는 소비처가 없어 최적화로 사라진다. TB / ILA 용이다.
    output wire [31:0]                       servo_pos_stat,
    output wire [31:0]                       control_stat,
    //  Direct START 배선 확인용. 내부에서 이미 u_a.hw_start 로 들어간다.
    output wire                              tensor_start,

    output wire                              irq,
    output wire [3:0]                        status_led
);
    //-----------------------------------------------------------------
    // A <-> C 내부 배선
    //-----------------------------------------------------------------
    wire        evt_we;
    wire [12:0] evt_addr;
    wire signed [7:0] evt_data;
    wire [31:0] input_stat;

    wire [31:0] event_cfg, pan_cmd, tilt_cmd, laser_ctrl, safe_limit;
    wire [31:0] track_err_x, track_err_y;
    wire [31:0] pan2_cmd, tilt2_cmd, safe_limit2, laser_cal;

    wire        npu_target_valid, npu_done, npu_busy;
    wire [5:0]  npu_target_x, npu_target_y;
    wire signed [7:0] npu_target_score;

    wire [31:0] c_servo_pos_stat, c_control_stat;
    // 상태 파이프라인 레지스터. 실제 대입은 이 파일 맨 아래 always 블록.
    // u_a 인스턴스가 이걸 입력으로 받으므로 선언만 앞으로 끌어올렸다.
    reg  [31:0] servo_pos_stat_r, control_stat_r;

    //-----------------------------------------------------------------
    // A : NPU SoC.  포트/동작은 A 단독 빌드와 완전히 동일하다.
    //-----------------------------------------------------------------
    top_system #(
        .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
    ) u_a (
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

        .evt_we(evt_we), .evt_addr(evt_addr), .evt_data(evt_data),
        .input_stat(input_stat),

        // Direct START (CR A-003 변경 2). CTRL[5]=0 이면 무시된다.
        .hw_start(tensor_start),
        // 0x58 / 0x5C RO (CR A-003 변경 1). 아래에서 1 cycle 등록한 값.
        .servo_pos_stat(servo_pos_stat_r), .control_stat(control_stat_r),

        .event_cfg(event_cfg), .pan_cmd(pan_cmd), .tilt_cmd(tilt_cmd),
        .laser_ctrl(laser_ctrl), .safe_limit(safe_limit),
        .track_err_x(track_err_x), .track_err_y(track_err_y),
        .pan2_cmd(pan2_cmd), .tilt2_cmd(tilt2_cmd),
        .safe_limit2(safe_limit2), .laser_cal(laser_cal),

        .npu_target_valid(npu_target_valid),
        .npu_target_x(npu_target_x), .npu_target_y(npu_target_y),
        .npu_target_score(npu_target_score),
        .npu_done(npu_done), .npu_busy(npu_busy),
        .irq(irq), .status_led(status_led)
    );

    //-----------------------------------------------------------------
    // C : Event / Tracking / Servo / Laser Interlock  (C 소유. 무수정)
    //-----------------------------------------------------------------
    //-----------------------------------------------------------------
    // PS 설정 레지스터 파이프라인 — 왜 한 박자 끊나
    //
    //  laser_interlock 의 자격 판정은
    //    SAFE_LIMIT/SAFE_LIMIT2 비교 -> runtime/static clamp 선택
    //    -> pt1_safe & pt2_safe -> qualification_inputs_ok -> confirm/on_count
    //  로 이어지는 14 단짜리 조합 cone 이다. 그 시작점이 npu_axi 안의
    //  r_safe_limit2 레지스터라, 배치가 AXI 쪽에 묶이면서 배선이 길어졌다.
    //  실측: WNS -0.097 ns, data path 10.044 ns 중 배선이 6.344 ns (63%)
    //        (근거: results/top_system_c_impl_critpath.rpt 갱신 전 판)
    //
    //  이 레지스터들은 PS 가 사람 시간 단위로 쓰는 설정값이다. 1 cycle 늦게
    //  반영돼도 의미가 변하지 않는다. 여기서 끊어 주면 배치기가 이 FF 를
    //  C 논리 옆에 놓고 fanout 도 복제할 수 있다.
    //
    //  주의: EVENT_CFG 는 끊지 않는다. Event Enable 은 src_valid 와 같은
    //  cycle 정합이 필요하고 조합 깊이도 얕다.
    //-----------------------------------------------------------------
    reg [31:0] q_pan_cmd, q_tilt_cmd, q_laser_ctrl, q_safe_limit;
    reg [31:0] q_pan2_cmd, q_tilt2_cmd, q_safe_limit2, q_laser_cal;
    reg [31:0] q_track_err_x, q_track_err_y;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            q_pan_cmd     <= 32'd0;  q_tilt_cmd    <= 32'd0;
            q_laser_ctrl  <= 32'd0;  q_safe_limit  <= 32'd0;
            q_pan2_cmd    <= 32'd0;  q_tilt2_cmd   <= 32'd0;
            q_safe_limit2 <= 32'd0;  q_laser_cal   <= 32'd0;
            q_track_err_x <= 32'd0;  q_track_err_y <= 32'd0;
        end else begin
            q_pan_cmd     <= pan_cmd;      q_tilt_cmd    <= tilt_cmd;
            q_laser_ctrl  <= laser_ctrl;   q_safe_limit  <= safe_limit;
            q_pan2_cmd    <= pan2_cmd;     q_tilt2_cmd   <= tilt2_cmd;
            q_safe_limit2 <= safe_limit2;  q_laser_cal   <= laser_cal;
            q_track_err_x <= track_err_x;  q_track_err_y <= track_err_y;
        end
    end

    //-----------------------------------------------------------------
    // Runtime Safe Limit 과 100 MHz — [해결됨 2026-08-27]
    //
    //  ## 예전에 무슨 일이 있었나 (c_control_v08)
    //  C 의 dual_head_control.v 안에서
    //    runtime_limit_values_ok  (8쌍 x 2 = 16 항 비교)
    //      -> pan1_min_eff .. tilt2_max_eff  (8개 mux)
    //      -> clamp_u8
    //      -> laser_interlock.qualification_inputs_ok
    //      -> confirm_count / on_count
    //  이 전부 한 cycle 조합 cone 이었다. 논리 14 단, data path 10.195 ns.
    //    OOC 기본 전략  WNS -0.248 ns  VIOLATED
    //    BD  -cfull     WNS -0.157 ns  VIOLATED
    //  그래서 아래 RUNTIME_LIMIT_SUPPORT=0 우회를 만들어 뒀었다.
    //
    //  ## 지금 (c_control_v09, A_TO_C_V01_REQUEST_001.md 요청1 반영본)
    //  C 가 8 개 유효 제한값 자체를 Register 로 원자 등록하게 고쳤다.
    //  cone 이 *_eff 레지스터에서 끊겨 크리티컬 패스에서 빠졌다.
    //  ** 수치는 여기 적지 않는다. 재빌드마다 바뀌는데 주석은 안 따라와서
    //     이 자리에 이미 한 번 옛 값(+0.531 / +0.548)이 화석으로 남았었다. **
    //  현재값 정본 : results/bd_timing_cfull.rpt (BD, 판정용)
    //               results/top_system_c_impl_timing.rpt (OOC, 자원 참고용)
    //  해석        : docs/PHASE4_VERIFICATION_LOG.md §15.4
    //  ** 보드용은 이제 전 기능 npu_soc_cfull.bit 이다. **
    //
    //  ## 그럼 아래 스위치는 왜 남겨 두나
    //  기능 격리용 디버그 스위치로만 남긴다. 0 이면 LASER_CTRL[8] 이 막혀
    //  runtime SAFE_LIMIT 덮어쓰기가 빠지고 정적 한계 32~224 만 남는다.
    //  기본값 1 (전 기능) 이 정상 경로다.
    //  ** 이제 -nortlim 과 전 기능의 WNS 차이가 사실상 없다 (§15.5).
    //     타이밍상 이 스위치를 쓸 이유는 없다. **
    //-----------------------------------------------------------------
    wire [31:0] c_laser_ctrl = (RUNTIME_LIMIT_SUPPORT != 0)
                             ? q_laser_ctrl
                             : (q_laser_ctrl & ~32'h0000_0100);

    //-----------------------------------------------------------------
    // 물리 스위치 2FF 동기화 — SW1(laser_arm_hw) / SW3(emergency_stop_hw)
    //
    //  이 둘은 Zybo 슬라이드 스위치다. s_axi_aclk 와 아무 위상 관계가 없고
    //  기계 접점이라 전이 중 중간 전압이 그대로 들어온다. 동기화 없이
    //  C 의 laser_interlock 자격 판정에 직결하면 metastability 가 안전 블록
    //  안으로 퍼진다. 여기서 2 단으로 받는다.
    //
    //  reset 기본값은 fail-closed 로 잡는다.
    //    laser_arm       -> 0 (무장 해제)
    //    emergency_stop  -> 1 (정지)
    //  E-stop 을 1 로 두면 C 의 arm_seen_low 재무장 래치가 전원인가 직후
    //  반드시 한 번 LOW 를 보게 되므로, 스위치를 올린 채 전원을 넣어도
    //  자동 점등되지 않는다.
    //
    //  이 wrapper 는 A 소유다. C 파일은 건드리지 않았다 (§5.4).
    //-----------------------------------------------------------------
    reg [1:0] arm_sync, estop_sync;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            arm_sync   <= 2'b00;
            estop_sync <= 2'b11;
        end else begin
            arm_sync   <= {arm_sync[0],   laser_arm_hw};
            estop_sync <= {estop_sync[0], emergency_stop_hw};
        end
    end
    wire laser_arm_hw_s      = arm_sync[1];
    wire emergency_stop_hw_s = estop_sync[1];

    c_event_control_top #(
        .CLK_HZ(100_000_000),
        .SENSOR_W(SENSOR_W), .SENSOR_H(SENSOR_H),
        .SRC_COORD_W(SRC_COORD_W), .OOR_POLICY(OOR_POLICY),
        .WINDOW_US(WINDOW_US), .WINDOW_SRC(WINDOW_SRC),
        .SCORE_THRESHOLD(SCORE_THRESHOLD),
        .LOCK_CONFIRM_UPDATES(LOCK_CONFIRM_UPDATES),
        .TARGET_TIMEOUT_FRAMES(TARGET_TIMEOUT_FRAMES),
        .MAX_ON_FRAMES(MAX_ON_FRAMES)
    ) u_c (
        .clk(s_axi_aclk), .rstn(s_axi_aresetn),

        .event_cfg(event_cfg), .pan_cmd(q_pan_cmd), .tilt_cmd(q_tilt_cmd),
        .laser_ctrl(c_laser_ctrl), .safe_limit(q_safe_limit),
        .track_err_x(q_track_err_x), .track_err_y(q_track_err_y),
        .pan2_cmd(q_pan2_cmd), .tilt2_cmd(q_tilt2_cmd),
        .safe_limit2(q_safe_limit2), .laser_cal(q_laser_cal),

        .npu_busy(npu_busy), .npu_done(npu_done),
        .target_valid(npu_target_valid),
        .target_x(npu_target_x), .target_y(npu_target_y),
        .target_score(npu_target_score),

        .src_valid(src_valid), .src_x(src_x), .src_y(src_y),
        .src_pol(src_pol), .src_window_end(src_window_end),

        .laser_arm_hw(laser_arm_hw_s),
        .emergency_stop_hw(emergency_stop_hw_s),

        .evt_we(evt_we), .evt_addr(evt_addr), .evt_data(evt_data),
        .tensor_start(tensor_start), .input_stat(input_stat),

        .servo_pos_stat(c_servo_pos_stat), .control_stat(c_control_stat),
        .servo_pwm(servo_pwm), .laser_en(laser_en)
    );

    //-----------------------------------------------------------------
    // 진단 상태 출력 — 왜 등록해서 내보내나
    //
    //  c_control_stat 는 laser_interlock 의 자격 판정 조합 논리(runtime limit
    //  비교 + clamp + aim_ready)를 그대로 끌고 나온다. 그대로 포트로 빼면
    //  r_safe_limit2 레지스터에서 포트까지 LUT/CARRY4 9 단이 걸려
    //  OOC 실측에서 control_stat[4] 가 WNS -1.904 ns 로 critical path 가 됐다.
    //  (근거: 첫 측정 결과. 실패 endpoint 7 개 중 2 개가 이 포트였다)
    //
    //  이 신호는 PS 가 읽는 상태값이지 제어 신호가 아니다. 1 cycle 늦어도
    //  의미가 변하지 않는다. 0x58/0x5C RO Register 로 승격되면 어차피
    //  AXI 읽기 경로에서 한 번 더 등록된다.
    //  C 소유 파일은 건드리지 않고 A 소유 wrapper 에서만 끊는다 (§5.4).
    //
    //  ** 2026-08-28 : 이 등록값이 그대로 0x58 / 0x5C RO 로도 나간다. **
    //  즉 PS 가 읽는 값과 이 포트로 나가는 값이 같은 FF 에서 나온다.
    //  포트는 ILA / 시뮬 관찰용으로 남긴다 (tb_top_system_c 가 직접 본다).
    //  선언은 위쪽 배선부에 있다. u_a 가 입력으로 받기 때문이다.
    //-----------------------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            servo_pos_stat_r <= 32'd0;
            control_stat_r   <= 32'd0;
        end else begin
            servo_pos_stat_r <= c_servo_pos_stat;
            control_stat_r   <= c_control_stat;
        end
    end
    assign servo_pos_stat = servo_pos_stat_r;
    assign control_stat   = control_stat_r;
endmodule
