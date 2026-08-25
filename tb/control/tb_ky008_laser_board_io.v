// ---------------------------------------------------------------------------
// tb_ky008_laser_board_io.v -- KY-008 실제 광원용 안전 게이트 자동 판정
//
// 광원 대신 논리 출력만 검증한다. Power-on Arm HIGH, E-stop release, max-on
// timeout 모두 Arm LOW->HIGH 수동 재무장 전에는 gate가 다시 켜지면 안 된다.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_ky008_laser_board_io;

    localparam integer CLK_HZ = 100_000;
    localparam integer PWM_HZ = 50;

    reg sysclk = 1'b0;
    reg [3:0] sw = 4'b0111; // Boot with Servo/Arm/Target all HIGH
    reg [3:0] btn = 4'b0000;

    wire [3:0] led;
    wire camera_pan_pwm, camera_tilt_pwm;
    wire laser_pan_pwm, laser_tilt_pwm;
    wire laser_gate_cmd;

    integer errors = 0;

    always #5000 sysclk = ~sysclk;

    ky008_laser_board_io #(
        .CLK_HZ(CLK_HZ),
        .USE_CLK_CONVERTER(0),
        .PWM_HZ(PWM_HZ),
        .MAX_ON_FRAMES(5)
    ) dut (
        .sysclk(sysclk), .sw(sw), .btn(btn), .led(led),
        .camera_pan_pwm(camera_pan_pwm), .camera_tilt_pwm(camera_tilt_pwm),
        .laser_pan_pwm(laser_pan_pwm), .laser_tilt_pwm(laser_tilt_pwm),
        .laser_gate_cmd(laser_gate_cmd)
    );

    task run_frames(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge dut.u_board.frame_tick);
            @(negedge sysclk);
        end
    endtask

    task settle_switch;
        begin
            repeat (8) @(posedge sysclk);
            @(negedge sysclk);
        end
    endtask

    task check(input [8*52-1:0] name, input integer got, input integer exp_v);
        begin
            if (got === exp_v)
                $display("  [PASS] %0s : %0d", name, got);
            else begin
                $display("  [FAIL] %0s : %0d (expected %0d)", name, got, exp_v);
                errors = errors + 1;
            end
        end
    endtask

    task check_true(input [8*52-1:0] name, input condition);
        begin
            if (condition)
                $display("  [PASS] %0s", name);
            else begin
                $display("  [FAIL] %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("=== tb_ky008_laser_board_io : default-OFF safe gate ===");

        // Arm이 HIGH인 채 부팅하면 유효 Target이 있어도 gate는 켜지지 않는다.
        run_frames(8);
        check("T1 boot Arm HIGH gate OFF", laser_gate_cmd, 0);
        check("T1 boot requires manual rearm",
              dut.u_board.laser_rearm_required, 1);

        sw[1] = 1'b0;
        settle_switch;
        check("T2 Arm LOW clears rearm",
              dut.u_board.laser_rearm_required, 0);
        check("T2 disarmed gate OFF", laser_gate_cmd, 0);

        // Arm OFF 상태에서 좁은 Servo 범위를 확인한 뒤 Target을 중앙 복귀한다.
        btn[1] = 1'b1;
        run_frames(3);
        btn[1] = 1'b0;
        run_frames(6);
        check_true("T3 PT1 stays in 112..144",
                   dut.u_board.camera_pan_pos >= 112 &&
                   dut.u_board.camera_pan_pos <= 144);
        check_true("T3 PT2 stays in 112..144",
                   dut.u_board.laser_pan_pos >= 112 &&
                   dut.u_board.laser_pan_pos <= 144);
        btn[1:0] = 2'b11;
        run_frames(3);
        btn[1:0] = 2'b00;
        run_frames(6);
        check("T3 target returns center", dut.u_board.target_x, 32);

        sw[1] = 1'b1;
        run_frames(4);
        check("T4 explicit Arm cycle enables gate", laser_gate_cmd, 1);
        check("T4 onboard LED3 mirrors gate", led[3], laser_gate_cmd);

        // E-stop release만으로는 다시 켜지지 않는다.
        sw[3] = 1'b1;
        settle_switch;
        check("T5 E-stop gate OFF", laser_gate_cmd, 0);
        check("T5 E-stop latches rearm",
              dut.u_board.laser_rearm_required, 1);
        sw[3] = 1'b0;
        run_frames(5);
        check("T5 E-stop release stays OFF", laser_gate_cmd, 0);

        sw[1] = 1'b0;
        settle_switch;
        sw[1] = 1'b1;
        run_frames(4);
        check("T6 post-E-stop Arm cycle enables gate", laser_gate_cmd, 1);

        // 5 frame(100 ms @ 50 Hz) 뒤 timeout되고 Arm LOW 전에는 유지된다.
        run_frames(7);
        check("T7 100 ms max-on gate OFF", laser_gate_cmd, 0);
        check("T7 timeout fault latched",
              dut.u_board.laser_timeout_fault, 1);
        check("T7 timeout requires manual rearm",
              dut.u_board.laser_rearm_required, 1);
        run_frames(4);
        check("T7 no automatic timeout recovery", laser_gate_cmd, 0);

        sw[1] = 1'b0;
        settle_switch;
        check("T8 Arm LOW clears timeout",
              dut.u_board.laser_timeout_fault, 0);
        check("T8 Arm LOW leaves gate OFF", laser_gate_cmd, 0);

        $display("=== result : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_ky008_laser_board_io FAILED");
        $finish;
    end

    initial begin
        repeat (6) #1_000_000_000;
        $fatal(1, "tb_ky008_laser_board_io TIMEOUT");
    end

endmodule

`default_nettype wire
