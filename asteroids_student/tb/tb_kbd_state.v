// tb_kbd_state - self-checking testbench (Task 10). Cases: the worked example
// of the Key-State Decoder section row by row (keys, ext, brk); E0 1D does not
// set W; the arrows without E0; seven keys held at once; valid low ignores code.
module tb_kbd_state;
    reg clk = 0, rst = 1, valid = 0;
    reg [7:0] code = 0;
    always #5 clk = ~clk;
    wire [9:0] keys;

    kbd_state dut (.clk(clk), .rst(rst), .code(code), .valid(valid), .keys(keys));

    integer errors = 0, row = 0;

    // send one byte with a one-clock valid, then check keys / ext / brk
    task byte_chk;
        input [7:0] b;
        input [9:0] exp_keys;
        input       exp_ext, exp_brk;
        begin
            @(negedge clk); code = b; valid = 1;
            @(negedge clk); valid = 0; code = 8'h00;
            row = row + 1;
            if (keys !== exp_keys || dut.ext !== exp_ext || dut.brk !== exp_brk) begin
                errors = errors + 1;
                $display("MISMATCH row %0d byte %h: keys=%b ext=%b brk=%b (expected %b %b %b)",
                         row, b, keys, dut.ext, dut.brk, exp_keys, exp_ext, exp_brk);
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 0;
        if (keys !== 0) begin errors = errors + 1; $display("MISMATCH after reset"); end

        // worked example from the handout
        byte_chk(8'h1D, 10'b00000_00001, 0, 0);   // W make
        byte_chk(8'hE0, 10'b00000_00001, 1, 0);   // prefix
        byte_chk(8'h75, 10'b00001_00001, 0, 0);   // Up make
        byte_chk(8'hF0, 10'b00001_00001, 0, 1);   // prefix
        byte_chk(8'h1D, 10'b00001_00000, 0, 0);   // W break
        byte_chk(8'hE0, 10'b00001_00000, 1, 0);
        byte_chk(8'hF0, 10'b00001_00000, 1, 1);   // ext stays 1
        byte_chk(8'h75, 10'b00000_00000, 0, 0);   // Up break
        byte_chk(8'h12, 10'b00000_00000, 0, 0);   // left Shift: ignored
        byte_chk(8'h1B, 10'b00000_00010, 0, 0);   // S make
        byte_chk(8'hAA, 10'b00000_00000, 0, 0);   // self-test: clear all

        // E0 1D is a different key and must not set W
        byte_chk(8'hE0, 10'b00000_00000, 1, 0);
        byte_chk(8'h1D, 10'b00000_00000, 0, 0);

        // arrows (keypad 8 2 4 6) without E0, then released
        byte_chk(8'h75, 10'b00001_00000, 0, 0);
        byte_chk(8'h72, 10'b00011_00000, 0, 0);
        byte_chk(8'h6B, 10'b00111_00000, 0, 0);
        byte_chk(8'h74, 10'b01111_00000, 0, 0);
        byte_chk(8'hF0, 10'b01111_00000, 0, 1);
        byte_chk(8'h75, 10'b01110_00000, 0, 0);
        byte_chk(8'hF0, 10'b01110_00000, 0, 1);
        byte_chk(8'h72, 10'b01100_00000, 0, 0);
        byte_chk(8'hF0, 10'b01100_00000, 0, 1);
        byte_chk(8'h6B, 10'b01000_00000, 0, 0);
        byte_chk(8'hF0, 10'b01000_00000, 0, 1);
        byte_chk(8'h74, 10'b00000_00000, 0, 0);

        // seven keys held at once: W S A D F, Up (E0 75), Enter
        byte_chk(8'h1D, 10'b00000_00001, 0, 0);
        byte_chk(8'h1B, 10'b00000_00011, 0, 0);
        byte_chk(8'h1C, 10'b00000_00111, 0, 0);
        byte_chk(8'h23, 10'b00000_01111, 0, 0);
        byte_chk(8'h2B, 10'b00000_11111, 0, 0);
        byte_chk(8'hE0, 10'b00000_11111, 1, 0);
        byte_chk(8'h75, 10'b00001_11111, 0, 0);
        byte_chk(8'h5A, 10'b10001_11111, 0, 0);
        byte_chk(8'h1D, 10'b10001_11111, 0, 0);   // typematic repeat: no change

        // valid low: code is ignored
        @(negedge clk); code = 8'hF0; repeat (3) @(negedge clk);
        code = 8'h1D; repeat (3) @(negedge clk);
        code = 8'hAA; repeat (3) @(negedge clk);
        code = 8'h00;
        if (keys !== 10'b10001_11111 || dut.ext !== 0 || dut.brk !== 0) begin
            errors = errors + 1;
            $display("MISMATCH valid low changed state: keys=%b", keys);
        end

        // keypad Enter (E0 5A) also acts as player 2 fire
        byte_chk(8'hE0, 10'b10001_11111, 1, 0);
        byte_chk(8'hF0, 10'b10001_11111, 1, 1);
        byte_chk(8'h5A, 10'b00001_11111, 0, 0);

        // reset clears everything
        @(negedge clk); rst = 1; @(negedge clk); rst = 0;
        if (keys !== 0) begin errors = errors + 1; $display("MISMATCH rst did not clear keys"); end

        if (errors == 0) $display("tb_kbd_state: PASS (%0d bytes)", row);
        else             $display("tb_kbd_state: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
