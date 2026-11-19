// game_engine.v - the shared game engine: one frame update per start pulse.
//
// This is a fixed sequencer, not a processor. It has no program counter, no
// instruction set and no branches chosen by data other than "does this record
// match". Every frame it performs the same three passes over the tables of
// whatever game is loaded:
//
//   pass 1  PREP     for every object: count its timer and cooldown down, expire LIFETIME
//                    objects, zero the velocity of "controlled" classes
//   pass 2  INPUT    for every input-mapping record whose key condition holds:
//                    apply MOVE or SPAWN to every matching object
//   pass 3  MOVE     for every object in index order: add velocity, handle the
//                    arena edges (EDGE event), then test it against every
//                    other object (COLLIDE events). Each event scans the rule
//                    table; every matching rule drives the fixed action
//                    datapath (motion response, ownership, score, fates).
//   wave             (if enabled) when no object of a watched class is left,
//                    reload every object of the wave classes from the ROM
//   end              evaluate the win / lose / draw conditions
//
// Memory timing (both memories have one clock of read latency):
//   state X_ADDR drives the address      -> memory samples it at the clock edge
//   state X_LOAD sees the data on *_q    -> it is copied into a register
//   later states work on the register only
//
// Working registers: a_rec is the record of the object being processed
// ("self"), b_rec the other object or the spawned object.
`include "ge_defs.vh"
`default_nettype none
module game_engine (
    input  wire               clk,
    input  wire               rst,
    input  wire               start,        // one clock: run one update
    input  wire               load_done,    // one clock: a game was just loaded
    input  wire [9:0]         keys,         // logical buttons, bit = button id
    // configuration of the loaded game (stable while busy)
    input  wire [6:0]         n_obj,
    input  wire [5:0]         n_inp,
    input  wire [5:0]         n_rule,
    input  wire [10:0]        obj_base,
    input  wire [10:0]        inp_base,
    input  wire [10:0]        rule_base,
    input  wire signed [10:0] xmin,
    input  wire signed [10:0] xmax,
    input  wire signed [10:0] ymin,
    input  wire signed [10:0] ymax,
    input  wire [6:0]         win_score,
    input  wire [6:0]         init_score,
    input  wire               lose_at_zero,
    input  wire [2:0]         spin_step,
    input  wire [4:0]         spin_max,
    input  wire [15:0]        collider_mask,
    input  wire [15:0]        controlled_mask,
    input  wire [3:0]         init_lives,
    input  wire [15:0]        wave_watch,
    input  wire [15:0]        wave_reload,
    // game ROM
    output reg  [10:0]        rom_addr,
    input  wire [31:0]        rom_q,
    // object RAM port A
    output reg                ram_we,
    output reg  [5:0]         ram_addr,
    output reg  [95:0]        ram_din,
    input  wire [95:0]        ram_q,
    // status
    output reg                busy,
    output reg                done,         // one clock at the end of an update
    output reg  [6:0]         score1,
    output reg  [6:0]         score2,
    output reg  [3:0]         lives1,
    output reg  [3:0]         lives2,
    output reg  [1:0]         gstate        // 0 playing, 1 P1 won, 2 P2 won, 3 draw
);
    // ------------------------------------------------------------------ states
    localparam [5:0]
        S_IDLE     = 6'd0,
        // pass 1
        S_P1_ADDR  = 6'd1,
        S_P1_LOAD  = 6'd2,
        S_P1_EXEC  = 6'd3,
        S_P1_WR    = 6'd4,
        // pass 2
        S_IN_ADDR  = 6'd5,
        S_IN_LOAD  = 6'd6,
        S_IN_CHK   = 6'd7,
        S_IT_ADDR  = 6'd8,
        S_IT_LOAD  = 6'd9,
        S_IT_EXEC  = 6'd10,
        S_IT_WR    = 6'd11,
        S_SP_ADDR  = 6'd12,
        S_SP_LOAD  = 6'd13,
        S_SP_CHK   = 6'd14,
        S_SP_PLACE = 6'd15,
        S_SP_WRB   = 6'd16,
        // pass 3
        S_MV_ADDR  = 6'd17,
        S_MV_LOAD  = 6'd18,
        S_MV_CHK   = 6'd19,
        S_MV_ADD   = 6'd20,
        S_MV_EDGE  = 6'd21,
        S_MV_POST  = 6'd22,
        S_CO_ADDR  = 6'd23,
        S_CO_LOAD  = 6'd24,
        S_CO_PEN   = 6'd25,
        S_CO_CHK   = 6'd26,
        S_CO_POST  = 6'd27,
        S_A_WR     = 6'd28,
        // rule scan (shared by EDGE and COLLIDE events)
        S_RS_ADDR  = 6'd29,
        S_RS_W0    = 6'd30,
        S_RS_W1    = 6'd31,
        S_RS_CHK   = 6'd32,
        S_RS_ACT1  = 6'd33,
        S_RS_ACT2  = 6'd34,
        S_RS_SELF  = 6'd35,
        S_RS_OTHER = 6'd36,
        S_RS_NEXT  = 6'd37,
        // reload one object record from the ROM (RESPAWN and SPAWN)
        S_RL_0     = 6'd38,
        S_RL_1     = 6'd39,
        S_RL_2     = 6'd40,
        S_RL_3     = 6'd41,
        S_END      = 6'd42,
        // MOVE with set_facing: point the heading along the velocity
        S_IT_FACE  = 6'd43,
        // SPLIT: write the parent back, then place up to two fragments
        S_SPL_WB   = 6'd44,
        S_SPL_ADDR = 6'd45,
        S_SPL_LOAD = 6'd46,
        S_SPL_CHK  = 6'd47,
        S_SPL_PLACE= 6'd48,
        S_SPL_WR   = 6'd49,
        S_SPL_NEXT = 6'd50,
        // wave: is any watched object left? if not, reload the wave classes
        S_WV_ADDR  = 6'd51,
        S_WV_LOAD  = 6'd52,
        S_WV_CHK   = 6'd53,
        S_WR_ADDR  = 6'd54,
        S_WR_LOAD  = 6'd55,
        S_WR_CHK   = 6'd56,
        S_WR_WR    = 6'd57;

    reg [5:0]  state;
    reg [5:0]  rs_ret;      // where the rule scan returns to
    reg [5:0]  rl_ret;      // where the record reload returns to

    reg [6:0]  i;           // index of self
    reg [6:0]  j;           // index of other / pool slot
    reg [5:0]  m;           // input-mapping index
    reg [5:0]  r;           // rule index

    reg [95:0] a_rec;
    reg [95:0] b_rec;
    reg [31:0] m_rec;       // current input-mapping word
    reg [31:0] r0;          // current rule, word 0 (match)
    reg [31:0] r1;          // current rule, word 1 (actions)

    reg [9:0]  btn_now;     // keys sampled at the start of this update
    reg [9:0]  btn_edge;    // keys that went down since the previous update
    reg [9:0]  btn_prev;

    reg        evt_col;     // current event: 1 COLLIDE, 0 EDGE
    reg [3:0]  evt_edges;
    reg        evt_axis_x;
    reg        evt_low;
    reg        a_gone;      // self was disabled or respawned: stop using it
    reg        b_dirty;     // other was changed and must be written back
    reg        rs_stop;     // stop scanning rules for the current event
    reg        rl_to_a;     // reload target: 1 a_rec, 0 b_rec
    reg [10:0] rl_ptr;      // ROM address of the record being reloaded

    // SPLIT: the parent, remembered while its fragments are placed
    reg [6:0]  k;           // fragment pool search index
    reg        spl_n;       // fragment 0 or 1
    reg [3:0]  spl_cls;     // class of the fragments
    reg signed [10:0] p_x, p_y;
    reg        [9:0]  p_w, p_h;
    reg signed [5:0]  p_vx, p_vy;
    reg        [1:0]  p_owner;

    // ------------------------------------------------------------ field views
    wire signed [10:0] a_x     = a_rec[`OBJ_X];
    wire signed [10:0] a_y     = a_rec[`OBJ_Y];
    wire        [9:0]  a_w     = a_rec[`OBJ_W];
    wire        [9:0]  a_h     = a_rec[`OBJ_H];
    wire signed [5:0]  a_vx    = a_rec[`OBJ_VX];
    wire signed [5:0]  a_vy    = a_rec[`OBJ_VY];
    wire        [3:0]  a_class = a_rec[`OBJ_CLASS];
    wire        [1:0]  a_owner = a_rec[`OBJ_OWNER];
    wire               a_en    = a_rec[`OBJ_ENABLED];
    wire        [1:0]  a_bmode = a_rec[`OBJ_BMODE];
    wire        [1:0]  a_tmode = a_rec[`OBJ_TMODE];
    wire        [2:0]  a_dir   = a_rec[`OBJ_DIR];
    wire        [3:0]  a_hp    = a_rec[`OBJ_HP];
    wire        [7:0]  a_timer = a_rec[`OBJ_TIMER];
    wire        [4:0]  a_cool  = a_rec[`OBJ_COOL];

    wire signed [10:0] b_x     = b_rec[`OBJ_X];
    wire signed [10:0] b_y     = b_rec[`OBJ_Y];
    wire        [9:0]  b_w     = b_rec[`OBJ_W];
    wire        [9:0]  b_h     = b_rec[`OBJ_H];
    wire signed [5:0]  b_vx    = b_rec[`OBJ_VX];
    wire signed [5:0]  b_vy    = b_rec[`OBJ_VY];
    wire        [3:0]  b_color = b_rec[`OBJ_COLOR];
    wire        [3:0]  b_class = b_rec[`OBJ_CLASS];
    wire        [1:0]  b_owner = b_rec[`OBJ_OWNER];
    wire               b_en    = b_rec[`OBJ_ENABLED];
    wire        [3:0]  b_hp    = b_rec[`OBJ_HP];

    wire [3:0] m_op    = m_rec[`INP_OP];
    wire [3:0] m_btn   = m_rec[`INP_BUTTON];
    wire [1:0] m_trig  = m_rec[`INP_TRIGGER];
    wire [1:0] m_owner = m_rec[`INP_OWNER];
    wire [3:0] m_class = m_rec[`INP_CLASS];
    wire [1:0] m_dir   = m_rec[`MOVE_DIR];
    wire       m_face  = m_rec[`MOVE_SET_FACING];
    wire [5:0] m_speed = m_rec[`MOVE_SPEED];
    wire [3:0] m_pool  = m_rec[`SPAWN_POOL];
    wire [7:0] m_cd    = m_rec[`SPAWN_COOLDOWN];

    wire [1:0] r_motion = r1[`R1_MOTION];
    wire [2:0] r_sfate  = r1[`R1_SELF_FATE];
    wire [2:0] r_ofate  = r1[`R1_OTHER_FATE];

    // ------------------------------------------------- pass 2: key condition
    wire btn_ok = (m_btn < 4'd10);
    wire m_trigd = btn_ok && ((m_trig == `TRIG_HELD)    ? btn_now[m_btn]  :
                              (m_trig == `TRIG_PRESSED) ? btn_edge[m_btn] : 1'b0);
    wire m_op_ok = (m_op == `OP_MOVE) || (m_op == `OP_SPAWN);
    wire m_match = a_en && (a_class == m_class) &&
                   ((m_owner == `OWNER_NONE) || (a_owner == m_owner));

    // ------------------------------------------------------ pass 3: datapath
    wire a_frozen   = (a_tmode == `TMODE_FREEZE) && (a_timer != 8'd0);
    wire a_shielded = (a_tmode == `TMODE_SHIELD) && (a_timer != 8'd0);
    wire a_moving   = (a_vx != 6'sd0) || (a_vy != 6'sd0);
    wire a_collider = collider_mask[a_class];

    wire signed [10:0] bnd_x, bnd_y;
    wire signed [5:0]  bnd_vx, bnd_vy;
    wire               bnd_en;
    wire        [3:0]  bnd_edges;
    ge_boundary u_boundary (
        .x(a_x), .y(a_y), .w(a_w), .h(a_h), .vx(a_vx), .vy(a_vy), .bmode(a_bmode),
        .xmin(xmin), .xmax(xmax), .ymin(ymin), .ymax(ymax),
        .nx(bnd_x), .ny(bnd_y), .nvx(bnd_vx), .nvy(bnd_vy), .nen(bnd_en), .edges(bnd_edges)
    );

    wire col_overlap, col_axis_x, col_low;
    ge_collide u_collide (
        .clk(clk),
        .ax(a_x), .ay(a_y), .aw(a_w), .ah(a_h),
        .bx(b_x), .by(b_y), .bw(b_w), .bh(b_h),
        .overlap(col_overlap), .axis_x(col_axis_x), .low(col_low)
    );

    wire signed [10:0] rsp_x, rsp_y;
    wire signed [5:0]  rsp_vx, rsp_vy;
    ge_response u_response (
        .ax(a_x), .ay(a_y), .aw(a_w), .ah(a_h), .avx(a_vx), .avy(a_vy),
        .bx(b_x), .by(b_y), .bw(b_w), .bh(b_h), .bvx(b_vx), .bvy(b_vy),
        .axis_x(evt_axis_x), .low(evt_low),
        .bounce(r_motion == `MOTION_BOUNCE), .spin(r1[`R1_SPIN]),
        .spin_step(spin_step), .spin_max(spin_max),
        .nx(rsp_x), .ny(rsp_y), .nvx(rsp_vx), .nvy(rsp_vy)
    );

    wire signed [10:0] spw_x, spw_y;
    wire signed [5:0]  spw_vx, spw_vy;
    ge_spawn u_spawn (
        .ax(a_x), .ay(a_y), .aw(a_w), .ah(a_h), .adir(a_dir),
        .tw(b_w), .th(b_h), .speed(b_vx),
        .nx(spw_x), .ny(spw_y), .nvx(spw_vx), .nvy(spw_vy)
    );

    wire signed [10:0] spl_x, spl_y;
    wire signed [5:0]  spl_vx, spl_vy;
    ge_split u_split (
        .px(p_x), .py(p_y), .pw(p_w), .ph(p_h), .pvx(p_vx), .pvy(p_vy),
        .fw(b_w), .fh(b_h), .which(spl_n),
        .nx(spl_x), .ny(spl_y), .nvx(spl_vx), .nvy(spl_vy)
    );

    // heading of a's (non-zero) velocity, from the signs of its components
    wire h_xp = !a_vx[5] && (a_vx != 6'sd0);
    wire h_xn =  a_vx[5];
    wire h_yp = !a_vy[5] && (a_vy != 6'sd0);
    wire h_yn =  a_vy[5];
    wire [2:0] a_heading = (h_xp && h_yn) ? `HD_NE : (h_xn && h_yn) ? `HD_NW :
                           (h_xn && h_yp) ? `HD_SW : (h_xp && h_yp) ? `HD_SE :
                           h_xp ? `HD_E : h_xn ? `HD_W : h_yn ? `HD_N : `HD_S;

    // ----------------------------------------------------------- rule match
    wire rel_ok = (r0[`R0_OWNER_REL] == `REL_ANY) ||
                  ((r0[`R0_OWNER_REL] == `REL_SAME)      && (a_owner == b_owner)) ||
                  ((r0[`R0_OWNER_REL] == `REL_DIFFERENT) && (a_owner != b_owner));
    wire r_match = (r0[`R0_SELF] == a_class) &&
                   (evt_col ? ((r0[`R0_EVENT] == `EVT_COLLIDE) &&
                               (r0[`R0_OTHER] == b_class) && rel_ok)
                            : ((r0[`R0_EVENT] == `EVT_EDGE) &&
                               ((r0[`R0_OTHER] & evt_edges) != 4'd0)));

    // which player's score a rule changes
    function [1:0] opponent;
        input [1:0] o;
        opponent = (o == `OWNER_P1) ? `OWNER_P2 : (o == `OWNER_P2) ? `OWNER_P1 : `OWNER_NONE;
    endfunction

    reg [1:0] sel_player;
    always @* begin
        case (r1[`R1_SCORE_SEL])
            `SEL_SELF_OWNER:     sel_player = a_owner;
            `SEL_OTHER_OWNER:    sel_player = evt_col ? b_owner : `OWNER_NONE;
            `SEL_SELF_OPPONENT:  sel_player = opponent(a_owner);
            `SEL_OTHER_OPPONENT: sel_player = evt_col ? opponent(b_owner) : `OWNER_NONE;
            `SEL_P1:             sel_player = `OWNER_P1;
            `SEL_P2:             sel_player = `OWNER_P2;
            default:             sel_player = `OWNER_NONE;
        endcase
    end

    // score + signed delta, saturating at 0 and 99
    wire signed [3:0] r_delta  = r1[`R1_SCORE_DELTA];
    wire signed [8:0] delta_e  = {{5{r_delta[3]}}, r_delta};
    wire signed [8:0] s1_sum   = $signed({2'b00, score1}) + delta_e;
    wire signed [8:0] s2_sum   = $signed({2'b00, score2}) + delta_e;
    wire        [6:0] score1_n = (s1_sum < 9'sd0) ? 7'd0 : (s1_sum > 9'sd99) ? 7'd99 : s1_sum[6:0];
    wire        [6:0] score2_n = (s2_sum < 9'sd0) ? 7'd0 : (s2_sum > 9'sd99) ? 7'd99 : s2_sum[6:0];
    // lives + signed delta, saturating at 0 and 9
    wire signed [5:0] l1_sum   = $signed({2'b00, lives1}) + delta_e[5:0];
    wire signed [5:0] l2_sum   = $signed({2'b00, lives2}) + delta_e[5:0];
    wire        [3:0] lives1_n = (l1_sum < 6'sd0) ? 4'd0 : (l1_sum > 6'sd9) ? 4'd9 : l1_sum[3:0];
    wire        [3:0] lives2_n = (l2_sum < 6'sd0) ? 4'd0 : (l2_sum > 6'sd9) ? 4'd9 : l2_sum[3:0];

    // ROM address of an object's initial record: obj_base + 3 * index
    function [10:0] rec_addr;
        input [10:0] base;
        input [6:0]  idx;
        rec_addr = base + {3'b000, idx, 1'b0} + {4'b0000, idx};
    endfunction

    wire [10:0] rule_addr = rule_base + {4'b0000, r, 1'b0};

    // end-of-frame conditions
    wire p1_wins = ((win_score != 7'd0) && (score1 >= win_score)) ||
                   (lose_at_zero && (lives2 == 4'd0));
    wire p2_wins = ((win_score != 7'd0) && (score2 >= win_score)) ||
                   (lose_at_zero && (lives1 == 4'd0));

    // ------------------------------------------- memory ports (combinational)
    always @* begin
        rom_addr = 11'd0;
        ram_we   = 1'b0;
        ram_addr = i[5:0];
        ram_din  = a_rec;
        case (state)
            S_P1_WR, S_IT_WR, S_A_WR, S_WR_WR: ram_we = 1'b1;
            S_SP_ADDR, S_CO_ADDR:       ram_addr = j[5:0];
            S_SPL_ADDR:                 ram_addr = k[5:0];
            S_SPL_WB: begin
                ram_we   = 1'b1;
                ram_addr = j[5:0];
                ram_din  = b_rec;
            end
            S_SPL_WR: begin
                ram_we   = 1'b1;
                ram_addr = k[5:0];
                ram_din  = b_rec;
            end
            S_SP_WRB: begin
                ram_we   = 1'b1;
                ram_addr = j[5:0];
                ram_din  = b_rec;
            end
            S_CO_POST: begin
                ram_we   = b_dirty;
                ram_addr = j[5:0];
                ram_din  = b_rec;
            end
            S_IN_ADDR:  rom_addr = inp_base + {5'b00000, m};
            S_RS_ADDR:  rom_addr = rule_addr;
            S_RS_W0:    rom_addr = rule_addr + 11'd1;
            S_RL_0:     rom_addr = rl_ptr;
            S_RL_1:     rom_addr = rl_ptr + 11'd1;
            S_RL_2:     rom_addr = rl_ptr + 11'd2;
            default: ;
        endcase
    end

    // ------------------------------------------------------------- sequencer
    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state <= S_IDLE; rs_ret <= S_IDLE; rl_ret <= S_IDLE;
            busy <= 1'b0;
            i <= 7'd0; j <= 7'd0; m <= 6'd0; r <= 6'd0;
            a_rec <= 96'd0; b_rec <= 96'd0; m_rec <= 32'd0; r0 <= 32'd0; r1 <= 32'd0;
            btn_now <= 10'd0; btn_edge <= 10'd0; btn_prev <= 10'd0;
            evt_col <= 1'b0; evt_edges <= 4'd0; evt_axis_x <= 1'b0; evt_low <= 1'b0;
            a_gone <= 1'b0; b_dirty <= 1'b0; rs_stop <= 1'b0; rl_to_a <= 1'b0; rl_ptr <= 11'd0;
            score1 <= 7'd0; score2 <= 7'd0; lives1 <= 4'd0; lives2 <= 4'd0;
            gstate <= `GS_PLAYING;
            k <= 7'd0; spl_n <= 1'b0; spl_cls <= 4'd0; p_x <= 11'sd0; p_y <= 11'sd0;
            p_w <= 10'd0; p_h <= 10'd0; p_vx <= 6'sd0; p_vy <= 6'sd0; p_owner <= 2'd0;
        end else begin
            if (load_done) begin
                // a new round: scores, round state and the key history restart
                score1   <= init_score;
                score2   <= init_score;
                lives1   <= init_lives;
                lives2   <= init_lives;
                gstate   <= `GS_PLAYING;
                btn_prev <= keys;
            end

            case (state)
            // -------------------------------------------------------- idle
            S_IDLE: begin
                if (start && (gstate == `GS_PLAYING)) begin
                    btn_now  <= keys;                   // input sampled here
                    btn_edge <= keys & ~btn_prev;
                    busy     <= 1'b1;
                    i        <= 7'd0;
                    state    <= S_P1_ADDR;
                end
            end

            // ------------------------------------------------ pass 1: prep
            S_P1_ADDR: begin
                if (i == n_obj) begin
                    m     <= 6'd0;
                    state <= S_IN_ADDR;
                end else
                    state <= S_P1_LOAD;
            end
            S_P1_LOAD: begin
                a_rec <= ram_q;
                state <= S_P1_EXEC;
            end
            S_P1_EXEC: begin
                if (!a_en || ((a_timer == 8'd0) && (a_cool == 5'd0) && !controlled_mask[a_class])) begin
                    i     <= i + 7'd1;                  // nothing to change
                    state <= S_P1_ADDR;
                end else begin
                    if (a_timer != 8'd0) begin
                        a_rec[`OBJ_TIMER] <= a_timer - 8'd1;
                        if ((a_timer == 8'd1) && (a_tmode == `TMODE_LIFETIME))
                            a_rec[`OBJ_ENABLED] <= 1'b0;
                    end
                    if (a_cool != 5'd0)
                        a_rec[`OBJ_COOL] <= a_cool - 5'd1;
                    if (controlled_mask[a_class]) begin
                        a_rec[`OBJ_VX] <= 6'd0;
                        a_rec[`OBJ_VY] <= 6'd0;
                    end
                    state <= S_P1_WR;
                end
            end
            S_P1_WR: begin
                i     <= i + 7'd1;
                state <= S_P1_ADDR;
            end

            // ----------------------------------------------- pass 2: input
            S_IN_ADDR: begin
                if (m == n_inp) begin
                    i     <= 7'd0;
                    state <= S_MV_ADDR;
                end else
                    state <= S_IN_LOAD;
            end
            S_IN_LOAD: begin
                m_rec <= rom_q;
                state <= S_IN_CHK;
            end
            S_IN_CHK: begin
                if (m_trigd && m_op_ok) begin
                    i     <= 7'd0;
                    state <= S_IT_ADDR;
                end else begin
                    m     <= m + 6'd1;
                    state <= S_IN_ADDR;
                end
            end
            S_IT_ADDR: begin
                if (i == n_obj) begin
                    m     <= m + 6'd1;
                    state <= S_IN_ADDR;
                end else
                    state <= S_IT_LOAD;
            end
            S_IT_LOAD: begin
                a_rec <= ram_q;
                state <= S_IT_EXEC;
            end
            S_IT_EXEC: begin
                if (!m_match) begin
                    i     <= i + 7'd1;
                    state <= S_IT_ADDR;
                end else if (m_op == `OP_MOVE) begin
                    case (m_dir)
                        `DIR_RIGHT: a_rec[`OBJ_VX] <= m_speed;
                        `DIR_LEFT:  a_rec[`OBJ_VX] <= -m_speed;
                        `DIR_DOWN:  a_rec[`OBJ_VY] <= m_speed;
                        default:    a_rec[`OBJ_VY] <= -m_speed;
                    endcase
                    state <= m_face ? S_IT_FACE : S_IT_WR;
                end else if (a_cool != 5'd0) begin      // SPAWN: cooldown running
                    i     <= i + 7'd1;
                    state <= S_IT_ADDR;
                end else begin                          // SPAWN: look for a free pool slot
                    j     <= 7'd0;
                    state <= S_SP_ADDR;
                end
            end
            S_IT_FACE: begin                            // heading follows the new velocity
                if ((a_vx != 6'sd0) || (a_vy != 6'sd0))
                    a_rec[`OBJ_DIR] <= a_heading;
                state <= S_IT_WR;
            end
            S_IT_WR: begin
                i     <= i + 7'd1;
                state <= S_IT_ADDR;
            end
            S_SP_ADDR: begin
                if (j == n_obj) begin                   // pool exhausted: no shot, no cooldown
                    i     <= i + 7'd1;
                    state <= S_IT_ADDR;
                end else
                    state <= S_SP_LOAD;
            end
            S_SP_LOAD: begin
                b_rec <= ram_q;
                state <= S_SP_CHK;
            end
            S_SP_CHK: begin
                if (!b_en && (b_class == m_pool) && (b_owner == a_owner)) begin
                    rl_ptr  <= rec_addr(obj_base, j);   // fetch the template from ROM
                    rl_to_a <= 1'b0;
                    rl_ret  <= S_SP_PLACE;
                    state   <= S_RL_0;
                end else begin
                    j     <= j + 7'd1;
                    state <= S_SP_ADDR;
                end
            end
            S_SP_PLACE: begin
                b_rec[`OBJ_X]       <= spw_x;
                b_rec[`OBJ_Y]       <= spw_y;
                b_rec[`OBJ_VX]      <= spw_vx;
                b_rec[`OBJ_VY]      <= spw_vy;
                b_rec[`OBJ_ENABLED] <= 1'b1;
                b_rec[`OBJ_DIR]     <= a_dir;
                b_rec[`OBJ_OWNER]   <= a_owner;
                a_rec[`OBJ_COOL]    <= m_cd[4:0];       // start the cooldown
                state <= S_SP_WRB;
            end
            S_SP_WRB: state <= S_IT_WR;                 // then write the spawner back

            // ------------------------------ pass 3: move, edges, collisions
            S_MV_ADDR: begin
                if (i == n_obj) begin
                    i     <= 7'd0;
                    state <= (wave_watch != 16'd0) ? S_WV_ADDR : S_END;
                end
                else
                    state <= S_MV_LOAD;
            end
            S_MV_LOAD: begin
                a_rec <= ram_q;
                state <= S_MV_CHK;
            end
            S_MV_CHK: begin
                a_gone <= 1'b0;
                if (!a_en || a_frozen) begin
                    i     <= i + 7'd1;
                    state <= S_MV_ADDR;
                end else if (a_moving) begin
                    state <= S_MV_ADD;
                end else if (a_collider && !a_shielded) begin
                    j     <= 7'd0;
                    state <= S_CO_ADDR;
                end else begin
                    i     <= i + 7'd1;
                    state <= S_MV_ADDR;
                end
            end
            S_MV_ADD: begin
                a_rec[`OBJ_X] <= a_x + {{5{a_vx[5]}}, a_vx};
                a_rec[`OBJ_Y] <= a_y + {{5{a_vy[5]}}, a_vy};
                state <= S_MV_EDGE;
            end
            S_MV_EDGE: begin
                a_rec[`OBJ_X]       <= bnd_x;
                a_rec[`OBJ_Y]       <= bnd_y;
                a_rec[`OBJ_VX]      <= bnd_vx;
                a_rec[`OBJ_VY]      <= bnd_vy;
                a_rec[`OBJ_ENABLED] <= bnd_en;
                a_gone    <= ~bnd_en;
                evt_edges <= bnd_edges;
                if (bnd_edges != 4'd0) begin            // EDGE event
                    evt_col <= 1'b0;
                    r       <= 6'd0;
                    rs_stop <= 1'b0;
                    rs_ret  <= S_MV_POST;
                    state   <= S_RS_ADDR;
                end else
                    state <= S_MV_POST;
            end
            S_MV_POST: begin
                if (!a_gone && a_collider && !a_shielded) begin
                    j     <= 7'd0;
                    state <= S_CO_ADDR;
                end else
                    state <= S_A_WR;
            end
            S_CO_ADDR: begin
                if (j == n_obj)
                    state <= S_A_WR;
                else if (j == i)
                    j <= j + 7'd1;                      // never against itself
                else
                    state <= S_CO_LOAD;
            end
            S_CO_LOAD: begin
                b_rec   <= ram_q;
                b_dirty <= 1'b0;
                state   <= S_CO_PEN;
            end
            S_CO_PEN: begin                             // ge_collide registers the depths
                if (!b_en) begin
                    j     <= j + 7'd1;
                    state <= S_CO_ADDR;
                end else
                    state <= S_CO_CHK;
            end
            S_CO_CHK: begin
                if (!col_overlap) begin
                    j     <= j + 7'd1;
                    state <= S_CO_ADDR;
                end else begin                          // COLLIDE event
                    evt_col    <= 1'b1;
                    evt_axis_x <= col_axis_x;
                    evt_low    <= col_low;
                    r          <= 6'd0;
                    rs_stop    <= 1'b0;
                    rs_ret     <= S_CO_POST;
                    state      <= S_RS_ADDR;
                end
            end
            S_CO_POST: begin                            // other is written back here
                j <= j + 7'd1;
                state <= a_gone ? S_A_WR : S_CO_ADDR;
            end
            S_A_WR: begin                               // self is written back here
                i     <= i + 7'd1;
                state <= S_MV_ADDR;
            end

            // --------------------------------------------------- rule scan
            S_RS_ADDR: begin
                if ((r == n_rule) || rs_stop)
                    state <= rs_ret;
                else
                    state <= S_RS_W0;
            end
            S_RS_W0: begin
                r0    <= rom_q;
                state <= S_RS_W1;
            end
            S_RS_W1: begin
                r1    <= rom_q;
                state <= S_RS_CHK;
            end
            S_RS_CHK: begin
                if (r_match)
                    state <= S_RS_ACT1;
                else begin
                    r     <= r + 6'd1;
                    state <= S_RS_ADDR;
                end
            end
            S_RS_ACT1: begin                            // motion response, ownership
                if (evt_col) begin
                    if ((r_motion == `MOTION_BOUNCE) || (r_motion == `MOTION_STOP)) begin
                        a_rec[`OBJ_X]  <= rsp_x;
                        a_rec[`OBJ_Y]  <= rsp_y;
                        a_rec[`OBJ_VX] <= rsp_vx;
                        a_rec[`OBJ_VY] <= rsp_vy;
                    end
                    if (r1[`R1_COPY_OWNER]) a_rec[`OBJ_OWNER] <= b_owner;
                    if (r1[`R1_COPY_COLOR]) a_rec[`OBJ_COLOR] <= b_color;
                end
                state <= S_RS_ACT2;
            end
            S_RS_ACT2: begin                            // score, then self fate
                if (r1[`R1_COUNTER] == `CNT_LIVES) begin
                    if (sel_player == `OWNER_P1) lives1 <= lives1_n;
                    if (sel_player == `OWNER_P2) lives2 <= lives2_n;
                end else begin
                    if (sel_player == `OWNER_P1) score1 <= score1_n;
                    if (sel_player == `OWNER_P2) score2 <= score2_n;
                end
                state <= S_RS_OTHER;
                case (r_sfate)
                    `FATE_DAMAGE: begin
                        if (a_hp <= 4'd1) begin
                            a_rec[`OBJ_HP]      <= 4'd0;
                            a_rec[`OBJ_ENABLED] <= 1'b0;
                            a_gone  <= 1'b1;
                            rs_stop <= 1'b1;
                        end else
                            a_rec[`OBJ_HP] <= a_hp - 4'd1;
                    end
                    `FATE_DESTROY: begin
                        a_rec[`OBJ_ENABLED] <= 1'b0;
                        a_gone  <= 1'b1;
                        rs_stop <= 1'b1;
                    end
                    `FATE_RESPAWN: begin
                        rl_ptr  <= rec_addr(obj_base, i);
                        rl_to_a <= 1'b1;
                        rl_ret  <= S_RS_SELF;
                        state   <= S_RL_0;
                    end
                    default: ;
                endcase
            end
            S_RS_SELF: begin                            // self has been reloaded
                if (r1[`R1_FLIP_X]) a_rec[`OBJ_VX] <= -a_vx;
                if (r1[`R1_FLIP_Y]) a_rec[`OBJ_VY] <= -a_vy;
                a_gone  <= 1'b1;
                rs_stop <= 1'b1;
                state   <= S_RS_OTHER;
            end
            S_RS_OTHER: begin                           // other fate (collisions only)
                state <= S_RS_NEXT;
                if (evt_col) begin
                    case (r_ofate)
                        `FATE_DAMAGE: begin
                            if (b_hp <= 4'd1) begin
                                b_rec[`OBJ_HP]      <= 4'd0;
                                b_rec[`OBJ_ENABLED] <= 1'b0;
                            end else
                                b_rec[`OBJ_HP] <= b_hp - 4'd1;
                            b_dirty <= 1'b1;
                        end
                        `FATE_DESTROY: begin
                            b_rec[`OBJ_ENABLED] <= 1'b0;
                            b_dirty <= 1'b1;
                        end
                        `FATE_RESPAWN: begin
                            rl_ptr  <= rec_addr(obj_base, j);
                            rl_to_a <= 1'b0;
                            rl_ret  <= S_RS_NEXT;
                            b_dirty <= 1'b1;
                            state   <= S_RL_0;
                        end
                        `FATE_SPLIT: begin                  // remember the parent, disable it
                            p_x     <= b_x;   p_y  <= b_y;
                            p_w     <= b_w;   p_h  <= b_h;
                            p_vx    <= b_vx;  p_vy <= b_vy;
                            p_owner <= b_owner;
                            spl_cls <= r1[`R1_SPLIT_CLASS];
                            spl_n   <= 1'b0;
                            b_rec[`OBJ_ENABLED] <= 1'b0;
                            state   <= S_SPL_WB;
                        end
                        default: ;
                    endcase
                end
            end
            S_RS_NEXT: begin
                if (r0[`R0_LAST]) rs_stop <= 1'b1;
                r     <= r + 6'd1;
                state <= S_RS_ADDR;
            end

            // ----------------------- reload a 3-word object record from ROM
            S_RL_0: state <= S_RL_1;                    // address of word 0 driven
            S_RL_1: begin                               // word 0 valid
                if (rl_to_a) a_rec[31:0] <= rom_q; else b_rec[31:0] <= rom_q;
                state <= S_RL_2;
            end
            S_RL_2: begin                               // word 1 valid
                if (rl_to_a) a_rec[63:32] <= rom_q; else b_rec[63:32] <= rom_q;
                state <= S_RL_3;
            end
            S_RL_3: begin                               // word 2 valid
                if (rl_to_a) a_rec[95:64] <= rom_q; else b_rec[95:64] <= rom_q;
                state <= rl_ret;
            end

            // ------------------- SPLIT: up to two fragments from the pool
            S_SPL_WB: begin                             // disabled parent written back
                b_dirty <= 1'b0;                        // b_rec is reused from here on
                k       <= 7'd0;
                state   <= S_SPL_ADDR;
            end
            S_SPL_ADDR: begin
                if (k == n_obj)
                    state <= S_SPL_NEXT;                // pool exhausted: no fragment
                else
                    state <= S_SPL_LOAD;
            end
            S_SPL_LOAD: begin
                b_rec <= ram_q;
                state <= S_SPL_CHK;
            end
            S_SPL_CHK: begin
                if ((k != i) && !b_en && (b_class == spl_cls) && (b_owner == p_owner)) begin
                    rl_ptr  <= rec_addr(obj_base, k);
                    rl_to_a <= 1'b0;
                    rl_ret  <= S_SPL_PLACE;
                    state   <= S_RL_0;
                end else begin
                    k     <= k + 7'd1;
                    state <= S_SPL_ADDR;
                end
            end
            S_SPL_PLACE: begin
                b_rec[`OBJ_X]       <= spl_x;
                b_rec[`OBJ_Y]       <= spl_y;
                b_rec[`OBJ_VX]      <= spl_vx;
                b_rec[`OBJ_VY]      <= spl_vy;
                b_rec[`OBJ_ENABLED] <= 1'b1;
                b_rec[`OBJ_OWNER]   <= p_owner;
                state <= S_SPL_WR;
            end
            S_SPL_WR: state <= S_SPL_NEXT;              // fragment written at k
            S_SPL_NEXT: begin
                if (!spl_n) begin
                    spl_n <= 1'b1;
                    k     <= 7'd0;
                    state <= S_SPL_ADDR;
                end else begin
                    rs_stop <= 1'b1;                    // b_rec no longer holds the other
                    state   <= S_RS_NEXT;
                end
            end

            // --------------------------------------------- wave reload
            S_WV_ADDR: begin
                if (i == n_obj) begin                   // nothing watched is left
                    i     <= 7'd0;
                    state <= S_WR_ADDR;
                end else
                    state <= S_WV_LOAD;
            end
            S_WV_LOAD: begin
                a_rec <= ram_q;
                state <= S_WV_CHK;
            end
            S_WV_CHK: begin
                if (a_en && wave_watch[a_class])
                    state <= S_END;                     // still something to shoot at
                else begin
                    i     <= i + 7'd1;
                    state <= S_WV_ADDR;
                end
            end
            S_WR_ADDR: begin
                if (i == n_obj)
                    state <= S_END;
                else
                    state <= S_WR_LOAD;
            end
            S_WR_LOAD: begin
                a_rec <= ram_q;
                state <= S_WR_CHK;
            end
            S_WR_CHK: begin
                if (wave_reload[a_class]) begin
                    rl_ptr  <= rec_addr(obj_base, i);
                    rl_to_a <= 1'b1;
                    rl_ret  <= S_WR_WR;
                    state   <= S_RL_0;
                end else begin
                    i     <= i + 7'd1;
                    state <= S_WR_ADDR;
                end
            end
            S_WR_WR: begin                              // reloaded record written at i
                i     <= i + 7'd1;
                state <= S_WR_ADDR;
            end

            // ------------------------------------------------ end of frame
            S_END: begin
                gstate   <= {p2_wins, p1_wins};
                btn_prev <= btn_now;
                busy     <= 1'b0;
                done     <= 1'b1;
                state    <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
