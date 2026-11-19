# Generates table-driven testbenches for ge_collide, ge_boundary, ge_split and
# hud_digits. Expected values follow tools/gemodel.py (_boundary_raw, _split,
# the collision code) and the handout geometry for the digits.
import random, sys, os

out = sys.argv[1]
random.seed(5722)

def s6(v):
    v &= 0x3F
    return v - 0x40 if v & 0x20 else v
def s11(v):
    v &= 0x7FF
    return v - 0x800 if v & 0x400 else v
def abs6(v):
    return s6(-v) if v < 0 else v
def sat31(v):
    return max(-31, min(31, v))

HDR = "// {name} - self-checking testbench (Task 10). Generated table of cases;\n// expected values follow tools/gemodel.py.\n"

# ---------------------------------------------------------------- collide
def collide(ax, ay, aw, ah, bx, by, bw, bh):
    dl = ax + aw - bx; dr = bx + bw - ax
    dt = ay + ah - by; db = by + bh - ay
    ov = int(dl > 0 and dr > 0 and dt > 0 and db > 0)
    lx = dl <= dr; ly = dt <= db
    ox = dl if lx else dr; oy = dt if ly else db
    axx = ox <= oy
    low = lx if axx else ly
    return ov, int(axx), int(low)

cases = [
    ("touching right edge",   (0, 0, 10, 10, 10, 0, 10, 10)),
    ("touching bottom edge",  (0, 0, 10, 10, 0, 10, 10, 10)),
    ("touching corner",       (0, 0, 10, 10, 10, 10, 10, 10)),
    ("1 px overlap x",        (0, 0, 10, 10, 9, 0, 10, 10)),
    ("1 px overlap y",        (0, 0, 10, 10, 0, 9, 10, 10)),
    ("1 px overlap from right", (19, 0, 10, 10, 10, 0, 10, 10)),
    ("x/y tie -> x",          (0, 0, 10, 10, 7, 7, 10, 10)),
    ("A inside B",            (20, 20, 4, 4, 0, 0, 64, 64)),
    ("B inside A",            (0, 0, 64, 64, 30, 10, 4, 4)),
    ("identical boxes",       (5, 5, 8, 8, 5, 5, 8, 8)),
    ("negative coords overlap", (-20, -15, 16, 16, -10, -10, 8, 8)),
    ("negative coords apart",  (-100, -100, 10, 10, -50, -50, 10, 10)),
    ("off-screen low corner", (-1024, -1024, 10, 10, -1020, -1022, 10, 10)),
    ("far apart",             (0, 0, 10, 10, 600, 400, 10, 10)),
    ("zero-size A",           (5, 5, 0, 0, 0, 0, 10, 10)),
    ("deep in y shallow in x", (0, 0, 10, 40, 8, 0, 10, 40)),
    ("A below B",             (0, 8, 10, 10, 0, 0, 10, 10)),
]
for i in range(150):
    ax = random.randint(-200, 840); ay = random.randint(-200, 680)
    bx = ax + random.randint(-40, 40); by = ay + random.randint(-40, 40)
    cases.append(("random %d" % i, (ax, ay, random.randint(0, 40), random.randint(0, 40),
                                     bx, by, random.randint(0, 40), random.randint(0, 40))))

lines = []
for name, a in cases:
    e = collide(*a)
    lines.append('        chk(%s, %d, %d, %d, "%s");' % (", ".join(str(v) for v in a), *e, name))
tb = HDR.format(name="tb_ge_collide") + """module tb_ge_collide;
    reg clk = 0;
    always #5 clk = ~clk;
    reg signed [10:0] ax, ay, bx, by;
    reg        [9:0]  aw, ah, bw, bh;
    wire overlap, axis_x, low;
    integer errors = 0, ncase = 0;

    ge_collide dut (.clk(clk), .ax(ax), .ay(ay), .aw(aw), .ah(ah),
                    .bx(bx), .by(by), .bw(bw), .bh(bh),
                    .overlap(overlap), .axis_x(axis_x), .low(low));

    task chk;
        input integer iax, iay, iaw, iah, ibx, iby, ibw, ibh;
        input integer e_ov, e_ax, e_lo;
        input [8*32-1:0] name;
        begin
            @(negedge clk);
            ax = iax; ay = iay; aw = iaw; ah = iah;
            bx = ibx; by = iby; bw = ibw; bh = ibh;
            @(negedge clk);                 // one clock of latency
            ncase = ncase + 1;
            if (overlap !== e_ov[0] || axis_x !== e_ax[0] || low !== e_lo[0]) begin
                errors = errors + 1;
                $display("MISMATCH %0s: A(%0d,%0d,%0d,%0d) B(%0d,%0d,%0d,%0d) got ov=%b ax=%b lo=%b exp %0d %0d %0d",
                         name, iax, iay, iaw, iah, ibx, iby, ibw, ibh,
                         overlap, axis_x, low, e_ov, e_ax, e_lo);
            end
        end
    endtask

    initial begin
""" + "\n".join(lines) + """
        if (errors == 0) $display("tb_ge_collide: PASS (%0d cases)", ncase);
        else             $display("tb_ge_collide: FAIL (%0d of %0d cases)", errors, ncase);
        $finish;
    end
endmodule
"""
open(os.path.join(out, "tb_ge_collide.v"), "w", newline="\n").write(tb)

# ---------------------------------------------------------------- boundary
def boundary(x, y, w, h, vx, vy, mode, x0, x1, y0, y1):
    nx, ny, nvx, nvy, nen, e = x, y, vx, vy, 1, 0
    xr, yb = x + w, y + h
    lo_x, hi_x, lo_y, hi_y = x < x0, xr > x1, y < y0, yb > y1
    if mode in (0, 1):
        b = mode == 1
        if lo_x:   nx = s11(x0); nvx = abs6(vx) if b else 0; e |= 1
        elif hi_x: nx = s11(x1 - w); nvx = s6(-abs6(vx)) if b else 0; e |= 2
        if lo_y:   ny = s11(y0); nvy = abs6(vy) if b else 0; e |= 4
        elif hi_y: ny = s11(y1 - h); nvy = s6(-abs6(vy)) if b else 0; e |= 8
    elif mode == 2:
        if xr <= x0:   nx = s11(x1); e |= 1
        elif x >= x1:  nx = s11(x0 - w); e |= 2
        if yb <= y0:   ny = s11(y1); e |= 4
        elif y >= y1:  ny = s11(y0 - h); e |= 8
    else:
        if lo_x: e |= 1
        elif hi_x: e |= 2
        if lo_y: e |= 4
        elif hi_y: e |= 8
        if e: nen = 0
    return nx, ny, nvx, nvy, nen, e

MODES = ["CLAMP", "BOUNCE", "WRAP", "DESTROY"]
A = (0, 640, 0, 480)
bcases = []
for m in range(4):
    mn = MODES[m]
    # partly out on each edge, and wholly out on each edge
    bcases += [
        (mn + " inside",               (300, 200, 20, 20, 3, -2, m) + A),
        (mn + " part out left",        (-5, 200, 20, 20, -3, 1, m) + A),
        (mn + " part out right",       (630, 200, 20, 20, 3, 1, m) + A),
        (mn + " part out top",         (300, -4, 20, 20, 1, -3, m) + A),
        (mn + " part out bottom",      (300, 470, 20, 20, 1, 3, m) + A),
        (mn + " wholly out left",      (-20, 200, 20, 20, -3, 0, m) + A),
        (mn + " wholly out right",     (640, 200, 20, 20, 3, 0, m) + A),
        (mn + " wholly out top",       (300, -20, 20, 20, 0, -3, m) + A),
        (mn + " wholly out bottom",    (300, 480, 20, 20, 0, 3, m) + A),
        (mn + " two edges top-left",   (-5, -5, 20, 20, -2, -2, m) + A),
        (mn + " two edges bottom-right", (630, 470, 20, 20, 2, 2, m) + A),
        (mn + " wholly out corner",    (-30, 490, 20, 20, -2, 2, m) + A),
        (mn + " vx = -32 left",        (-2, 100, 8, 8, -32, -32, m) + A),
        (mn + " vx = -32 right",       (636, 476, 8, 8, -32, -32, m) + A),
        (mn + " exactly on edges",     (0, 0, 640, 480, 5, 5, m) + A),
        (mn + " wider than arena",     (-10, 100, 700, 10, 1, 1, m) + A),
        (mn + " other arena",          (5, 5, 10, 10, -4, -4, m, 10, 300, 20, 200)),
    ]
for i in range(120):
    m = random.randint(0, 3)
    bcases.append(("random %d" % i, (random.randint(-60, 700), random.randint(-60, 540),
                   random.randint(0, 60), random.randint(0, 60),
                   random.randint(-32, 31), random.randint(-32, 31), m) + A))
lines = []
for name, a in bcases:
    e = boundary(*a)
    lines.append('        chk(%s, %s, "%s");' % (", ".join(str(v) for v in a), ", ".join(str(v) for v in e), name))
tb = HDR.format(name="tb_ge_boundary") + """`include "ge_defs.vh"
module tb_ge_boundary;
    reg signed [10:0] x, y, xmin, xmax, ymin, ymax;
    reg        [9:0]  w, h;
    reg signed [5:0]  vx, vy;
    reg        [1:0]  bmode;
    wire signed [10:0] nx, ny;
    wire signed [5:0]  nvx, nvy;
    wire               nen;
    wire        [3:0]  edges;
    integer errors = 0, ncase = 0;

    ge_boundary dut (.x(x), .y(y), .w(w), .h(h), .vx(vx), .vy(vy), .bmode(bmode),
                     .xmin(xmin), .xmax(xmax), .ymin(ymin), .ymax(ymax),
                     .nx(nx), .ny(ny), .nvx(nvx), .nvy(nvy), .nen(nen), .edges(edges));

    task chk;
        input integer ix, iy, iw, ih, ivx, ivy, imode, ix0, ix1, iy0, iy1;
        input integer enx, eny, envx, envy, enen, eedges;
        input [8*32-1:0] name;
        begin
            x = ix; y = iy; w = iw; h = ih; vx = ivx; vy = ivy; bmode = imode;
            xmin = ix0; xmax = ix1; ymin = iy0; ymax = iy1;
            #1;
            ncase = ncase + 1;
            if (nx != enx || ny != eny || nvx != envx || nvy != envy ||
                nen !== enen[0] || edges !== eedges[3:0]) begin
                errors = errors + 1;
                $display("MISMATCH %0s: in x=%0d y=%0d w=%0d h=%0d v=(%0d,%0d) mode=%0d",
                         name, ix, iy, iw, ih, ivx, ivy, imode);
                $display("         got  n=(%0d,%0d) v=(%0d,%0d) en=%b edges=%b",
                         nx, ny, nvx, nvy, nen, edges);
                $display("         exp  n=(%0d,%0d) v=(%0d,%0d) en=%0d edges=%b",
                         enx, eny, envx, envy, enen, eedges[3:0]);
            end
        end
    endtask

    initial begin
""" + "\n".join(lines) + """
        if (errors == 0) $display("tb_ge_boundary: PASS (%0d cases)", ncase);
        else             $display("tb_ge_boundary: FAIL (%0d of %0d cases)", errors, ncase);
        $finish;
    end
endmodule
"""
open(os.path.join(out, "tb_ge_boundary.v"), "w", newline="\n").write(tb)

# ---------------------------------------------------------------- split
def split(px, py, pw, ph, vx, vy, fw, fh, which):
    nx = s11(px + ((pw - fw) >> 1)); ny = s11(py + ((ph - fh) >> 1))
    if which == 0: v = (sat31(vx - vy), sat31(vy + vx))
    else:          v = (sat31(vx + vy), sat31(vy - vx))
    return nx, ny, s6(v[0]), s6(v[1])

scases = []
base = [
    ("large -> medium",          (100, 100, 32, 32, 3, 1, 16, 16)),
    ("medium -> small odd size", (51, 77, 17, 15, -2, 3, 8, 8)),
    ("fragment larger than parent", (200, 150, 8, 8, 1, -1, 16, 16)),
    ("odd negative difference",  (200, 150, 8, 8, 1, -1, 13, 11)),
    ("saturate +31",             (10, 10, 32, 32, 31, 31, 16, 16)),
    ("saturate -31",             (10, 10, 32, 32, -32, -32, 16, 16)),
    ("mixed saturate",           (10, 10, 32, 32, 31, -32, 16, 16)),
    ("parent at rest",           (300, 200, 32, 32, 0, 0, 16, 16)),
    ("negative position",        (-20, -30, 32, 32, -5, 4, 16, 16)),
    ("off-screen low",           (-1024, -1024, 32, 32, 2, 2, 16, 16)),
]
for name, a in base:
    for wh in (0, 1):
        scases.append(("%s which=%d" % (name, wh), a + (wh,)))
for i in range(80):
    scases.append(("random %d" % i, (random.randint(-100, 700), random.randint(-100, 540),
                   random.randint(0, 64), random.randint(0, 64),
                   random.randint(-32, 31), random.randint(-32, 31),
                   random.randint(0, 64), random.randint(0, 64), random.randint(0, 1))))
lines = []
for name, a in scases:
    e = split(*a)
    lines.append('        chk(%s, %s, "%s");' % (", ".join(str(v) for v in a), ", ".join(str(v) for v in e), name))
tb = HDR.format(name="tb_ge_split") + """module tb_ge_split;
    reg signed [10:0] px, py;
    reg        [9:0]  pw, ph, fw, fh;
    reg signed [5:0]  pvx, pvy;
    reg               which;
    wire signed [10:0] nx, ny;
    wire signed [5:0]  nvx, nvy;
    integer errors = 0, ncase = 0;

    ge_split dut (.px(px), .py(py), .pw(pw), .ph(ph), .pvx(pvx), .pvy(pvy),
                  .fw(fw), .fh(fh), .which(which),
                  .nx(nx), .ny(ny), .nvx(nvx), .nvy(nvy));

    task chk;
        input integer ipx, ipy, ipw, iph, ivx, ivy, ifw, ifh, iwhich;
        input integer enx, eny, envx, envy;
        input [8*40-1:0] name;
        begin
            px = ipx; py = ipy; pw = ipw; ph = iph; pvx = ivx; pvy = ivy;
            fw = ifw; fh = ifh; which = iwhich;
            #1;
            ncase = ncase + 1;
            if (nx != enx || ny != eny || nvx != envx || nvy != envy) begin
                errors = errors + 1;
                $display("MISMATCH %0s: got n=(%0d,%0d) v=(%0d,%0d) exp n=(%0d,%0d) v=(%0d,%0d)",
                         name, nx, ny, nvx, nvy, enx, eny, envx, envy);
            end
        end
    endtask

    initial begin
""" + "\n".join(lines) + """
        if (errors == 0) $display("tb_ge_split: PASS (%0d cases)", ncase);
        else             $display("tb_ge_split: FAIL (%0d of %0d cases)", errors, ncase);
        $finish;
    end
endmodule
"""
open(os.path.join(out, "tb_ge_split.v"), "w", newline="\n").write(tb)

# ---------------------------------------------------------------- hud digits
# Expected bitmaps from the handout geometry: 20 x 36 cell, 4-px segments,
# g on rows 16..19, b/f rows 0..19, c/e rows 16..35.
SEG7 = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F]
RECTS = {0: (0, 20, 0, 4), 1: (16, 20, 0, 20), 2: (16, 20, 16, 36), 3: (0, 20, 32, 36),
         4: (0, 4, 16, 36), 5: (0, 4, 0, 20), 6: (0, 20, 16, 20)}   # (x0, x1, y0, y1)
rows = []
for d in range(10):
    for dy in range(36):
        m = 0
        for dx in range(20):
            for s, (x0, x1, y0, y1) in RECTS.items():
                if SEG7[d] >> s & 1 and x0 <= dx < x1 and y0 <= dy < y1:
                    m |= 1 << dx
        rows.append(m)
init = "\n".join("        pat[%d] = 20'h%05X;" % (i, m) for i, m in enumerate(rows))
tb = "// tb_hud_digits - self-checking testbench (Task 10). Draws every digit 0..9\n// as text (# = lit) and compares each pixel with the expected pattern\n// (bit dx of pat[digit*36 + dy]).\n" + """module tb_hud_digits;
    reg  [9:0] hcount, vcount, p1_x, p2_x;
    reg  [8:0] y;
    reg  [3:0] d0, d1, d2, d3;
    reg        en;
    wire       on, p2;
    reg  [19:0] pat [0:359];
    reg  [8*20-1:0] line;
    integer d, dx, dy, errors = 0;

    hud_digits dut (.hcount(hcount), .vcount(vcount), .en(en), .p1_x(p1_x), .p2_x(p2_x),
                    .y(y), .d0(d0), .d1(d1), .d2(d2), .d3(d3), .on(on), .p2(p2));

    initial begin
""" + init + """
        en = 1; p1_x = 10'd100; p2_x = 10'd400; y = 9'd20;
        d1 = 4'd15; d2 = 4'd15; d3 = 4'd15;         // blank digits elsewhere
        for (d = 0; d < 10; d = d + 1) begin
            d0 = d;
            $display("digit %0d:", d);
            for (dy = 0; dy < 36; dy = dy + 1) begin
                for (dx = 0; dx < 20; dx = dx + 1) begin
                    hcount = p1_x + dx; vcount = y + dy;
                    #1;
                    line[8*(19-dx) +: 8] = on ? "#" : ".";
                    if (on !== pat[d*36 + dy][dx]) begin
                        errors = errors + 1;
                        $display("MISMATCH digit %0d at dx=%0d dy=%0d: got %b", d, dx, dy, on);
                    end
                end
                $display("  %s", line);
            end
        end
        // outside the cells nothing is lit; player 2 cells set p2; en = 0 blanks
        d0 = 4'd8; d1 = 4'd8; d2 = 4'd8; d3 = 4'd8;
        hcount = 10'd99;  vcount = 10'd20; #1; if (on)  begin errors = errors + 1; $display("MISMATCH lit left of cell"); end
        hcount = 10'd120; vcount = 10'd20; #1; if (on)  begin errors = errors + 1; $display("MISMATCH lit in gap between digits"); end
        hcount = 10'd100; vcount = 10'd56; #1; if (on)  begin errors = errors + 1; $display("MISMATCH lit below cell"); end
        hcount = 10'd424; vcount = 10'd20; #1; if (!on || !p2) begin errors = errors + 1; $display("MISMATCH player 2 ones digit"); end
        hcount = 10'd124; vcount = 10'd20; #1; if (!on || p2)  begin errors = errors + 1; $display("MISMATCH player 1 ones digit"); end
        en = 0; #1; if (on) begin errors = errors + 1; $display("MISMATCH en = 0 still lit"); end
        if (errors == 0) $display("tb_hud_digits: PASS");
        else             $display("tb_hud_digits: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
"""
open(os.path.join(out, "tb_hud_digits.v"), "w", newline="\n").write(tb)
print("generated", len(cases), len(bcases), len(scases))
