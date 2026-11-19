#!/usr/bin/env python3
"""
gamec.py - game-definition compiler for the BRAM game engine.

    python3 tools/gamec.py games/pong.json games/breakout.json \
            games/tank.json games/race.json -o build

Reads up to four JSON game definitions (slot 0..3 in command-line order),
validates them, packs them into the binary format defined in geformat.py
and writes:

    games.mem         $readmemh image (simulation and inferred BRAM)
    games.coe         Vivado Block Memory Generator image (same words)
    games.lst         annotated listing: every word with its decoded fields
    memory_map.txt    address map, storage usage, cycle and scanline budgets
    games_meta.json   name -> index tables for tools and testbenches

Other modes:

    --emit-vh FILE        write the Verilog header generated from geformat.py
    --update-doc FILE     refresh generated field tables inside a markdown file

Standard library only.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import geformat as gf  # noqa: E402


class CompileError(Exception):
    pass


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
def _err(where, msg):
    raise CompileError("%s: %s" % (where, msg))


def _strip_comments(obj):
    """Remove "//" keys (JSON has no comments, so definitions use this key)."""
    if isinstance(obj, dict):
        return dict((k, _strip_comments(v)) for k, v in obj.items() if k != "//")
    if isinstance(obj, list):
        return [_strip_comments(v) for v in obj]
    return obj


def _keys(where, d, required, optional=()):
    if not isinstance(d, dict):
        _err(where, "expected an object {...}")
    for k in required:
        if k not in d:
            _err(where, "missing key '%s'" % k)
    for k in d:
        if k not in required and k not in optional:
            _err(where, "unknown key '%s' (allowed: %s)"
                 % (k, ", ".join(list(required) + list(optional))))


def _int(where, name, v, lo, hi):
    if isinstance(v, bool) or not isinstance(v, int):
        _err(where, "'%s' must be an integer, got %r" % (name, v))
    if v < lo or v > hi:
        _err(where, "'%s' = %d is outside %d..%d" % (name, v, lo, hi))
    return v


def _bool(where, name, v):
    if not isinstance(v, bool):
        _err(where, "'%s' must be true or false, got %r" % (name, v))
    return int(v)


def _enum(where, name, v, table):
    if not isinstance(v, str) or v not in table:
        _err(where, "'%s' = %r is not supported (choose from %s)"
             % (name, v, ", ".join(table)))
    return table[v]


def _color(where, s):
    if (not isinstance(s, str) or len(s) != 4 or s[0] != "#"
            or any(c not in "0123456789abcdefABCDEF" for c in s[1:])):
        _err(where, "colour %r must be written as \"#RGB\" (4 bits per channel)" % (s,))
    return int(s[1:], 16)


# ---------------------------------------------------------------------------
# Parsing + validation of one game
# ---------------------------------------------------------------------------
class Game(object):
    """A validated game with all names resolved to numbers."""

    def __init__(self):
        self.name = ""
        self.title = ""
        self.source = ""
        self.hdr = {}            # header fields except the table addresses
        self.palette = []        # [(name, rgb12)]
        self.classes = []        # [(name, controlled)]
        self.objects = []        # list of dicts with numeric OBJ fields + meta
        self.inputs = []         # list of dicts: numeric INP fields + meta
        self.rules = []          # list of dicts: numeric RULE fields + meta
        self.warnings = []
        self.addr = {}           # filled by the linker
        self.slot = None

    # convenience -----------------------------------------------------------
    def class_name(self, cid):
        return self.classes[cid][0] if cid < len(self.classes) else "class%d" % cid

    def obj_index(self, name):
        for i, o in enumerate(self.objects):
            if o["_name"] == name:
                return i
        raise KeyError(name)


def parse_game(path):
    with open(path, "r") as fh:
        try:
            raw = json.load(fh)
        except ValueError as e:
            raise CompileError("%s: not valid JSON: %s" % (path, e))
    return build_game(_strip_comments(raw), path)


def build_game(raw, source="<dict>", strict=True):
    """Validate one game. strict=False turns the scanline and cycle-budget
    limits into warnings (used by tests that provoke those conditions)."""
    g = Game()
    g.strict = strict
    g.source = source
    W = os.path.basename(source)
    _keys(W, raw,
          ["name", "arena", "palette", "classes", "objects", "inputs", "rules"],
          ["title", "win_score", "init_score", "lose_at_zero", "spin", "hud",
           "lives", "wave", "mark_color"])
    g.name = raw["name"]
    if not isinstance(g.name, str) or not g.name:
        _err(W, "'name' must be a non-empty string")
    g.title = raw.get("title", g.name)
    W = g.name

    # ---- arena -------------------------------------------------------------
    a = raw["arena"]
    _keys(W + ".arena", a, ["xmin", "xmax", "ymin", "ymax"])
    hdr = {}
    for k in ("xmin", "xmax", "ymin", "ymax"):
        hdr[k] = _int(W + ".arena", k, a[k], gf.ARENA_MIN, gf.ARENA_MAX)
    if hdr["xmin"] >= hdr["xmax"] or hdr["ymin"] >= hdr["ymax"]:
        _err(W + ".arena", "min must be smaller than max on both axes")

    # ---- end conditions ----------------------------------------------------
    hdr["win_score"] = _int(W, "win_score", raw.get("win_score", 0), 0, 99)
    hdr["init_score"] = _int(W, "init_score", raw.get("init_score", 0), 0, 99)
    hdr["lose_at_zero"] = _bool(W, "lose_at_zero", raw.get("lose_at_zero", False))
    hdr["init_lives"] = _int(W, "lives", raw.get("lives", 0), 0, gf.LIVES_MAX)
    if hdr["lose_at_zero"] and hdr["init_lives"] == 0:
        _err(W, "lose_at_zero needs lives >= 1, otherwise the game is a draw at once")
    if hdr["win_score"] and hdr["init_score"] >= hdr["win_score"]:
        _err(W, "init_score must be below win_score")
    if not hdr["win_score"] and not hdr["lose_at_zero"]:
        g.warnings.append("no end condition: neither win_score nor lose_at_zero is set")

    sp = raw.get("spin", {"step": 0, "max": 0})
    _keys(W + ".spin", sp, ["step", "max"])
    hdr["spin_step"] = _int(W + ".spin", "step", sp["step"], 0, 7)
    hdr["spin_max"] = _int(W + ".spin", "max", sp["max"], 0, gf.VEL_MAX)

    hud = raw.get("hud", {"enabled": False, "p1_x": 0, "p2_x": 0, "y": 0})
    _keys(W + ".hud", hud, ["p1_x", "p2_x", "y"], ["enabled"])
    hdr["hud_en"] = _bool(W + ".hud", "enabled", hud.get("enabled", True))
    hdr["hud_p1_x"] = _int(W + ".hud", "p1_x", hud["p1_x"], 0, gf.SCREEN_W - 44)
    hdr["hud_p2_x"] = _int(W + ".hud", "p2_x", hud["p2_x"], 0, gf.SCREEN_W - 44)
    hdr["hud_y"] = _int(W + ".hud", "y", hud["y"], 0, gf.SCREEN_H - 36)
    width = 90 if hdr["init_lives"] else 44     # nine life pips are 86 pixels wide
    if hdr["hud_en"] and abs(hdr["hud_p1_x"] - hdr["hud_p2_x"]) < width:
        _err(W + ".hud", "the two score displays overlap (each is %d pixels wide)" % width)
    if hdr["hud_en"] and hdr["init_lives"]:
        if max(hdr["hud_p1_x"], hdr["hud_p2_x"]) > gf.SCREEN_W - 90 or hdr["hud_y"] > gf.SCREEN_H - 46:
            _err(W + ".hud", "with lives the display needs 90 x 46 pixels on screen")
    g.hdr = hdr

    # ---- palette -----------------------------------------------------------
    pal = raw["palette"]
    if not isinstance(pal, list) or not (3 <= len(pal) <= gf.N_PAL):
        _err(W + ".palette", "need a list of 3..%d [name, \"#RGB\"] pairs "
             "(index 0 background, 1 player 1, 2 player 2)" % gf.N_PAL)
    pal_idx = {}
    for i, ent in enumerate(pal):
        where = "%s.palette[%d]" % (W, i)
        if not isinstance(ent, list) or len(ent) != 2 or not isinstance(ent[0], str):
            _err(where, "expected [name, \"#RGB\"]")
        if ent[0] in pal_idx:
            _err(where, "duplicate colour name '%s'" % ent[0])
        pal_idx[ent[0]] = i
        g.palette.append((ent[0], _color(where, ent[1])))

    # ---- classes -----------------------------------------------------------
    cls = raw["classes"]
    if not isinstance(cls, list) or not (1 <= len(cls) <= gf.N_CLASS):
        _err(W + ".classes", "need a list of 1..%d classes" % gf.N_CLASS)
    cls_idx = {}
    for i, c in enumerate(cls):
        where = "%s.classes[%d]" % (W, i)
        _keys(where, c, ["name"], ["controlled"])
        if c["name"] in cls_idx:
            _err(where, "duplicate class name '%s'" % c["name"])
        cls_idx[c["name"]] = i
        g.classes.append((c["name"], _bool(where, "controlled", c.get("controlled", False))))

    # ---- facing marker colour, wave reload ----------------------------------
    mc = raw.get("mark_color", g.palette[min(3, len(g.palette) - 1)][0])
    if mc not in pal_idx:
        _err(W, "mark_color %r is not in the palette" % (mc,))
    hdr["mark_color"] = pal_idx[mc]
    wave = raw.get("wave", {"watch": [], "reload": []})
    _keys(W + ".wave", wave, ["watch", "reload"])
    for k in ("watch", "reload"):
        if not isinstance(wave[k], list):
            _err(W + ".wave", "'%s' must be a list of class names" % k)
        m = 0
        for c in wave[k]:
            m |= 1 << _enum(W + ".wave", k, c, cls_idx)
        hdr["wave_" + k] = m
    if bool(hdr["wave_watch"]) != bool(hdr["wave_reload"]):
        _err(W + ".wave", "give both 'watch' and 'reload', or neither")

    # ---- objects -----------------------------------------------------------
    if not isinstance(raw["objects"], list):
        _err(W + ".objects", "expected a list")
    for oi, o in enumerate(raw["objects"]):
        where = "%s.objects[%d]" % (W, oi)
        _keys(where, o, ["class", "x", "y", "w", "h", "color"],
              ["name", "owner", "vx", "vy", "bmode", "tmode", "timer", "hp",
               "dir", "enabled", "pool", "repeat", "mark"])
        rep = o.get("repeat", {"nx": 1, "ny": 1, "dx": 0, "dy": 0})
        _keys(where + ".repeat", rep, ["nx", "ny", "dx", "dy"])
        nx = _int(where + ".repeat", "nx", rep["nx"], 1, gf.MAX_OBJ)
        ny = _int(where + ".repeat", "ny", rep["ny"], 1, gf.MAX_OBJ)
        dx = _int(where + ".repeat", "dx", rep["dx"], -1023, 1023)
        dy = _int(where + ".repeat", "dy", rep["dy"], -1023, 1023)
        pool = _bool(where, "pool", o.get("pool", False))
        enabled = _bool(where, "enabled", o.get("enabled", not pool))
        if pool and enabled:
            _err(where, "a pool object must start disabled (remove \"enabled\": true)")
        if not isinstance(o["color"], str) or o["color"] not in pal_idx:
            _err(where, "colour %r is not in the palette" % (o["color"],))
        base = {
            "w": _int(where, "w", o["w"], 1, 1023),
            "h": _int(where, "h", o["h"], 1, 1023),
            "vx": _int(where, "vx", o.get("vx", 0), -gf.VEL_MAX, gf.VEL_MAX),
            "vy": _int(where, "vy", o.get("vy", 0), -gf.VEL_MAX, gf.VEL_MAX),
            "color": pal_idx[o["color"]],
            "class": _enum(where, "class", o["class"], cls_idx),
            "owner": _enum(where, "owner", o.get("owner", "NONE"), gf.OWNER),
            "enabled": enabled,
            "bmode": _enum(where, "bmode", o.get("bmode", "CLAMP"), gf.BMODE),
            "tmode": _enum(where, "tmode", o.get("tmode", "COUNTDOWN"), gf.TMODE),
            "dir": _enum(where, "dir", gf.HEADING_ALIAS.get(o.get("dir", "E"), o.get("dir", "E")),
                         gf.HEADING),
            "mark": _bool(where, "mark", o.get("mark", False)),
            "cool": 0,
            "hp": _int(where, "hp", o.get("hp", 0), 0, 15),
            "timer": _int(where, "timer", o.get("timer", 0), 0, 255),
        }
        x0 = _int(where, "x", o["x"], gf.COORD_MIN, gf.COORD_MAX)
        y0 = _int(where, "y", o["y"], gf.COORD_MIN, gf.COORD_MAX)
        nm = o.get("name", "%s%d" % (o["class"].lower(), oi))
        for iy in range(ny):
            for ix in range(nx):
                rec = dict(base)
                rec["x"] = _int(where, "x (after repeat)", x0 + ix * dx,
                                gf.COORD_MIN, gf.COORD_MAX)
                rec["y"] = _int(where, "y (after repeat)", y0 + iy * dy,
                                gf.COORD_MIN, gf.COORD_MAX)
                rec["_pool"] = pool
                rec["_name"] = nm if nx * ny == 1 else "%s[%d,%d]" % (nm, ix, iy)
                rec["_where"] = where
                g.objects.append(rec)
    if len(g.objects) > gf.MAX_OBJ:
        _err(W + ".objects", "%d objects after repeat expansion, capacity is %d"
             % (len(g.objects), gf.MAX_OBJ))
    names = [o["_name"] for o in g.objects]
    for n in names:
        if names.count(n) > 1:
            _err(W + ".objects", "duplicate object name '%s'" % n)

    # ---- input mappings ----------------------------------------------------
    if not isinstance(raw["inputs"], list):
        _err(W + ".inputs", "expected a list")
    if len(raw["inputs"]) > gf.MAX_INP:
        _err(W + ".inputs", "%d mappings, capacity is %d" % (len(raw["inputs"]), gf.MAX_INP))
    for ii, m in enumerate(raw["inputs"]):
        where = "%s.inputs[%d]" % (W, ii)
        if not isinstance(m, dict) or "op" not in m:
            _err(where, "missing key 'op'")
        op = _enum(where, "op", m["op"], gf.OP)
        rec = {"op": op}
        if m["op"] == "MOVE":
            _keys(where, m, ["button", "class", "op", "dir", "speed"],
                  ["trigger", "owner", "set_facing"])
            par = {
                "dir": _enum(where, "dir", m["dir"], gf.DIR),
                "set_facing": _bool(where, "set_facing", m.get("set_facing", False)),
                "speed": _int(where, "speed", m["speed"], 0, gf.VEL_MAX),
            }
            rec["param"] = gf.pack(gf.MOVE_FIELDS, par, 1, where)[0]
            rec["_par"] = par
        else:
            _keys(where, m, ["button", "class", "op", "pool"],
                  ["trigger", "owner", "cooldown"])
            par = {
                "pool": _enum(where, "pool", m["pool"], cls_idx),
                "cooldown": _int(where, "cooldown", m.get("cooldown", 0), 0, gf.COOL_MAX),
            }
            rec["param"] = gf.pack(gf.SPAWN_FIELDS, par, 1, where)[0]
            rec["_par"] = par
        rec["button"] = _enum(where, "button", m["button"], gf.BUTTON)
        rec["trigger"] = _enum(where, "trigger", m.get("trigger", "HELD"), gf.TRIGGER)
        rec["class"] = _enum(where, "class", m["class"], cls_idx)
        rec["owner"] = _enum(where, "owner", m.get("owner", "NONE"), gf.OWNER)
        rec["_where"] = where
        rec["_src"] = m
        g.inputs.append(rec)

    # ---- rules -------------------------------------------------------------
    if not isinstance(raw["rules"], list):
        _err(W + ".rules", "expected a list")
    if len(raw["rules"]) > gf.MAX_RULE:
        _err(W + ".rules", "%d rules, capacity is %d" % (len(raw["rules"]), gf.MAX_RULE))
    for ri, r in enumerate(raw["rules"]):
        where = "%s.rules[%d]" % (W, ri)
        if not isinstance(r, dict) or "event" not in r:
            _err(where, "missing key 'event'")
        ev = _enum(where, "event", r["event"], gf.EVENT)
        common = ["score", "self_fate", "flip_x", "flip_y", "last"]
        if r["event"] == "COLLIDE":
            _keys(where, r, ["event", "self", "other"],
                  common + ["owner_rel", "motion", "spin", "copy_owner",
                            "copy_color", "other_fate", "split"])
            other = _enum(where, "other", r["other"], cls_idx)
        else:
            # EDGE events have no "other" object, so every action that needs
            # one is rejected here instead of being silently ignored.
            _keys(where, r, ["event", "self", "edges"], common)
            edges = r["edges"]
            if not isinstance(edges, list) or not edges:
                _err(where, "'edges' must be a non-empty list of LEFT/RIGHT/TOP/BOTTOM")
            other = 0
            for e in edges:
                other |= _enum(where, "edges", e, gf.EDGE)
        sc = r.get("score", {"player": "NONE", "delta": 0})
        _keys(where + ".score", sc, ["player", "delta"], ["counter"])
        counter = _enum(where + ".score", "counter", sc.get("counter", "SCORE"), gf.COUNTER)
        sel = _enum(where + ".score", "player", sc["player"], gf.SCORE_SEL)
        delta = _int(where + ".score", "delta", sc["delta"], -8, 7)
        if (sel == 0) != (delta == 0):
            _err(where + ".score", "use player NONE with delta 0, or a player with a non-zero delta")
        if r["event"] == "EDGE" and sc["player"] in ("OTHER_OWNER", "OTHER_OPPONENT"):
            _err(where + ".score", "an EDGE event has no other object; player %s is not supported"
                 % sc["player"])
        rec = {
            "event": ev,
            "self": _enum(where, "self", r["self"], cls_idx),
            "other": other,
            "owner_rel": _enum(where, "owner_rel", r.get("owner_rel", "ANY"), gf.OWNER_REL),
            "last": _bool(where, "last", r.get("last", False)),
            "motion": _enum(where, "motion", r.get("motion", "NONE"), gf.MOTION),
            "spin": _bool(where, "spin", r.get("spin", False)),
            "copy_owner": _bool(where, "copy_owner", r.get("copy_owner", False)),
            "copy_color": _bool(where, "copy_color", r.get("copy_color", False)),
            "score_sel": sel,
            "score_delta": delta,
            "self_fate": _enum(where, "self_fate", r.get("self_fate", "NONE"), gf.FATE),
            "other_fate": _enum(where, "other_fate", r.get("other_fate", "NONE"), gf.FATE),
            "flip_x": _bool(where, "flip_x", r.get("flip_x", False)),
            "flip_y": _bool(where, "flip_y", r.get("flip_y", False)),
            "counter": counter,
            "split_class": 0,
        }
        if rec["self_fate"] == gf.FATE["SPLIT"]:
            _err(where, "SPLIT is only defined as an other_fate")
        if rec["other_fate"] == gf.FATE["SPLIT"]:
            if "split" not in r:
                _err(where, "other_fate SPLIT needs \"split\": <class of the fragments>")
            rec["split_class"] = _enum(where, "split", r["split"], cls_idx)
        elif "split" in r:
            _err(where, "\"split\" only applies to other_fate SPLIT")
        if counter == gf.COUNTER["LIVES"] and not hdr["init_lives"]:
            _err(where, "rule changes lives but the game has no \"lives\"")
        if rec["spin"] and rec["motion"] != gf.MOTION["BOUNCE"]:
            _err(where, "spin is only defined together with motion BOUNCE")
        if rec["spin"] and (hdr["spin_step"] == 0 or hdr["spin_max"] == 0):
            _err(where, "rule uses spin but the game's spin step/max is 0")
        if (rec["flip_x"] or rec["flip_y"]) and rec["self_fate"] != gf.FATE["RESPAWN"]:
            _err(where, "flip_x / flip_y only apply to self_fate RESPAWN")
        rec["_where"] = where
        rec["_src"] = r
        g.rules.append(rec)

    _semantic_checks(g)
    return g


# ---------------------------------------------------------------------------
# Cross-record checks, derived masks, budgets
# ---------------------------------------------------------------------------
def _class_speed(g, cid):
    """Largest per-axis speed an object of this class can reach."""
    s = 0
    for o in g.objects:
        if o["class"] == cid:
            s = max(s, abs(o["vx"]), abs(o["vy"]))
    for m in g.inputs:
        if m["op"] == gf.OP["MOVE"] and m["class"] == cid:
            s = max(s, m["_par"]["speed"])
    for r in g.rules:
        if r["spin"] and r["self"] == cid:
            s = max(s, g.hdr["spin_max"])
    return s


def is_movable(g, o):
    """(can x change, can y change) over the whole game for this object.

    Used by the scanline analysis: an object whose y can never change only
    occupies renderer slots on the lines it covers at load time.
    """
    cid = o["class"]
    mx = bool(o["vx"]) or o["_pool"]
    my = bool(o["vy"]) or o["_pool"]
    for m in g.inputs:
        if m["op"] == gf.OP["MOVE"] and m["class"] == cid:
            if m["_par"]["dir"] in (gf.DIR["LEFT"], gf.DIR["RIGHT"]):
                mx = True
            else:
                my = True
    for r in g.rules:
        if r["event"] == gf.EVENT["COLLIDE"] and r["self"] == cid and r["motion"]:
            mx = my = True          # push-out and spin can act on either axis
    return mx, my


def _semantic_checks(g):
    W = g.name
    hdr = g.hdr
    ncls = len(g.classes)

    coll = 0
    for r in g.rules:
        if r["event"] == gf.EVENT["COLLIDE"]:
            coll |= 1 << r["self"]
    ctl = 0
    for cid, (_n, c) in enumerate(g.classes):
        if c:
            ctl |= 1 << cid
    hdr["collider_mask"] = coll
    hdr["controlled_mask"] = ctl

    by_class = dict((c, []) for c in range(ncls))
    for o in g.objects:
        by_class[o["class"]].append(o)

    # objects that move must fit in the arena, pool templates must be usable
    aw = hdr["xmax"] - hdr["xmin"]
    ah = hdr["ymax"] - hdr["ymin"]
    for o in g.objects:
        if any(is_movable(g, o)) and (o["w"] > aw or o["h"] > ah):
            _err(o["_where"], "movable object '%s' is larger than the arena" % o["_name"])
        if o["w"] > gf.SCREEN_W or o["h"] > gf.SCREEN_W:
            _err(o["_where"], "object '%s': w and h are limited to %d so that edge "
                 "arithmetic cannot overflow" % (o["_name"], gf.SCREEN_W))
        if o["_pool"] and not (1 <= o["vx"] <= gf.VEL_MAX and o["vy"] == 0):
            _err(o["_where"], "pool object '%s': vx is the launch speed and must be "
                 "1..%d, vy must be 0" % (o["_name"], gf.VEL_MAX))

    for m in g.inputs:
        tgt = [o for o in by_class[m["class"]]
               if m["owner"] == 0 or o["owner"] == m["owner"]]
        if not tgt:
            g.warnings.append("%s: no object matches class %s / owner filter"
                              % (m["_where"], g.class_name(m["class"])))
        if m["op"] == gf.OP["MOVE"]:
            if not g.classes[m["class"]][1]:
                g.warnings.append("%s: class %s is not 'controlled', so the velocity "
                                  "set by MOVE persists after the key is released"
                                  % (m["_where"], g.class_name(m["class"])))
        else:
            pool = [o for o in by_class[m["_par"]["pool"]] if o["_pool"]]
            if not pool:
                _err(m["_where"], "SPAWN pool class %s has no object with \"pool\": true"
                     % g.class_name(m["_par"]["pool"]))
            for s in tgt:
                if not [p for p in pool if p["owner"] == s["owner"]]:
                    _err(m["_where"], "spawner '%s' (owner %s) has no pool object of class "
                         "%s with the same owner" % (s["_name"],
                                                     gf.enum_name(gf.OWNER, s["owner"]),
                                                     g.class_name(m["_par"]["pool"])))

    for r in g.rules:
        if r["other_fate"] == gf.FATE["SPLIT"]:
            pool = [o for o in by_class[r["split_class"]] if o["_pool"]]
            if not pool:
                _err(r["_where"], "SPLIT fragment class %s has no object with \"pool\": true"
                     % g.class_name(r["split_class"]))
            for o in by_class[r["other"]]:
                if not [p for p in pool if p["owner"] == o["owner"]]:
                    g.warnings.append("%s: '%s' can never split: no %s pool object has its owner"
                                      % (r["_where"], o["_name"], g.class_name(r["split_class"])))
        if not by_class[r["self"]]:
            g.warnings.append("%s: no object has self class %s"
                              % (r["_where"], g.class_name(r["self"])))
        if r["event"] == gf.EVENT["COLLIDE"]:
            if not by_class[r["other"]]:
                g.warnings.append("%s: no object has other class %s"
                                  % (r["_where"], g.class_name(r["other"])))
            # tunnelling: two boxes approaching at rel pixels/frame cannot skip
            # each other if rel is smaller than the sum of their thicknesses
            rel = _class_speed(g, r["self"]) + _class_speed(g, r["other"])
            dims = [min(o["w"], o["h"]) for o in by_class[r["self"]]]
            dimo = [min(o["w"], o["h"]) for o in by_class[r["other"]]]
            if dims and dimo and rel >= min(dims) + min(dimo):
                g.warnings.append("%s: closing speed %d px/frame can tunnel through "
                                  "the thinnest %s/%s pair (%d px)"
                                  % (r["_where"], rel, g.class_name(r["self"]),
                                     g.class_name(r["other"]), min(dims) + min(dimo)))

    g.slot_report = scanline_analysis(g)
    if g.slot_report["worst"] > gf.N_SLOTS and not g.strict:
        g.warnings.append("scanline bound %d exceeds the %d renderer slots"
                          % (g.slot_report["worst"], gf.N_SLOTS))
    elif g.slot_report["worst"] > gf.N_SLOTS:
        _err(W, "scanline %d can hold %d visible objects (%d fixed-row + %d roaming); the "
             "renderer has %d line slots" % (g.slot_report["worst_y"], g.slot_report["worst"],
                                             g.slot_report["worst_static"],
                                             g.slot_report["movable"], gf.N_SLOTS))
    g.cycle_report = cycle_bound(g)
    if g.cycle_report["total"] > gf.UPDATE_BUDGET_CLOCKS and not g.strict:
        g.warnings.append("worst-case update bound %d exceeds the budget" % g.cycle_report["total"])
    elif g.cycle_report["total"] > gf.UPDATE_BUDGET_CLOCKS:
        _err(W, "worst-case update needs %d clocks, the vertical-blanking budget is %d"
             % (g.cycle_report["total"], gf.UPDATE_BUDGET_CLOCKS))


def scanline_analysis(g):
    """Guaranteed upper bound of renderer slots needed on any one scanline.

    Objects whose y can never change are counted on the lines they cover at
    load time; every other visible object is assumed to reach every line.
    """
    fixed = [0] * gf.SCREEN_H
    roaming = 0
    for o in g.objects:
        if o["color"] == 0 or not (o["enabled"] or o["_pool"]):
            continue
        mx, my = is_movable(g, o)
        slots = 2 if o["mark"] else 1        # a facing marker takes a second slot
        if my:
            roaming += slots
            continue
        if not mx and (o["x"] >= gf.SCREEN_W or o["x"] + o["w"] <= 0):
            continue
        for y in range(max(0, o["y"]), min(gf.SCREEN_H, o["y"] + o["h"])):
            fixed[y] += slots
    ws = max(fixed)
    return {"worst": ws + roaming, "worst_static": ws, "movable": roaming,
            "worst_y": fixed.index(ws)}


def cycle_bound(g):
    """Provable upper bound of system clocks for one update.

    Mirrors the state sequence of rtl/game_engine.v (see ARCHITECTURE.md,
    "Cycle budget"). It assumes every key is active, every object is enabled,
    every collider overlaps every other object at once and every matching
    rule fires with the most expensive fates. The only saving it takes is
    the one the hardware guarantees: once a rule disables or respawns the
    object being processed, that object's collision loop ends, so for rule
    groups that always do so only the most expensive one is counted.
    """
    n = len(g.objects)
    R = len(g.rules)
    FIRE = 13                     # extra clocks of a fired rule over a non-matching one
    SPLIT = 2 + 2 * (3 * n + 7)   # write back, then two pool searches, reloads, writes
    scan_base = 4 * R + 1         # read+test every rule, final exit state
    gone = (gf.FATE["DESTROY"], gf.FATE["RESPAWN"])

    def group(event, s, o=None):
        return [r for r in g.rules if r["event"] == event and r["self"] == s
                and (o is None or r["other"] == o)]

    def fire_cost(rules):
        return sum(FIRE + (SPLIT if r["other_fate"] == gf.FATE["SPLIT"] else 0) for r in rules)

    p1 = 4 * n + 1
    p2 = 1
    for m in g.inputs:
        cost = 3 + 1                          # fetch/test the mapping, loop exit
        for o in g.objects:
            cost += 3                         # read + test the object
            if o["class"] == m["class"] and (m["owner"] == 0 or o["owner"] == m["owner"]):
                if m["op"] == gf.OP["MOVE"]:
                    cost += 1 + m["_par"]["set_facing"]
                else:
                    cost += 3 * n + 8
        p2 += cost
    p3 = 1
    n_coll = 0
    for a in g.objects:
        cost = 7 + scan_base + fire_cost(group(gf.EVENT["EDGE"], a["class"]))
        if (g.hdr["collider_mask"] >> a["class"]) & 1:
            n_coll += 1
            cost += 2                         # self-index skip, loop exit
            ending = 0
            for b in g.objects:
                if b is a:
                    continue
                cost += 5 + scan_base
                grp = group(gf.EVENT["COLLIDE"], a["class"], b["class"])
                if grp and all(r["self_fate"] in gone for r in grp):
                    ending = max(ending, fire_cost(grp))     # ends the loop: at most once
                else:
                    cost += fire_cost(grp)
            cost += ending
        p3 += cost
    p4 = 11 * n + 2 if g.hdr["wave_watch"] else 0
    total = 1 + p1 + p2 + p3 + p4 + 1
    return {"prep": p1, "input": p2, "move_collide": p3, "wave": p4, "total": total,
            "colliders": n_coll}


# ---------------------------------------------------------------------------
# Packing + linking
# ---------------------------------------------------------------------------
def _public(d):
    return dict((k, v) for k, v in d.items() if not k.startswith("_"))


class Image(object):
    def __init__(self, depth):
        self.depth = depth
        self.words = [0] * depth
        self.notes = [""] * depth       # listing text per address
        self.games = [None] * gf.N_GAMES
        self.used = 0


def link(games, depth=gf.ROM_DEPTH):
    """Place up to four games behind the directory. Deterministic: the image
    depends only on the game definitions and their order."""
    if len(games) > gf.N_GAMES:
        raise CompileError("at most %d games fit in the directory" % gf.N_GAMES)
    img = Image(depth)
    addr = gf.DIR_WORDS

    def put(a, w, note):
        if a >= depth:
            raise CompileError("ROM overflow: address %d does not fit in %d words" % (a, depth))
        img.words[a] = w
        img.notes[a] = note

    for slot in range(gf.N_GAMES):
        if slot >= len(games) or games[slot] is None:
            put(slot, 0, "DIR[%d] empty slot" % slot)
            continue
        g = games[slot]
        g.slot = slot
        n_obj, n_inp, n_rule = len(g.objects), len(g.inputs), len(g.rules)
        A = {}
        A["hdr"] = addr
        A["pal"] = A["hdr"] + gf.HDR_WORDS
        A["obj"] = A["pal"] + gf.N_PAL
        A["inp"] = A["obj"] + gf.OBJ_WORDS * n_obj
        A["rule"] = A["inp"] + gf.INP_WORDS * n_inp
        A["end"] = A["rule"] + gf.RULE_WORDS * n_rule
        if A["end"] > depth:
            raise CompileError("ROM overflow: game '%s' ends at word %d, depth is %d"
                               % (g.name, A["end"], depth))
        g.addr = A
        addr = A["end"]

        d = gf.pack(gf.DIR_FIELDS, {"hdr_addr": A["hdr"], "version": gf.VERSION, "valid": 1},
                    1, "directory")
        put(slot, d[0], "DIR[%d] -> %s header @0x%03X" % (slot, g.name, A["hdr"]))

        hv = dict(g.hdr)
        hv.update({"magic": gf.MAGIC, "n_obj": n_obj, "n_inp": n_inp, "n_rule": n_rule,
                   "obj_base": A["obj"], "inp_base": A["inp"], "rule_base": A["rule"],
                   "pal_base": A["pal"]})
        g.hdr_full = hv
        hw = gf.pack(gf.HDR_FIELDS, hv, gf.HDR_WORDS, g.name + ".header")
        for k in range(gf.HDR_WORDS):
            fs = ["%s=%d" % (f.name, hv[f.name]) for f in gf.HDR_FIELDS if f.word == k]
            put(A["hdr"] + k, hw[k], "%s H%d  %s" % (g.name, k, " ".join(fs)))

        for i in range(gf.N_PAL):
            nm, rgb = g.palette[i] if i < len(g.palette) else ("-", 0)
            put(A["pal"] + i, rgb, "%s PAL[%d] %s #%03X" % (g.name, i, nm, rgb))

        for i, o in enumerate(g.objects):
            ow = gf.pack(gf.OBJ_FIELDS, _public(o), gf.OBJ_WORDS, o["_where"])
            o["_words"] = ow
            for k in range(gf.OBJ_WORDS):
                fs = ["%s=%d" % (f.name, o[f.name]) for f in gf.OBJ_FIELDS if f.word == k]
                put(A["obj"] + gf.OBJ_WORDS * i + k, ow[k],
                    "%s OBJ[%d].W%d %-16s %s" % (g.name, i, k, o["_name"], " ".join(fs)))

        for i, m in enumerate(g.inputs):
            mw = gf.pack(gf.INP_FIELDS, _public(m), gf.INP_WORDS, m["_where"])
            m["_words"] = mw
            put(A["inp"] + i, mw[0], "%s INP[%d] %s" % (g.name, i, describe_input(g, m)))

        for i, r in enumerate(g.rules):
            rw = gf.pack(gf.RULE_FIELDS, _public(r), gf.RULE_WORDS, r["_where"])
            r["_words"] = rw
            put(A["rule"] + 2 * i, rw[0], "%s RULE[%d].W0 %s" % (g.name, i, describe_rule(g, r)[0]))
            put(A["rule"] + 2 * i + 1, rw[1], "%s RULE[%d].W1 %s" % (g.name, i, describe_rule(g, r)[1]))
        img.games[slot] = g
    img.used = addr
    return img


def describe_input(g, m):
    s = "%s %s -> class %s owner %s: " % (
        gf.enum_name(gf.BUTTON, m["button"]), gf.enum_name(gf.TRIGGER, m["trigger"]),
        g.class_name(m["class"]), gf.enum_name(gf.OWNER, m["owner"]) if m["owner"] else "ANY")
    p = m["_par"]
    if m["op"] == gf.OP["MOVE"]:
        s += "MOVE %s speed %d%s" % (gf.enum_name(gf.DIR, p["dir"]), p["speed"],
                                     " set_facing" if p["set_facing"] else "")
    else:
        s += "SPAWN %s cooldown %d" % (g.class_name(p["pool"]), p["cooldown"])
    return s


def describe_rule(g, r):
    if r["event"] == gf.EVENT["COLLIDE"]:
        w0 = "COLLIDE self=%s other=%s owner_rel=%s" % (
            g.class_name(r["self"]), g.class_name(r["other"]),
            gf.enum_name(gf.OWNER_REL, r["owner_rel"]))
    else:
        edges = [k for k, v in gf.EDGE.items() if r["other"] & v]
        w0 = "EDGE self=%s edges=%s" % (g.class_name(r["self"]), "|".join(edges))
    if r["last"]:
        w0 += " last"
    acts = []
    if r["motion"]:
        acts.append(gf.enum_name(gf.MOTION, r["motion"]) + ("+SPIN" if r["spin"] else ""))
    if r["copy_owner"]:
        acts.append("copy_owner")
    if r["copy_color"]:
        acts.append("copy_color")
    if r["score_sel"]:
        acts.append("%s[%s]%+d" % ("lives" if r["counter"] else "score",
                                   gf.enum_name(gf.SCORE_SEL, r["score_sel"]), r["score_delta"]))
    if r["self_fate"]:
        acts.append("self:" + gf.enum_name(gf.FATE, r["self_fate"])
                    + ("(flip_x)" if r["flip_x"] else "") + ("(flip_y)" if r["flip_y"] else ""))
    if r["other_fate"]:
        acts.append("other:" + gf.enum_name(gf.FATE, r["other_fate"])
                    + ("(%s)" % g.class_name(r["split_class"])
                       if r["other_fate"] == gf.FATE["SPLIT"] else ""))
    return w0, " ".join(acts) if acts else "no action"


# ---------------------------------------------------------------------------
# Output writers
# ---------------------------------------------------------------------------
def write_mem(img, path):
    """$readmemh image: one 32-bit word per line, address order, full depth."""
    with open(path, "w") as fh:
        fh.write("// BRAM game engine ROM image - generated by gamec.py, do not edit\n")
        fh.write("// %d words x 32 bits, hexadecimal, word 0 first\n" % img.depth)
        for w in img.words:
            fh.write("%08X\n" % w)


def write_coe(img, path):
    """Xilinx COE for the Block Memory Generator: same words, same order."""
    with open(path, "w") as fh:
        fh.write("; BRAM game engine ROM image - generated by gamec.py, do not edit\n")
        fh.write("; %d words x 32 bits\n" % img.depth)
        fh.write("memory_initialization_radix=16;\n")
        fh.write("memory_initialization_vector=\n")
        fh.write(",\n".join("%08X" % w for w in img.words))
        fh.write(";\n")


def write_lst(img, path):
    with open(path, "w") as fh:
        fh.write("addr  word      meaning\n")
        for a in range(img.used):
            fh.write("%03X   %08X  %s\n" % (a, img.words[a], img.notes[a]))
        fh.write("%03X.. 00000000  unused (%d words)\n" % (img.used, img.depth - img.used))


def write_map(img, path):
    L = []
    L.append("BRAM game engine - memory map and budgets")
    L.append("=========================================")
    L.append("")
    L.append("ROM: %d words x %d bits = %d bits (%d of %d words used, %.1f %%)"
             % (img.depth, gf.WORD_BITS, img.depth * gf.WORD_BITS, img.used, img.depth,
                100.0 * img.used / img.depth))
    L.append("Capacity per game: %d objects, %d input mappings, %d rules, %d classes, "
             "%d colours" % (gf.MAX_OBJ, gf.MAX_INP, gf.MAX_RULE, gf.N_CLASS, gf.N_PAL))
    L.append("")
    L.append("addr range     words  contents")
    L.append("0x000-0x%03X   %5d  game directory" % (gf.DIR_WORDS - 1, gf.DIR_WORDS))
    for g in img.games:
        if g is None:
            continue
        A = g.addr
        for key, nxt, what in (("hdr", "pal", "header"), ("pal", "obj", "palette"),
                               ("obj", "inp", "objects (%d x 3)" % len(g.objects)),
                               ("inp", "rule", "input mappings (%d)" % len(g.inputs)),
                               ("rule", "end", "rules (%d x 2)" % len(g.rules))):
            n = A[nxt] - A[key]
            if n:
                L.append("0x%03X-0x%03X   %5d  game %d %-9s %s"
                         % (A[key], A[nxt] - 1, n, g.slot, g.name, what))
            else:
                L.append("  (empty)      %5d  game %d %-9s %s" % (0, g.slot, g.name, what))
    L.append("0x%03X-0x%03X   %5d  unused, reads as 0"
             % (img.used, img.depth - 1, img.depth - img.used))
    L.append("")
    L.append("Per-game usage")
    L.append("--------------")
    L.append("slot name       objects  inputs  rules  classes  colours  ROM words")
    for g in img.games:
        if g is None:
            continue
        L.append("%4d %-10s %4d/%-2d  %3d/%-2d  %2d/%-2d   %2d/%-2d    %2d/%-2d   %5d"
                 % (g.slot, g.name, len(g.objects), gf.MAX_OBJ, len(g.inputs), gf.MAX_INP,
                    len(g.rules), gf.MAX_RULE, len(g.classes), gf.N_CLASS,
                    len(g.palette), gf.N_PAL, g.addr["end"] - g.addr["hdr"]))
    L.append("")
    L.append("Worst-case update cost (system clocks, provable upper bound)")
    L.append("------------------------------------------------------------")
    L.append("budget: %d clocks = vertical-blanking lines 480..523 at %d clocks/line"
             % (gf.UPDATE_BUDGET_CLOCKS, gf.H_TOTAL * gf.CLK_PER_PIXEL))
    L.append("slot name       prep  input  move+collide   wave   total  of budget  colliders")
    for g in img.games:
        if g is None:
            continue
        c = g.cycle_report
        L.append("%4d %-10s %4d  %5d  %12d  %5d  %6d   %6.2f %%  %9d"
                 % (g.slot, g.name, c["prep"], c["input"], c["move_collide"], c["wave"], c["total"],
                    100.0 * c["total"] / gf.UPDATE_BUDGET_CLOCKS, c["colliders"]))
    L.append("")
    L.append("Scanline occupancy (renderer has %d line slots; a facing marker uses one more)" % gf.N_SLOTS)
    L.append("-----------------------------------------------")
    L.append("slot name       fixed-row(max)  roaming  bound  worst line")
    for g in img.games:
        if g is None:
            continue
        s = g.slot_report
        L.append("%4d %-10s %14d  %7d  %5d  %10d"
                 % (g.slot, g.name, s["worst_static"], s["movable"], s["worst"], s["worst_y"]))
    L.append("")
    for g in img.games:
        if g is None:
            continue
        L.append("Game %d: %s (%s)" % (g.slot, g.title, os.path.basename(g.source)))
        L.append("  classes : " + ", ".join(
            "%d=%s%s" % (i, n, "*" if c else "") for i, (n, c) in enumerate(g.classes))
            + "   (* = controlled)")
        L.append("  palette : " + ", ".join(
            "%d=%s #%03X" % (i, n, rgb) for i, (n, rgb) in enumerate(g.palette)))
        L.append("  collider_mask=0x%04X controlled_mask=0x%04X"
                 % (g.hdr["collider_mask"], g.hdr["controlled_mask"]))
        for i, m in enumerate(g.inputs):
            L.append("  input %2d @0x%03X %08X  %s"
                     % (i, g.addr["inp"] + i, m["_words"][0], describe_input(g, m)))
        for i, r in enumerate(g.rules):
            d = describe_rule(g, r)
            L.append("  rule  %2d @0x%03X %08X %08X  %s => %s"
                     % (i, g.addr["rule"] + 2 * i, r["_words"][0], r["_words"][1], d[0], d[1]))
        for w in g.warnings:
            L.append("  warning : " + w)
        L.append("")
    with open(path, "w") as fh:
        fh.write("\n".join(L))


def write_meta(img, path):
    meta = {"depth": img.depth, "used": img.used, "games": []}
    for g in img.games:
        if g is None:
            meta["games"].append(None)
            continue
        meta["games"].append({
            "name": g.name, "title": g.title, "slot": g.slot, "addr": g.addr,
            "classes": [n for n, _c in g.classes],
            "palette": [n for n, _c in g.palette],
            "objects": [o["_name"] for o in g.objects],
            "n_obj": len(g.objects), "n_inp": len(g.inputs), "n_rule": len(g.rules),
            "cycle_bound": g.cycle_report["total"],
        })
    with open(path, "w") as fh:
        json.dump(meta, fh, indent=1, sort_keys=True)
        fh.write("\n")


# ---------------------------------------------------------------------------
# Generated Verilog header and documentation tables
# ---------------------------------------------------------------------------
def render_vh():
    L = []
    L.append("// ge_defs.vh - GENERATED by tools/gamec.py --emit-vh from tools/geformat.py.")
    L.append("// Do not edit by hand: change geformat.py and regenerate, so that the")
    L.append("// compiler, the reference model and the RTL can never disagree.")
    L.append("//")
    L.append("// Naming: <RECORD>_<FIELD> is a bit range you can use as  word[`NAME].")
    L.append("// For multi-word records the range indexes the whole record with word 0 in")
    L.append("// the least significant 32 bits (an object record is {W2, W1, W0} = 96 bits).")
    L.append("`ifndef GE_DEFS_VH")
    L.append("`define GE_DEFS_VH")
    L.append("")
    consts = [("GE_ROM_AW", gf.ROM_AW), ("GE_MAX_OBJ", gf.MAX_OBJ), ("GE_MAX_INP", gf.MAX_INP),
              ("GE_MAX_RULE", gf.MAX_RULE), ("GE_N_SLOTS", gf.N_SLOTS),
              ("GE_HDR_WORDS", gf.HDR_WORDS), ("GE_OBJ_WORDS", gf.OBJ_WORDS),
              ("GE_N_PAL", gf.N_PAL), ("GE_OBJ_BITS", gf.OBJ_WORDS * 32)]
    for n, v in consts:
        L.append("`define %-22s %d" % (n, v))
    L.append("`define %-22s 8'h%02X" % ("GE_MAGIC", gf.MAGIC))
    L.append("")
    for prefix, title, fields, words in gf.RECORDS:
        L.append("// %s (%d word%s)" % (title, words, "" if words == 1 else "s"))
        for f in fields:
            lo = f.word * 32 + f.lsb if prefix in ("OBJ",) else f.lsb
            hi = lo + f.width - 1
            rng = "%d:%d" % (hi, lo) if f.width > 1 else "%d" % lo
            tag = prefix if prefix not in ("HDR", "RULE") else "%s%d" % (prefix[0], f.word)
            name = "%s_%s" % (tag, f.name.upper())
            L.append("`define %-22s %-7s // %s%s" % (name, rng, "signed. " if f.signed else "", f.doc))
        L.append("")
    for prefix, table, width in gf.ENUMS:
        for k, v in table.items():
            L.append("`define %-22s %d'd%d" % ("%s_%s" % (prefix, k), width, v))
        L.append("")
    L.append("`endif")
    return "\n".join(L) + "\n"


def render_field_table(prefix):
    for p, title, fields, words in gf.RECORDS:
        if p == prefix:
            break
    else:
        raise KeyError(prefix)
    L = ["| Word | Bits | Field | Type | Range | Meaning |", "|---|---|---|---|---|---|"]
    for f in sorted(fields, key=lambda f: (f.word, -f.lsb)):
        bits = "[%d:%d]" % (f.msb, f.lsb) if f.width > 1 else "[%d]" % f.lsb
        L.append("| %d | %s | `%s` | %s%d | %d..%d | %s |"
                 % (f.word, bits, f.name, "s" if f.signed else "u", f.width, f.lo, f.hi, f.doc))
    res = gf.reserved_mask(fields, words)
    for k in range(words):
        if res[k]:
            L.append("| %d | mask 0x%08X | reserved | - | 0 | must be written as 0 |" % (k, res[k]))
    return "\n".join(L)


def update_doc(path):
    """Replace text between <!-- GEN:xxx --> and <!-- END:xxx --> markers."""
    with open(path, "r") as fh:
        text = fh.read()
    out, pos, n = [], 0, 0
    while True:
        a = text.find("<!-- GEN:", pos)
        if a < 0:
            out.append(text[pos:])
            break
        b = text.index("-->", a)
        key = text[a + 9:b].strip()
        endm = "<!-- END:%s -->" % key
        e = text.index(endm, b)
        out.append(text[pos:b + 3])
        out.append("\n" + render_field_table(key) + "\n")
        out.append(endm)
        pos = e + len(endm)
        n += 1
    new = "".join(out)
    if new != text:
        with open(path, "w") as fh:
            fh.write(new)
    return n, new != text


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------
def compile_files(paths, depth=gf.ROM_DEPTH):
    return link([parse_game(p) for p in paths], depth)


def main(argv=None):
    ap = argparse.ArgumentParser(description="BRAM game engine compiler")
    ap.add_argument("games", nargs="*", help="game definition files, slot 0 first")
    ap.add_argument("-o", "--outdir", default="build")
    ap.add_argument("--name", default="games", help="base name of the image files")
    ap.add_argument("--emit-vh", metavar="FILE")
    ap.add_argument("--update-doc", metavar="FILE")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args(argv)

    if args.emit_vh:
        with open(args.emit_vh, "w") as fh:
            fh.write(render_vh())
        if not args.quiet:
            print("wrote " + args.emit_vh)
    if args.update_doc:
        n, changed = update_doc(args.update_doc)
        if not args.quiet:
            print("%s: %d generated tables%s" % (args.update_doc, n, " (updated)" if changed else ""))
    if not args.games:
        if not (args.emit_vh or args.update_doc):
            ap.error("no game definitions given")
        return 0
    try:
        img = compile_files(args.games)
    except CompileError as e:
        sys.stderr.write("gamec: error: %s\n" % e)
        return 1
    if not os.path.isdir(args.outdir):
        os.makedirs(args.outdir)
    base = os.path.join(args.outdir, args.name)
    write_mem(img, base + ".mem")
    write_coe(img, base + ".coe")
    write_lst(img, base + ".lst")
    write_map(img, os.path.join(args.outdir, "memory_map.txt" if args.name == "games"
                                else args.name + "_map.txt"))
    write_meta(img, base + "_meta.json")
    if not args.quiet:
        for g in img.games:
            if g is None:
                continue
            print("slot %d %-9s %2d objects %2d inputs %2d rules  bound %6d clocks (%.1f %% of budget)"
                  % (g.slot, g.name, len(g.objects), len(g.inputs), len(g.rules),
                     g.cycle_report["total"],
                     100.0 * g.cycle_report["total"] / gf.UPDATE_BUDGET_CLOCKS))
            for w in g.warnings:
                print("  warning: " + w)
        print("%d of %d ROM words used -> %s.mem / .coe" % (img.used, img.depth, base))
    return 0


if __name__ == "__main__":
    sys.exit(main())
