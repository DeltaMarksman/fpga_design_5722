// vga_render.v - turns the object RAM into pixels.
//
// Line slots: while the beam is in horizontal blanking, the renderer reads
// all 64 object records (one per clock) and copies the ones that cross the
// next scanline into at most N_SLOTS "line slots" {x start, x end, colour}.
// During the visible part of the line every slot is compared with the pixel
// counter in parallel; the slot filled last (highest object index) wins.
// 64 records take 67 clocks, horizontal blanking lasts 640 clocks.
//
// Pixel pipeline, three stages on pix_ce:
//   stage 1  slot hit flags, score-digit hit, border hit
//   stage 2  priority: game-over border > score digits > objects > background
//   stage 3  palette lookup, blanking forced to black
// hsync / vsync are delayed by the same three stages, so picture and sync
// stay aligned and RGB is exactly 0 outside the 640x480 window.
`include "ge_defs.vh"
`default_nettype none
module vga_render_orig #(
    parameter N_SLOTS = `GE_N_SLOTS      // 2..32 (the slot index is 5 bits)
) (
    input  wire        clk,
    input  wire        rst,
    // timing
    input  wire        pix_ce,
    input  wire [9:0]  hcount,
    input  wire [9:0]  vcount,
    input  wire        hsync_n_in,
    input  wire        vsync_n_in,
    input  wire        active_in,
    input  wire        scan_tick,
    input  wire [9:0]  scan_y,
    // object RAM port B
    output wire [5:0]  ob_addr,
    input  wire [95:0] ob_q,
    // palette load
    input  wire        pal_we,
    input  wire [3:0]  pal_idx,
    input  wire [11:0] pal_rgb,
    // overlays
    input  wire        hud_en,
    input  wire [9:0]  hud_p1_x,
    input  wire [9:0]  hud_p2_x,
    input  wire [8:0]  hud_y,
    input  wire [6:0]  score1,
    input  wire [6:0]  score2,
    input  wire [3:0]  lives1,
    input  wire [3:0]  lives2,
    input  wire [3:0]  init_lives,      // 0 = this game shows no lives
    input  wire [3:0]  mark_color,
    input  wire [1:0]  gstate,
    input  wire        clr_flags,
    // board pins
    output reg  [3:0]  vga_r,
    output reg  [3:0]  vga_g,
    output reg  [3:0]  vga_b,
    output reg         hsync_n,
    output reg         vsync_n,
    output reg         line_overflow    // sticky: more than N_SLOTS objects on a line
);
    // ---------------------------------------------------------- line slots
    reg [9:0] slot_xs  [0:N_SLOTS-1];
    reg [9:0] slot_xe  [0:N_SLOTS-1];
    reg [3:0] slot_col [0:N_SLOTS-1];

    reg        scanning;
    reg [5:0]  sc_i;        // record whose address is on the RAM this clock
    reg        sc_v1;       // ob_q holds the record addressed one clock ago
    reg        sc_v2;       // ob_r holds a record
    reg [95:0] ob_r;        // registered copy of the RAM output
    reg [5:0]  sc_cnt;      // slots filled so far
    reg [9:0]  sc_y;        // scanline being prepared

    assign ob_addr = sc_i;

    // Scan pipeline, one record per clock:
    //   clock n   : sc_i = k on the RAM address
    //   clock n+1 : ob_q = record k        -> copied to ob_r (no logic after the RAM)
    //   clock n+2 : ob_r = record k        -> tested, slot written at the clock edge
    wire signed [10:0] o_x   = ob_r[`OBJ_X];
    wire signed [10:0] o_y   = ob_r[`OBJ_Y];
    wire        [9:0]  o_w   = ob_r[`OBJ_W];
    wire        [9:0]  o_h   = ob_r[`OBJ_H];
    wire        [3:0]  o_col = ob_r[`OBJ_COLOR];
    wire               o_en  = ob_r[`OBJ_ENABLED];
    wire        [2:0]  o_dir = ob_r[`OBJ_DIR];
    wire               o_mrk = ob_r[`OBJ_MARK];

    wire signed [12:0] x0 = {{2{o_x[10]}}, o_x};
    wire signed [12:0] y0 = {{2{o_y[10]}}, o_y};
    wire signed [12:0] x1 = x0 + $signed({3'b000, o_w});
    wire signed [12:0] y1 = y0 + $signed({3'b000, o_h});
    wire signed [12:0] ly = {3'b000, sc_y};
    wire signed [12:0] xl = (x0 < 13'sd0)   ? 13'sd0   : x0;       // clip to the screen
    wire signed [12:0] xr = (x1 > 13'sd640) ? 13'sd640 : x1;
    // a shielded object blinks: hidden while bit 2 of its timer is set
    wire [7:0] o_tmr = ob_r[`OBJ_TIMER];
    wire [1:0] o_tmd = ob_r[`OBJ_TMODE];
    wire o_blink = (o_tmd == `TMODE_SHIELD) && o_tmr[2];
    wire o_hit = o_en && (o_col != 4'd0) && !o_blink && (ly >= y0) && (ly < y1) && (xr > xl);

    // facing marker: a 4 x 4 square inside the object on the side it faces
    wire hx_p = (o_dir == `HD_E)  || (o_dir == `HD_NE) || (o_dir == `HD_SE);
    wire hx_n = (o_dir == `HD_NW) || (o_dir == `HD_W)  || (o_dir == `HD_SW);
    wire hy_n = (o_dir == `HD_NE) || (o_dir == `HD_N)  || (o_dir == `HD_NW);
    wire hy_p = (o_dir == `HD_SW) || (o_dir == `HD_S)  || (o_dir == `HD_SE);
    wire signed [12:0] mx = hx_p ? x1 - 13'sd4 : hx_n ? x0 : x0 + (($signed({3'b000, o_w}) - 13'sd4) >>> 1);
    wire signed [12:0] my = hy_n ? y0 : hy_p ? y1 - 13'sd4 : y0 + (($signed({3'b000, o_h}) - 13'sd4) >>> 1);
    wire signed [12:0] mx1 = mx + 13'sd4;
    wire signed [12:0] ml = (mx < 13'sd0)    ? 13'sd0   : mx;
    wire signed [12:0] mr = (mx1 > 13'sd640) ? 13'sd640 : mx1;
    wire m_hit = o_hit && o_mrk && (ly >= my) && (ly < my + 13'sd4) && (mr > ml);

    integer s;
    always @(posedge clk) begin
        if (rst) begin
            scanning <= 1'b0; sc_i <= 6'd0; sc_v1 <= 1'b0; sc_v2 <= 1'b0; ob_r <= 96'd0;
            sc_cnt <= 6'd0; sc_y <= 10'd0;
            line_overflow <= 1'b0;
            for (s = 0; s < N_SLOTS; s = s + 1) begin
                slot_xs[s] <= 10'd0; slot_xe[s] <= 10'd0; slot_col[s] <= 4'd0;
            end
        end else begin
            sc_v1 <= scanning;
            sc_v2 <= sc_v1;
            ob_r  <= ob_q;
            if (clr_flags)
                line_overflow <= 1'b0;
            if (scan_tick) begin
                scanning <= 1'b1;
                sc_i     <= 6'd0;
                sc_cnt   <= 6'd0;
                sc_y     <= scan_y;
                for (s = 0; s < N_SLOTS; s = s + 1) begin
                    slot_xs[s] <= 10'd0;            // empty: start = end
                    slot_xe[s] <= 10'd0;
                end
            end else begin
                if (scanning) begin
                    sc_i <= sc_i + 6'd1;
                    if (sc_i == 6'd63)
                        scanning <= 1'b0;
                end
                if (sc_v2 && o_hit) begin
                    if (sc_cnt < N_SLOTS) begin
                        slot_xs[sc_cnt[4:0]]  <= xl[9:0];
                        slot_xe[sc_cnt[4:0]]  <= xr[9:0];
                        slot_col[sc_cnt[4:0]] <= o_col;
                        if (m_hit && (sc_cnt + 6'd1 < N_SLOTS)) begin
                            slot_xs[sc_cnt[4:0] + 5'd1]  <= ml[9:0];    // marker: next slot,
                            slot_xe[sc_cnt[4:0] + 5'd1]  <= mr[9:0];    // so it is on top
                            slot_col[sc_cnt[4:0] + 5'd1] <= mark_color;
                            sc_cnt <= sc_cnt + 6'd2;
                        end else begin
                            sc_cnt <= sc_cnt + 6'd1;
                            if (m_hit) line_overflow <= 1'b1;
                        end
                    end else
                        line_overflow <= 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------- palette
    reg [11:0] pal [0:`GE_N_PAL-1];
    integer p;
    initial for (p = 0; p < `GE_N_PAL; p = p + 1) pal[p] = 12'h000;
    always @(posedge clk)
        if (pal_we) pal[pal_idx] <= pal_rgb;

    // -------------------------------------------------------- score digits
    // binary -> BCD (Task 8): scores change only in vertical blanking and
    // a conversion takes 15 clocks, so the digits are settled long before
    // the first visible line.
    wire [3:0] s1_tens, s1_ones, s2_tens, s2_ones;
    binary2bcd u_bcd1 (.clk(clk), .rst(rst), .start(1'b1), .in(score1),
                       .bcd1(s1_tens), .bcd0(s1_ones), .done(), .count(), .state());
    binary2bcd u_bcd2 (.clk(clk), .rst(rst), .start(1'b1), .in(score2),
                       .bcd1(s2_tens), .bcd0(s2_ones), .done(), .count(), .state());

    wire hud_on, hud_p2, hud_dig, hud_dig_p2;
    hud_digits u_hud (
        .hcount(hcount), .vcount(vcount), .en(hud_en),
        .p1_x(hud_p1_x), .p2_x(hud_p2_x), .y(hud_y),
        .d0(s1_tens), .d1(s1_ones),
        .d2(s2_tens), .d3(s2_ones),
        .on(hud_dig), .p2(hud_dig_p2)
    );

    wire pip_on, pip_p2;
    hud_pips u_pips (
        .hcount(hcount), .vcount(vcount), .en(hud_en && (init_lives != 4'd0)),
        .p1_x(hud_p1_x), .p2_x(hud_p2_x), .y(hud_y), .lives1(lives1), .lives2(lives2),
        .on(pip_on), .p2(pip_p2)
    );
    assign hud_on = hud_dig | pip_on;
    assign hud_p2 = pip_on ? pip_p2 : hud_dig_p2;

    // ------------------------------------------------------ pixel pipeline
    wire in_border = (hcount < 10'd8) || (hcount >= 10'd632) ||
                     (vcount < 10'd8) || (vcount >= 10'd472);

    reg [N_SLOTS-1:0] hit1;
    reg hud1, hud_p2_1, border1, right1, act1, hs1, vs1;
    reg [3:0] idx2;
    reg act2, hs2, vs2;

    reg [3:0] obj_idx;
    integer q;
    always @* begin
        obj_idx = 4'd0;
        for (q = 0; q < N_SLOTS; q = q + 1)
            if (hit1[q]) obj_idx = slot_col[q];     // last filled slot wins
    end

    wire [11:0] rgb = pal[idx2];
    integer t;

    always @(posedge clk) begin
        if (rst) begin
            hit1 <= {N_SLOTS{1'b0}};
            hud1 <= 1'b0; hud_p2_1 <= 1'b0; border1 <= 1'b0; right1 <= 1'b0;
            act1 <= 1'b0; hs1 <= 1'b1; vs1 <= 1'b1;
            idx2 <= 4'd0; act2 <= 1'b0; hs2 <= 1'b1; vs2 <= 1'b1;
            vga_r <= 4'd0; vga_g <= 4'd0; vga_b <= 4'd0; hsync_n <= 1'b1; vsync_n <= 1'b1;
        end else if (pix_ce) begin
            // stage 1
            for (t = 0; t < N_SLOTS; t = t + 1)
                hit1[t] <= (hcount >= slot_xs[t]) && (hcount < slot_xe[t]);
            hud1     <= hud_on;
            hud_p2_1 <= hud_p2;
            border1  <= in_border;
            right1   <= (hcount >= 10'd320);
            act1     <= active_in;
            hs1      <= hsync_n_in;
            vs1      <= vsync_n_in;
            // stage 2
            if ((gstate != `GS_PLAYING) && border1)
                idx2 <= (gstate == `GS_P1_WON) ? 4'd1 :
                        (gstate == `GS_P2_WON) ? 4'd2 :
                        right1 ? 4'd2 : 4'd1;       // draw: half and half
            else if (hud1)
                idx2 <= hud_p2_1 ? 4'd2 : 4'd1;
            else
                idx2 <= obj_idx;
            act2 <= act1;
            hs2  <= hs1;
            vs2  <= vs1;
            // stage 3
            vga_r   <= act2 ? rgb[11:8] : 4'd0;
            vga_g   <= act2 ? rgb[7:4]  : 4'd0;
            vga_b   <= act2 ? rgb[3:0]  : 4'd0;
            hsync_n <= hs2;
            vsync_n <= vs2;
        end
    end
endmodule
