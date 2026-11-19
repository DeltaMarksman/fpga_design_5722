// game_loader.v - copies one game from the ROM into the runtime state.
//
// Started by a one-clock pulse on start with the slot number on game.
//   1. read the directory entry           -> header address
//   2. read the 10 header words           -> configuration registers
//   3. read 16 palette words              -> palette RAM in the renderer
//   4. read 3 words per object            -> object RAM (one 96-bit write)
//      slots n_obj..63 are written as 0   (disabled)
// then pulses done. If the slot is empty (valid bit 0) or the header magic is
// wrong, or the image is not format version 2, it pulses fail instead and
// changes nothing.
//
// ROM latency: each word takes two states. In the first the address is
// driven; the ROM samples it at the end of that clock. In the second the
// data word is on rom_q and is stored.
`include "ge_defs.vh"
`default_nettype none
module game_loader (
    input  wire               clk,
    input  wire               rst,
    input  wire               start,
    input  wire [1:0]         game,
    output reg                busy,
    output reg                done,
    output reg                fail,
    // ROM
    output reg  [10:0]        rom_addr,
    input  wire [31:0]        rom_q,
    // object RAM port A
    output reg                ram_we,
    output wire [5:0]         ram_addr,
    output wire [95:0]        ram_din,
    // palette
    output reg                pal_we,
    output wire [3:0]         pal_idx,
    output wire [11:0]        pal_rgb,
    // configuration registers
    output reg  [6:0]         n_obj,
    output reg  [5:0]         n_inp,
    output reg  [5:0]         n_rule,
    output reg  [10:0]        obj_base,
    output reg  [10:0]        inp_base,
    output reg  [10:0]        rule_base,
    output reg  signed [10:0] xmin,
    output reg  signed [10:0] xmax,
    output reg  signed [10:0] ymin,
    output reg  signed [10:0] ymax,
    output reg  [6:0]         win_score,
    output reg  [6:0]         init_score,
    output reg                lose_at_zero,
    output reg  [2:0]         spin_step,
    output reg  [4:0]         spin_max,
    output reg                hud_en,
    output reg  [9:0]         hud_p1_x,
    output reg  [9:0]         hud_p2_x,
    output reg  [8:0]         hud_y,
    output reg  [15:0]        collider_mask,
    output reg  [15:0]        controlled_mask,
    output reg  [3:0]         init_lives,
    output reg  [3:0]         mark_color,
    output reg  [15:0]        wave_watch,
    output reg  [15:0]        wave_reload
);
    localparam [3:0]
        L_IDLE  = 4'd0,
        L_DIR   = 4'd1,     // drive directory address
        L_DIRW  = 4'd2,     // directory word valid
        L_HDR   = 4'd3,     // drive header address
        L_HDRW  = 4'd4,     // header word valid
        L_PAL   = 4'd5,
        L_PALW  = 4'd6,
        L_OBJ   = 4'd7,
        L_OBJW  = 4'd8,
        L_OBJWR = 4'd9,
        L_FIN   = 4'd10;

    reg [3:0]  state;
    reg [1:0]  g;
    reg [10:0] hdr;         // address of H0
    reg [10:0] pal_base;
    reg [10:0] optr;        // running ROM address inside the object table
    reg [4:0]  k;           // word counter inside header / palette / object
    reg [6:0]  i;           // object slot
    reg [95:0] rec;

    assign ram_addr = i[5:0];
    assign ram_din  = rec;
    assign pal_idx  = k[3:0];
    assign pal_rgb  = rom_q[`PAL_RGB];

    // combinational outputs that depend on the state
    always @* begin
        rom_addr = 11'd0;
        ram_we   = 1'b0;
        pal_we   = 1'b0;
        case (state)
            L_DIR:   rom_addr = {9'd0, g};
            L_HDR:   rom_addr = hdr + {6'd0, k};
            L_PAL:   rom_addr = pal_base + {6'd0, k};
            L_PALW:  pal_we   = 1'b1;
            L_OBJ:   rom_addr = optr;
            L_OBJWR: ram_we   = 1'b1;
            default: ;
        endcase
    end

    always @(posedge clk) begin
        done <= 1'b0;
        fail <= 1'b0;
        if (rst) begin
            state <= L_IDLE;
            busy  <= 1'b0;
            g <= 2'd0; hdr <= 11'd0; pal_base <= 11'd0; optr <= 11'd0;
            k <= 5'd0; i <= 7'd0; rec <= 96'd0;
            n_obj <= 7'd0; n_inp <= 6'd0; n_rule <= 6'd0;
            obj_base <= 11'd0; inp_base <= 11'd0; rule_base <= 11'd0;
            xmin <= 11'sd0; xmax <= 11'sd0; ymin <= 11'sd0; ymax <= 11'sd0;
            win_score <= 7'd0; init_score <= 7'd0; lose_at_zero <= 1'b0;
            spin_step <= 3'd0; spin_max <= 5'd0;
            hud_en <= 1'b0; hud_p1_x <= 10'd0; hud_p2_x <= 10'd0; hud_y <= 9'd0;
            collider_mask <= 16'd0; controlled_mask <= 16'd0;
            init_lives <= 4'd0; mark_color <= 4'd0; wave_watch <= 16'd0; wave_reload <= 16'd0;
        end else begin
            case (state)
                L_IDLE: begin
                    if (start) begin
                        g     <= game;
                        busy  <= 1'b1;
                        state <= L_DIR;
                    end
                end

                L_DIR:  state <= L_DIRW;

                L_DIRW: begin
                    if (rom_q[`GDIR_VALID] && (rom_q[`GDIR_VERSION] == 8'd2)) begin
                        hdr   <= rom_q[`GDIR_HDR_ADDR];
                        k     <= 5'd0;
                        state <= L_HDR;
                    end else begin
                        fail  <= 1'b1;
                        busy  <= 1'b0;
                        state <= L_IDLE;
                    end
                end

                L_HDR:  state <= L_HDRW;

                L_HDRW: begin
                    k     <= k + 5'd1;
                    state <= L_HDR;
                    case (k[3:0])
                        4'd0: begin
                            if (rom_q[`H0_MAGIC] != `GE_MAGIC) begin
                                fail  <= 1'b1;      // nothing has been changed yet
                                busy  <= 1'b0;
                                state <= L_IDLE;
                            end else begin
                                // 7 bits are enough for 0..64; larger values are clamped
                                n_obj  <= (rom_q[22:16] > 7'd64) ? 7'd64 : rom_q[22:16];
                                n_inp  <= rom_q[13:8];
                                n_rule <= rom_q[5:0];
                            end
                        end
                        4'd1: begin
                            obj_base <= rom_q[`H1_OBJ_BASE];
                            inp_base <= rom_q[`H1_INP_BASE];
                            optr     <= rom_q[`H1_OBJ_BASE];
                        end
                        4'd2: begin
                            rule_base <= rom_q[`H2_RULE_BASE];
                            pal_base  <= rom_q[`H2_PAL_BASE];
                        end
                        4'd3: begin
                            xmin <= rom_q[`H3_XMIN];
                            xmax <= rom_q[`H3_XMAX];
                        end
                        4'd4: begin
                            ymin <= rom_q[`H4_YMIN];
                            ymax <= rom_q[`H4_YMAX];
                        end
                        4'd5: begin
                            win_score    <= rom_q[`H5_WIN_SCORE];
                            init_score   <= rom_q[`H5_INIT_SCORE];
                            lose_at_zero <= rom_q[`H5_LOSE_AT_ZERO];
                            spin_step    <= rom_q[`H5_SPIN_STEP];
                            spin_max     <= rom_q[`H5_SPIN_MAX];
                        end
                        4'd6: begin
                            hud_p1_x <= rom_q[`H6_HUD_P1_X];
                            hud_p2_x <= rom_q[`H6_HUD_P2_X];
                            hud_y    <= rom_q[`H6_HUD_Y];
                            hud_en   <= rom_q[`H6_HUD_EN];
                        end
                        4'd7: begin
                            collider_mask   <= rom_q[`H7_COLLIDER_MASK];
                            controlled_mask <= rom_q[`H7_CONTROLLED_MASK];
                        end
                        4'd8: begin
                            init_lives <= rom_q[`H8_INIT_LIVES];
                            mark_color <= rom_q[`H8_MARK_COLOR];
                            wave_watch <= rom_q[`H8_WAVE_WATCH];
                        end
                        default: begin
                            wave_reload <= rom_q[`H9_WAVE_RELOAD];
                            k     <= 5'd0;
                            state <= L_PAL;
                        end
                    endcase
                end

                L_PAL:  state <= L_PALW;

                L_PALW: begin
                    if (k == 5'd15) begin
                        k     <= 5'd0;
                        i     <= 7'd0;
                        state <= L_OBJ;
                    end else begin
                        k     <= k + 5'd1;
                        state <= L_PAL;
                    end
                end

                L_OBJ: begin
                    if (i == 7'd64) begin
                        state <= L_FIN;
                    end else if (i >= n_obj) begin
                        rec   <= 96'd0;             // unused slot: disabled
                        state <= L_OBJWR;
                    end else begin
                        state <= L_OBJW;
                    end
                end

                L_OBJW: begin
                    case (k[1:0])
                        2'd0:    rec[31:0]  <= rom_q;
                        2'd1:    rec[63:32] <= rom_q;
                        default: rec[95:64] <= rom_q;
                    endcase
                    optr <= optr + 11'd1;
                    if (k[1:0] == 2'd2) begin
                        k     <= 5'd0;
                        state <= L_OBJWR;
                    end else begin
                        k     <= k + 5'd1;
                        state <= L_OBJ;
                    end
                end

                L_OBJWR: begin
                    i     <= i + 7'd1;
                    state <= L_OBJ;
                end

                L_FIN: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= L_IDLE;
                end

                default: state <= L_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
