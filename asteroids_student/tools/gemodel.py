#!/usr/bin/env python3
"""
gemodel.py - executable specification of the game engine.

A frame-accurate, bit-accurate reference model written straight from
docs/MEMORY_FORMAT.md. It reads the same ROM image as the hardware and
produces, frame by frame, the exact contents of the object RAM, the scores
and the round state, plus the exact picture the renderer must draw.

The RTL is checked against this model (sim/run_all.py): thousands of frames
of random play per game, compared word for word.

Standard library only.
"""

import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import geformat as gf  # noqa: E402

COLLIDE, EDGE = gf.EVENT["COLLIDE"], gf.EVENT["EDGE"]


def s11(v):
    v &= 0x7FF
    return v - 0x800 if v & 0x400 else v


def s6(v):
    v &= 0x3F
    return v - 0x40 if v & 0x20 else v


def abs6(v):
    """|v| as the hardware computes it: 6-bit negate, so -32 stays -32."""
    return s6(-v) if v < 0 else v


# heading 0..7 = E NE N NW W SW S SE: unit steps (screen y grows downwards)
HX = [1, 1, 0, -1, -1, -1, 0, 1]
HY = [0, -1, -1, -1, 0, 1, 1, 1]


def heading(vx, vy):
    """Heading of a non-zero velocity, from the signs of its components."""
    sx = (vx > 0) - (vx < 0)
    sy = (vy > 0) - (vy < 0)
    return [k for k in range(8) if HX[k] == sx and HY[k] == sy][0]


def sat31(v):
    return max(-31, min(31, v))


def read_mem(path):
    """Read a $readmemh file written by gamec.py (one hex word per line)."""
    words = []
    with open(path, "r") as fh:
        for line in fh:
            line = line.split("//")[0].strip()
            if line:
                words.append(int(line, 16))
    return words


_OBJ_RSV = gf.reserved_mask(gf.OBJ_FIELDS, gf.OBJ_WORDS)


class Obj(object):
    """Runtime object record. Attribute names are the OBJ field names
    (the field called "class" is stored as cls)."""

    __slots__ = ("x", "y", "w", "h", "vx", "vy", "color", "cls", "owner",
                 "enabled", "bmode", "tmode", "dir", "hp", "timer", "mark", "cool", "rsv")

    def __init__(self, words=(0, 0, 0)):
        self.load(words)

    def load(self, words):
        d = gf.unpack(gf.OBJ_FIELDS, words)
        for k, v in d.items():
            setattr(self, "cls" if k == "class" else k, v)
        self.rsv = [w & m for w, m in zip(words, _OBJ_RSV)]

    def words(self):
        out = list(self.rsv)
        for f in gf.OBJ_FIELDS:
            v = getattr(self, "cls" if f.name == "class" else f.name)
            out[f.word] |= (v & ((1 << f.width) - 1)) << f.lsb
        return out

    def packed(self):
        w = self.words()
        return w[0] | (w[1] << 32) | (w[2] << 64)


class Model(object):
    def __init__(self, rom):
        self.rom = list(rom) + [0] * (gf.ROM_DEPTH - len(rom))
        self.objs = [Obj() for _ in range(gf.MAX_OBJ)]
        self.pal = [0] * gf.N_PAL
        self.cfg = dict((f.name, 0) for f in gf.HDR_FIELDS)
        self.score = [0, 0]
        self.lives = [0, 0]
        self.gstate = 0
        self.prev = 0
        self.game = 0
        self.loaded = False
        # coverage counters: ("rule", slot, index), ("input", slot, index),
        # ("spawn", slot), ("spawn_blocked", slot), ("end", slot, gstate)
        self.stats = {}

    def _count(self, *key):
        self.stats[key] = self.stats.get(key, 0) + 1

    def _feature(self, R, evt):
        """Coverage only: which parts of the rule format a fired rule used."""
        f = ["event:" + gf.enum_name(gf.EVENT, evt)]
        if evt == COLLIDE:
            f.append("owner_rel:" + gf.enum_name(gf.OWNER_REL, R["owner_rel"]))
            f.append("motion:" + gf.enum_name(gf.MOTION, R["motion"]))
            f.append("other_fate:" + gf.enum_name(gf.FATE, R["other_fate"]))
            for k in ("spin", "copy_owner", "copy_color"):
                if R[k]:
                    f.append(k)
        f.append("self_fate:" + gf.enum_name(gf.FATE, R["self_fate"]))
        f.append("score:" + gf.enum_name(gf.SCORE_SEL, R["score_sel"]))
        if R["counter"]:
            f.append("counter:LIVES")
        for k in ("flip_x", "flip_y", "last"):
            if R[k]:
                f.append(k)
        for name in f:
            self._count("feature", name)

    # ------------------------------------------------------------------ load
    def load(self, g, keys=0):
        """Game select / restart. Returns False if the slot is not loadable,
        in which case nothing changes (the current game keeps running)."""
        d = gf.unpack(gf.DIR_FIELDS, [self.rom[g & 3]])
        if not d["valid"] or d["version"] != gf.VERSION:
            return False
        hdr = d["hdr_addr"]
        h = gf.unpack(gf.HDR_FIELDS, self.rom[hdr:hdr + gf.HDR_WORDS])
        if h["magic"] != gf.MAGIC:
            return False
        h["n_obj"] &= 0x7F
        h["n_inp"] &= 0x3F
        h["n_rule"] &= 0x3F
        self.cfg = h
        self.pal = [self.rom[(h["pal_base"] + i) & 0x7FF] & 0xFFF for i in range(gf.N_PAL)]
        for i in range(gf.MAX_OBJ):
            self.objs[i].load(self._rom_obj(i) if i < h["n_obj"] else (0, 0, 0))
        self.score = [h["init_score"], h["init_score"]]
        self.lives = [h["init_lives"], h["init_lives"]]
        self.gstate = 0
        self.prev = keys & 0x3FF
        self.game = g & 3
        self.loaded = True
        return True

    def _rom_obj(self, i):
        a = self.cfg["obj_base"] + 3 * i
        return [self.rom[(a + k) & 0x7FF] for k in range(3)]

    # ------------------------------------------------------------------ step
    def step(self, keys):
        """One frame update. Does nothing after the round has ended."""
        if not self.loaded or self.gstate != 0:
            return
        c = self.cfg
        n = min(c["n_obj"], gf.MAX_OBJ)
        objs = self.objs
        now = keys & 0x3FF
        edge = now & ~self.prev

        # ---- pass 1: timers, zero the velocity of controlled classes ------
        for i in range(n):
            o = objs[i]
            if not o.enabled:
                continue
            if o.timer:
                o.timer -= 1
                if o.timer == 0 and o.tmode == gf.TMODE["LIFETIME"]:
                    o.enabled = 0
            if o.cool:
                o.cool -= 1
            if (c["controlled_mask"] >> o.cls) & 1:
                o.vx = o.vy = 0

        # ---- pass 2: input mappings, in table order ------------------------
        for k in range(c["n_inp"]):
            m = gf.unpack(gf.INP_FIELDS, [self.rom[(c["inp_base"] + k) & 0x7FF]])
            b = m["button"]
            if b >= gf.N_BUTTONS:
                continue
            if m["trigger"] == gf.TRIGGER["HELD"]:
                trig = (now >> b) & 1
            elif m["trigger"] == gf.TRIGGER["PRESSED"]:
                trig = (edge >> b) & 1
            else:
                trig = 0
            if not trig or m["op"] not in (gf.OP["MOVE"], gf.OP["SPAWN"]):
                continue
            for i in range(n):
                a = objs[i]
                if not (a.enabled and a.cls == m["class"]
                        and (m["owner"] == 0 or a.owner == m["owner"])):
                    continue
                self._count("input", self.game, k)
                if m["op"] == gf.OP["MOVE"]:
                    p = gf.unpack(gf.MOVE_FIELDS, [m["param"]])
                    sp = p["speed"]
                    if p["dir"] == 0:
                        a.vx = s6(sp)
                    elif p["dir"] == 1:
                        a.vx = s6(-sp)
                    elif p["dir"] == 2:
                        a.vy = s6(sp)
                    else:
                        a.vy = s6(-sp)
                    if p["set_facing"] and (a.vx or a.vy):
                        a.dir = heading(a.vx, a.vy)
                else:
                    self._spawn(a, gf.unpack(gf.SPAWN_FIELDS, [m["param"]]), n)

        # ---- pass 3: move, arena edges, collisions - one object at a time --
        for i in range(n):
            a = objs[i]
            if not a.enabled or (a.tmode == gf.TMODE["FREEZE"] and a.timer != 0):
                continue
            gone = False
            if a.vx != 0 or a.vy != 0:
                a.x = s11(a.x + a.vx)
                a.y = s11(a.y + a.vy)
                edges = self._boundary(a)
                gone = not a.enabled
                if edges:
                    gone = self._scan(EDGE, i, None, edges, False, False, gone)
            if gone or not (c["collider_mask"] >> a.cls) & 1:
                continue
            if a.tmode == gf.TMODE["SHIELD"] and a.timer != 0:
                continue                         # shielded: moves, but collides as nobody's self
            for j in range(n):
                if j == i:
                    continue
                b = objs[j]
                if not b.enabled:
                    continue
                dl = a.x + a.w - b.x
                dr = b.x + b.w - a.x
                dt = a.y + a.h - b.y
                db = b.y + b.h - a.y
                if not (dl > 0 and dr > 0 and dt > 0 and db > 0):
                    continue
                low_x = dl <= dr
                low_y = dt <= db
                ox = dl if low_x else dr
                oy = dt if low_y else db
                axis_x = ox <= oy
                low = low_x if axis_x else low_y
                gone = self._scan(COLLIDE, i, j, 0, axis_x, low, False)
                if gone:
                    break

        # ---- wave: field cleared -> reload the wave classes from the ROM ----
        if c["wave_watch"]:
            alive = any(o.enabled and (c["wave_watch"] >> o.cls) & 1 for o in objs[:n])
            if not alive:
                self._count("feature", "wave")
                self._count("wave", self.game)
                for i in range(n):
                    if (c["wave_reload"] >> objs[i].cls) & 1:
                        objs[i].load(self._rom_obj(i))

        # ---- end of frame: round state -------------------------------------
        win, lz = c["win_score"], c["lose_at_zero"]
        p1 = (win != 0 and self.score[0] >= win) or (lz and self.lives[1] == 0)
        p2 = (win != 0 and self.score[1] >= win) or (lz and self.lives[0] == 0)
        self.gstate = int(bool(p1)) | (int(bool(p2)) << 1)
        if self.gstate:
            self._count("end", self.game, self.gstate)
        self.prev = now

    # ----------------------------------------------------------- operations
    def _spawn(self, a, p, n):
        if a.cool != 0:                        # cooldown still running
            self._count("spawn_blocked", self.game)
            return
        for j in range(n):
            b = self.objs[j]
            if b.enabled or b.cls != p["pool"] or b.owner != a.owner:
                continue
            b.load(self._rom_obj(j))           # template from ROM
            sp = b.vx
            hx, hy = HX[a.dir], HY[a.dir]
            if hx > 0:
                b.x = s11(a.x + a.w)
            elif hx < 0:
                b.x = s11(a.x - b.w)
            else:
                b.x = s11(a.x + ((a.w - b.w) >> 1))
            if hy < 0:
                b.y = s11(a.y - b.h)
            elif hy > 0:
                b.y = s11(a.y + a.h)
            else:
                b.y = s11(a.y + ((a.h - b.h) >> 1))
            b.vx, b.vy = s6(hx * sp), s6(hy * sp)
            b.enabled = 1
            b.dir = a.dir
            b.owner = a.owner
            a.cool = p["cooldown"]
            self._count("spawn", self.game)
            return
        self._count("spawn_blocked", self.game)

    def _split(self, b, cls, skip):
        """Disable b and put up to two fragments of class cls at its centre,
        flying at v + rot90(v) and v - rot90(v), where v is b's velocity.
        Slot `skip` (the object whose rule is running) is never used as a
        fragment, even if that rule has just disabled it."""
        n = min(self.cfg["n_obj"], gf.MAX_OBJ)
        px, py, pw, ph, vx, vy, own = b.x, b.y, b.w, b.h, b.vx, b.vy, b.owner
        b.enabled = 0
        for fvx, fvy in ((sat31(vx - vy), sat31(vy + vx)), (sat31(vx + vy), sat31(vy - vx))):
            for k in range(n):
                f = self.objs[k]
                if k == skip or f.enabled or f.cls != cls or f.owner != own:
                    continue
                f.load(self._rom_obj(k))
                f.x = s11(px + ((pw - f.w) >> 1))
                f.y = s11(py + ((ph - f.h) >> 1))
                f.vx, f.vy = s6(fvx), s6(fvy)
                f.enabled = 1
                f.owner = own
                self._count("feature", "split_fragment")
                break

    def _boundary(self, a):
        """Arena boundary handling for an object that just moved.
        Returns the edge mask {BOTTOM, TOP, RIGHT, LEFT}."""
        edges = self._boundary_raw(a)
        if edges:
            self._count("feature", "edge:" + gf.enum_name(gf.BMODE, a.bmode))
        return edges

    def _boundary_raw(self, a):
        c = self.cfg
        xr, yb = a.x + a.w, a.y + a.h
        lo_x, hi_x = a.x < c["xmin"], xr > c["xmax"]
        lo_y, hi_y = a.y < c["ymin"], yb > c["ymax"]
        edges = 0
        if a.bmode in (gf.BMODE["CLAMP"], gf.BMODE["BOUNCE"]):
            bounce = a.bmode == gf.BMODE["BOUNCE"]
            if lo_x:
                a.x = s11(c["xmin"])
                a.vx = abs6(a.vx) if bounce else 0
                edges |= 1
            elif hi_x:
                a.x = s11(c["xmax"] - a.w)
                a.vx = s6(-abs6(a.vx)) if bounce else 0
                edges |= 2
            if lo_y:
                a.y = s11(c["ymin"])
                a.vy = abs6(a.vy) if bounce else 0
                edges |= 4
            elif hi_y:
                a.y = s11(c["ymax"] - a.h)
                a.vy = s6(-abs6(a.vy)) if bounce else 0
                edges |= 8
        elif a.bmode == gf.BMODE["WRAP"]:
            if xr <= c["xmin"]:
                a.x = s11(c["xmax"])
                edges |= 1
            elif a.x >= c["xmax"]:
                a.x = s11(c["xmin"] - a.w)
                edges |= 2
            if yb <= c["ymin"]:
                a.y = s11(c["ymax"])
                edges |= 4
            elif a.y >= c["ymax"]:
                a.y = s11(c["ymin"] - a.h)
                edges |= 8
        else:                                   # DESTROY
            if lo_x:
                edges |= 1
            elif hi_x:
                edges |= 2
            if lo_y:
                edges |= 4
            elif hi_y:
                edges |= 8
            if edges:
                a.enabled = 0
        return edges

    def _player(self, sel, a, b):
        def opp(o):
            return 2 if o == 1 else 1 if o == 2 else 0
        if sel == 1:
            return a.owner
        if sel == 2:
            return b.owner if b is not None else 0
        if sel == 3:
            return opp(a.owner)
        if sel == 4:
            return opp(b.owner) if b is not None else 0
        if sel == 5:
            return 1
        if sel == 6:
            return 2
        return 0

    def _spin(self, p, q):
        c = self.cfg
        if q == 0:
            return p
        t = p + c["spin_step"] if q > 0 else p - c["spin_step"]
        return max(-c["spin_max"], min(c["spin_max"], t))

    def _scan(self, evt, i, j, edges, axis_x, low, gone):
        """Scan the rule table for one event; fire every matching rule."""
        c = self.cfg
        a = self.objs[i]
        b = self.objs[j] if j is not None else None
        stop = False
        for r in range(c["n_rule"]):
            if stop:
                break
            base = c["rule_base"] + 2 * r
            R = gf.unpack(gf.RULE_FIELDS, [self.rom[base & 0x7FF], self.rom[(base + 1) & 0x7FF]])
            if R["event"] != evt or R["self"] != a.cls:
                continue
            if evt == COLLIDE:
                rel = R["owner_rel"]
                if R["other"] != b.cls:
                    continue
                if not (rel == 0 or (rel == 1 and a.owner == b.owner)
                        or (rel == 2 and a.owner != b.owner)):
                    continue
            elif not (R["other"] & edges):
                continue

            self._count("rule", self.game, r)
            self._feature(R, evt)
            # ---- step 1: motion response and ownership (collisions only) ---
            if evt == COLLIDE:
                mo = R["motion"]
                if mo in (gf.MOTION["BOUNCE"], gf.MOTION["STOP"]):
                    bounce = mo == gf.MOTION["BOUNCE"]
                    if axis_x:
                        a.x = s11(b.x - a.w) if low else s11(b.x + b.w)
                        if not bounce:
                            a.vx = 0
                        else:
                            a.vx = s6(-abs6(a.vx)) if low else abs6(a.vx)
                            if R["spin"]:
                                a.vy = s6(self._spin(a.vy, b.vy))
                    else:
                        a.y = s11(b.y - a.h) if low else s11(b.y + b.h)
                        if not bounce:
                            a.vy = 0
                        else:
                            a.vy = s6(-abs6(a.vy)) if low else abs6(a.vy)
                            if R["spin"]:
                                a.vx = s6(self._spin(a.vx, b.vx))
                if R["copy_owner"]:
                    a.owner = b.owner
                if R["copy_color"]:
                    a.color = b.color

            # ---- step 2: score, then self fate, then other fate -------------
            p = self._player(R["score_sel"], a, b)
            if p in (1, 2):
                if R["counter"]:
                    self.lives[p - 1] = max(0, min(gf.LIVES_MAX, self.lives[p - 1] + R["score_delta"]))
                else:
                    self.score[p - 1] = max(0, min(99, self.score[p - 1] + R["score_delta"]))
            sf = R["self_fate"]
            if sf == gf.FATE["DAMAGE"]:
                if a.hp <= 1:
                    a.hp = 0
                    a.enabled = 0
                    gone = stop = True
                else:
                    a.hp -= 1
            elif sf == gf.FATE["DESTROY"]:
                a.enabled = 0
                gone = stop = True
            elif sf == gf.FATE["RESPAWN"]:
                a.load(self._rom_obj(i))
                if R["flip_x"]:
                    a.vx = s6(-a.vx)
                if R["flip_y"]:
                    a.vy = s6(-a.vy)
                gone = stop = True
            if evt == COLLIDE:
                of = R["other_fate"]
                if of == gf.FATE["DAMAGE"]:
                    if b.hp <= 1:
                        b.hp = 0
                        b.enabled = 0
                    else:
                        b.hp -= 1
                elif of == gf.FATE["DESTROY"]:
                    b.enabled = 0
                elif of == gf.FATE["RESPAWN"]:
                    b.load(self._rom_obj(j))
                elif of == gf.FATE["SPLIT"]:
                    self._split(b, R["split_class"], i)
                    stop = True
            if R["last"]:
                stop = True
        return gone

    # ---------------------------------------------------------------- dumps
    def dump_line(self):
        """Text line in the format written by sim/tb_cosim.v."""
        return "%d %02x %02x %x %x %s" % (self.gstate, self.score[0], self.score[1],
                                          self.lives[0], self.lives[1],
                                    "".join("%024x" % o.packed() for o in self.objs))

    # --------------------------------------------------------------- render
    def render(self):
        """Expected picture: SCREEN_H rows of SCREEN_W 12-bit RGB values."""
        c = self.cfg
        digits = [self.score[0] // 10, self.score[0] % 10,
                  self.score[1] // 10, self.score[1] % 10]
        dx0 = [c["hud_p1_x"], c["hud_p1_x"] + 24, c["hud_p2_x"], c["hud_p2_x"] + 24]
        frame = []
        for y in range(gf.SCREEN_H):
            row = [0] * gf.SCREEN_W
            nslot = 0
            for o in self.objs:
                if not o.enabled or o.color == 0 or not (o.y <= y < o.y + o.h):
                    continue
                if o.tmode == gf.TMODE["SHIELD"] and o.timer & 4:
                    continue                     # shielded objects blink: hidden 4 frames in 8
                xl, xr = max(o.x, 0), min(o.x + o.w, gf.SCREEN_W)
                if xr <= xl:
                    continue
                if nslot == gf.N_SLOTS:        # line overflow: later objects are dropped
                    continue
                nslot += 1
                row[xl:xr] = [o.color] * (xr - xl)
                if o.mark:                      # facing marker: a second slot, drawn on top
                    mx, my = marker_xy(o)
                    ml, mr = max(mx, 0), min(mx + 4, gf.SCREEN_W)
                    if my <= y < my + 4 and mr > ml and nslot < gf.N_SLOTS:
                        nslot += 1
                        row[ml:mr] = [c["mark_color"]] * (mr - ml)
            if c["hud_en"] and c["hud_y"] <= y < c["hud_y"] + 36:
                for d in range(4):
                    seg = SEGMENTS[digits[d]]
                    for x in range(dx0[d], min(dx0[d] + 20, gf.SCREEN_W)):
                        if hud_pixel(seg, x - dx0[d], y - c["hud_y"]):
                            row[x] = 1 if d < 2 else 2
            if c["hud_en"] and c["init_lives"] and c["hud_y"] + 40 <= y < c["hud_y"] + 46:
                for pl, x0 in ((0, c["hud_p1_x"]), (1, c["hud_p2_x"])):
                    for k in range(self.lives[pl]):
                        for x in range(x0 + 10 * k, min(x0 + 10 * k + 6, gf.SCREEN_W)):
                            row[x] = 1 + pl
            if self.gstate:
                for x in range(gf.SCREEN_W):
                    if x < 8 or x >= gf.SCREEN_W - 8 or y < 8 or y >= gf.SCREEN_H - 8:
                        row[x] = (self.gstate if self.gstate != 3
                                  else (1 if x < gf.SCREEN_W // 2 else 2))
            frame.append([self.pal[i] for i in row])
        return frame


def marker_xy(o):
    """Top-left corner of the 4 x 4 facing marker: inside the object, on the
    edge (or corner) it faces."""
    hx, hy = HX[o.dir], HY[o.dir]
    mx = o.x + o.w - 4 if hx > 0 else o.x if hx < 0 else o.x + ((o.w - 4) >> 1)
    my = o.y if hy < 0 else o.y + o.h - 4 if hy > 0 else o.y + ((o.h - 4) >> 1)
    return mx, my


# seven-segment patterns, bit 0 = a ... bit 6 = g
SEGMENTS = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F]


def hud_pixel(seg, dx, dy):
    """Is pixel (dx, dy) of a 20x36 digit cell lit for segment mask seg?"""
    top, mid, bot = dy < 4, 16 <= dy < 20, dy >= 32
    left, right = dx < 4, dx >= 16
    upper, lower = dy < 20, dy >= 16
    return bool((seg & 0x01 and top) or (seg & 0x02 and right and upper)
                or (seg & 0x04 and right and lower) or (seg & 0x08 and bot)
                or (seg & 0x10 and left and lower) or (seg & 0x20 and left and upper)
                or (seg & 0x40 and mid))


# ---------------------------------------------------------------------------
# Picture helpers (PNG writer without third-party libraries)
# ---------------------------------------------------------------------------
def frame_to_png(frame, path, scale=1):
    h, w = len(frame), len(frame[0])
    raw = bytearray()
    for row in frame:
        line = bytearray()
        for p in row:
            px = bytes((((p >> 8) & 15) * 17, ((p >> 4) & 15) * 17, (p & 15) * 17))
            line += px * scale
        for _ in range(scale):
            raw += b"\x00" + line

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w * scale, h * scale, 8, 2, 0, 0, 0)))
        fh.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        fh.write(chunk(b"IEND", b""))


def read_frame_dump(path):
    """Read a frame written by sim/tb_core.v: one 3-digit hex RGB per pixel."""
    with open(path, "r") as fh:
        vals = [int(t, 16) for t in fh.read().split()]
    if len(vals) != gf.SCREEN_W * gf.SCREEN_H:
        raise ValueError("%s: %d pixels, expected %d" % (path, len(vals), gf.SCREEN_W * gf.SCREEN_H))
    return [vals[y * gf.SCREEN_W:(y + 1) * gf.SCREEN_W] for y in range(gf.SCREEN_H)]


if __name__ == "__main__":
    # python3 tools/gemodel.py build/games.mem <slot> <frames> out.png
    rom = read_mem(sys.argv[1])
    m = Model(rom)
    m.load(int(sys.argv[2]))
    for _ in range(int(sys.argv[3])):
        m.step(0)
    frame_to_png(m.render(), sys.argv[4])
    print("wrote", sys.argv[4])
