`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: keyboard_vga_display
// Description:
//   PS/2 keyboard -> VGA character display (640x480 @ 60 Hz, 100 MHz input clock).
//
//     - Number keys 0-9 (top row or keypad) show that digit in the upper-left corner
//     - Enter (Return)                      clears the screen to blank
//     - Any other key                       shows the character "E"
//     - btnC                                resets the decoder and clears the screen
//     - led[15:0]                           0-9 for a digit key, FFFF for any other
//                                           key, 0000 after Enter / reset
//
//   Port and instance names match vga_key.xdc (Hsync, Vsync, vgaRed/Green/Blue,
//   led, u_key, rst_meta).
//
//   Built from the supplied ps2_interface.v (PS/2 frame receiver) and
//   vga_color_changer.v (VGA timing generator). The font is read from a Xilinx
//   Block Memory Generator ROM named blk_mem_gen_0 loaded with font.coe:
//     Memory Type          : Single Port ROM
//     Port A width / depth : 8 / 128   (address width 7)
//     Enable Port Type     : Always Enabled   (no ena pin)
//     Primitive Output Reg : unchecked        (read latency = 1 clk)
//     Load Init File       : font.coe
//   If you check "Primitive Output Register", set BRAM_LATENCY to 2.
//   Each font pixel is drawn as an 8x8 block, so the character is 64x64 pixels.
//////////////////////////////////////////////////////////////////////////////////

module top(
        input   wire        clk,        // 100 MHz
        input   wire        btnC,
        input   wire        PS2Clk,
        input   wire        PS2Data,
        output  wire        Hsync,
        output  wire        Vsync,
        output  reg  [15:0] led,
        output  wire [3:0]  vgaRed,
        output  wire [3:0]  vgaGreen,
        output  wire [3:0]  vgaBlue
    );

    // Character colour (change freely) - currently green
    localparam [3:0] FG_R = 4'h0;
    localparam [3:0] FG_G = 4'hF;
    localparam [3:0] FG_B = 4'h0;

    // Read latency of the block ROM in clk cycles (1 = no output register, 2 = with)
    localparam BRAM_LATENCY = 1;

    // Glyph numbers in the font ROM
    localparam [3:0] GLYPH_E = 4'd10;


    // ------------------------------------------------------------------
    // btnC synchroniser (reset)
    // ------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg rst_meta;
    (* ASYNC_REG = "TRUE" *) reg rst_sync;

    always @(posedge clk) begin
        rst_meta <= btnC;
        rst_sync <= rst_meta;
    end


    // ------------------------------------------------------------------
    // PS/2 receiver
    // ------------------------------------------------------------------
    wire [7:0] scan_code;
    wire       scan_valid;

    ps2_rx u_key (
        .clk        (clk),
        .rst        (rst_sync),
        .PS2Clk     (PS2Clk),
        .PS2Data    (PS2Data),
        .scan_code  (scan_code),
        .scan_valid (scan_valid)
    );


    // ------------------------------------------------------------------
    // Key decoding
    //   A key press sends its make code; a release sends F0 followed by the
    //   same code, and extended keys are prefixed with E0. Releases are
    //   ignored so each press is acted on exactly once, and E0-prefixed
    //   keys (arrows, Insert, ...) are not mistaken for keypad digits.
    // ------------------------------------------------------------------
    reg is_digit;
    reg [3:0] digit_val;

    always @(*) begin
        is_digit  = 1'b1;
        digit_val = 4'd0;
        case (scan_code)
            // Top row
            8'h45: digit_val = 4'd0;
            8'h16: digit_val = 4'd1;
            8'h1E: digit_val = 4'd2;
            8'h26: digit_val = 4'd3;
            8'h25: digit_val = 4'd4;
            8'h2E: digit_val = 4'd5;
            8'h36: digit_val = 4'd6;
            8'h3D: digit_val = 4'd7;
            8'h3E: digit_val = 4'd8;
            8'h46: digit_val = 4'd9;
            // Keypad (Num Lock on)
            8'h70: digit_val = 4'd0;
            8'h69: digit_val = 4'd1;
            8'h72: digit_val = 4'd2;
            8'h7A: digit_val = 4'd3;
            8'h6B: digit_val = 4'd4;
            8'h73: digit_val = 4'd5;
            8'h74: digit_val = 4'd6;
            8'h6C: digit_val = 4'd7;
            8'h75: digit_val = 4'd8;
            8'h7D: digit_val = 4'd9;
            default: is_digit = 1'b0;
        endcase
    end

    reg       show          = 1'b0;     // 0 = blank screen
    reg [3:0] glyph         = 4'd0;     // which font glyph to display
    reg       break_pending = 1'b0;     // saw F0, next code is a key release
    reg       extended      = 1'b0;     // saw E0, next code is an extended key

    always @(posedge clk) begin
        if (rst_sync) begin
            show          <= 1'b0;
            glyph         <= 4'd0;
            break_pending <= 1'b0;
            extended      <= 1'b0;
            led           <= 16'h0000;
        end else if (scan_valid) begin
            case (scan_code)
                8'hF0: break_pending <= 1'b1;
                8'hE0: extended      <= 1'b1;
                8'hAA,                          // keyboard self-test passed
                8'hFA: ;                        // ACK - not key presses
                default: begin
                    break_pending <= 1'b0;
                    extended      <= 1'b0;
                    if (!break_pending) begin   // key press only
                        if (scan_code == 8'h5A) begin       // Enter / keypad Enter
                            show <= 1'b0;
                            led  <= 16'h0000;
                        end else if (is_digit && !extended) begin
                            glyph <= digit_val;
                            show  <= 1'b1;
                            led   <= {12'h000, digit_val};
                        end else begin                      // any other key
                            glyph <= GLYPH_E;
                            show  <= 1'b1;
                            led   <= 16'hFFFF;
                        end
                    end
                end
            endcase
        end
    end


    // ------------------------------------------------------------------
    // VGA timing (from vga_color_changer.v)
    // ------------------------------------------------------------------
    reg [9:0] horizontal_pixel = 0;
    reg [9:0] vertical_pixel   = 0;
    reg [1:0] pixel_div        = 0;
    wire pixel_tick = (pixel_div == 3);
    wire visible;

    always @(posedge clk) begin : vga_driver
        // Run on every 4th tick (100 MHz / 4 = 25 MHz pixel clock)
        pixel_div <= pixel_div + 1;
        if (pixel_tick) begin
            // End of horizontal
            if (horizontal_pixel == 799) begin

                // Reset horizontal
                horizontal_pixel <= 0;

                if (vertical_pixel == 524) begin
                    // Reset vertical
                    vertical_pixel <= 0;
                end else begin
                    vertical_pixel <= vertical_pixel + 1;
                end
            end else begin
                horizontal_pixel <= horizontal_pixel + 1;
            end
        end
    end

    wire hsync_raw = ~((horizontal_pixel > 656) && (horizontal_pixel < 752));
    wire vsync_raw = ~((vertical_pixel > 490) && (vertical_pixel < 492));

    assign visible = (horizontal_pixel < 640) && (vertical_pixel < 480);


    // ------------------------------------------------------------------
    // Font ROM (Block Memory Generator IP, loaded with font.coe)
    //   Address = {glyph, font_row}; data = 8 pixels of that row, MSB = leftmost.
    //   8x8 font scaled 8x -> 64x64 box in the upper-left corner.
    // ------------------------------------------------------------------
    wire [2:0]  font_col  = horizontal_pixel[5:3];          // which font column (0 = leftmost)
    wire [2:0]  font_row  = vertical_pixel[5:3];            // which font row
    wire [6:0]  font_addr = {glyph, font_row};
    wire [7:0]  font_bits;

    blk_mem_gen_0 font_rom (
        .clka   (clk),
        .addra  (font_addr),
        .douta  (font_bits)
    );


    // ------------------------------------------------------------------
    // The ROM output arrives BRAM_LATENCY clocks after the address, so every
    // other signal used to build the pixel is delayed by the same amount.
    // ------------------------------------------------------------------
    wire        in_char_box = (horizontal_pixel < 64) && (vertical_pixel < 64);

    // {font_col[2:0], in_char_box, show, visible, hsync, vsync}
    wire [7:0]  pipe_in = {font_col, in_char_box, show, visible, hsync_raw, vsync_raw};
    reg  [7:0]  pipe [0:BRAM_LATENCY-1];
    integer     k;

    always @(posedge clk) begin
        pipe[0] <= pipe_in;
        for (k = 1; k < BRAM_LATENCY; k = k + 1)
            pipe[k] <= pipe[k-1];
    end

    wire [7:0]  pipe_out      = pipe[BRAM_LATENCY-1];
    wire [2:0]  font_col_d    = pipe_out[7:5];
    wire        in_char_box_d = pipe_out[4];
    wire        show_d        = pipe_out[3];
    wire        visible_d     = pipe_out[2];
    wire        hsync_d       = pipe_out[1];
    wire        vsync_d       = pipe_out[0];

    wire font_pixel = font_bits[3'd7 - font_col_d];         // MSB is the leftmost pixel
    wire pixel_on   = show_d & in_char_box_d & font_pixel & visible_d;

    assign Hsync    = hsync_d;
    assign Vsync    = vsync_d;
    assign vgaRed   = pixel_on ? FG_R : 4'b0000;
    assign vgaGreen = pixel_on ? FG_G : 4'b0000;
    assign vgaBlue  = pixel_on ? FG_B : 4'b0000;

endmodule


//////////////////////////////////////////////////////////////////////////////////
// ps2_rx - PS/2 frame receiver (from ps2_interface.v)
//   Synchronises PS2Clk/PS2Data, shifts in the 11-bit frame on each falling PS2Clk
//   edge, and pulses scan_valid for one clk when a frame passes the start, odd-parity
//   and stop-bit checks.
//////////////////////////////////////////////////////////////////////////////////
module ps2_rx(
        input   wire        clk,
        input   wire        rst,
        input   wire        PS2Clk,
        input   wire        PS2Data,
        output  reg  [7:0]  scan_code,
        output  reg         scan_valid
    );

    (* ASYNC_REG = "TRUE" *) reg [1:0] ps2clk_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ps2data_sync;
    wire ps2clk_s  = ps2clk_sync[1];
    wire ps2data_s = ps2data_sync[1];

    reg  ps2clk_prev;
    wire ps2_falling_edge = ps2clk_prev && !ps2clk_s;

    always @(posedge clk) begin
        ps2clk_sync  <= {ps2clk_sync[0], PS2Clk};
        ps2data_sync <= {ps2data_sync[0], PS2Data};
    end

    always @(posedge clk) begin
        ps2clk_prev <= ps2clk_s;
    end

    reg [3:0]   bit_count  = 4'd0;
    reg         parity_bit = 1'b0;

    initial begin
        scan_code  = 8'd0;
        scan_valid = 1'b0;
    end

    always @(posedge clk) begin
        scan_valid <= 1'b0;

        if (rst) begin
            bit_count  <= 4'd0;
            scan_code  <= 8'd0;
            parity_bit <= 1'b0;
        end else begin
            if (ps2_falling_edge) begin
                case (bit_count)
                    4'd0: begin
                        if (ps2data_s == 1'b0)          // start bit
                            bit_count <= 4'd1;
                    end
                    4'd1: begin
                        scan_code[0] <= ps2data_s;
                        bit_count <= 4'd2;
                    end
                    4'd2: begin
                        scan_code[1] <= ps2data_s;
                        bit_count <= 4'd3;
                    end
                    4'd3: begin
                        scan_code[2] <= ps2data_s;
                        bit_count <= 4'd4;
                    end
                    4'd4: begin
                        scan_code[3] <= ps2data_s;
                        bit_count <= 4'd5;
                    end
                    4'd5: begin
                        scan_code[4] <= ps2data_s;
                        bit_count <= 4'd6;
                    end
                    4'd6: begin
                        scan_code[5] <= ps2data_s;
                        bit_count <= 4'd7;
                    end
                    4'd7: begin
                        scan_code[6] <= ps2data_s;
                        bit_count <= 4'd8;
                    end
                    4'd8: begin
                        scan_code[7] <= ps2data_s;
                        bit_count <= 4'd9;
                    end
                    4'd9: begin
                        parity_bit <= ps2data_s;
                        bit_count <= 4'd10;
                    end
                    4'd10: begin                        // stop bit + odd-parity check
                        bit_count <= 4'd0;
                        if (ps2data_s && ((^scan_code) ^ parity_bit))
                            scan_valid <= 1'b1;
                    end
                    default: bit_count <= 4'd0;
                endcase
            end
        end
    end
endmodule