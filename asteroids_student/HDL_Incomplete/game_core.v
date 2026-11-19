// game_core.v - the complete game machine without board-specific I/O:
// VGA timing, game logic and renderer. Inputs are already-clean signals
// (logical key vector, load request), so testbenches can drive it directly.
`include "ge_defs.vh"
`default_nettype none
module game_core #(
    parameter MEM_FILE = "games.mem"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [9:0]  keys,
    input  wire        load_req,
    input  wire [1:0]  load_game,
    output wire        load_ack,
    output wire [3:0]  vga_r,
    output wire [3:0]  vga_g,
    output wire [3:0]  vga_b,
    output wire        hsync_n,
    output wire        vsync_n,
    output wire [6:0]  score1,
    output wire [6:0]  score2,
    output wire [1:0]  gstate,
    output wire [1:0]  game_id,
    output wire        loaded,
    output wire        overrun,
    output wire        load_err,
    output wire        line_overflow
);
    wire        pix_ce, hs_raw, vs_raw, active, frame_tick, scan_tick;
    wire [9:0]  hcount, vcount, scan_y;

    vga_timing u_timing (
        .clk(clk), .rst(rst), .pix_ce(pix_ce), .hcount(hcount), .vcount(vcount),
        .hsync_n(hs_raw), .vsync_n(vs_raw), .active(active),
        .frame_tick(frame_tick), .scan_tick(scan_tick), .scan_y(scan_y)
    );

    wire [5:0]  ob_addr;
    wire [95:0] ob_q;
    wire        pal_we;
    wire [3:0]  pal_idx;
    wire [11:0] pal_rgb;
    wire        hud_en;
    wire [9:0]  hud_p1_x, hud_p2_x;
    wire [8:0]  hud_y;
    wire        busy, load_done, update_done;
    wire [3:0]  lives1, lives2, init_lives, mark_color;

    game_logic #(.MEM_FILE(MEM_FILE)) u_logic (
        .clk(clk), .rst(rst), .frame_tick(frame_tick), .scan_tick(scan_tick),
        .load_req(load_req), .load_game(load_game), .load_ack(load_ack),
        .keys(keys),
        .ob_addr(ob_addr), .ob_q(ob_q),
        .pal_we(pal_we), .pal_idx(pal_idx), .pal_rgb(pal_rgb),
        .hud_en(hud_en), .hud_p1_x(hud_p1_x), .hud_p2_x(hud_p2_x), .hud_y(hud_y),
        .score1(score1), .score2(score2), .lives1(lives1), .lives2(lives2),
        .init_lives(init_lives), .mark_color(mark_color), .gstate(gstate),
        .game_id(game_id), .loaded(loaded), .busy(busy),
        .load_done(load_done), .update_done(update_done),
        .overrun(overrun), .load_err(load_err)
    );

    vga_render u_render (
        .clk(clk), .rst(rst), .pix_ce(pix_ce), .hcount(hcount), .vcount(vcount),
        .hsync_n_in(hs_raw), .vsync_n_in(vs_raw), .active_in(active),
        .scan_tick(scan_tick), .scan_y(scan_y),
        .ob_addr(ob_addr), .ob_q(ob_q),
        .pal_we(pal_we), .pal_idx(pal_idx), .pal_rgb(pal_rgb),
        .hud_en(hud_en), .hud_p1_x(hud_p1_x), .hud_p2_x(hud_p2_x), .hud_y(hud_y),
        .score1(score1), .score2(score2), .lives1(lives1), .lives2(lives2),
        .init_lives(init_lives), .mark_color(mark_color),
        .gstate(gstate), .clr_flags(load_done),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
        .hsync_n(hsync_n), .vsync_n(vsync_n), .line_overflow(line_overflow)
    );
endmodule
`default_nettype wire
