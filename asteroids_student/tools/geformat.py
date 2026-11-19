"""
geformat.py - single source of truth for the game-ROM binary format.

Everything that needs to know a bit position imports it from here:
  * gamec.py    packs records with these tables
  * gemodel.py  unpacks records with these tables (reference model)
  * rtl/ge_defs.vh is GENERATED from these tables (gamec.py --emit-vh)
  * docs/MEMORY_FORMAT.md field tables are GENERATED from these tables

Standard library only.
"""

# --------------------------------------------------------------------------
# Global capacities
# --------------------------------------------------------------------------
WORD_BITS = 32
ROM_AW = 11                     # ROM address width
ROM_DEPTH = 1 << ROM_AW         # 2048 words of 32 bits
N_GAMES = 4
MAX_OBJ = 64                    # object slots per game
MAX_INP = 32                    # input-mapping records per game
MAX_RULE = 32                   # event-action rules per game
N_CLASS = 16                    # object classes per game
N_PAL = 16                      # palette entries per game
N_SLOTS = 32                    # renderer line slots (rectangles per scanline)

DIR_WORDS = N_GAMES             # directory: one word per game, address 0..3
HDR_WORDS = 10
OBJ_WORDS = 3
RULE_WORDS = 2
INP_WORDS = 1

MAGIC = 0xA5
VERSION = 2

# Screen / frame constants used by the validator and the cycle budget
SCREEN_W = 640
SCREEN_H = 480
CLK_PER_PIXEL = 4               # 100 MHz system clock / 25 MHz pixel rate
H_TOTAL = 800
V_TOTAL = 525
# The update starts at line 480 and must be finished before line 524,
# because the renderer scans the object RAM for line 0 during line 524.
UPDATE_BUDGET_CLOCKS = (524 - 480) * H_TOTAL * CLK_PER_PIXEL   # 140800

COORD_MIN, COORD_MAX = -1024, 1023      # s11
ARENA_MIN, ARENA_MAX = -256, 768        # allowed arena rectangle range
VEL_MAX = 31                            # |velocity| limit (s6 without -32)


class Field(object):
    """One bit field inside a record. lsb is relative to its 32-bit word."""

    def __init__(self, name, word, lsb, width, signed=False, doc=""):
        self.name = name
        self.word = word
        self.lsb = lsb
        self.width = width
        self.signed = signed
        self.doc = doc

    @property
    def msb(self):
        return self.lsb + self.width - 1

    @property
    def lo(self):
        return -(1 << (self.width - 1)) if self.signed else 0

    @property
    def hi(self):
        return (1 << (self.width - 1)) - 1 if self.signed else (1 << self.width) - 1


F = Field

# --------------------------------------------------------------------------
# Record layouts
# --------------------------------------------------------------------------
DIR_FIELDS = [
    F("hdr_addr", 0, 0, 11, doc="ROM address of the game's header word H0"),
    F("version", 0, 16, 8, doc="format version, must be 2"),
    F("valid", 0, 31, 1, doc="1 = slot holds a game; 0 = loader ignores the request"),
]

HDR_FIELDS = [
    F("n_rule", 0, 0, 8, doc="number of rule records, 0..32"),
    F("n_inp", 0, 8, 8, doc="number of input-mapping records, 0..32"),
    F("n_obj", 0, 16, 8, doc="number of object records, 0..64"),
    F("magic", 0, 24, 8, doc="0xA5; the loader aborts on any other value"),
    F("obj_base", 1, 0, 11, doc="ROM address of object record 0, word 0"),
    F("inp_base", 1, 16, 11, doc="ROM address of input-mapping record 0"),
    F("rule_base", 2, 0, 11, doc="ROM address of rule record 0, word 0"),
    F("pal_base", 2, 16, 11, doc="ROM address of palette entry 0"),
    F("xmin", 3, 0, 11, True, doc="arena left edge, inclusive, pixels"),
    F("xmax", 3, 16, 11, True, doc="arena right edge, exclusive, pixels"),
    F("ymin", 4, 0, 11, True, doc="arena top edge, inclusive, pixels"),
    F("ymax", 4, 16, 11, True, doc="arena bottom edge, exclusive, pixels"),
    F("win_score", 5, 0, 7, doc="a player wins when score >= this; 0 disables"),
    F("init_score", 5, 8, 7, doc="both scores are set to this at load"),
    F("lose_at_zero", 5, 16, 1, doc="1 = a player whose lives counter is 0 loses"),
    F("spin_step", 5, 20, 3, doc="SPIN velocity increment, pixels/frame"),
    F("spin_max", 5, 24, 5, doc="SPIN clamp, |v| <= spin_max"),
    F("hud_p1_x", 6, 0, 10, doc="screen x of player 1 score digits"),
    F("hud_p2_x", 6, 10, 10, doc="screen x of player 2 score digits"),
    F("hud_y", 6, 20, 9, doc="screen y of both score displays"),
    F("hud_en", 6, 31, 1, doc="1 = draw on-screen scores"),
    F("collider_mask", 7, 0, 16, doc="bit c = class c is evaluated as SELF of collisions"),
    F("controlled_mask", 7, 16, 16, doc="bit c = class c has its velocity zeroed every frame"),
    F("init_lives", 8, 0, 4, doc="both lives counters are set to this at load, 0..9; 0 = no lives display"),
    F("mark_color", 8, 8, 4, doc="palette index of the facing marker"),
    F("wave_watch", 8, 16, 16, doc="bit c = class c is watched; 0 disables the wave reload"),
    F("wave_reload", 9, 0, 16, doc="bit c = class c is reloaded when no watched object is left"),
]

OBJ_FIELDS = [
    F("x", 0, 0, 11, True, doc="left edge, pixels (screen x; may be off screen)"),
    F("y", 0, 11, 11, True, doc="top edge, pixels"),
    F("w", 0, 22, 10, doc="width, pixels, 1..1023"),
    F("h", 1, 0, 10, doc="height, pixels, 1..1023"),
    F("vx", 1, 10, 6, True, doc="x velocity, pixels/frame, -31..31"),
    F("vy", 1, 16, 6, True, doc="y velocity, pixels/frame, -31..31"),
    F("color", 1, 22, 4, doc="palette index; 0 = invisible"),
    F("class", 1, 26, 4, doc="object class, matched by rules and input mappings"),
    F("owner", 1, 30, 2, doc="0 none, 1 player 1, 2 player 2"),
    F("enabled", 2, 0, 1, doc="1 = object exists"),
    F("bmode", 2, 1, 2, doc="arena boundary mode: 0 CLAMP 1 BOUNCE 2 WRAP 3 DESTROY"),
    F("tmode", 2, 3, 2, doc="timer mode: 0 COUNTDOWN 1 FREEZE 2 LIFETIME 3 SHIELD"),
    F("dir", 2, 5, 3, doc="heading: 0 E 1 NE 2 N 3 NW 4 W 5 SW 6 S 7 SE"),
    F("hp", 2, 8, 4, doc="hit points used by the DAMAGE fate"),
    F("timer", 2, 12, 8, doc="frames; decremented every update while non-zero"),
    F("mark", 2, 20, 1, doc="1 = draw a 4 x 4 facing marker inside the object"),
    F("cool", 2, 21, 5, doc="SPAWN cooldown, frames; decremented every update while non-zero"),
]

INP_FIELDS = [
    F("param", 0, 0, 16, doc="operation parameter, see MOVE / SPAWN layouts"),
    F("class", 0, 16, 4, doc="target class"),
    F("owner", 0, 20, 2, doc="target owner: 0 any, 1 player 1, 2 player 2"),
    F("trigger", 0, 22, 2, doc="0 HELD, 1 PRESSED"),
    F("button", 0, 24, 4, doc="logical button 0..9"),
    F("op", 0, 28, 4, doc="1 MOVE, 2 SPAWN"),
]

# param sub-layouts (bit positions inside the 16-bit param field)
MOVE_FIELDS = [
    F("dir", 0, 0, 2, doc="0 RIGHT 1 LEFT 2 DOWN 3 UP"),
    F("set_facing", 0, 2, 1, doc="1 = afterwards point the heading along the velocity"),
    F("speed", 0, 4, 6, doc="pixels/frame, 0..31"),
]
SPAWN_FIELDS = [
    F("pool", 0, 0, 4, doc="class of the pooled object to activate"),
    F("cooldown", 0, 8, 8, doc="frames written to the spawner's cool field, 0..31"),
]

RULE_FIELDS = [
    F("last", 0, 0, 1, doc="1 = stop scanning rules for this event after this rule fires"),
    F("owner_rel", 0, 16, 2, doc="COLLIDE only: 0 ANY, 1 SAME owner, 2 DIFFERENT owner"),
    F("other", 0, 20, 4, doc="COLLIDE: other class. EDGE: edge mask {B,T,R,L}"),
    F("self", 0, 24, 4, doc="class of the object the event belongs to"),
    F("event", 0, 28, 4, doc="0 COLLIDE, 1 EDGE"),
    F("motion", 1, 0, 2, doc="self motion response: 0 NONE 1 BOUNCE 2 STOP"),
    F("spin", 1, 2, 1, doc="with BOUNCE: nudge perpendicular velocity by other's motion"),
    F("copy_owner", 1, 3, 1, doc="self.owner := other.owner"),
    F("copy_color", 1, 4, 1, doc="self.color := other.color"),
    F("counter", 1, 5, 1, doc="0 = change the score, 1 = change the lives counter"),
    F("score_sel", 1, 8, 3, doc="which player's counter changes"),
    F("score_delta", 1, 12, 4, True, doc="signed change, -8..7; score saturates 0..99, lives 0..9"),
    F("self_fate", 1, 16, 3, doc="0 NONE 1 DAMAGE 2 DESTROY 3 RESPAWN"),
    F("other_fate", 1, 19, 3, doc="0 NONE 1 DAMAGE 2 DESTROY 3 RESPAWN 4 SPLIT"),
    F("flip_x", 1, 22, 1, doc="self RESPAWN: negate the reloaded vx"),
    F("flip_y", 1, 23, 1, doc="self RESPAWN: negate the reloaded vy"),
    F("split_class", 1, 24, 4, doc="SPLIT: class of the pooled fragments"),
]

PAL_FIELDS = [
    F("rgb", 0, 0, 12, doc="{R[3:0], G[3:0], B[3:0]}"),
]

# --------------------------------------------------------------------------
# Enumerations
# --------------------------------------------------------------------------
OWNER = {"NONE": 0, "P1": 1, "P2": 2}
BMODE = {"CLAMP": 0, "BOUNCE": 1, "WRAP": 2, "DESTROY": 3}
TMODE = {"COUNTDOWN": 0, "FREEZE": 1, "LIFETIME": 2, "SHIELD": 3}
COOL_MAX = 31
DIR = {"RIGHT": 0, "LEFT": 1, "DOWN": 2, "UP": 3}          # MOVE: which axis and sign
HEADING = {"E": 0, "NE": 1, "N": 2, "NW": 3, "W": 4, "SW": 5, "S": 6, "SE": 7}
HEADING_ALIAS = {"RIGHT": "E", "LEFT": "W", "UP": "N", "DOWN": "S"}
COUNTER = {"SCORE": 0, "LIVES": 1}
LIVES_MAX = 9
BUTTON = {
    "P1_UP": 0, "P1_DOWN": 1, "P1_LEFT": 2, "P1_RIGHT": 3, "P1_ACT": 4,
    "P2_UP": 5, "P2_DOWN": 6, "P2_LEFT": 7, "P2_RIGHT": 8, "P2_ACT": 9,
}
N_BUTTONS = 10
TRIGGER = {"HELD": 0, "PRESSED": 1}
OP = {"MOVE": 1, "SPAWN": 2}
EVENT = {"COLLIDE": 0, "EDGE": 1}
EDGE = {"LEFT": 1, "RIGHT": 2, "TOP": 4, "BOTTOM": 8}     # mask bits
OWNER_REL = {"ANY": 0, "SAME": 1, "DIFFERENT": 2}
MOTION = {"NONE": 0, "BOUNCE": 1, "STOP": 2}
FATE = {"NONE": 0, "DAMAGE": 1, "DESTROY": 2, "RESPAWN": 3, "SPLIT": 4}
SCORE_SEL = {
    "NONE": 0, "SELF_OWNER": 1, "OTHER_OWNER": 2,
    "SELF_OPPONENT": 3, "OTHER_OPPONENT": 4, "P1": 5, "P2": 6,
}
GSTATE = {"PLAYING": 0, "P1_WON": 1, "P2_WON": 2, "DRAW": 3}

ENUMS = [
    ("OWNER", OWNER, 2), ("BMODE", BMODE, 2), ("TMODE", TMODE, 2),
    ("DIR", DIR, 2), ("HD", HEADING, 3), ("CNT", COUNTER, 1),
    ("BTN", BUTTON, 4), ("TRIG", TRIGGER, 2),
    ("OP", OP, 4), ("EVT", EVENT, 4), ("EDGE", EDGE, 4),
    ("REL", OWNER_REL, 2), ("MOTION", MOTION, 2), ("FATE", FATE, 3),
    ("SEL", SCORE_SEL, 3), ("GS", GSTATE, 2),
]

RECORDS = [
    # (prefix, title, field list, words)
    ("GDIR", "Directory entry", DIR_FIELDS, 1),
    ("HDR", "Game header", HDR_FIELDS, HDR_WORDS),
    ("OBJ", "Object record", OBJ_FIELDS, OBJ_WORDS),
    ("INP", "Input-mapping record", INP_FIELDS, INP_WORDS),
    ("MOVE", "MOVE parameter (INP.param)", MOVE_FIELDS, 1),
    ("SPAWN", "SPAWN parameter (INP.param)", SPAWN_FIELDS, 1),
    ("RULE", "Rule record", RULE_FIELDS, RULE_WORDS),
    ("PAL", "Palette entry", PAL_FIELDS, 1),
]


class FormatError(ValueError):
    pass


def _check_layout():
    """Fields of one record must not overlap and must fit their word."""
    for prefix, _title, fields, words in RECORDS:
        used = [0] * words
        for f in fields:
            if f.word >= words or f.msb >= WORD_BITS:
                raise FormatError("%s.%s does not fit" % (prefix, f.name))
            mask = ((1 << f.width) - 1) << f.lsb
            if used[f.word] & mask:
                raise FormatError("%s.%s overlaps another field" % (prefix, f.name))
            used[f.word] |= mask


_check_layout()


def pack(fields, values, nwords, what="record"):
    """Pack a dict of field values into a list of nwords 32-bit words.

    Every field must be present, every value must be an int in range, and
    no unknown keys are allowed. Reserved bits are written as zero.
    """
    words = [0] * nwords
    names = set(f.name for f in fields)
    extra = set(values) - names
    if extra:
        raise FormatError("%s: unknown field(s) %s" % (what, sorted(extra)))
    for f in fields:
        if f.name not in values:
            raise FormatError("%s: missing field '%s'" % (what, f.name))
        v = values[f.name]
        if isinstance(v, bool):
            v = int(v)
        if not isinstance(v, int):
            raise FormatError("%s: field '%s' must be an integer, got %r" % (what, f.name, v))
        if v < f.lo or v > f.hi:
            raise FormatError("%s: field '%s' = %d is outside %d..%d"
                              % (what, f.name, v, f.lo, f.hi))
        words[f.word] |= (v & ((1 << f.width) - 1)) << f.lsb
    return words


def unpack(fields, words):
    """Inverse of pack(). Returns a dict of ints (signed fields sign-extended)."""
    out = {}
    for f in fields:
        v = (words[f.word] >> f.lsb) & ((1 << f.width) - 1)
        if f.signed and v >> (f.width - 1):
            v -= 1 << f.width
        out[f.name] = v
    return out


def reserved_mask(fields, nwords):
    """Per-word mask of bits not covered by any field."""
    used = [0] * nwords
    for f in fields:
        used[f.word] |= ((1 << f.width) - 1) << f.lsb
    return [(~u) & 0xFFFFFFFF for u in used]


def enum_name(enum, value):
    for k, v in enum.items():
        if v == value:
            return k
    return "?%d" % value
