// ---------------------------------------------------------------------------
// event_accumulator.v -- Event Stream -> 64x64x2 Tensor -> NPU 전송
//
//  담당 : C   (SPEC §5.3 이 rtl/event/event_accumulator.v 를 C 소유로 명시)
//  상위 권한 : docs/NPU_EVENT_CAMERA_TEAM_COMMON_AI_INTEGRATION_SPEC_v1.2.md
//  규격 : SPEC §6.1  Event 입력 형식 (변경 금지)
//         SPEC §7.1  Tensor Shape 64x64x2, Ch0 = Positive / Ch1 = Negative
//         SPEC §9.1  Event Count 0 ~ 127 포화 (Wrap 금지)
//         docs/D3_FREEZE_REQUEST_A_001.md  1번 CHW 주소식 / 5번 ext_* 프로토콜
//         docs/C_TO_A_DELIVERY_SPEC.md     §2 전송 규격
//
//  주소식 (A 확정)
//      addr = (polarity << 12) | (y << 6) | x
//      polarity 0 = Positive -> Channel 0 -> addr 0    ~ 4095
//      polarity 1 = Negative -> Channel 1 -> addr 4096 ~ 8191
//
//  동작
//      event_valid       -> 해당 주소 카운트 +1 (127 포화)
//      event_window_end  -> 버퍼 확정, 반대 버퍼로 전환
//                           npu_busy 가 내려가면 8192 byte 순차 전송
//                           전송하면서 그 버퍼를 0 으로 지운다
//      전송 완료         -> tensor_start 1 cycle pulse
//
// ---------------------------------------------------------------------------
//  설계상 까다로운 지점 세 가지
//
//  (1) Read-Modify-Write 포워딩
//      카운트 +1 은 읽고-더하고-쓰기다. BRAM 읽기가 1 cycle 지연되므로
//      같은 주소 이벤트가 연속으로 오면 두 번째가 갱신 전 값을 읽는다.
//      그대로 두면 2 개가 들어와도 카운트가 1 만 오르고, 참조 모델과 어긋난다.
//      실제 이벤트 스트림에서 같은 픽셀이 연달아 튀는 것은 흔한 일이다.
//
//      해결 : 한 단계 뒤(r3)에서 방금 쓴 주소/값을 들고 있다가,
//      지금 계산할 주소와 같으면 BRAM 출력 대신 그 값을 쓴다.
//      두 단계 뒤부터는 BRAM 에 이미 반영되어 있어 한 단계면 충분하다.
//
//      부수 효과로 "읽기 포트와 쓰기 포트가 같은 주소를 동시에 치는" 경우의
//      하드웨어 미정의 동작도 함께 막힌다. 그 경우가 곧 포워딩 조건이라
//      BRAM 출력을 아예 쓰지 않기 때문이다.
//
//  (2) Ping-Pong 과 파이프라인 잔류
//      A 규격상 npu_busy 동안 쓰기가 금지되고, 8192 byte 전송에 8192 cycle 이
//      걸린다. 그 사이에도 다음 Window 이벤트는 계속 들어오므로 버퍼가 2 개
//      필요하다. 하나로 하면 전송 시간만큼 이벤트가 통째로 유실된다.
//
//      다만 window_end 시점에 RMW 파이프라인 안에 남아 있는 이벤트들은
//      "이전 Window" 소속이다. 버퍼 선택을 즉시 바꾸면 그것들이 새 버퍼로
//      새어 들어간다. 그래서 버퍼 선택 비트를 이벤트와 함께 파이프라인에
//      실어 보내고(r1_sel, r2_sel), 전송은 파이프라인이 비워진 뒤에 시작한다.
//
//  (3) 전송 중 0 초기화
//      다음에 이 버퍼를 다시 쓰려면 0 이어야 한다. 따로 지우면 8192 cycle 을
//      더 쓰므로, 전송하면서 같이 지운다.
//      단 읽기 주소와 쓰기 주소를 같은 cycle 에 겹치지 않게 한 박자 어긋내
//      쓴다 (읽은 다음 cycle 에 그 주소를 0 으로). 서로 다른 포트가 같은
//      주소를 동시에 치는 상황을 아예 만들지 않기 위한 것이다.
//
//  전원 인가 직후 BRAM 내용은 미정의다. 그래서 INIT 상태에서 두 버퍼를
//  0 으로 채운 뒤에야 첫 Window 를 받는다. acc_ready 가 그 완료 신호다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module event_accumulator #(
    // SPEC §9.1 Conv1 입력 Event Count = 0 ~ 127. Wrap 금지, 포화.
    parameter integer SAT_MAX   = 127,
    // window_end 후 RMW 파이프라인이 비워질 때까지 기다리는 cycle 수.
    // 파이프라인이 2 단이므로 3 이면 충분하고 1 을 여유로 둔다.
    parameter integer DRAIN_CYC = 4
)(
    input  wire              clk,
    input  wire              rst_n,        // Active-Low 비동기 Reset

    // --- SPEC §6.1 내부 표준 Event 입력 (이름/폭 변경 금지) ---------------
    input  wire              event_valid,
    input  wire  [5:0]       event_x,
    input  wire  [5:0]       event_y,
    input  wire              event_polarity,   // 0 = Positive(Ch0), 1 = Negative(Ch1)
    input  wire              event_window_end,

    // --- A 의 npu_core 로 나가는 Tensor 출력 (C_TO_A_DELIVERY_SPEC §2) -----
    input  wire              npu_busy,     // npu_core.busy. 1 이면 쓰기 금지
    output reg               tensor_we,    // -> ext_we
    output reg   [12:0]      tensor_addr,  // -> ext_addr
    output reg signed [7:0]  tensor_data,  // -> ext_data
    output reg               tensor_start, // -> start. 전송 완료 후 1 cycle pulse

    // --- 진단 출력 (규격 밖. 상위는 무시해도 된다) ------------------------
    output wire              acc_ready,    // 0 이면 아직 INIT 중이라 이벤트를 받지 않는다
    output reg               overrun       // sticky. 전송이 끝나기 전에 다음
                                           // window_end 가 왔다 = 설계 여유 위반
);

    localparam integer DEPTH = 8192;

    // -----------------------------------------------------------------------
    // 상태
    // -----------------------------------------------------------------------
    localparam [2:0] S_INIT  = 3'd0,   // 두 버퍼를 0 으로 채운다
                     S_ACC   = 3'd1,   // 누적 중. window_end 대기
                     S_DRAIN = 3'd2,   // RMW 파이프라인 배수
                     S_WAIT  = 3'd3,   // npu_busy 가 내려가기를 대기
                     S_XFER  = 3'd4,   // 8192 byte 전송 + 0 초기화
                     S_PULSE = 3'd5;   // tensor_start 1 cycle

    reg [2:0]  state;
    reg [13:0] cnt;          // INIT / XFER 공용 카운터 (0 ~ 8192)
    reg [2:0]  drain_cnt;

    assign acc_ready = (state != S_INIT);

    // -----------------------------------------------------------------------
    // 버퍼 선택
    //   acc_sel  : 지금 이벤트가 쌓이는 버퍼
    //   xfer_sel : 전송/초기화 대상 버퍼 (= 직전 Window 것)
    // -----------------------------------------------------------------------
    reg acc_sel;
    reg xfer_sel;

    // -----------------------------------------------------------------------
    // RMW 파이프라인
    //   r1 : 입력 등록. 이 주소로 BRAM 읽기를 건다
    //   r2 : 읽은 값 도착. 포화 +1 계산 후 쓰기
    //   r3 : 방금 쓴 주소/값. 포워딩 소스
    // -----------------------------------------------------------------------
    wire [12:0] ev_addr = {event_polarity, event_y, event_x};

    reg         r1_v, r2_v, r3_v;
    reg  [12:0] r1_a, r2_a, r3_a;
    reg         r1_s, r2_s;
    reg  [7:0]  r3_d;

    wire [7:0] q0, q1;                       // 버퍼별 BRAM 읽기 출력
    wire [7:0] q_rmw = r2_s ? q1 : q0;

    // 한 단계 뒤에 쓴 값이 아직 BRAM 에 안 보일 수 있다 -> 그 값을 그대로 쓴다
    wire fwd = r2_v && r3_v && (r2_a == r3_a);
    wire [7:0] cur = fwd ? r3_d : q_rmw;
    wire [7:0] nxt = (cur >= SAT_MAX[7:0]) ? SAT_MAX[7:0] : (cur + 8'd1);

    // -----------------------------------------------------------------------
    // 전송 경로
    //   읽기는 cnt, 0 쓰기는 한 박자 뒤(cnt_d). 두 주소가 절대 겹치지 않는다
    // -----------------------------------------------------------------------
    wire        xfer_rd = (state == S_XFER) && (cnt < DEPTH[13:0]);
    reg         xfer_ov;                     // 읽기 결과가 유효한 cycle
    reg  [12:0] xfer_ad;
    wire [7:0]  q_xfer = xfer_sel ? q1 : q0;

    // -----------------------------------------------------------------------
    // 버퍼 포트 배선
    //   불변식 : 전송 대상 버퍼(xfer_sel)와 누적 대상 버퍼(acc_sel)는 다르고,
    //   전송은 파이프라인 배수 후에만 도는다. 따라서 한 버퍼에 두 용도가
    //   동시에 걸리는 일이 없다.
    // -----------------------------------------------------------------------
    wire init_we = (state == S_INIT);

    wire b0_xfer = (state == S_XFER) && (xfer_sel == 1'b0);
    wire b1_xfer = (state == S_XFER) && (xfer_sel == 1'b1);

    wire [12:0] b0_ra = b0_xfer ? cnt[12:0] : r1_a;
    wire [12:0] b1_ra = b1_xfer ? cnt[12:0] : r1_a;

    wire        b0_we = init_we ? 1'b1 : (b0_xfer ? xfer_ov : (r2_v && (r2_s == 1'b0)));
    wire        b1_we = init_we ? 1'b1 : (b1_xfer ? xfer_ov : (r2_v && (r2_s == 1'b1)));

    wire [12:0] b0_wa = init_we ? cnt[12:0] : (b0_xfer ? xfer_ad : r2_a);
    wire [12:0] b1_wa = init_we ? cnt[12:0] : (b1_xfer ? xfer_ad : r2_a);

    wire [7:0]  b0_wd = (init_we || b0_xfer) ? 8'd0 : nxt;
    wire [7:0]  b1_wd = (init_we || b1_xfer) ? 8'd0 : nxt;

    bram_8k u_buf0 (.clk(clk), .we(b0_we), .wa(b0_wa), .wd(b0_wd), .ra(b0_ra), .q(q0));
    bram_8k u_buf1 (.clk(clk), .we(b1_we), .wa(b1_wa), .wd(b1_wd), .ra(b1_ra), .q(q1));

    // -----------------------------------------------------------------------
    // 파이프라인 / FSM
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_INIT;
            cnt          <= 14'd0;
            drain_cnt    <= 3'd0;
            acc_sel      <= 1'b0;
            xfer_sel     <= 1'b0;
            r1_v <= 1'b0; r2_v <= 1'b0; r3_v <= 1'b0;
            r1_a <= 13'd0; r2_a <= 13'd0; r3_a <= 13'd0;
            r1_s <= 1'b0; r2_s <= 1'b0; r3_d <= 8'd0;
            xfer_ov      <= 1'b0;
            xfer_ad      <= 13'd0;
            tensor_we    <= 1'b0;
            tensor_addr  <= 13'd0;
            tensor_data  <= 8'sd0;
            tensor_start <= 1'b0;
            overrun      <= 1'b0;
        end else begin
            tensor_start <= 1'b0;

            // ---- RMW 파이프라인 -------------------------------------------
            // INIT 중에는 이벤트를 받지 않는다 (버퍼가 아직 미정의)
            r1_v <= event_valid && (state != S_INIT);
            r1_a <= ev_addr;
            r1_s <= acc_sel;              // toggle 이전 값이 잡힌다

            r2_v <= r1_v;
            r2_a <= r1_a;
            r2_s <= r1_s;

            r3_v <= r2_v;
            r3_a <= r2_a;
            r3_d <= nxt;

            // ---- 전송 출력 정렬 (BRAM 1 cycle 지연) -----------------------
            xfer_ov     <= xfer_rd;
            xfer_ad     <= cnt[12:0];
            tensor_we   <= xfer_ov;
            tensor_addr <= xfer_ad;
            tensor_data <= $signed(q_xfer);

            // ---- Window 경계 ----------------------------------------------
            // 같은 clock 의 이벤트는 현재 Window 에 포함된다 (HANDOFF §1).
            // r1_s 가 toggle 이전 acc_sel 을 잡으므로 자동으로 성립한다.
            if (event_window_end && (state != S_INIT)) begin
                if (state == S_ACC) begin
                    acc_sel   <= ~acc_sel;
                    xfer_sel  <= acc_sel;
                    drain_cnt <= 3'd0;
                    state     <= S_DRAIN;
                end else begin
                    // 직전 전송이 아직 안 끝났다. 이번 Window 는 버릴 수밖에 없다.
                    // 설계 여유(33.3 ms vs 1.34 ms) 위반이므로 기록만 남긴다.
                    overrun <= 1'b1;
                end
            end else begin
                case (state)
                    S_INIT: begin
                        if (cnt == DEPTH[13:0] - 14'd1) begin
                            cnt   <= 14'd0;
                            state <= S_ACC;
                        end else begin
                            cnt <= cnt + 14'd1;
                        end
                    end

                    S_DRAIN: begin
                        if (drain_cnt == DRAIN_CYC[2:0] - 3'd1) state <= S_WAIT;
                        else drain_cnt <= drain_cnt + 3'd1;
                    end

                    S_WAIT: begin
                        if (!npu_busy) begin
                            cnt   <= 14'd0;
                            state <= S_XFER;
                        end
                    end

                    S_XFER: begin
                        if (cnt < DEPTH[13:0]) cnt <= cnt + 14'd1;
                        else if (!xfer_ov)     state <= S_PULSE;
                    end

                    S_PULSE: begin
                        tensor_start <= 1'b1;
                        state        <= S_ACC;
                    end

                    default: ;   // S_ACC : window_end 대기
                endcase
            end
        end
    end

endmodule


// ---------------------------------------------------------------------------
// bram_8k -- 8192 x 8 Simple Dual Port. 읽기 1 cycle 지연.
//
//  읽기 포트와 쓰기 포트가 같은 주소를 동시에 치는 경우의 하드웨어 동작은
//  보장되지 않는다. 상위 event_accumulator 가 그 상황을 두 가지 방법으로
//  회피한다 -- RMW 는 포워딩으로 BRAM 출력을 버리고, 전송은 읽기와 0 쓰기의
//  주소를 한 박자 어긋내 애초에 겹치지 않게 한다.
// ---------------------------------------------------------------------------
module bram_8k (
    input  wire        clk,
    input  wire        we,
    input  wire [12:0] wa,
    input  wire [7:0]  wd,
    input  wire [12:0] ra,
    output reg  [7:0]  q
);
    (* ram_style = "block" *) reg [7:0] mem [0:8191];

    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        q <= mem[ra];
    end
endmodule

`default_nettype wire
