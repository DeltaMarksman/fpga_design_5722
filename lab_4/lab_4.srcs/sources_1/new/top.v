`timescale 1ns / 1ps


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

        localparam [3:0] FG_R = 4'h0;
    localparam [3:0] FG_G = 4'hF;
    localparam [3:0] FG_B = 4'h0;

     localparam BRAM_LATENCY = 1;


    localparam [3:0] GLYPH_E = 4'd10;



    (* ASYNC_REG = "TRUE" *) reg rst_meta;
    (* ASYNC_REG = "TRUE" *) reg rst_sync;

    always @(posedge clk) begin
        rst_meta <= btnC;
        rst_sync <= rst_meta;
    end




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

    reg       show          = 1'b0;     
    reg [3:0] glyph         = 4'd0;    
    reg       break_pending = 1'b0;    
    reg       extended      = 1'b0;   

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
                8'hAA,                         
                8'hFA: ;                        
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



    wire [2:0]  font_col  = horizontal_pixel[5:3];          // which font column (0 = leftmost)
    wire [2:0]  font_row  = vertical_pixel[5:3];            // which font row
    wire [6:0]  font_addr = {glyph, font_row};
    wire [7:0]  font_bits;

    blk_mem_gen_0 font_rom (
        .clka   (clk),
        .addra  (font_addr),
        .douta  (font_bits)
    );



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
                    4'd10: begin                      
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