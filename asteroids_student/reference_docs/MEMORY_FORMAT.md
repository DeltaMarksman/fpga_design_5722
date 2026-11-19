# Memory format and behaviour contract (format version 2)

This file is the contract between the game compiler (`tools/gamec.py`), the
reference model (`tools/gemodel.py`) and the hardware (`rtl/`). The bit
tables below are generated from `tools/geformat.py`, the same file the
compiler packs with and from which `rtl/ge_defs.vh` is generated; a unit test
fails if this document, the header or the compiler disagree. In the tables,
"Range" is what the field can hold; which values are legal is stated in the
Meaning column and in the notes under each table.

Version 2 added, for Asteroids: eight headings and the facing marker, the
SPLIT fate, a lives counter per player, the wave reload, the SHIELD timer mode,
a separate shot cooldown, and 32 renderer slots.

Contents: [1 Memories](#1-memories) · [2 ROM layout](#2-rom-layout) ·
[3 Directory](#3-directory-entry) · [4 Header](#4-game-header) ·
[5 Palette](#5-palette-entry) · [6 Objects](#6-object-record) ·
[7 Input mappings](#7-input-mapping-record) · [8 Rules](#8-rule-record) ·
[9 Runtime state](#9-writable-runtime-state) · [10 Capacities](#10-capacities-and-why) ·
[11 Frame update](#11-what-one-frame-update-does) · [12 Semantics](#12-exact-semantics) ·
[13 Worked example](#13-worked-example-from-a-json-rule-to-a-gameplay-action)

## 1. Memories

| Memory | Size | Kind | Written by | Read by |
|---|---|---|---|---|
| Game ROM | 2048 x 32 bit | block RAM, initialised from `games.mem` | nobody (bitstream) | loader, engine |
| Object RAM | 64 x 96 bit | true dual-port block RAM | loader, engine (port A) | engine (port A), renderer (port B) |
| Palette | 16 x 12 bit | distributed RAM | loader | renderer |
| Configuration | about 220 flip-flops | registers | loader | engine, renderer |
| Scores, lives, round state | 24 flip-flops | registers | engine | renderer, board displays |

Both block RAMs have **one clock of read latency**: an address sampled at a
rising clock edge produces its data after that edge, ready to be used or
registered during the following clock.

All four variants are in the ROM at the same time. A board button does not
upload anything: it tells the loader which directory entry to follow.
Uploading new definitions at run time (for example over UART) is not part of
this design; changing a game means recompiling the ROM image and rebuilding
the bitstream.

## 2. ROM layout

One word is 32 bits. Addresses are word addresses, 11 bits.

```
0x000 .. 0x003   directory: one word per game slot (btnU, btnR, btnD, btnL)
then, for each game in slot order, back to back:
    header       10 words
    palette      16 words
    objects       3 words x n_obj
    inputs        1 word  x n_inp
    rules         2 words x n_rule
rest             0
```

Address of every record (all bases come from the header):

```
header word k        = DIR[slot].hdr_addr + k            k = 0..9
palette entry c      = pal_base  + c                     c = 0..15
object i, word k     = obj_base  + 3*i + k               i = 0..n_obj-1, k = 0..2
input mapping m      = inp_base  + m                     m = 0..n_inp-1
rule r, word k       = rule_base + 2*r + k               r = 0..n_rule-1, k = 0..1
```

The image is deterministic: it depends only on the game files and their
order on the command line. `build/memory_map.txt` lists the real addresses
and `build/games.lst` decodes every word.

## 3. Directory entry

1 word at address `slot` (0..3).

<!-- GEN:GDIR -->
| Word | Bits | Field | Type | Range | Meaning |
|---|---|---|---|---|---|
| 0 | [31] | `valid` | u1 | 0..1 | 1 = slot holds a game; 0 = loader ignores the request |
| 0 | [23:16] | `version` | u8 | 0..255 | format version, must be 2 |
| 0 | [10:0] | `hdr_addr` | u11 | 0..2047 | ROM address of the game's header word H0 |
| 0 | mask 0x7F00F800 | reserved | - | 0 | must be written as 0 |
<!-- END:GDIR -->

A load request is refused if the slot's `valid` bit is 0, its `version` is
not 2, or the header's magic number is wrong: nothing changes, the current
game keeps running, and the error LED lights.

## 4. Game header

10 words. Copied into configuration registers by the loader.

<!-- GEN:HDR -->
| Word | Bits | Field | Type | Range | Meaning |
|---|---|---|---|---|---|
| 0 | [31:24] | `magic` | u8 | 0..255 | 0xA5; the loader aborts on any other value |
| 0 | [23:16] | `n_obj` | u8 | 0..255 | number of object records, 0..64 |
| 0 | [15:8] | `n_inp` | u8 | 0..255 | number of input-mapping records, 0..32 |
| 0 | [7:0] | `n_rule` | u8 | 0..255 | number of rule records, 0..32 |
| 1 | [26:16] | `inp_base` | u11 | 0..2047 | ROM address of input-mapping record 0 |
| 1 | [10:0] | `obj_base` | u11 | 0..2047 | ROM address of object record 0, word 0 |
| 2 | [26:16] | `pal_base` | u11 | 0..2047 | ROM address of palette entry 0 |
| 2 | [10:0] | `rule_base` | u11 | 0..2047 | ROM address of rule record 0, word 0 |
| 3 | [26:16] | `xmax` | s11 | -1024..1023 | arena right edge, exclusive, pixels |
| 3 | [10:0] | `xmin` | s11 | -1024..1023 | arena left edge, inclusive, pixels |
| 4 | [26:16] | `ymax` | s11 | -1024..1023 | arena bottom edge, exclusive, pixels |
| 4 | [10:0] | `ymin` | s11 | -1024..1023 | arena top edge, inclusive, pixels |
| 5 | [28:24] | `spin_max` | u5 | 0..31 | SPIN clamp, |v| <= spin_max |
| 5 | [22:20] | `spin_step` | u3 | 0..7 | SPIN velocity increment, pixels/frame |
| 5 | [16] | `lose_at_zero` | u1 | 0..1 | 1 = a player whose lives counter is 0 loses |
| 5 | [14:8] | `init_score` | u7 | 0..127 | both scores are set to this at load |
| 5 | [6:0] | `win_score` | u7 | 0..127 | a player wins when score >= this; 0 disables |
| 6 | [31] | `hud_en` | u1 | 0..1 | 1 = draw on-screen scores |
| 6 | [28:20] | `hud_y` | u9 | 0..511 | screen y of both score displays |
| 6 | [19:10] | `hud_p2_x` | u10 | 0..1023 | screen x of player 2 score digits |
| 6 | [9:0] | `hud_p1_x` | u10 | 0..1023 | screen x of player 1 score digits |
| 7 | [31:16] | `controlled_mask` | u16 | 0..65535 | bit c = class c has its velocity zeroed every frame |
| 7 | [15:0] | `collider_mask` | u16 | 0..65535 | bit c = class c is evaluated as SELF of collisions |
| 8 | [31:16] | `wave_watch` | u16 | 0..65535 | bit c = class c is watched; 0 disables the wave reload |
| 8 | [11:8] | `mark_color` | u4 | 0..15 | palette index of the facing marker |
| 8 | [3:0] | `init_lives` | u4 | 0..15 | both lives counters are set to this at load, 0..9; 0 = no lives display |
| 9 | [15:0] | `wave_reload` | u16 | 0..65535 | bit c = class c is reloaded when no watched object is left |
| 1 | mask 0xF800F800 | reserved | - | 0 | must be written as 0 |
| 2 | mask 0xF800F800 | reserved | - | 0 | must be written as 0 |
| 3 | mask 0xF800F800 | reserved | - | 0 | must be written as 0 |
| 4 | mask 0xF800F800 | reserved | - | 0 | must be written as 0 |
| 5 | mask 0xE08E8080 | reserved | - | 0 | must be written as 0 |
| 6 | mask 0x60000000 | reserved | - | 0 | must be written as 0 |
| 8 | mask 0x0000F0F0 | reserved | - | 0 | must be written as 0 |
| 9 | mask 0xFFFF0000 | reserved | - | 0 | must be written as 0 |
<!-- END:HDR -->

Notes:

- The arena is the rectangle `xmin <= x < xmax`, `ymin <= y < ymax`. The
  compiler accepts arena edges from -256 to 768.
- `collider_mask` and `controlled_mask` are derived by the compiler: a
  collider bit for every class that is `self` of a COLLIDE rule, a controlled
  bit for every class declared `"controlled": true`.
- `init_lives` 0 means the game has no lives: no rule may change lives,
  `lose_at_zero` must be 0, and no life squares are drawn.
- `wave_watch` and `wave_reload` are both 0 or both non-zero.
- The loader keeps only the low 7 bits of `n_obj` (clamped to 64) and the low
  6 bits of `n_inp` and `n_rule`.
- Reset values: all configuration registers are 0 after power-up, which is an
  empty game. The first frame boundary after power-up loads slot 0.

## 5. Palette entry

16 words per game, one colour each. Unused entries are 0.

<!-- GEN:PAL -->
| Word | Bits | Field | Type | Range | Meaning |
|---|---|---|---|---|---|
| 0 | [11:0] | `rgb` | u12 | 0..4095 | {R[3:0], G[3:0], B[3:0]} |
| 0 | mask 0xFFFFF000 | reserved | - | 0 | must be written as 0 |
<!-- END:PAL -->

Fixed meanings: index 0 is the background colour, and an object whose colour
field is 0 is invisible; index 1 is player 1's colour and index 2 player 2's
(score digits, life squares, end-of-round frame). `mark_color` in the header
picks the facing-marker colour.

## 6. Object record

3 words = 96 bits. The same layout is used for the initial records in the ROM
and for the live records in the object RAM (`{W2, W1, W0}`), so loading a
game is a plain copy.

<!-- GEN:OBJ -->
| Word | Bits | Field | Type | Range | Meaning |
|---|---|---|---|---|---|
| 0 | [31:22] | `w` | u10 | 0..1023 | width, pixels, 1..1023 |
| 0 | [21:11] | `y` | s11 | -1024..1023 | top edge, pixels |
| 0 | [10:0] | `x` | s11 | -1024..1023 | left edge, pixels (screen x; may be off screen) |
| 1 | [31:30] | `owner` | u2 | 0..3 | 0 none, 1 player 1, 2 player 2 |
| 1 | [29:26] | `class` | u4 | 0..15 | object class, matched by rules and input mappings |
| 1 | [25:22] | `color` | u4 | 0..15 | palette index; 0 = invisible |
| 1 | [21:16] | `vy` | s6 | -32..31 | y velocity, pixels/frame, -31..31 |
| 1 | [15:10] | `vx` | s6 | -32..31 | x velocity, pixels/frame, -31..31 |
| 1 | [9:0] | `h` | u10 | 0..1023 | height, pixels, 1..1023 |
| 2 | [25:21] | `cool` | u5 | 0..31 | SPAWN cooldown, frames; decremented every update while non-zero |
| 2 | [20] | `mark` | u1 | 0..1 | 1 = draw a 4 x 4 facing marker inside the object |
| 2 | [19:12] | `timer` | u8 | 0..255 | frames; decremented every update while non-zero |
| 2 | [11:8] | `hp` | u4 | 0..15 | hit points used by the DAMAGE fate |
| 2 | [7:5] | `dir` | u3 | 0..7 | heading: 0 E 1 NE 2 N 3 NW 4 W 5 SW 6 S 7 SE |
| 2 | [4:3] | `tmode` | u2 | 0..3 | timer mode: 0 COUNTDOWN 1 FREEZE 2 LIFETIME 3 SHIELD |
| 2 | [2:1] | `bmode` | u2 | 0..3 | arena boundary mode: 0 CLAMP 1 BOUNCE 2 WRAP 3 DESTROY |
| 2 | [0] | `enabled` | u1 | 0..1 | 1 = object exists |
| 2 | mask 0xFC000000 | reserved | - | 0 | must be written as 0 |
<!-- END:OBJ -->

- Positions are screen pixels; x = 0, y = 0 is the top-left pixel. An object
  occupies `x .. x+w-1`, `y .. y+h-1`. Off-screen positions are legal.
- Velocity is added to the position once per update; the compiler limits it
  to -31..31 and `w`, `h` to 640.
- `dir` is a heading. Heading k points at 45 * k degrees counter-clockwise
  from east; with y growing downwards its unit step is
  E (+1,0), NE (+1,-1), N (0,-1), NW (-1,-1), W (-1,0), SW (-1,+1), S (0,+1), SE (+1,+1).
  The game files may also write RIGHT, LEFT, UP, DOWN for E, W, N, S.
- `cool` is always 0 in the ROM; it is runtime state set by SPAWN.
- `owner` 3 is reserved and behaves as "no player". All `bmode`, `tmode` and
  `dir` values are defined.
- Reserved bits are written as 0 by the compiler and carried through
  unchanged by the hardware.
- An object with `"pool": true` is stored with `enabled` 0 and is the
  template for SPAWN or SPLIT. For SPAWN its `vx` is the launch speed; SPLIT
  ignores the template's velocity.

Initialisation: at a load, slots `0 .. n_obj-1` receive their ROM records and
slots `n_obj .. 63` are written as 0 (disabled). RESPAWN, SPAWN, SPLIT and
the wave reload re-read one record from the ROM at `obj_base + 3*i`.

## 7. Input-mapping record

1 word. "When this key condition holds, do this to every matching object."

<!-- GEN:INP -->
| Word | Bits | Field | Type | Range | Meaning |
|---|---|---|---|---|---|
| 0 | [31:28] | `op` | u4 | 0..15 | 1 MOVE, 2 SPAWN |
| 0 | [27:24] | `button` | u4 | 0..15 | logical button 0..9 |
| 0 | [23:22] | `trigger` | u2 | 0..3 | 0 HELD, 1 PRESSED |
| 0 | [21:20] | `owner` | u2 | 0..3 | target owner: 0 any, 1 player 1, 2 player 2 |
| 0 | [19:16] | `class` | u4 | 0..15 | target class |
| 0 | [15:0] | `param` | u16 | 0..65535 | operation parameter, see MOVE / SPAWN layouts |
<!-- END:INP -->

Buttons: 0 P1_UP (W), 1 P1_DOWN (S), 2 P1_LEFT (A), 3 P1_RIGHT (D),
4 P1_ACT (F), 5 P2_UP, 6 P2_DOWN, 7 P2_LEFT, 8 P2_RIGHT (arrows),
9 P2_ACT (Enter). Values 10..15 never trigger. `trigger` 2 and 3 never
trigger. `op` values other than 1 and 2 do nothing.

`param` for MOVE (`dir` here is an axis and sign, not a heading):

<!-- GEN:MOVE -->
| Word | Bits | Field | Type | Range | Meaning |
|---|---|---|---|---|---|
| 0 | [9:4] | `speed` | u6 | 0..63 | pixels/frame, 0..31 |
| 0 | [2] | `set_facing` | u1 | 0..1 | 1 = afterwards point the heading along the velocity |
| 0 | [1:0] | `dir` | u2 | 0..3 | 0 RIGHT 1 LEFT 2 DOWN 3 UP |
| 0 | mask 0xFFFFFC08 | reserved | - | 0 | must be written as 0 |
<!-- END:MOVE -->

`param` for SPAWN (the compiler limits `cooldown` to 0..31; the hardware uses
its low 5 bits):

<!-- GEN:SPAWN -->
| Word | Bits | Field | Type | Range | Meaning |
|---|---|---|---|---|---|
| 0 | [15:8] | `cooldown` | u8 | 0..255 | frames written to the spawner's cool field, 0..31 |
| 0 | [3:0] | `pool` | u4 | 0..15 | class of the pooled object to activate |
| 0 | mask 0xFFFF00F0 | reserved | - | 0 | must be written as 0 |
<!-- END:SPAWN -->

## 8. Rule record

2 words. Word 0 says which event the rule matches, word 1 which of the fixed
action steps it switches on. A rule is not an instruction: every fired rule
goes through the same steps in the same order (section 12.4).

<!-- GEN:RULE -->
| Word | Bits | Field | Type | Range | Meaning |
|---|---|---|---|---|---|
| 0 | [31:28] | `event` | u4 | 0..15 | 0 COLLIDE, 1 EDGE |
| 0 | [27:24] | `self` | u4 | 0..15 | class of the object the event belongs to |
| 0 | [23:20] | `other` | u4 | 0..15 | COLLIDE: other class. EDGE: edge mask {B,T,R,L} |
| 0 | [17:16] | `owner_rel` | u2 | 0..3 | COLLIDE only: 0 ANY, 1 SAME owner, 2 DIFFERENT owner |
| 0 | [0] | `last` | u1 | 0..1 | 1 = stop scanning rules for this event after this rule fires |
| 1 | [27:24] | `split_class` | u4 | 0..15 | SPLIT: class of the pooled fragments |
| 1 | [23] | `flip_y` | u1 | 0..1 | self RESPAWN: negate the reloaded vy |
| 1 | [22] | `flip_x` | u1 | 0..1 | self RESPAWN: negate the reloaded vx |
| 1 | [21:19] | `other_fate` | u3 | 0..7 | 0 NONE 1 DAMAGE 2 DESTROY 3 RESPAWN 4 SPLIT |
| 1 | [18:16] | `self_fate` | u3 | 0..7 | 0 NONE 1 DAMAGE 2 DESTROY 3 RESPAWN |
| 1 | [15:12] | `score_delta` | s4 | -8..7 | signed change, -8..7; score saturates 0..99, lives 0..9 |
| 1 | [10:8] | `score_sel` | u3 | 0..7 | which player's counter changes |
| 1 | [5] | `counter` | u1 | 0..1 | 0 = change the score, 1 = change the lives counter |
| 1 | [4] | `copy_color` | u1 | 0..1 | self.color := other.color |
| 1 | [3] | `copy_owner` | u1 | 0..1 | self.owner := other.owner |
| 1 | [2] | `spin` | u1 | 0..1 | with BOUNCE: nudge perpendicular velocity by other's motion |
| 1 | [1:0] | `motion` | u2 | 0..3 | self motion response: 0 NONE 1 BOUNCE 2 STOP |
| 0 | mask 0x000CFFFE | reserved | - | 0 | must be written as 0 |
| 1 | mask 0xF00008C0 | reserved | - | 0 | must be written as 0 |
<!-- END:RULE -->

- `event` 2..15 and `owner_rel` 3 are reserved and never match; `motion` 3
  acts as NONE; `self_fate` 4..7 and `other_fate` 5..7 act as NONE (SPLIT is
  only defined for the other object).
- For an EDGE rule `other` is a mask: bit 0 LEFT (`xmin`), bit 1 RIGHT
  (`xmax`), bit 2 TOP (`ymin`), bit 3 BOTTOM (`ymax`).
- `score_sel`: 0 none, 1 self's owner, 2 other's owner, 3 opponent of self's
  owner, 4 opponent of other's owner, 5 player 1, 6 player 2, 7 none.
  `counter` picks which of that player's two counters changes.
- An EDGE event has no other object. The compiler rejects EDGE rules that use
  `motion`, `spin`, `copy_owner`, `copy_color`, `other_fate` or the "other"
  score selectors; the hardware ignores them for EDGE events.

## 9. Writable runtime state

| State | Where | Load value | Changed by |
|---|---|---|---|
| 64 object records | object RAM | ROM records, rest 0 | engine |
| score 1, score 2 (0..99) | engine | `init_score` | rules |
| lives 1, lives 2 (0..9) | engine | `init_lives` | rules |
| round state `gstate` | engine | 0 PLAYING | end-of-frame check |
| previous key sample | engine | the keys held at the load | every update |
| palette, configuration | renderer / loader | from the header | loader only |

`gstate`: 0 playing, 1 player 1 won, 2 player 2 won, 3 draw. A restart
(btnC) is exactly a load of the current slot.

## 10. Capacities and why

| Limit | Value | Largest use | Why |
|---|---|---|---|
| Objects per game | 64 | 29 (Asteroids: 2 ships, 6 shots, 3 + 6 + 12 rocks) | rock pools must hold every fragment a wave can produce; the earlier Breakout used 46 |
| Rules per game | 32 | 8 | one rule scan costs 4 clocks per rule |
| Input mappings | 32 | 10 | ten buttons |
| Classes | 16 | 5 | 4-bit field, masks fit 16-bit header fields |
| Colours | 16 | 9 | 4-bit colour field |
| Rectangles per scanline | 32 | 31 guaranteed bound (Asteroids) | every roaming object can reach every line; two ships with markers + 6 shots + 21 rocks = 31 |
| Lives | 0..9 | 5 | one digit's worth of squares |
| ROM words | 2048 | 511 used | two RAMB36 blocks |

## 11. What one frame update does

```
sample:  now  = the ten key bits
         edge = now AND NOT (keys at the previous update)

pass 1   for each enabled object:
           if timer != 0: timer -= 1; if it reached 0 and tmode = LIFETIME: disable
           if cool  != 0: cool -= 1
           if the class is "controlled": vx = vy = 0

pass 2   for each input mapping whose key condition holds, in table order:
           for each enabled object of the mapping's class and owner:
             MOVE (then, with set_facing, point the heading along the velocity) or SPAWN

pass 3   for each enabled object that is not FROZEN, in index order:
           if it moves: add velocity, arena boundary by bmode -> EDGE event
           if it is still alive, is a collider and is not SHIELDED:
             for each other enabled object: if they overlap -> COLLIDE event
             (stop as soon as a rule disabled or respawned this object)

wave     if wave_watch != 0 and no enabled object has a watched class:
           reload every object whose class is in wave_reload from the ROM

end      player 1 wins if (win_score != 0 and score1 >= win_score)
                       or (lose_at_zero and lives2 = 0); same for player 2
         gstate = {p2 wins, p1 wins};  remember the keys
```

If `gstate` is not 0 no update runs.

## 12. Exact semantics

### 12.1 Keys, movement and heading

- **HELD** is true in every update in which the key is down; **PRESSED** only
  in the first update that sees it down after one that saw it up. A key
  already down at a load is not "pressed".
- MOVE sets one velocity component: RIGHT `vx = +speed`, LEFT `vx = -speed`,
  DOWN `vy = +speed`, UP `vy = -speed`. Mappings apply in table order.
- With `set_facing`, after the component is set the heading becomes the one
  whose step has the signs of (vx, vy), if the velocity is not zero. Holding
  UP and RIGHT therefore gives NE whichever mapping comes first; a ship that
  stops keeps its heading.

### 12.2 Timers and cooldown

`timer` counts down by one per update while non-zero. Its meaning depends on
`tmode`:

- **COUNTDOWN**: nothing else.
- **FREEZE**: while `timer != 0` (after the decrement) pass 3 skips the
  object: it does not move and is not the self of any event.
- **LIFETIME**: the update in which the timer reaches 0 disables the object
  before it moves; 0 means "no limit".
- **SHIELD**: while `timer != 0` the object moves normally and its EDGE events
  happen, but it is not the self of COLLIDE events. The renderer hides it
  whenever bit 2 of the timer is 1, so it blinks four frames on, four off.

`cool` is a separate 5-bit down-counter used only by SPAWN, so shooting does
not interfere with the timer.

### 12.3 Arena boundary

Checked for an object that moved this update:

| bmode | condition (x; y is the same) | effect | edge |
|---|---|---|---|
| CLAMP | `x < xmin`, else `x + w > xmax` | pulled to the edge, `vx = 0` | LEFT / RIGHT |
| BOUNCE | same | pulled to the edge, velocity pointed inside | LEFT / RIGHT |
| WRAP | `x + w <= xmin`, else `x >= xmax` (completely outside) | `x = xmax`, resp. `x = xmin - w` | LEFT / RIGHT |
| DESTROY | `x < xmin`, else `x + w > xmax` | disabled | LEFT / RIGHT |

With WRAP an object slides out on one side and back in on the other; it
never jumps while visible. The boundary effect comes first; then, if any edge
bit is set, an EDGE event scans the rules.

### 12.4 Events, rule matching and the action steps

- **COLLIDE(self = i, other = j)** is raised while object i is processed in
  pass 3, for every j it overlaps, in index order. The pair is ordered: the
  rule's `self` class must match i and `other` j.
- **EDGE(self = i)** is raised by the boundary handling.

For each event the rule table is scanned from rule 0 upwards and every
matching rule fires, in order. The scan stops early when a fired rule has
`last`, when a self fate disabled or respawned the self object, or when an
other fate was SPLIT.

A fired rule runs these steps in this order:

1. **Motion** (collisions): BOUNCE or STOP, with SPIN.
2. **Ownership** (collisions): `copy_owner`, `copy_color`.
3. **Counter**: the selected player's score (0..99) or lives (0..9) changes by
   `score_delta`, saturating. The selector is evaluated after step 2.
4. **Self fate**: DAMAGE (hp - 1, disabled at 0), DESTROY, or RESPAWN (whole
   record from ROM, then `flip_x` / `flip_y` negate the reloaded velocity).
5. **Other fate** (collisions): DAMAGE, DESTROY, RESPAWN or SPLIT.

### 12.5 Collision geometry and motion responses

Two boxes overlap when all of these are greater than 0 (touching is not a
collision):

```
dl = self.x + self.w - other.x      dr = other.x + other.w - self.x
dt = self.y + self.h - other.y      db = other.y + other.h - self.y
```

The collision axis is the one with the smaller penetration, x on a tie; on
that axis self is on the low side if `dl <= dr` (resp. `dt <= db`). BOUNCE
and STOP move self to touch the other object on that axis; BOUNCE points the
velocity away, STOP zeroes it; SPIN (with BOUNCE) nudges the other velocity
component by `spin_step` in the other object's direction, limited to
`spin_max`. Only self is ever moved.

### 12.6 SPLIT

SPLIT on the other object P (class `split_class` names the fragments):

1. P's position, size, velocity (vx, vy) and owner are remembered; P is
   disabled and written back.
2. Two fragments are created, each from the first slot (lowest index) that is
   disabled, has class `split_class` and has P's owner. The slot is reloaded
   from its ROM record, then:
   - centred on P: `x = P.x + (P.w - w) / 2`, `y = P.y + (P.h - h) / 2`
     (division rounds down);
   - fragment 0 velocity `(vx - vy, vy + vx)`, fragment 1 `(vx + vy, vy - vx)`,
     each component limited to -31..31;
   - enabled, with P's owner.
   If no free slot is left a fragment is simply not created. The slot of
   the object whose rule is running (the self) is never used, even when the
   same rule has just disabled it; it becomes available from the next event.
3. The rule scan for this event ends.

Fragments take part in pass 3 when their index comes; a fragment in a slot
below the current object therefore first moves in the next update. A
fragment can overlap the self object; if the self object is not disabled or
respawned by the same rule, it can collide with the fragment later in the
same loop (all four Asteroids variants destroy or respawn the self object).

### 12.7 Projectiles: SPAWN

SPAWN on a spawner S requires `S.cool = 0`; it searches slots from 0 upwards
for the first disabled object of class `pool` with S's owner, reloads it from
ROM, enables it, gives it S's owner and heading, and places it next to S on
the side or corner S faces, centred on any axis without a step:

| step on x | x | step on y | y |
|---|---|---|---|
| +1 | `S.x + S.w` | -1 | `S.y - h` |
| -1 | `S.x - w` | +1 | `S.y + S.h` |
| 0 | `S.x + (S.w - w) / 2` | 0 | `S.y + (S.h - h) / 2` |

The velocity is (step x * speed, step y * speed) with speed = the template's
`vx`. Then `S.cool = cooldown`. No free slot: nothing happens, no cooldown.
The new object takes part in pass 3 of the same update.

### 12.8 Order, simultaneity, conflicts

Objects are processed one at a time in index order, each against the current
state of all others; every change is applied immediately. An object
overlapping several others handles them in index order and stops when a rule
removes it, so a shot touching two rocks breaks only the first. Two shots
hitting the same ship in one frame: the first respawns the ship (it is then
elsewhere and shielded), the second is not a hit. Several rules changing the
same field in one scan: the later wins (position, velocity) or the changes
accumulate (counters, damage).

### 12.9 Waves

After pass 3, if `wave_watch` is non-zero and no enabled object has a class in
`wave_watch`, every object (enabled or not) whose class is in `wave_reload`
gets its whole ROM record back. In Asteroids the watch mask is the three rock
classes and the reload mask the large rocks, so the large rocks return to
their start positions when the last fragment is gone; the fragment pools stay
disabled.

### 12.10 Victory, defeat, draw

Checked once at the end of each update: a player wins on reaching
`win_score` (if not 0) or when the opponent's lives are 0 (if
`lose_at_zero`). Both players at once is a draw.

### 12.11 Arithmetic and limits

- Positions are 11-bit two's complement; sums are formed in 13 bits and
  stored modulo 2^11. With the compiler's limits objects stay far inside
  -1024..1023.
- Velocities are 6-bit; SPLIT limits fragment components to -31..31.
- Score saturates at 0 and 99, lives at 0 and 9, `hp` at 0; `timer` and
  `cool` stop at 0.
- More than 32 rectangles on a scanline: the lowest-index ones are drawn, the
  rest are missing on that line, LED 14 lights. The compiler rejects games
  for which this could happen. A facing marker counts as a rectangle.
- An update that would not finish in vertical blanking lights LED 15. The
  compiler rejects games whose worst-case bound exceeds the budget.

## 13. Worked example: from a JSON rule to a gameplay action

**The rule as written** (`games/asteroids.json`, rule 0):

```json
{"event": "COLLIDE", "self": "SHOT", "other": "ROCK_L", "self_fate": "DESTROY",
 "other_fate": "SPLIT", "split": "ROCK_M", "score": {"player": "SELF_OWNER", "delta": 1}}
```

**Names to numbers.** Classes in this game: SHIP 0, SHOT 1, ROCK_L 2,
ROCK_M 3, ROCK_S 4. COLLIDE = 0, DESTROY = 2, SPLIT = 4, SELF_OWNER = 1,
counter SCORE = 0.

**Packing.**

```
word 0:  event 0 << 28 | self 1 << 24 | other 2 << 20 | owner_rel 0 << 16 | last 0
       = 0x0120_0000
word 1:  split_class 3 << 24 | other_fate 4 << 19 | self_fate 2 << 16
         | score_delta 1 << 12 | score_sel 1 << 8 | counter 0 << 5
       = 0x0300_0000 | 0x0020_0000 | 0x0002_0000 | 0x1000 | 0x0100 = 0x0322_1100
```

**Address.** Asteroids is slot 0. `DIR[0]` at address 0x000 holds 0x80020004
(valid, version 2, header at 0x004). Header word 2 (0x006) holds 0x000E007F:
`rule_base` = 0x07F. Rule 0 is at **0x07F and 0x080**. `build/games.lst`:

```
07F   01200000  asteroids RULE[0].W0 COLLIDE self=SHOT other=ROCK_L owner_rel=ANY
080   03221100  asteroids RULE[0].W1 score[SELF_OWNER]+1 self:DESTROY other:SPLIT(ROCK_M)
```

**Field extraction in the RTL** (`rtl/game_engine.v`, names from
`rtl/ge_defs.vh`). The engine has a shot in `a_rec` and a large rock in
`b_rec` and has found that they overlap. The rule scan reads the two words
into `r0` and `r1`:

```verilog
wire r_match = (r0[`R0_SELF] == a_class) &&                  // r0[27:24] = 1 = SHOT
               (evt_col ? ((r0[`R0_EVENT] == `EVT_COLLIDE) &&   // r0[31:28] = 0
                           (r0[`R0_OTHER] == b_class) && rel_ok)  // r0[23:20] = 2 = ROCK_L
                        : ...);
```

**Action.**

| Step | Bits of `r1` | What happens |
|---|---|---|
| motion, ownership | `r1[4:0]` = 0 | nothing |
| counter | `r1[5]` = 0 score, `r1[10:8]` = 1, `r1[15:12]` = +1 | the shot's owner gets 1 point |
| self fate | `r1[18:16]` = 2 DESTROY | the shot is disabled; its turn ends after this rule |
| other fate | `r1[21:19]` = 4 SPLIT, `r1[27:24]` = 3 | the rock is disabled and written back; two ROCK_M slots from the pool get the rock's centre and the velocities 45 degrees either side of its path |

The shot record is written back last. In the next frame the large rock is
gone and two medium rocks fly apart from where it was.

**Changing behaviour without touching the RTL.** Edit the JSON, recompile,
done. Two cases are automated (`sim/run_all.py`, step 9) with one and the
same compiled simulator:

| Edit | ROM word | Observed |
|---|---|---|
| rule 3: hitting the other ship `"delta": 5` -> `7` | 0x086: `00105200` -> `00107200` | the same hit, same frame, scores 7 instead of 5 |
| input 0: P1 move speed 3 -> 1 | 0x075: `10100037` -> `10100017` | ten frames of W move the ship 10 pixels instead of 30 |
