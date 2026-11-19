// vga_timing.v - 640x480 @ 60 Hz timing generator.
//
// The whole design runs on the 100 MHz board clock. Pixels advance on pix_ce,
// a clock enable that is high one clock in four (25.000 MHz pixel rate; the
// VESA value is 25.175 MHz, 0.7 % faster - monitors accept it).
//
//   horizontal: 640 visible, 16 front porch, 96 sync, 48 back porch = 800
//   vertical  : 480 visible, 10 front porch,  2 sync, 33 back porch = 525
//   both sync pulses are active low
//
// hsync_n / vsync_n / active are aligned with hcount / vcount. The renderer
// delays them by its own pipeline depth, so they are not the board outputs.
//
// Two strobes tell the rest of the design where it is in the frame:
//   frame_tick : first clock of vertical blanking (line 480, pixel 0).
//                Game state may only change after this strobe.
//   scan_tick  : start of horizontal blanking on every line whose successor
//                is visible (lines 524 and 0..478). The renderer reads the
//                object RAM for line scan_y starting at this strobe.
//
// *** TASK 1: complete this module (see the project handout, "Your VGA
//     Module"). Do not change the port list: hcount and vcount must stay
//     'output reg' - the grading testbenches look at them by name.
`default_nettype none
module vga_timing #(
    parameter H_ACTIVE = 640,
    parameter H_FP     = 16,
    parameter H_SYNC   = 96,
    parameter H_BP     = 48,
    parameter V_ACTIVE = 480,
    parameter V_FP     = 10,
    parameter V_SYNC   = 2,
    parameter V_BP     = 33
) (
    input  wire       clk,
    input  wire       rst,          // synchronous, active high
    output wire       pix_ce,       // one clock in four
    output reg  [9:0] hcount,       // 0..799, advances on pix_ce
    output reg  [9:0] vcount,       // 0..524, advances at the end of each line
    output wire       hsync_n,      // active low
    output wire       vsync_n,      // active low
    output wire       active,       // (hcount, vcount) is inside 640 x 480
    output wire       frame_tick,   // one clock: line 480, pixel 0, on pix_ce
    output wire       scan_tick,    // one clock: pixel 640 of lines 524, 0..478, on pix_ce
    output wire [9:0] scan_y        // the line the renderer must prepare next
);
    localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;     // 800
    localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;     // 525

    reg [1:0] div;                  // divide-by-4 counter for pix_ce

    // ---------------------------------------------------------------------
    // TASK 1 - insert your timing generator here:
    //   1. the divide-by-4 counter 'div' and pix_ce
    //   2. the hcount / vcount registers (synchronous reset to 0)
    //   3. hsync_n, vsync_n and active
    //   4. frame_tick, scan_tick and scan_y
    // Adapted from the lab VGA module (same phase counter / 800x525 counters),
    // moved to the fixed interface and parameterised.
    // ---------------------------------------------------------------------
    localparam HS_START = H_ACTIVE + H_FP;              // 656
    localparam HS_END   = H_ACTIVE + H_FP + H_SYNC;     // 752
    localparam VS_START = V_ACTIVE + V_FP;              // 490
    localparam VS_END   = V_ACTIVE + V_FP + V_SYNC;     // 492

    // 1. divide-by-4 clock enable
    always @(posedge clk) begin
        if (rst) div <= 2'd0;
        else     div <= div + 2'd1;
    end
    assign pix_ce = (div == 2'd3);

    // 2. pixel / line counters, advancing only on pix_ce
    always @(posedge clk) begin
        if (rst) begin
            hcount <= 10'd0;
            vcount <= 10'd0;
        end else if (pix_ce) begin
            if (hcount == H_TOTAL - 1) begin
                hcount <= 10'd0;
                if (vcount == V_TOTAL - 1) vcount <= 10'd0;
                else                       vcount <= vcount + 10'd1;
            end else begin
                hcount <= hcount + 10'd1;
            end
        end
    end

    // 3. syncs and active region (combinational from the counters)
    assign hsync_n = ~((hcount >= HS_START) && (hcount < HS_END));
    assign vsync_n = ~((vcount >= VS_START) && (vcount < VS_END));
    assign active  =  (hcount < H_ACTIVE) && (vcount < V_ACTIVE);

    // 4. strobes for the game logic and the renderer
    assign frame_tick = pix_ce && (hcount == 10'd0) && (vcount == V_ACTIVE);
    assign scan_tick  = pix_ce && (hcount == H_ACTIVE) &&
                        ((vcount == V_TOTAL - 1) || (vcount < V_ACTIVE - 1));
    assign scan_y     = (vcount == V_TOTAL - 1) ? 10'd0 : vcount + 10'd1;
    // ------------------------------------------------------ END TASK 1 ----
endmodule
`default_nettype wire
