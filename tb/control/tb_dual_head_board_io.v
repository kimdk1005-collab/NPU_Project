// ---------------------------------------------------------------------------
// tb_dual_head_board_io.v -- 4-Servo + 외부 RED LED 최종 보드 Top 검증
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_dual_head_board_io;

    localparam integer CLK_HZ = 1_000_000;
    localparam integer PWM_HZ = 50;

    reg sysclk = 1'b0;
    reg [3:0] sw = 4'b0000;
    reg [3:0] btn = 4'b0000;
    wire [3:0] led;
    wire camera_pan_pwm, camera_tilt_pwm;
    wire laser_pan_pwm, laser_tilt_pwm;
    wire laser_red;

    integer errors = 0;
    integer m_cam_pan, m_cam_tilt, m_laser_pan, m_laser_tilt, m_total;

    always #500 sysclk = ~sysclk;

    dual_head_board_io #(
        .CLK_HZ(CLK_HZ),
        .USE_CLK_CONVERTER(0),
        .PWM_HZ(PWM_HZ),
        .MAX_ON_FRAMES(25)
    ) dut (
        .sysclk(sysclk), .sw(sw), .btn(btn), .led(led),
        .camera_pan_pwm(camera_pan_pwm), .camera_tilt_pwm(camera_tilt_pwm),
        .laser_pan_pwm(laser_pan_pwm), .laser_tilt_pwm(laser_tilt_pwm),
        .laser_red(laser_red)
    );

    task run_frames(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge dut.frame_tick);
            @(negedge sysclk);
        end
    endtask

    task check(input [8*44-1:0] name, input integer got, input integer exp_v);
        begin
            if (got == exp_v)
                $display("  [PASS] %0s : %0d", name, got);
            else begin
                $display("  [FAIL] %0s : %0d (expected %0d)", name, got, exp_v);
                errors = errors + 1;
            end
        end
    endtask

    task check_true(input [8*44-1:0] name, input condition);
        begin
            if (condition)
                $display("  [PASS] %0s", name);
            else begin
                $display("  [FAIL] %0s", name);
                errors = errors + 1;
            end
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

    task center_x;
        begin
            btn[1:0] = 2'b11;
            run_frames(3);
            btn[1:0] = 2'b00;
            run_frames(3);
        end
    endtask

    task center_y;
        begin
            btn[3:2] = 2'b11;
            run_frames(3);
            btn[3:2] = 2'b00;
            run_frames(3);
        end
    endtask

    task measure_pwm;
        begin
            @(posedge dut.frame_tick);
            @(negedge sysclk);
            m_cam_pan = 0; m_cam_tilt = 0;
            m_laser_pan = 0; m_laser_tilt = 0; m_total = 0;
            forever begin
                @(negedge sysclk);
                m_total = m_total + 1;
                if (camera_pan_pwm)  m_cam_pan = m_cam_pan + 1;
                if (camera_tilt_pwm) m_cam_tilt = m_cam_tilt + 1;
                if (laser_pan_pwm)   m_laser_pan = m_laser_pan + 1;
                if (laser_tilt_pwm)  m_laser_tilt = m_laser_tilt + 1;
                if (dut.frame_tick) disable measure_pwm;
            end
        end
    endtask

    initial begin
        $display("=== tb_dual_head_board_io : final 4-Servo + RED drive test ===");

        run_frames(3);
        check("T1 reset target X center", dut.target_x, 32);
        check("T1 reset target Y center", dut.target_y, 32);
        check("T1 Servo disabled", camera_pan_pwm | camera_tilt_pwm |
                                  laser_pan_pwm | laser_tilt_pwm, 0);
        check("T1 RED fail-closed", laser_red, 0);

        // Servo + Target만 켜고 Arm은 아직 끈다.
        sw[0] = 1'b1;
        sw[2] = 1'b1;
        run_frames(3);
        measure_pwm;
        check("T2 common PWM frame", m_total, CLK_HZ / PWM_HZ);
        check_true("T2 camera PAN neutral PWM", m_cam_pan >= 1498 && m_cam_pan <= 1502);
        check_true("T2 camera TILT neutral PWM", m_cam_tilt >= 1498 && m_cam_tilt <= 1502);
        check_true("T2 laser PAN neutral PWM", m_laser_pan >= 1498 && m_laser_pan <= 1502);
        check_true("T2 laser TILT neutral PWM", m_laser_tilt >= 1498 && m_laser_tilt <= 1502);
        check("T2 Arm off keeps RED off", laser_red, 0);

        // X+ 한 번: Target 40, 두 PAN 축이 +방향으로 이동한다.
        press_button(1);
        check("T3 btn1 target X+8", dut.target_x, 40);
        check_true("T3 camera PAN follows X+", dut.camera_pan_pos > 128);
        check_true("T3 laser PAN target includes residual",
                   dut.laser_pan_target > dut.camera_pan_pos);
        check_true("T3 laser PAN follows X+", dut.laser_pan_pos > 128);
        check("T3 off-center keeps RED off", laser_red, 0);

        center_x;
        run_frames(5);
        check("T4 X chord returns center", dut.target_x, 32);
        check_true("T4 PT2 catches camera PAN", dut.laser_pan_pos == dut.camera_pan_pos);

        // Y+ 한 번: 두 TILT 축을 검증한다.
        press_button(3);
        check("T5 btn3 target Y+8", dut.target_y, 40);
        check_true("T5 camera TILT follows Y+", dut.camera_tilt_pos > 128);
        check_true("T5 laser TILT target includes residual",
                   dut.laser_tilt_target > dut.camera_tilt_pos);
        check_true("T5 laser TILT follows Y+", dut.laser_tilt_pos > 128);

        center_y;
        run_frames(5);
        check("T6 Y chord returns center", dut.target_y, 32);
        check_true("T6 PT2 catches camera TILT", dut.laser_tilt_pos == dut.camera_tilt_pos);

        // Center + Valid + Aim Ready에서 Arm 후 3회 확인되어야 RED ON.
        sw[1] = 1'b1;
        run_frames(5);
        check("T7 qualified RED on", laser_red, 1);
        check("T7 onboard LED3 mirrors RED", led[3], 1);

        // E-stop은 동기화 뒤 즉시 Fail-Closed.
        sw[3] = 1'b1;
        repeat (8) @(posedge sysclk);
        check("T8 emergency stop RED off", laser_red, 0);
        sw[3] = 1'b0;
        run_frames(5);
        check("T8 re-confirm after E-stop", laser_red, 1);

        // 연속 ON 500 ms 제한.
        run_frames(30);
        check("T9 max-on RED off", laser_red, 0);
        check("T9 timeout fault latched", dut.laser_timeout_fault, 1);

        // Arm off로 fault를 clear한 뒤 Servo disable까지 확인한다.
        sw[1] = 1'b0;
        repeat (8) @(posedge sysclk);
        check("T10 Arm off clears timeout", dut.laser_timeout_fault, 0);
        sw[0] = 1'b0;
        repeat (8) @(posedge sysclk);
        check("T10 Servo disable PWM off", camera_pan_pwm | camera_tilt_pwm |
                                            laser_pan_pwm | laser_tilt_pwm, 0);
        check("T10 Servo disable RED off", laser_red, 0);

        $display("=== result : %0s (errors=%0d) ===",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "tb_dual_head_board_io FAILED");
        $finish;
    end

    initial begin
        repeat (8) #1_000_000_000;
        $fatal(1, "tb_dual_head_board_io TIMEOUT");
    end

endmodule

`default_nettype wire
