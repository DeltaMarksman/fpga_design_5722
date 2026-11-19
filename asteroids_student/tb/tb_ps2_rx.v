// tb_ps2_rx - self-checking testbench (Task 10). PS/2 clock and data are
// driven with real timing (12.5 kHz, 80 us per bit). Cases: several codes;
// a frame with a wrong parity bit (frame_err, no valid); a clock that stops
// in the middle of a frame (time-out frame_err, then the next frame is
// received correctly).
module tb_ps2_rx;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg ps2_clk = 1, ps2_data = 1;
    wire [7:0] code;
    wire valid, frame_err;

    ps2_rx dut (.clk(clk), .rst(rst), .ps2_clk(ps2_clk), .ps2_data(ps2_data),
                .code(code), .valid(valid), .frame_err(frame_err));

    integer errors = 0, n_valid = 0, n_err = 0, v0, e0;
    reg [7:0] last_code = 0;

    always @(negedge clk) begin
        if (valid)     begin n_valid = n_valid + 1; last_code = code; end
        if (frame_err) n_err = n_err + 1;
    end

    // one bit: data set while the clock is high, sampled at the falling edge
    task send_bit;
        input b;
        begin
            ps2_data = b;
            #20000;  ps2_clk = 0;
            #40000;  ps2_clk = 1;
            #20000;
        end
    endtask

    // send the first nbits bits of a frame (11 = a full frame)
    task send_frame;
        input [7:0] data;
        input       bad_parity;
        input integer nbits;
        reg [10:0] f;
        integer i;
        begin
            f = {1'b1, (~^data) ^ bad_parity, data, 1'b0};  // stop, odd parity, data, start
            for (i = 0; i < nbits; i = i + 1) send_bit(f[i]);
            ps2_data = 1;
            #100000;                                        // gap between frames
        end
    endtask

    task expect_rx;
        input [7:0] data;
        begin
            v0 = n_valid; e0 = n_err;
            send_frame(data, 1'b0, 11);
            if (n_valid != v0 + 1 || n_err != e0 || last_code !== data) begin
                errors = errors + 1;
                $display("MISMATCH frame %h: valid +%0d err +%0d code %h", data,
                         n_valid - v0, n_err - e0, last_code);
            end else
                $display("received %h", data);
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        #50000;

        // several codes
        expect_rx(8'h1D);       // W
        expect_rx(8'hF0);       // break prefix
        expect_rx(8'hE0);       // extended prefix
        expect_rx(8'h75);       // up arrow
        expect_rx(8'h5A);       // enter
        expect_rx(8'hAA);       // self-test passed
        expect_rx(8'h00);
        expect_rx(8'hFF);

        // wrong parity: frame_err, no valid
        v0 = n_valid; e0 = n_err;
        send_frame(8'h1B, 1'b1, 11);
        if (n_valid != v0 || n_err != e0 + 1) begin
            errors = errors + 1;
            $display("MISMATCH bad parity: valid +%0d err +%0d", n_valid - v0, n_err - e0);
        end else $display("bad parity frame rejected");

        // clock stops after 5 bits: time-out after 2**18 clocks (2.6 ms)
        v0 = n_valid; e0 = n_err;
        send_frame(8'h23, 1'b0, 5);
        #3000000;
        if (n_valid != v0 || n_err != e0 + 1) begin
            errors = errors + 1;
            $display("MISMATCH time-out: valid +%0d err +%0d", n_valid - v0, n_err - e0);
        end else $display("time-out frame_err seen");

        // the next frame is received correctly
        expect_rx(8'h2B);

        if (errors == 0) $display("tb_ps2_rx: PASS");
        else             $display("tb_ps2_rx: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
