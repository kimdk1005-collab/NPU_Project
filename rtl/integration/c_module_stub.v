`timescale 1ns/1ps
//=====================================================================
// c_module_stub : C 담당 모듈의 통합시험용 자리표시자
// 담당: A  (통합 검증 목적. C 의 실제 설계가 아니다)
//
//  !! C 가 실물을 주면 이 모듈은 통째로 교체된다. !!
//
//  왜 만드나
//   1. C 포트(evt_* / pan_cmd / ... / laser_cal)가 미연결이면 Vivado 가
//      전부 최적화로 지워버린다. 그러면 통합 리소스/타이밍 수치가
//      실제보다 낮게 나와 "여유 있다"고 착각하게 된다.
//   2. C 모듈이 붙었을 때 100 MHz 가 유지되는지 미리 재본다.
//   3. C 에게 넘길 포트 골격이 된다. 안을 채우면 실물이 된다.
//
//  들어 있는 것 (전부 최소 구현. 계수/부호/제어정책은 C 가 정한다)
//   - Servo PWM 4채널 (PAN1 / TILT1 / PAN2 / TILT2)
//   - Tracking 좌표 변환 : spec v1.5 §15.2 의 형태
//                theta_pan_target = theta_pan1 + k_x*(target_x-32)
//   - Event Accumulator : NPU 입력버퍼에 evt_* 로 기록
//   - Laser Interlock   : PT#1 / PT#2 SAFE_LIMIT 동시 검사
//=====================================================================
module c_module_stub #(
    parameter PWM_W = 20            // 20 bit @100MHz = 10.49 ms 주기
)(
    input  wire        clk,
    input  wire        rstn,

    // --- AXI Register 에서 오는 설정 (C 소유 영역) ---
    input  wire [31:0] event_cfg,       // 0x08
    input  wire [31:0] pan_cmd,         // 0x20  PT#1 카메라 헤드
    input  wire [31:0] tilt_cmd,        // 0x24  PT#1
    input  wire [31:0] laser_ctrl,      // 0x28
    input  wire [31:0] safe_limit,      // 0x2C  PT#1
    input  wire [31:0] track_err_x,     // 0x30
    input  wire [31:0] track_err_y,     // 0x34
    input  wire [31:0] pan2_cmd,        // 0x48  PT#2 레이저 헤드
    input  wire [31:0] tilt2_cmd,       // 0x4C  PT#2
    input  wire [31:0] safe_limit2,     // 0x50  PT#2
    input  wire [31:0] laser_cal,       // 0x54

    // --- NPU 결과 (A -> C) ---
    input  wire        npu_busy,
    input  wire        npu_done,
    input  wire        target_valid,
    input  wire [5:0]  target_x,
    input  wire [5:0]  target_y,
    input  wire signed [7:0] target_score,

    // --- Event Tensor 기록 (C -> A, spec §7.3) ---
    output reg         evt_we,
    output reg  [12:0] evt_addr,
    output reg  signed [7:0] evt_data,
    output wire [31:0] input_stat,      // 0x0C  (C -> PS)

    // --- 외부 핀 ---
    output wire [3:0]  servo_pwm,       // {TILT2, PAN2, TILT1, PAN1}
    output wire        laser_en
);
    //=================================================================
    // 1. Tracking 좌표 변환 (spec v1.5 §15.2 의 형태)
    //
    //      err          = target - 32
    //      theta_target = theta_pan1 + k * err        <- theta_pan1 을 더한다
    //      pt2_cmd      = theta_target + LASER_OFFSET
    //
    //    theta_pan1 을 더하는 것이 핵심이다. err 만 쓰면
    //    레이저가 표적이 아니라 "오차"를 따라간다.
    //    k / OFFSET 은 laser_cal 에서 뽑는다 (실값은 C 가 실측).
    //=================================================================
    wire signed [7:0] err_raw_x = $signed({2'b0, target_x}) - 8'sd32;
    wire signed [7:0] err_raw_y = $signed({2'b0, target_y}) - 8'sd32;

    // event_cfg[2] = 1 이면 PS 가 0x30/0x34 에 써준 오차를 대신 쓴다
    wire signed [7:0] err_x = event_cfg[2] ? $signed(track_err_x[7:0]) : err_raw_x;
    wire signed [7:0] err_y = event_cfg[2] ? $signed(track_err_y[7:0]) : err_raw_y;

    wire signed  [7:0] k_x   = $signed(laser_cal[7:0]);      // deg/pixel 계수 자리
    wire signed  [7:0] k_y   = $signed(laser_cal[15:8]);
    wire signed [15:0] ofs   = $signed(laser_cal[31:16]);    // LASER_OFFSET 자리

    reg signed [23:0] theta_pan_t, theta_tilt_t;
    reg signed [23:0] pt2_pan_calc, pt2_tilt_calc;

    always @(posedge clk) begin
        if (!rstn) begin
            theta_pan_t   <= 24'sd0; theta_tilt_t  <= 24'sd0;
            pt2_pan_calc  <= 24'sd0; pt2_tilt_calc <= 24'sd0;
        end else begin
            if (npu_done) begin
                theta_pan_t  <= $signed(pan_cmd [23:0]) + $signed(err_x * k_x);
                theta_tilt_t <= $signed(tilt_cmd[23:0]) + $signed(err_y * k_y);
            end
            pt2_pan_calc  <= theta_pan_t  + {{8{ofs[15]}}, ofs};
            pt2_tilt_calc <= theta_tilt_t + {{8{ofs[15]}}, ofs};
        end
    end

    //=================================================================
    // 2. Servo PWM 4채널
    //    event_cfg[1] = 1 : PT#2 duty 를 §15.2 계산값으로 (자동 추적)
    //    event_cfg[1] = 0 : PS 가 0x48/0x4C 에 직접 쓴 값으로 (수동 보정)
    //    실제 서보 duty 매핑(1.0~2.0 ms)은 C 가 정한다.
    //=================================================================
    reg [PWM_W-1:0] pwm_cnt;
    always @(posedge clk) begin
        if (!rstn) pwm_cnt <= {PWM_W{1'b0}};
        else       pwm_cnt <= pwm_cnt + {{(PWM_W-1){1'b0}}, 1'b1};
    end

    wire [PWM_W-1:0] duty0 = pan_cmd [PWM_W-1:0];
    wire [PWM_W-1:0] duty1 = tilt_cmd[PWM_W-1:0];
    wire [PWM_W-1:0] duty2 = event_cfg[1] ? pt2_pan_calc [PWM_W-1:0]
                                          : pan2_cmd     [PWM_W-1:0];
    wire [PWM_W-1:0] duty3 = event_cfg[1] ? pt2_tilt_calc[PWM_W-1:0]
                                          : tilt2_cmd    [PWM_W-1:0];

    reg [3:0] pwm_r;
    always @(posedge clk) begin
        if (!rstn) pwm_r <= 4'd0;
        else begin
            pwm_r[0] <= (pwm_cnt < duty0);
            pwm_r[1] <= (pwm_cnt < duty1);
            pwm_r[2] <= (pwm_cnt < duty2);
            pwm_r[3] <= (pwm_cnt < duty3);
        end
    end
    assign servo_pwm = pwm_r;

    //=================================================================
    // 3. Event Accumulator 자리
    //    Event Window 가 끝나면 8192 byte 를 NPU 입력버퍼에 기록한다.
    //    여기서는 주소를 훑는 최소 형태만 둔다.
    //    NPU 가 busy 인 동안 evt_we 를 올리지 않는다 (spec §7.3).
    //=================================================================
    reg [12:0] evt_cnt;
    reg        evt_run;
    reg [31:0] evt_total;

    always @(posedge clk) begin
        if (!rstn) begin
            evt_run  <= 1'b0; evt_cnt <= 13'd0;
            evt_we   <= 1'b0; evt_addr <= 13'd0; evt_data <= 8'sd0;
            evt_total <= 32'd0;
        end else begin
            evt_we <= 1'b0;
            // event_cfg[0] = Window 종료 신호 자리
            if (!evt_run && event_cfg[0] && !npu_busy) begin
                evt_run <= 1'b1; evt_cnt <= 13'd0;
            end else if (evt_run) begin
                evt_we    <= 1'b1;
                evt_addr  <= evt_cnt;
                evt_data  <= $signed(event_cfg[15:8]);  // 실물은 누적 이벤트 값
                evt_total <= evt_total + 32'd1;
                if (evt_cnt == 13'd8191) evt_run <= 1'b0;
                evt_cnt <= evt_cnt + 13'd1;
            end
        end
    end

    assign input_stat = evt_total;              // 0x0C 로 PS 가 읽는다

    //=================================================================
    // 4. Laser Interlock (spec v1.5 §17)
    //    PT#1 과 PT#2 를 둘 다 검사한다.
    //    헤드가 2개가 되면서 "카메라가 보는 곳 = 레이저가 가는 곳"이라는
    //    기구적 보장이 사라졌기 때문이다.
    //=================================================================
    wire [15:0] pt1_lo = safe_limit [15:0];
    wire [15:0] pt1_hi = safe_limit [31:16];
    wire [15:0] pt2_lo = safe_limit2[15:0];
    wire [15:0] pt2_hi = safe_limit2[31:16];

    wire pt1_ok = (pan_cmd [15:0] >= pt1_lo) && (pan_cmd [15:0] <= pt1_hi) &&
                  (tilt_cmd[15:0] >= pt1_lo) && (tilt_cmd[15:0] <= pt1_hi);

    // PT#2 는 실제로 서보에 나가는 값(duty2/duty3 원본)을 검사해야 한다
    wire [15:0] pt2_pan_eff  = event_cfg[1] ? pt2_pan_calc [15:0] : pan2_cmd [15:0];
    wire [15:0] pt2_tilt_eff = event_cfg[1] ? pt2_tilt_calc[15:0] : tilt2_cmd[15:0];
    wire pt2_ok = (pt2_pan_eff  >= pt2_lo) && (pt2_pan_eff  <= pt2_hi) &&
                  (pt2_tilt_eff >= pt2_lo) && (pt2_tilt_eff <= pt2_hi);

    wire lock_ok = (err_x <= 8'sd4) && (err_x >= -8'sd4) &&
                   (err_y <= 8'sd4) && (err_y >= -8'sd4);

    reg laser_r;
    always @(posedge clk) begin
        if (!rstn) laser_r <= 1'b0;
        else laser_r <= laser_ctrl[0]                          // C enable
                      & target_valid
                      & (target_score > $signed(laser_ctrl[15:8]))
                      & pt1_ok & pt2_ok                        // 두 헤드 다 안전
                      & lock_ok
                      & ~laser_ctrl[31];                       // Emergency Stop
    end
    assign laser_en = laser_r;

endmodule
