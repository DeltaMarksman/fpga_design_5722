// game_logic.v - everything that decides what the game state is:
// the game ROM, the object RAM, the loader, the engine and the small
// frame controller that starts one of them at each frame boundary.
//
// Frame boundary rule: runtime state changes only between frame_tick (first
// clock of vertical blanking) and the next scan_tick (the renderer starts
// reading the object RAM for line 0 during line 524).
//
//   at frame_tick:  load requested      -> run the loader (no update this frame)
//                   else round running  -> run one engine update
//                   else                -> nothing (picture frozen)
//
// The same ROM read port and object-RAM port A are used by the loader and by
// the engine; they never run at the same time, so a plain mux is enough.
`include "ge_defs.vh"
`default_nettype none
module game_logic #(
    parameter MEM_FILE = "games.mem"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_tick,
    input  wire        scan_tick,       // only used to detect an update overrun
    // game selection
    input  wire        load_req,        // level: a load is pending
    input  wire [1:0]  load_game,
    output reg         load_ack,        // one clock: the pending request was taken
    // player input
    input  wire [9:0]  keys,
    // renderer side
    input  wire [5:0]  ob_addr,         // object RAM port B
    output wire [95:0] ob_q,
    output wire        pal_we,
    output wire [3:0]  pal_idx,
    output wire [11:0] pal_rgb,
    output wire        hud_en,
    output wire [9:0]  hud_p1_x,
    output wire [9:0]  hud_p2_x,
    output wire [8:0]  hud_y,
    output wire [6:0]  score1,
    output wire [6:0]  score2,
    output wire [3:0]  lives1,
    output wire [3:0]  lives2,
    output wire [3:0]  init_lives,
    output wire [3:0]  mark_color,
    output wire [1:0]  gstate,
    // status
    output reg  [1:0]  game_id,         // slot of the loaded game
    output reg         loaded,          // a game has been loaded since reset
    output wire        busy,            // loader or engine is working
    output wire        load_done,       // one clock: load finished
    output wire        update_done,     // one clock: engine update finished
    output reg         overrun,         // sticky: work was not finished in time
    output reg         load_err         // sticky: last load request was rejected
);
    // ----------------------------------------------------------------- ROM
    wire [10:0] ld_rom_addr, en_rom_addr;
    wire [31:0] rom_q;
    wire        ld_busy, en_busy;
    wire [10:0] rom_addr = ld_busy ? ld_rom_addr : en_rom_addr;

    game_rom #(.AW(11), .MEM_FILE(MEM_FILE)) u_rom (
        .clk(clk), .addr(rom_addr), .dout(rom_q)
    );

    // ---------------------------------------------------------- object RAM
    wire        ld_ram_we, en_ram_we;
    wire [5:0]  ld_ram_addr, en_ram_addr;
    wire [95:0] ld_ram_din, en_ram_din;
    wire [95:0] ram_q;

    obj_ram #(.AW(6), .DW(96)) u_obj_ram (
        .clk(clk),
        .a_we  (ld_busy ? ld_ram_we   : en_ram_we),
        .a_addr(ld_busy ? ld_ram_addr : en_ram_addr),
        .a_din (ld_busy ? ld_ram_din  : en_ram_din),
        .a_dout(ram_q),
        .b_addr(ob_addr),
        .b_dout(ob_q)
    );

    // -------------------------------------------------------------- loader
    reg         ld_start;
    reg  [1:0]  ld_game;
    wire        ld_done, ld_fail;
    wire [6:0]  n_obj;
    wire [5:0]  n_inp, n_rule;
    wire [10:0] obj_base, inp_base, rule_base;
    wire signed [10:0] xmin, xmax, ymin, ymax;
    wire [6:0]  win_score, init_score;
    wire        lose_at_zero;
    wire [2:0]  spin_step;
    wire [4:0]  spin_max;
    wire [15:0] collider_mask, controlled_mask;
    wire [15:0] wave_watch, wave_reload;

    game_loader u_loader (
        .clk(clk), .rst(rst), .start(ld_start), .game(ld_game),
        .busy(ld_busy), .done(ld_done), .fail(ld_fail),
        .rom_addr(ld_rom_addr), .rom_q(rom_q),
        .ram_we(ld_ram_we), .ram_addr(ld_ram_addr), .ram_din(ld_ram_din),
        .pal_we(pal_we), .pal_idx(pal_idx), .pal_rgb(pal_rgb),
        .n_obj(n_obj), .n_inp(n_inp), .n_rule(n_rule),
        .obj_base(obj_base), .inp_base(inp_base), .rule_base(rule_base),
        .xmin(xmin), .xmax(xmax), .ymin(ymin), .ymax(ymax),
        .win_score(win_score), .init_score(init_score), .lose_at_zero(lose_at_zero),
        .spin_step(spin_step), .spin_max(spin_max),
        .hud_en(hud_en), .hud_p1_x(hud_p1_x), .hud_p2_x(hud_p2_x), .hud_y(hud_y),
        .collider_mask(collider_mask), .controlled_mask(controlled_mask),
        .init_lives(init_lives), .mark_color(mark_color),
        .wave_watch(wave_watch), .wave_reload(wave_reload)
    );

    // -------------------------------------------------------------- engine
    reg en_start;
    game_engine u_engine (
        .clk(clk), .rst(rst), .start(en_start), .load_done(ld_done), .keys(keys),
        .n_obj(n_obj), .n_inp(n_inp), .n_rule(n_rule),
        .obj_base(obj_base), .inp_base(inp_base), .rule_base(rule_base),
        .xmin(xmin), .xmax(xmax), .ymin(ymin), .ymax(ymax),
        .win_score(win_score), .init_score(init_score), .lose_at_zero(lose_at_zero),
        .spin_step(spin_step), .spin_max(spin_max),
        .collider_mask(collider_mask), .controlled_mask(controlled_mask),
        .init_lives(init_lives), .wave_watch(wave_watch), .wave_reload(wave_reload),
        .rom_addr(en_rom_addr), .rom_q(rom_q),
        .ram_we(en_ram_we), .ram_addr(en_ram_addr), .ram_din(en_ram_din), .ram_q(ram_q),
        .busy(en_busy), .done(update_done),
        .score1(score1), .score2(score2), .lives1(lives1), .lives2(lives2), .gstate(gstate)
    );

    // ld_done is included so that 'loaded' and the scores have settled before
    // the controller may start anything else
    assign busy      = ld_busy | en_busy | ld_start | en_start | ld_done;
    assign load_done = ld_done;

    // ---------------------------------------------------- frame controller
    always @(posedge clk) begin
        ld_start <= 1'b0;
        en_start <= 1'b0;
        load_ack <= 1'b0;
        if (rst) begin
            ld_game  <= 2'd0;
            game_id  <= 2'd0;
            loaded   <= 1'b0;
            overrun  <= 1'b0;
            load_err <= 1'b0;
        end else begin
            if (frame_tick) begin
                if (busy) begin
                    overrun <= 1'b1;                // previous work still running
                end else if (load_req) begin
                    ld_start <= 1'b1;
                    ld_game  <= load_game;
                    load_ack <= 1'b1;
                    load_err <= 1'b0;
                    overrun  <= 1'b0;
                end else if (loaded && (gstate == `GS_PLAYING)) begin
                    en_start <= 1'b1;
                end
            end
            if (scan_tick && busy)
                overrun <= 1'b1;                    // renderer needs the RAM now
            if (ld_done) begin
                loaded  <= 1'b1;
                game_id <= ld_game;
            end
            if (ld_fail)
                load_err <= 1'b1;
        end
    end
endmodule
`default_nettype wire
