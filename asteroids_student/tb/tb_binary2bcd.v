// tb_binary2bcd - self-checking testbench (Task 10). Cases: every input from
// 0 to 99; continuous mode (start held high, as in the design): the outputs
// change only on a done clock and never show an intermediate value; each
// conversion finishes within 64 clocks; done is one clock wide.
module tb_binary2bcd;
    reg clk = 0, rst = 1, start = 0;
    reg [6:0] in = 0, prev_in = 0;
    always #5 clk = ~clk;
    wire [3:0] bcd1, bcd0;
    wire       done;
    wire [2:0] count;
    wire [1:0] state;

    binary2bcd dut (.clk(clk), .rst(rst), .start(start), .in(in),
                    .bcd1(bcd1), .bcd0(bcd0), .done(done), .count(count), .state(state));

    integer errors = 0, v, val, since_done = 0, max_gap = 0;
    reg [3:0] last1 = 0, last0 = 0;
    reg       last_done = 0;

    // continuous checks on every clock
    always @(negedge clk) if (!rst) begin
        since_done = since_done + 1;
        if ((bcd1 !== last1 || bcd0 !== last0) && !done) begin
            errors = errors + 1;
            $display("MISMATCH outputs changed without done: %0d%0d", bcd1, bcd0);
        end
        if (done) begin
            if (last_done) begin errors = errors + 1; $display("MISMATCH done wider than 1 clock"); end
            val = bcd1 * 10 + bcd0;
            if (bcd1 > 9 || bcd0 > 9 || (val != in && val != prev_in)) begin
                errors = errors + 1;
                $display("MISMATCH intermediate value shown: %0d%0d (in=%0d)", bcd1, bcd0, in);
            end
            if (start && since_done > max_gap) max_gap = since_done;
            since_done = 0;
        end
        last1 = bcd1; last0 = bcd0; last_done = done;
    end

    initial begin
        repeat (3) @(negedge clk);
        if (bcd1 !== 0 || bcd0 !== 0) begin errors = errors + 1; $display("MISMATCH reset"); end
        rst = 0;
        start = 1;                              // continuous mode, as in sevenseg / vga_render
        for (v = 0; v < 100; v = v + 1) begin
            @(negedge clk);
            prev_in = in;
            in = v;
            @(posedge done); @(posedge done);   // the second conversion surely used v
            @(negedge clk);
            if (bcd1 != v / 10 || bcd0 != v % 10) begin
                errors = errors + 1;
                $display("MISMATCH %0d -> %0d %0d", v, bcd1, bcd0);
            end
        end
        if (max_gap > 64) begin
            errors = errors + 1;
            $display("MISMATCH a conversion took %0d clocks (> 64)", max_gap);
        end

        // a single conversion with a start pulse; with start low the outputs hold
        start = 0; repeat (30) @(negedge clk);
        prev_in = 7'd73; in = 7'd73; start = 1; @(negedge clk); start = 0;
        @(posedge done); @(negedge clk);
        if (bcd1 != 7 || bcd0 != 3) begin errors = errors + 1; $display("MISMATCH 73 with start pulse"); end
        in = 7'd5; prev_in = 7'd5; repeat (100) @(negedge clk);
        if (bcd1 != 7 || bcd0 != 3) begin errors = errors + 1; $display("MISMATCH outputs moved with start low"); end

        $display("longest gap between done pulses: %0d clocks", max_gap);
        if (errors == 0) $display("tb_binary2bcd: PASS (0..99)");
        else             $display("tb_binary2bcd: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
