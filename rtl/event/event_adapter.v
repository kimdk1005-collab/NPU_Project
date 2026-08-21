// ---------------------------------------------------------------------------
// event_adapter.v -- Raw Event Source -> SPEC §6.1 내부 표준 Event Stream
//
//  담당 : C   (SPEC §5.3 이 rtl/event/event_adapter.v 를 C 소유로 명시)
//  상위 권한 : docs/NPU_EVENT_CAMERA_TEAM_COMMON_AI_INTEGRATION_SPEC_v1.2.md
//  규격     : SPEC §6.1  출력 형식 (변경 금지)
//             SPEC §7.2  C 책임 = Spatial Binning
//             SPEC §14.1 Source -> 64x64 Mapping  ** v1.2 에서 Freeze 됨 **
//             handoff/C_EVENT_CONTROL_HANDOFF.md §1
//
//  하는 일
//    1. 원본 센서 좌표 (SENSOR_W x SENSOR_H) -> 64 x 64 Spatial Binning
//    2. 좌표 범위 밖 이벤트 처리 (OOR_POLICY)
//    3. Event Window 경계 pulse 생성 (내부 타이머 또는 외부 pulse)
//    4. Window 당 이벤트 수 / 폐기 수 계수  -- 진단용, SPEC §6.1 밖
//
//  하지 않는 일
//    Tensor 누적은 event_accumulator.v (D3) 담당이다. 여기서는 하지 않는다.
//    SPEC §7.3 물리적 전달 방식은 v1.2 §21.2 기준 여전히 TBD 이므로
//    이 모듈은 그것에 의존하지 않는다.
//
// ---------------------------------------------------------------------------
//  Spatial Binning -- SPEC §14.1 확정식을 나눗셈 없이 "완전히 동일하게" 낸다
//
//  SPEC v1.2 §14.1 이 Freeze 한 식은 다음과 같다.
//
//      x64 = min(63, floor(x_raw * 64 / frame_width))
//      y64 = min(63, floor(y_raw * 64 / frame_height))
//
//      Crop 없음 / Padding 없음 / 좌우 반전 없음
//      X 축 = 왼쪽 -> 오른쪽 증가,  Y 축 = 위 -> 아래 증가
//
//  참조 모델 tools/gen_event_vector.py 의 accumulate() 도 같은 식을 쓴다.
//  RTL 이 이 값과 한 칸이라도 다르면 D3 Golden 비교가 깨진다.
//  그런데 frame_width 는 640, 346 처럼 2 의 거듭제곱이 아닐 수 있어 시프트로 안 된다.
//
//  그래서 역수 곱셈을 쓴다.
//      MUL_X = ceil( 64 * 2^BIN_SHIFT / SENSOR_W )
//      bx    = min(63, (x * MUL_X) >> BIN_SHIFT)
//
//  이것이 floor(64x/W) 와 항상 같다는 조건은 다음과 같다.
//      ERR_X = MUL_X * SENSOR_W - 64 * 2^BIN_SHIFT     (0 <= ERR_X < SENSOR_W)
//      (SENSOR_W - 1) * ERR_X  <  2^BIN_SHIFT
//
//  근거 : x*MUL_X / 2^S = 64x/W + x*ERR/(W * 2^S) 이고,
//  64x/W 는 분모가 W 이므로 다음 정수까지 최소 1/W 만큼 떨어져 있다.
//  따라서 오차항이 1/W 보다 작으면 floor 결과가 바뀌지 않는다.
//  즉 x*ERR/(W*2^S) < 1/W  <=>  x*ERR < 2^S  이고 x <= W-1 이므로 위 조건이 된다.
//
//  이 조건은 아래 initial 블록에서 elaboration 시점에 검사한다.
//  만족하지 못하면 BIN_SHIFT 를 키우면 된다. BIN_SHIFT=22 는 SENSOR 2048 까지 통과한다.
//  tb/event/tb_event_adapter.v 가 64 / 346 / 640 / 1280 전 좌표를 실제로 훑어
//  정수 나눗셈과 일치하는지 확인한다 (조건식만 믿지 않는다).
//
//  SENSOR_W 가 64 / 128 / 256 처럼 2 의 거듭제곱이면 MUL_X 가 2 의 거듭제곱이 되어
//  합성기가 곱셈기를 통째로 없앤다 (단순 비트 선택). DSP 는 그때만 안 쓴다.
//
// ---------------------------------------------------------------------------
//  파이프라인 2 단 -- Window 경계를 같은 깊이로 지연시키는 것이 핵심이다
//
//    stage0 : 입력 등록 + 범위 판정 + Window pulse 등록
//    stage1 : 곱셈 결과 시프트 -> 출력 등록
//
//  이벤트와 window_end 가 같은 깊이를 지나므로 순서가 보존된다.
//  window_end 만 지연 없이 내보내면 그 Window 의 마지막 이벤트들이
//  window_end 뒤에 도착해 다음 Window 로 새는 버그가 된다.
//
//  HANDOFF §1 : src_valid 와 Window 경계가 같은 clock 에 겹치면
//  그 이벤트는 "현재 Window 에 포함" 한다. 두 신호가 같은 파이프라인을
//  타므로 출력에서도 같은 clock 에 나오고, 계수기도 그 이벤트를 센 뒤 리셋한다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module event_adapter #(
    // --- 센서 원본 해상도 --------------------------------------------------
    //  SPEC v1.2 §14.1 이 "현재 640x480 Webcam Fallback" 을 명시하므로
    //  기본값을 640x480 으로 둔다. 실제 Event Camera 로 바뀌면
    //  SPEC §14.1 지시대로 이 두 parameter 만 실제 센서 해상도로 교체한다.
    //     실제 Event Camera (DVS346)  346 x 260
    //     Webcam Frame Difference     640 x 480   <- 현재 기본값
    //     PC 생성 자극                 64 x  64   (gen_event_vector.py 기본값)
    //  64 미만은 지원하지 않는다 (Binning 은 축소 전용).
    parameter integer SENSOR_W     = 640,
    parameter integer SENSOR_H     = 480,

    // 입력 좌표 버스 폭. 센서 해상도보다 넓어도 되며 남는 값은 OOR_POLICY 를 탄다.
    parameter integer SRC_COORD_W  = 11,          // 최대 2047

    //  좌표 범위 밖 이벤트 처리
    //    0 = DROP  : 폐기한다. HANDOFF §1 에 기록된 C 내부 결정이며 기본값.
    //                Tensor 가장자리에 가짜 카운트가 쌓여 Argmax 를 끌어당기는 것을 막는다.
    //    1 = CLAMP : SPEC §14.1 의 min(63,.) 를 문자 그대로 적용해 63 으로 물린다.
    //  정상 입력에서는 x_raw < SENSOR_W 이므로 두 정책의 결과가 같다.
    //  차이가 나는 것은 입력이 규격을 벗어났을 때뿐이다.
    parameter integer OOR_POLICY   = 0,

    // --- Event Window ------------------------------------------------------
    parameter integer CLK_HZ       = 100_000_000, // CR C-003 확정. npu_core 와 단일 domain
                                                  //   ext_* 로 직결되므로 CDC 가 없어야 한다
    //  [TBD] SPEC §21 D3 Freeze 항목. C 단독 확정 금지 (SPEC §0-10).
    //  SPEC §14.1 이 명시한 640x480 웹캠은 30 fps 상한이라 33333 이 강제된다.
    //  이 충돌은 CHANGE REQUEST C-002 로 팀에 올라가 있다. 승인 전까지
    //  기본값은 gen_event_vector.py 와 맞춘 10000 을 유지한다 (확정 아님).
    parameter integer WINDOW_US    = 10_000,
    //  0 = 내부 타이머로 Window 생성
    //  1 = 외부 pulse (src_window_end) 사용. 웹캠 프레임 경계처럼
    //      Window 가 이미 입력원에 의해 정해지는 경우 이쪽이 맞다.
    parameter integer WINDOW_SRC   = 0,

    // --- 구현 상수 ---------------------------------------------------------
    parameter integer BIN_SHIFT    = 22,          // 역수 곱셈 정밀도
    parameter integer EVT_CNT_W    = 20           // 진단 계수기 폭 (포화, Wrap 금지)
)(
    input  wire                    clk,
    input  wire                    rst_n,        // Active-Low 비동기 Reset

    // --- 원본 Event Source -------------------------------------------------
    //  Backpressure 없음. SPEC §6.1 내부 표준에 ready 가 없으므로
    //  1 event / clock 을 항상 받는다.
    input  wire                    src_valid,
    input  wire [SRC_COORD_W-1:0]  src_x,
    input  wire [SRC_COORD_W-1:0]  src_y,
    input  wire                    src_pol,      // 0 = Positive(Ch0), 1 = Negative(Ch1)
    //  WINDOW_SRC = 1 일 때만 쓴다. Level 로 들어와도 되게 상승엣지를 잡는다.
    input  wire                    src_window_end,

    // --- SPEC §6.1 내부 표준 형식 (변경 금지) ------------------------------
    output reg                     event_valid,
    output reg  [5:0]              event_x,
    output reg  [5:0]              event_y,
    output reg                     event_polarity,
    output reg                     event_window_end,

    // --- 진단 출력 (SPEC §6.1 밖. 하위 모듈은 무시해도 된다) ---------------
    //  직전 Window 의 값이며 event_window_end 와 같은 clock 에 갱신되어
    //  다음 window_end 까지 유지된다. Event Rate 실측 (HANDOFF §2) 에 쓴다.
    output reg  [EVT_CNT_W-1:0]    win_evt_count,
    output reg  [EVT_CNT_W-1:0]    win_drop_count
);

    // -----------------------------------------------------------------------
    // Binning 상수
    // -----------------------------------------------------------------------
    localparam integer BIN_ONE = 1 << BIN_SHIFT;

    localparam integer MUL_X = ((64 * BIN_ONE) + SENSOR_W - 1) / SENSOR_W;
    localparam integer MUL_Y = ((64 * BIN_ONE) + SENSOR_H - 1) / SENSOR_H;

    localparam integer ERR_X = MUL_X * SENSOR_W - 64 * BIN_ONE;
    localparam integer ERR_Y = MUL_Y * SENSOR_H - 64 * BIN_ONE;

    localparam integer CYC_PER_US  = CLK_HZ / 1_000_000;
    localparam integer WINDOW_CYC  = CYC_PER_US * WINDOW_US;
    localparam integer WCNT_W      = $clog2(WINDOW_CYC);

    localparam [EVT_CNT_W-1:0] CNT_MAX = {EVT_CNT_W{1'b1}};

    initial begin
        if (SENSOR_W < 64 || SENSOR_H < 64)
            $error("event_adapter: SENSOR %0dx%0d -- Binning 은 축소 전용이라 64 미만 불가",
                   SENSOR_W, SENSOR_H);
        if ((SENSOR_W - 1) * ERR_X >= BIN_ONE)
            $error("event_adapter: X Binning 이 SPEC §14.1 정수식과 불일치. BIN_SHIFT(%0d) 를 키울 것 (ERR_X=%0d)",
                   BIN_SHIFT, ERR_X);
        if ((SENSOR_H - 1) * ERR_Y >= BIN_ONE)
            $error("event_adapter: Y Binning 이 SPEC §14.1 정수식과 불일치. BIN_SHIFT(%0d) 를 키울 것 (ERR_Y=%0d)",
                   BIN_SHIFT, ERR_Y);
        if (CYC_PER_US * 1_000_000 != CLK_HZ)
            $error("event_adapter: CLK_HZ(%0d) 가 1 MHz 의 정수배가 아니라 Window 길이가 어긋난다",
                   CLK_HZ);
        if (WINDOW_SRC == 0 && WINDOW_CYC < 4)
            $error("event_adapter: WINDOW_CYC(%0d) 가 파이프라인 깊이보다 짧다", WINDOW_CYC);
        if (SRC_COORD_W < 6)
            $error("event_adapter: SRC_COORD_W(%0d) 가 6 미만이면 64 좌표를 못 담는다", SRC_COORD_W);
        if (OOR_POLICY != 0 && OOR_POLICY != 1)
            $error("event_adapter: OOR_POLICY(%0d) 는 0(DROP) 또는 1(CLAMP)", OOR_POLICY);
    end

    // -----------------------------------------------------------------------
    // Window 경계 생성
    //   WINDOW_SRC = 0 : 내부 자유 진행 타이머
    //   WINDOW_SRC = 1 : 외부 신호의 상승엣지 (Level 입력도 허용)
    // -----------------------------------------------------------------------
    wire window_end_raw;

    generate
        if (WINDOW_SRC == 0) begin : g_win_timer
            reg [WCNT_W-1:0] win_cnt;
            wire win_last = (win_cnt == WINDOW_CYC - 1);

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)         win_cnt <= {WCNT_W{1'b0}};
                else if (win_last)  win_cnt <= {WCNT_W{1'b0}};
                else                win_cnt <= win_cnt + 1'b1;
            end

            assign window_end_raw = win_last;
        end else begin : g_win_extern
            reg ext_d;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) ext_d <= 1'b0;
                else        ext_d <= src_window_end;
            end
            assign window_end_raw = src_window_end & ~ext_d;
        end
    endgenerate

    // -----------------------------------------------------------------------
    // stage0 -- 입력 등록 + 범위 판정
    // -----------------------------------------------------------------------
    wire in_range = (src_x < SENSOR_W) && (src_y < SENSOR_H);

    reg                    s0_valid;
    reg                    s0_range_ok;
    reg                    s0_pol;
    reg                    s0_wend;
    reg [SRC_COORD_W-1:0]  s0_x, s0_y;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid    <= 1'b0;
            s0_range_ok <= 1'b0;
            s0_pol      <= 1'b0;
            s0_wend     <= 1'b0;
            s0_x        <= {SRC_COORD_W{1'b0}};
            s0_y        <= {SRC_COORD_W{1'b0}};
        end else begin
            s0_valid    <= src_valid;
            s0_range_ok <= in_range;
            s0_pol      <= src_pol;
            s0_wend     <= window_end_raw;
            s0_x        <= src_x;
            s0_y        <= src_y;
        end
    end

    // -----------------------------------------------------------------------
    // 조합 -- 역수 곱셈. stage0 / stage1 레지스터가 DSP 의 입출력 레지스터가 된다
    //
    //  ovf 비트는 (x*MUL)>>BIN_SHIFT 가 64 이상인 경우, 즉 x >= SENSOR_W 일 때만 선다.
    //  따라서 bin_*_sat 는 SPEC §14.1 의 min(63, floor(x*64/W)) 와 문자 그대로 같다.
    // -----------------------------------------------------------------------
    wire [SRC_COORD_W+BIN_SHIFT:0] prod_x = s0_x * MUL_X;
    wire [SRC_COORD_W+BIN_SHIFT:0] prod_y = s0_y * MUL_Y;

    wire ovf_x = |prod_x[SRC_COORD_W+BIN_SHIFT : BIN_SHIFT+6];
    wire ovf_y = |prod_y[SRC_COORD_W+BIN_SHIFT : BIN_SHIFT+6];

    wire [5:0] bin_x = ovf_x ? 6'd63 : prod_x[BIN_SHIFT+5 : BIN_SHIFT];
    wire [5:0] bin_y = ovf_y ? 6'd63 : prod_y[BIN_SHIFT+5 : BIN_SHIFT];

    wire s1_pass   = s0_range_ok || (OOR_POLICY == 1);
    wire s1_accept = s0_valid &  s1_pass;
    wire s1_drop   = s0_valid & ~s1_pass;

    // -----------------------------------------------------------------------
    // stage1 -- 출력 등록 + 진단 계수
    // -----------------------------------------------------------------------
    reg [EVT_CNT_W-1:0] evt_cnt, drop_cnt;

    wire [EVT_CNT_W-1:0] evt_nxt =
        (s1_accept && evt_cnt != CNT_MAX)  ? evt_cnt  + 1'b1 : evt_cnt;
    wire [EVT_CNT_W-1:0] drop_nxt =
        (s1_drop   && drop_cnt != CNT_MAX) ? drop_cnt + 1'b1 : drop_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            event_valid      <= 1'b0;
            event_x          <= 6'd0;
            event_y          <= 6'd0;
            event_polarity   <= 1'b0;
            event_window_end <= 1'b0;
            evt_cnt          <= {EVT_CNT_W{1'b0}};
            drop_cnt         <= {EVT_CNT_W{1'b0}};
            win_evt_count    <= {EVT_CNT_W{1'b0}};
            win_drop_count   <= {EVT_CNT_W{1'b0}};
        end else begin
            event_valid      <= s1_accept;
            event_x          <= bin_x;
            event_y          <= bin_y;
            event_polarity   <= s0_pol;
            event_window_end <= s0_wend;

            // Window 경계에 걸친 이벤트는 현재 Window 에 포함한다 (HANDOFF §1).
            // 그래서 nxt 를 먼저 세고 나서 계수기를 비운다.
            if (s0_wend) begin
                win_evt_count  <= evt_nxt;
                win_drop_count <= drop_nxt;
                evt_cnt        <= {EVT_CNT_W{1'b0}};
                drop_cnt       <= {EVT_CNT_W{1'b0}};
            end else begin
                evt_cnt        <= evt_nxt;
                drop_cnt       <= drop_nxt;
            end
        end
    end

endmodule

`default_nettype wire
