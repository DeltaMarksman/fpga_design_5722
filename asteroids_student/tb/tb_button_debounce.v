// tb_button_debounce - self-checking testbench (Task 10). CNT_BITS = 4, so
// the input must disagree for 16 clocks. Cases: a bouncing press and a
// bouncing release; exactly one press pulse per press however long it is
// held; a pulse shorter than the debounce time is ignored.
module tb_button_debounce;
    reg clk = 0, rst = 1, btn = 0;
    always #5 clk = ~clk;
    wire level, press;

    button_debounce #(.CNT_BITS(4)) dut (.clk(clk), .rst(rst), .btn(btn), .level(level), .press(press));

    integer errors = 0, presses = 0;
    reg     prev_press = 0, prev_level = 0;

    // count press pulses; each must be one clock wide and on a 0->1 of level
    always @(negedge clk) if (!rst) begin
        if (press) begin
            presses = presses + 1;
            if (prev_press) begin errors = errors + 1; $display("MISMATCH press wider than 1 clock"); end
            if (!(level && !prev_level)) begin errors = errors + 1; $display("MISMATCH press without level 0->1"); end
        end
        prev_press = press;
        prev_level = level;
    end

    task bounce;            // n quick toggles, each shorter than the debounce time
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                btn = ~btn;
                repeat (3 + (i % 5)) @(negedge clk);
            end
        end
    endtask

    task expect_state;
        input exp_level;
        input integer exp_presses;
        input [8*40-1:0] what;
        begin
            if (level !== exp_level || presses != exp_presses) begin
                errors = errors + 1;
                $display("MISMATCH %0s: level=%b presses=%0d (expected %b, %0d)",
                         what, level, presses, exp_level, exp_presses);
            end
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        if (level !== 0) begin errors = errors + 1; $display("MISMATCH reset level"); end
        rst = 0;
        repeat (20) @(negedge clk);

        // 1. short pulse (8 clocks < 16) is ignored
        btn = 1; repeat (8) @(negedge clk); btn = 0;
        repeat (40) @(negedge clk);
        expect_state(0, 0, "short pulse");

        // 2. bouncing press (7 toggles end high), then held a long time
        btn = 0; bounce(7);
        repeat (400) @(negedge clk);
        expect_state(1, 1, "bouncing press, long hold");

        // 3. bouncing release (7 toggles end low)
        bounce(7);
        repeat (60) @(negedge clk);
        expect_state(0, 1, "bouncing release");

        // 4. a second press gives exactly one more pulse
        btn = 1; repeat (100) @(negedge clk);
        expect_state(1, 2, "second press");
        btn = 0; repeat (60) @(negedge clk);
        expect_state(0, 2, "second release");

        // 5. reset clears level while the button is held
        btn = 1; repeat (60) @(negedge clk);
        rst = 1; @(negedge clk); rst = 0;
        if (level !== 0) begin errors = errors + 1; $display("MISMATCH rst did not clear level"); end
        btn = 0; repeat (60) @(negedge clk);

        if (errors == 0) $display("tb_button_debounce: PASS (%0d press pulses)", presses);
        else             $display("tb_button_debounce: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
