// ge_units.v - the fixed-function datapath blocks of the game engine.
//
// *** TASKS 5, 6 and 7 are in this file: ge_collide, ge_boundary, ge_split.
//     ge_response and ge_spawn are provided complete - read them, they use
//     the same arithmetic conventions you will need.
//
// Each block is one reusable operation. None of them knows which game is
// running: all behaviour comes from the object records and the rule words
// the engine feeds them.
//
//   ge_collide   axis-aligned box overlap test with penetration depths
//   ge_response  BOUNCE / STOP push-out and velocity response, with SPIN
//   ge_boundary  arena edge handling: CLAMP / BOUNCE / WRAP / DESTROY
//   ge_spawn     placement of a pooled object next to its spawner (8 headings)
//   ge_split     placement and velocity of a fragment when an object splits
//
// Coordinates are signed 11-bit pixels, sizes unsigned 10-bit, velocities
// signed 6-bit. All sums are formed in 13-bit signed arithmetic, which
// cannot overflow for any legal input; results stored back into a record
// are truncated to 11 bits (see MEMORY_FORMAT.md, "Arithmetic").
`include "ge_defs.vh"
`default_nettype none

// ---------------------------------------------------------------------------
// ge_collide: do boxes A and B overlap, and how should A be pushed out?
//
// One register stage: inputs sampled on clock n give outputs on clock n+1.
//
//   dl = A.right  - B.left     how far A's right edge is inside B
//   dr = B.right  - A.left     how far A's left edge is inside B
//   dt = A.bottom - B.top
//   db = B.bottom - A.top
//   overlap  <=> all four are > 0   (touching boxes do not overlap)
//   x depth  = min(dl, dr), y depth = min(dt, db)
//   axis_x   = (x depth <= y depth)       shallower axis wins, tie -> x
//   low      = A is on the low-coordinate side on that axis (tie -> low)
//
// *** TASK 5
// ---------------------------------------------------------------------------
module ge_collide (
    input  wire               clk,
    input  wire signed [10:0] ax, ay,
    input  wire        [9:0]  aw, ah,
    input  wire signed [10:0] bx, by,
    input  wire        [9:0]  bw, bh,
    output wire               overlap,
    output wire               axis_x,
    output wire               low
);
    wire signed [12:0] ax_e = {{2{ax[10]}}, ax};
    wire signed [12:0] ay_e = {{2{ay[10]}}, ay};
    wire signed [12:0] bx_e = {{2{bx[10]}}, bx};
    wire signed [12:0] by_e = {{2{by[10]}}, by};
    wire signed [12:0] aw_e = {3'b000, aw};
    wire signed [12:0] ah_e = {3'b000, ah};
    wire signed [12:0] bw_e = {3'b000, bw};
    wire signed [12:0] bh_e = {3'b000, bh};

    reg signed [12:0] dl, dr, dt, db;   // the four penetration differences

    // ---------------------------------------------------------------------
    // TASK 5 - insert the box overlap test here:
    //   1. register dl, dr, dt, db (one clock stage, no reset needed)
    //   2. from the registered values form overlap, axis_x and low exactly
    //      as described in the comment above this module
    // ---------------------------------------------------------------------
    always @(posedge clk) begin
        dl <= ax_e + aw_e - bx_e;
        dr <= bx_e + bw_e - ax_e;
        dt <= ay_e + ah_e - by_e;
        db <= by_e + bh_e - ay_e;
    end

    wire low_x = (dl <= dr);
    wire low_y = (dt <= db);
    wire signed [12:0] xdepth = low_x ? dl : dr;
    wire signed [12:0] ydepth = low_y ? dt : db;

    assign overlap = (dl > 13'sd0) && (dr > 13'sd0) && (dt > 13'sd0) && (db > 13'sd0);
    assign axis_x  = (xdepth <= ydepth);
    assign low     = axis_x ? low_x : low_y;
    // ------------------------------------------------------ END TASK 5 ----
endmodule

// ---------------------------------------------------------------------------
// ge_response: motion response of A after a collision with B (combinational).
//
// On the collision axis A is moved so that it just touches B, and its
// velocity on that axis is
//     BOUNCE : pointed away from B, magnitude kept
//     STOP   : set to 0
// SPIN (BOUNCE only) nudges A's velocity on the other axis by spin_step in
// the direction B is moving, clamped to +-spin_max.
// ---------------------------------------------------------------------------
module ge_response (
    input  wire signed [10:0] ax, ay,
    input  wire        [9:0]  aw, ah,
    input  wire signed [5:0]  avx, avy,
    input  wire signed [10:0] bx, by,
    input  wire        [9:0]  bw, bh,
    input  wire signed [5:0]  bvx, bvy,
    input  wire               axis_x,
    input  wire               low,
    input  wire               bounce,       // 1 BOUNCE, 0 STOP
    input  wire               spin,
    input  wire        [2:0]  spin_step,
    input  wire        [4:0]  spin_max,
    output reg  signed [10:0] nx, ny,
    output reg  signed [5:0]  nvx, nvy
);
    function signed [5:0] abs6;
        input signed [5:0] v;
        abs6 = v[5] ? -v : v;
    endfunction

    // perpendicular velocity p nudged by the sign of q
    function signed [5:0] spin_f;
        input signed [5:0] p;
        input signed [5:0] q;
        input        [2:0] step;
        input        [4:0] vmax;
        reg signed [7:0] t, lim, p8, st8;
        begin
            lim = {3'b000, vmax};
            p8  = {{2{p[5]}}, p};
            st8 = {5'b00000, step};
            if (q == 6'sd0)      t = p8;
            else if (q[5])       t = p8 - st8;
            else                 t = p8 + st8;
            if (q != 6'sd0 && t > lim)        t = lim;
            else if (q != 6'sd0 && t < -lim)  t = -lim;
            spin_f = t[5:0];
        end
    endfunction

    wire signed [12:0] bx_e = {{2{bx[10]}}, bx};
    wire signed [12:0] by_e = {{2{by[10]}}, by};
    wire signed [12:0] x_lo = bx_e - $signed({3'b000, aw});   // A left of B
    wire signed [12:0] x_hi = bx_e + $signed({3'b000, bw});   // A right of B
    wire signed [12:0] y_lo = by_e - $signed({3'b000, ah});
    wire signed [12:0] y_hi = by_e + $signed({3'b000, bh});

    always @* begin
        nx = ax; ny = ay; nvx = avx; nvy = avy;
        if (axis_x) begin
            nx  = low ? x_lo[10:0] : x_hi[10:0];
            if (!bounce)   nvx = 6'sd0;
            else begin
                nvx = low ? -abs6(avx) : abs6(avx);
                if (spin) nvy = spin_f(avy, bvy, spin_step, spin_max);
            end
        end else begin
            ny  = low ? y_lo[10:0] : y_hi[10:0];
            if (!bounce)   nvy = 6'sd0;
            else begin
                nvy = low ? -abs6(avy) : abs6(avy);
                if (spin) nvx = spin_f(avx, bvx, spin_step, spin_max);
            end
        end
    end
endmodule

// ---------------------------------------------------------------------------
// ge_boundary: arena edge handling for an object that has just moved
// (combinational). edges = {BOTTOM, TOP, RIGHT, LEFT}.
//
//   CLAMP   : outside part pulled back to the edge, velocity on that axis 0
//   BOUNCE  : pulled back to the edge, velocity pointed back inside
//   WRAP    : once completely outside, re-enters completely outside the
//             opposite edge (so it slides in smoothly)
//   DESTROY : disabled as soon as any part is outside
//
// *** TASK 6
// ---------------------------------------------------------------------------
module ge_boundary (
    input  wire signed [10:0] x, y,
    input  wire        [9:0]  w, h,
    input  wire signed [5:0]  vx, vy,
    input  wire        [1:0]  bmode,
    input  wire signed [10:0] xmin, xmax, ymin, ymax,
    output reg  signed [10:0] nx, ny,
    output reg  signed [5:0]  nvx, nvy,
    output reg                nen,
    output reg         [3:0]  edges
);
    function signed [5:0] abs6;
        input signed [5:0] v;
        abs6 = v[5] ? -v : v;
    endfunction

    wire signed [12:0] x_e  = {{2{x[10]}}, x};
    wire signed [12:0] y_e  = {{2{y[10]}}, y};
    wire signed [12:0] w_e  = {3'b000, w};
    wire signed [12:0] h_e  = {3'b000, h};
    wire signed [12:0] x0   = {{2{xmin[10]}}, xmin};
    wire signed [12:0] x1   = {{2{xmax[10]}}, xmax};
    wire signed [12:0] y0   = {{2{ymin[10]}}, ymin};
    wire signed [12:0] y1   = {{2{ymax[10]}}, ymax};
    wire signed [12:0] xr   = x_e + w_e;
    wire signed [12:0] yb   = y_e + h_e;

    wire is_bounce = (bmode == `BMODE_BOUNCE);

    // ---------------------------------------------------------------------
    // TASK 6 - insert the arena edge logic here (see the handout, "Arena
    // Edges"). Suggested intermediate signals, all in 13-bit arithmetic:
    //   lo_x, hi_x, lo_y, hi_y   : part of the box is outside an edge
    //   out_l, out_r, out_t, out_b : the WHOLE box is outside an edge
    // then one case on bmode: CLAMP/BOUNCE, WRAP, default (DESTROY).
    // Keep the defaults line at the top of the always block.
    // ---------------------------------------------------------------------
    wire lo_x  = (x_e < x0);        // part of the box out on the left
    wire hi_x  = (xr  > x1);        // ... right
    wire lo_y  = (y_e < y0);        // ... top
    wire hi_y  = (yb  > y1);        // ... bottom
    wire out_l = (xr  <= x0);       // whole box out on the left
    wire out_r = (x_e >= x1);       // ... right
    wire out_t = (yb  <= y0);       // ... top
    wire out_b = (y_e >= y1);       // ... bottom

    wire signed [12:0] x_clr = x1 - w_e;    // x so the box touches the right edge
    wire signed [12:0] y_clb = y1 - h_e;    // y so the box touches the bottom
    wire signed [12:0] x_wr  = x0 - w_e;    // x wholly left of xmin
    wire signed [12:0] y_wb  = y0 - h_e;    // y wholly above ymin

    always @* begin
        nx = x; ny = y; nvx = vx; nvy = vy; nen = 1'b1; edges = 4'b0000;
        case (bmode)
            `BMODE_CLAMP, `BMODE_BOUNCE: begin
                if (lo_x) begin
                    nx = x0[10:0];
                    nvx = is_bounce ? abs6(vx) : 6'sd0;
                    edges[0] = 1'b1;
                end else if (hi_x) begin
                    nx = x_clr[10:0];
                    nvx = is_bounce ? -abs6(vx) : 6'sd0;
                    edges[1] = 1'b1;
                end
                if (lo_y) begin
                    ny = y0[10:0];
                    nvy = is_bounce ? abs6(vy) : 6'sd0;
                    edges[2] = 1'b1;
                end else if (hi_y) begin
                    ny = y_clb[10:0];
                    nvy = is_bounce ? -abs6(vy) : 6'sd0;
                    edges[3] = 1'b1;
                end
            end
            `BMODE_WRAP: begin
                if (out_l) begin
                    nx = x1[10:0];
                    edges[0] = 1'b1;
                end else if (out_r) begin
                    nx = x_wr[10:0];
                    edges[1] = 1'b1;
                end
                if (out_t) begin
                    ny = y1[10:0];
                    edges[2] = 1'b1;
                end else if (out_b) begin
                    ny = y_wb[10:0];
                    edges[3] = 1'b1;
                end
            end
            default: begin              // DESTROY
                edges = {hi_y & ~lo_y, lo_y, hi_x & ~lo_x, lo_x};
                nen   = ~(lo_x | hi_x | lo_y | hi_y);
            end
        endcase
    end
    // ------------------------------------------------------ END TASK 6 ----
endmodule

// ---------------------------------------------------------------------------
// ge_spawn: where a pooled object T appears when spawner A fires
// (combinational). A's heading (0 E, 1 NE, 2 N, 3 NW, 4 W, 5 SW, 6 S, 7 SE)
// gives a step (hx, hy) in {-1, 0, +1}. On an axis with a step, T is placed
// just outside A on that side; on an axis without one, T is centred on A
// (rounding down). T flies at (hx * speed, hy * speed), speed being the pool
// record's vx as stored in the ROM.
// ---------------------------------------------------------------------------
module ge_spawn (
    input  wire signed [10:0] ax, ay,
    input  wire        [9:0]  aw, ah,
    input  wire        [2:0]  adir,
    input  wire        [9:0]  tw, th,
    input  wire signed [5:0]  speed,
    output reg  signed [10:0] nx, ny,
    output reg  signed [5:0]  nvx, nvy
);
    wire signed [12:0] ax_e = {{2{ax[10]}}, ax};
    wire signed [12:0] ay_e = {{2{ay[10]}}, ay};
    wire signed [12:0] aw_e = {3'b000, aw};
    wire signed [12:0] ah_e = {3'b000, ah};
    wire signed [12:0] tw_e = {3'b000, tw};
    wire signed [12:0] th_e = {3'b000, th};
    wire signed [12:0] cx   = ax_e + ((aw_e - tw_e) >>> 1);   // centred, floor
    wire signed [12:0] cy   = ay_e + ((ah_e - th_e) >>> 1);
    wire signed [12:0] rx   = ax_e + aw_e;                     // right of A
    wire signed [12:0] lx   = ax_e - tw_e;                     // left of A
    wire signed [12:0] dy   = ay_e + ah_e;                     // below A
    wire signed [12:0] uy   = ay_e - th_e;                     // above A

    // step per heading: x positive for E NE SE, negative for NW W SW;
    //                   y negative (up) for NE N NW, positive for SW S SE
    wire xpos = (adir == `HD_E)  || (adir == `HD_NE) || (adir == `HD_SE);
    wire xneg = (adir == `HD_NW) || (adir == `HD_W)  || (adir == `HD_SW);
    wire yneg = (adir == `HD_NE) || (adir == `HD_N)  || (adir == `HD_NW);
    wire ypos = (adir == `HD_SW) || (adir == `HD_S)  || (adir == `HD_SE);

    always @* begin
        nx  = xpos ? rx[10:0] : xneg ? lx[10:0] : cx[10:0];
        ny  = yneg ? uy[10:0] : ypos ? dy[10:0] : cy[10:0];
        nvx = xpos ? speed : xneg ? -speed : 6'sd0;
        nvy = ypos ? speed : yneg ? -speed : 6'sd0;
    end
endmodule

// ---------------------------------------------------------------------------
// ge_split: placement of one fragment F when parent P splits
// (combinational). F is centred on P (rounding down). With P's velocity
// v = (vx, vy) and rot90(v) = (-vy, vx):
//     fragment 0 flies at v + rot90(v) = (vx - vy, vy + vx)
//     fragment 1 flies at v - rot90(v) = (vx + vy, vy - vx)
// i.e. 45 degrees either side of the parent's path, sqrt(2) times faster.
// Components are limited to -31..31.
//
// *** TASK 7
// ---------------------------------------------------------------------------
module ge_split (
    input  wire signed [10:0] px, py,
    input  wire        [9:0]  pw, ph,
    input  wire signed [5:0]  pvx, pvy,
    input  wire        [9:0]  fw, fh,
    input  wire               which,
    output wire signed [10:0] nx, ny,
    output wire signed [5:0]  nvx, nvy
);
    function signed [5:0] sat31;
        input signed [7:0] v;
        sat31 = (v > 8'sd31) ? 6'sd31 : (v < -8'sd31) ? -6'sd31 : v[5:0];
    endfunction

    // ---------------------------------------------------------------------
    // TASK 7 - insert the fragment placement here:
    //   nx, ny   : F centred on P, rounding down (13-bit signed arithmetic,
    //              keep the low 11 bits)
    //   nvx, nvy : which = 0 -> (vx - vy, vy + vx)
    //              which = 1 -> (vx + vy, vy - vx)
    //              each component saturated with sat31 (8-bit sums!)
    // ---------------------------------------------------------------------
    wire signed [12:0] px_e = {{2{px[10]}}, px};
    wire signed [12:0] py_e = {{2{py[10]}}, py};
    wire signed [12:0] dw   = $signed({3'b000, pw}) - $signed({3'b000, fw});
    wire signed [12:0] dh   = $signed({3'b000, ph}) - $signed({3'b000, fh});
    wire signed [12:0] cx   = px_e + (dw >>> 1);     // arithmetic shift = floor
    wire signed [12:0] cy   = py_e + (dh >>> 1);

    wire signed [7:0] vx8 = {{2{pvx[5]}}, pvx};
    wire signed [7:0] vy8 = {{2{pvy[5]}}, pvy};
    wire signed [7:0] sx  = which ? (vx8 + vy8) : (vx8 - vy8);
    wire signed [7:0] sy  = which ? (vy8 - vx8) : (vy8 + vx8);

    assign nx  = cx[10:0];
    assign ny  = cy[10:0];
    assign nvx = sat31(sx);
    assign nvy = sat31(sy);
    // ------------------------------------------------------ END TASK 7 ----
endmodule
`default_nettype wire
