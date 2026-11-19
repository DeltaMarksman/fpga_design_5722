// top_basys3.v - Digilent Basys3 top level of the BRAM game engine.
//
//   btnU / btnR / btnD / btnL : load game 0 / 1 / 2 / 3
//   btnC                      : restart the current game
//   PS/2 keyboard (USB HID port): W A S D + F, arrow keys + Enter
//   VGA 640x480 @ 60 Hz, 12-bit colour
//   seven-segment display     : P1 score . P2 score
//   sw[0] = 1 (keyboard debug): the display shows the last two PS/2 bytes in
//             hex (left = older, right = newest); the rightmost decimal point
//             lights once a bad PS/2 frame has been seen. sw[1] = 1 clears
//             the held-key bits (unsticks keys whose release was lost).
//   sw[15] = 1 (board controls, no keyboard needed):
//             player 1: btnU/btnD/btnL/btnR move, btnC fires
//             player 2: sw[13] left, sw[12] up, sw[11] down, sw[10] right
//                       (held while the switch is up), each flip of sw[14]
//                       up fires once
//             the buttons do not select games in this mode; the keyboard
//             still works alongside.
//   led[9:0]  held keys (bit = logical button id, see kbd_state.v)
//   led[11:10] loaded game slot
//   led[12]   player 1 has won      led[13] player 2 has won (both = draw)
//   led[14]   sticky: a scanline had more objects than the renderer has slots
//   led[15]   sticky: update overran vertical blanking, or a load was rejected
//
// There is no reset button: the registers start in a known state from the
// bitstream and a short power-on reset counter then releases the design,
// which loads game 0 by itself.
`default_nettype none
module top_basys3 #(
    parameter MEM_FILE         = "games.mem",
    parameter DEBOUNCE_BITS    = 20,
    parameter PS2_FILTER_BITS  = 7,
    parameter PS2_TIMEOUT_BITS = 18
) (
    input  wire        clk,         // 100 MHz
    input  wire        btnC,
    input  wire        btnU,
    input  wire        btnL,
    input  wire        btnR,
    input  wire        btnD,
    input  wire        PS2Clk,
    input  wire        PS2Data,
    input  wire [15:0] sw,
    output wire [3:0]  vgaRed,
    output wire [3:0]  vgaGreen,
    output wire [3:0]  vgaBlue,
    output wire        Hsync,
    output wire        Vsync,
    output wire [6:0]  seg,
    output wire        dp,
    output wire [3:0]  an,
    output wire [15:0] led
);
    // power-on reset: 16 clocks
    reg [3:0] por_cnt = 4'd0;
    reg       rst     = 1'b1;
    always @(posedge clk) begin
        if (por_cnt != 4'hF)
            por_cnt <= por_cnt + 4'd1;
        else
            rst <= 1'b0;
    end

    // ---------------------------------------------------------- push buttons
    // switches are slow manual inputs: two-flop synchronisers suffice
    reg [15:0] sw_m, sw_s;
    always @(posedge clk) begin
        sw_m <= sw;
        sw_s <= sw_m;
    end
    wire board_mode = sw_s[15];

    wire bp_u, bp_r, bp_d, bp_l, bp_c;          // one-shot presses
    wire bl_u, bl_r, bl_d, bl_l, bl_c;          // debounced levels
    button_debounce #(.CNT_BITS(DEBOUNCE_BITS)) u_bu (.clk(clk), .rst(rst), .btn(btnU), .level(bl_u), .press(bp_u));
    button_debounce #(.CNT_BITS(DEBOUNCE_BITS)) u_br (.clk(clk), .rst(rst), .btn(btnR), .level(bl_r), .press(bp_r));
    button_debounce #(.CNT_BITS(DEBOUNCE_BITS)) u_bd (.clk(clk), .rst(rst), .btn(btnD), .level(bl_d), .press(bp_d));
    button_debounce #(.CNT_BITS(DEBOUNCE_BITS)) u_bl (.clk(clk), .rst(rst), .btn(btnL), .level(bl_l), .press(bp_l));
    button_debounce #(.CNT_BITS(DEBOUNCE_BITS)) u_bc (.clk(clk), .rst(rst), .btn(btnC), .level(bl_c), .press(bp_c));
    // in board-control mode the buttons belong to player 1, not to game select
    wire press_u = bp_u & ~board_mode;
    wire press_r = bp_r & ~board_mode;
    wire press_d = bp_d & ~board_mode;
    wire press_l = bp_l & ~board_mode;
    wire press_c = bp_c & ~board_mode;

    wire       load_req, load_ack;
    wire [1:0] load_game, game_id;
    game_select u_select (
        .clk(clk), .rst(rst),
        .press_u(press_u), .press_r(press_r), .press_d(press_d), .press_l(press_l),
        .press_c(press_c), .cur_game(game_id), .load_ack(load_ack),
        .load_req(load_req), .load_game(load_game)
    );

    // -------------------------------------------------------------- keyboard
    wire [7:0] ps2_code;
    wire       ps2_valid, ps2_err;
    wire [9:0] kbd_keys, keys;
    ps2_rx #(.FILTER_BITS(PS2_FILTER_BITS), .TIMEOUT_BITS(PS2_TIMEOUT_BITS)) u_ps2 (
        .clk(clk), .rst(rst), .ps2_clk(PS2Clk), .ps2_data(PS2Data),
        .code(ps2_code), .valid(ps2_valid), .frame_err(ps2_err)
    );
    kbd_state u_kbd (.clk(clk), .rst(rst | sw_s[1]), .code(ps2_code), .valid(ps2_valid), .keys(kbd_keys));

    // board controls, same bit order as kbd_state:
    //   P1 up, down, left, right, fire, P2 up, down, left, right, fire
    wire [9:0] board_keys = {sw_s[14], sw_s[10], sw_s[13], sw_s[11], sw_s[12],
                             bl_c, bl_r, bl_l, bl_d, bl_u};
    assign keys = kbd_keys | (board_mode ? board_keys : 10'd0);

    // keyboard debug: history of received bytes, sticky frame error
    reg [15:0] ps2_hist;
    reg        ps2_err_seen;
    always @(posedge clk) begin
        if (rst) begin
            ps2_hist     <= 16'd0;
            ps2_err_seen <= 1'b0;
        end else begin
            if (ps2_valid) ps2_hist <= {ps2_hist[7:0], ps2_code};
            if (ps2_err)   ps2_err_seen <= 1'b1;
        end
    end

    // ------------------------------------------------------------- game core
    wire [6:0] score1, score2;
    wire [1:0] gstate;
    wire       loaded, overrun, load_err, line_overflow;
    game_core #(.MEM_FILE(MEM_FILE)) u_core (
        .clk(clk), .rst(rst), .keys(keys),
        .load_req(load_req), .load_game(load_game), .load_ack(load_ack),
        .vga_r(vgaRed), .vga_g(vgaGreen), .vga_b(vgaBlue),
        .hsync_n(Hsync), .vsync_n(Vsync),
        .score1(score1), .score2(score2), .gstate(gstate), .game_id(game_id),
        .loaded(loaded), .overrun(overrun), .load_err(load_err),
        .line_overflow(line_overflow)
    );

    // ------------------------------------------------------- board displays
    sevenseg u_seg (.clk(clk), .rst(rst), .score1(score1), .score2(score2),
                    .hex_mode(sw_s[0]), .hex_val(ps2_hist), .hex_dp(ps2_err_seen),
                    .seg(seg), .dp(dp), .an(an));

    assign led[9:0]   = keys;
    assign led[11:10] = game_id;
    assign led[13:12] = gstate;
    assign led[14]    = line_overflow;
    assign led[15]    = overrun | load_err;
endmodule
`default_nettype wire
