// ---------------------------------------------------------------------------
// tb_component_manual_test_top.v -- 연결 부품 수동 점검 Top 자동판정
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_component_manual_test_top;

    // servo_pwm의 us 환산이 실제와 같도록 최소 1 MHz를 사용한다.
    localparam integer CLK_HZ = 1_000_000;
    localparam integer PWM_HZ = 50;

    reg sysclk = 1'b0;
    reg [3:0] sw = 4'b0000;
    reg [3:0] btn = 4'b0000;

    wire [3:0] led;
    wire camera_pan_pwm, camera_tilt_pwm;
    wire laser_pan_pwm, laser_tilt_pwm;
    wire laser_gate_cmd;

    integer errors = 0;

    always #500 sysclk = ~sysclk;

    component_manual_test_top #(
        .CLK_HZ(CLK_HZ),
        .USE_CLK_CONVERTER(0),
        .PWM_HZ(PWM_HZ),
        .MAX_ON_FRAMES(50)
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
                @(posedge dut.frame_tick);
            @(negedge sysclk);
        end
    endtask

    task settle_inputs;
        begin
            repeat (8) @(posedge sysclk);
            @(negedge sysclk);
        end
    endtask

    task press_button(input integer idx);
        begin
            btn[idx] = 1'b1;
            run_frames(3);
            btn[idx] = 1'b0;
            run_frames(3);
        end
    endtask

    task press_virtual_btn4;
        begin
            btn[1:0] = 2'b11;
            run_frames(3);
            btn[1:0] = 2'b00;
            run_frames(3);
        end
    endtask

    task check(input [8*56-1:0] name, input integer got, input integer exp_v);
        begin
            if (got === exp_v)
                $display("  [PASS] %0s : %0d", name, got);
            else begin
                $display("  [FAIL] %0s : %0d (expected %0d)", name, got, exp_v);
                errors = errors + 1;
            end
        end
    endtask

    task check_true(input [8*56-1:0] name, input condition);
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
        $display("=== tb_component_manual_test_top ===");

        run_frames(3);
        check("T1 boot gate OFF", laser_gate_cmd, 0);
        check("T1 boot Servo LED OFF", led[1], 0);
        check("T1 camera PAN neutral", dut.camera_pan_pos, 128);
        check("T1 camera TILT neutral", dut.camera_tilt_pos, 128);
        check("T1 laser PAN neutral", dut.laser_pan_pos, 128);
        check("T1 laser TILT neutral", dut.laser_tilt_pos, 128);

        sw[0] = 1'b1;
        settle_inputs;
        check("T2 SW0 enables Servo LED", led[1], 1);
        @(posedge dut.frame_tick);
        repeat (3) @(posedge sysclk);
        check("T2 Camera PAN PWM active", camera_pan_pwm, 1);
        check("T2 Camera TILT PWM active", camera_tilt_pwm, 1);
        check("T2 Laser PAN PWM active", laser_pan_pwm, 1);
        check("T2 Laser TILT PWM active", laser_tilt_pwm, 1);

        // SW3:SW2=00, Camera PAN
        sw[3:2] = 2'b00;
        settle_inputs;
        press_button(1);
        check("T3 Camera PAN BTN1 +8", dut.camera_pan_pos, 136);
        press_button(1);
        press_button(1);
        check("T3 Camera PAN upper clamp", dut.camera_pan_pos, 144);
        press_button(2);
        check("T3 Camera PAN BTN2 neutral", dut.camera_pan_pos, 128);

        // SW3:SW2=01, Camera TILT
        sw[3:2] = 2'b01;
        settle_inputs;
        press_button(0);
        check("T4 Camera TILT BTN0 -8", dut.camera_tilt_pos, 120);

        // SW3:SW2=10, Laser PAN
        sw[3:2] = 2'b10;
        settle_inputs;
        press_button(1);
        check("T5 Laser PAN BTN1 +8", dut.laser_pan_pos, 136);

        // SW3:SW2=11, Laser TILT
        sw[3:2] = 2'b11;
        settle_inputs;
        press_button(0);
        check("T6 Laser TILT BTN0 -8", dut.laser_tilt_pos, 120);

        // 논리 BTN4 = BTN0+BTN1: 모두 Neutral
        press_virtual_btn4;
        check("T7 BTN4 Camera PAN neutral", dut.camera_pan_pos, 128);
        check("T7 BTN4 Camera TILT neutral", dut.camera_tilt_pos, 128);
        check("T7 BTN4 Laser PAN neutral", dut.laser_pan_pos, 128);
        check("T7 BTN4 Laser TILT neutral", dut.laser_tilt_pos, 128);

        // Arm LOW 이력을 만든 뒤 HIGH. Ready LED가 켜져야 한다.
        sw[1] = 1'b1;
        settle_inputs;
        check("T8 SW1 Arm ready LED", led[2], 1);

        // Arm 동안 Servo 위치 명령은 무시한다.
        press_button(1);
        check("T8 Arm blocks Servo movement", dut.laser_tilt_pos, 128);

        // BTN3을 누르는 동안 Gate를 유지하고, 놓으면 즉시 꺼진다.
        btn[3] = 1'b1;
        settle_inputs;
        run_frames(4);
        check("T9 BTN3 hold Laser Gate ON", laser_gate_cmd, 1);
        check("T9 LED3 mirrors Laser Gate", led[3], 1);
        run_frames(10);
        check("T9 Gate stays ON while BTN3 held", laser_gate_cmd, 1);
        btn[3] = 1'b0;
        settle_inputs;
        check("T9 BTN3 release Gate OFF", laser_gate_cmd, 0);
        check("T9 release has no timeout fault", dut.laser_timeout_fault, 0);

        // 계속 누르면 1 s 상한 뒤 timeout되고 SW1 재무장이 필요하다.
        btn[3] = 1'b1;
        settle_inputs;
        run_frames(4);
        check("T10 second hold Gate ON", laser_gate_cmd, 1);
        run_frames(52);
        check("T10 1 s timeout Gate OFF", laser_gate_cmd, 0);
        check("T10 timeout fault latched", dut.laser_timeout_fault, 1);
        check("T10 manual rearm required", dut.laser_rearm_required, 1);
        btn[3] = 1'b0;
        settle_inputs;

        btn[3] = 1'b1;
        settle_inputs;
        run_frames(6);
        check("T11 no trigger before rearm", laser_gate_cmd, 0);
        btn[3] = 1'b0;
        settle_inputs;

        sw[1] = 1'b0;
        settle_inputs;
        run_frames(1);
        check("T11 Arm LOW clears timeout", dut.laser_timeout_fault, 0);
        check("T11 Arm LOW clears rearm", dut.laser_rearm_required, 0);

        // 재무장 후 다시 켜고 논리 BTN5 = BTN2+BTN3로 즉시 정지한다.
        sw[1] = 1'b1;
        settle_inputs;
        btn[3] = 1'b1;
        settle_inputs;
        run_frames(4);
        check("T12 rearmed Gate ON", laser_gate_cmd, 1);

        btn[3:2] = 2'b11;
        settle_inputs;
        check("T12 BTN5 Gate immediate OFF", laser_gate_cmd, 0);
        check("T12 BTN5 Servo LED OFF", led[1], 0);
        check("T12 BTN5 four Servo PWM OFF",
              {camera_pan_pwm, camera_tilt_pwm,
               laser_pan_pwm, laser_tilt_pwm}, 0);
        check("T12 BTN5 latches rearm", dut.laser_rearm_required, 1);

        btn[3:2] = 2'b00;
        settle_inputs;
        check("T13 BTN5 release stays Gate OFF", laser_gate_cmd, 0);
        sw[1] = 1'b0;
        settle_inputs;
        run_frames(1);
        check("T13 post-E-stop Arm LOW clears rearm",
              dut.laser_rearm_required, 0);

        sw = 4'b0000;
        settle_inputs;
        check("T14 final Gate OFF", laser_gate_cmd, 0);
        check("T14 final Servo PWM disabled", led[1], 0);

        $display("=== result : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_component_manual_test_top FAILED");
        $finish;
    end

    initial begin
        repeat (10) #1_000_000_000;
        $fatal(1, "tb_component_manual_test_top TIMEOUT");
    end

endmodule

`default_nettype wire
