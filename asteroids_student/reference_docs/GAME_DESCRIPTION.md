# Game description files (game_data/*.json) and how they map to the ROM

These files are the input of the provided compiler, tools/gamec.py, which
writes game_data/games.coe and games.mem from them. Edit them to change the
game (or to add difficulty levels) without touching the RTL. The bit
positions of every field are in MEMORY_FORMAT.md (sections 2 to 8) and in
`tools/geformat.py`; this file says where each value comes from.
Keys starting with `//` are comments and are ignored.

## Linking: where each game goes

The provided ROM (game_data/game.coe) holds one game, asteroids.json, in
slot 0 (btnU). Further files given to the compiler fill slots 1, 2 and 3
(btnR, btnD, btnL) in order. The first game's header is at address 0x004;
each game is stored back to back:

```
header 10 words | palette 16 words | objects 3 x n_obj | key mappings 1 x n_inp | rules 2 x n_rule
```

and the next game starts right after the previous game's last rule word.
Directory word `slot` = `valid 1, version 2, hdr_addr`. Unused directory
words and all remaining ROM words are 0.

Note: in the provided game.coe, directory words 1-3 are not 0: they point
to 0x08F, 0x10D and 0x174, where nothing is stored, so the loader finds a
wrong magic number and refuses those slots (LED 15). A ROM written by
gamec.py from asteroids.json alone has 0 there instead; slot 0 is identical.

## Header (10 words)

| Header field | From the JSON | Default |
|---|---|---|
| magic, n_obj, n_inp, n_rule | 0xA5, and the counts after `repeat` expansion | |
| obj_base, inp_base, rule_base, pal_base | the addresses given by linking | |
| xmin, xmax, ymin, ymax | `arena` | required |
| win_score | `win_score` (0 = no points target) | 0 |
| init_score | `init_score` | 0 |
| lose_at_zero | `lose_at_zero` | false |
| init_lives | `lives` (0..9; 0 = this game has no lives) | 0 |
| spin_step, spin_max | `spin.step`, `spin.max` | 0, 0 |
| hud_en, hud_p1_x, hud_p2_x, hud_y | `hud.enabled`, `hud.p1_x`, `hud.p2_x`, `hud.y` | enabled = true if `hud` is given; no `hud` = all 0 |
| collider_mask | bit c set if class c is the `self` of at least one COLLIDE rule | derived |
| controlled_mask | bit c set if class c has `"controlled": true` | derived |
| mark_color | palette index of `mark_color` | palette entry 3 |
| wave_watch, wave_reload | one bit per class named in `wave.watch` / `wave.reload` | 0 |

## Palette (16 words)

`palette` is a list of `[name, "#RGB"]`; entry i is word i, value = the three
hex digits as a 12-bit number (`"#F64"` -> 0x00000F64). Entries 0, 1, 2 are
the background, player 1 and player 2 colours. Missing entries are 0.
Objects and `mark_color` refer to colours by name.

## Classes

`classes` is a list; the class number is the position in the list (max 16).
`"controlled": true` marks a class whose velocity is zeroed every frame (it
moves only while a key is held).

## Objects (3 words each)

| Record field | From the JSON | Default |
|---|---|---|
| x, y | `x`, `y` (+ repeat offsets) | required |
| w, h | `w`, `h` | required |
| vx, vy | `vx`, `vy` (for a pool object vx is the launch speed) | 0 |
| color | palette index of `color` | required |
| class | class number of `class` | required |
| owner | `owner`: NONE 0, P1 1, P2 2 | NONE |
| enabled | `enabled`; otherwise 0 for `"pool": true` objects, 1 for the rest | |
| bmode | CLAMP 0, BOUNCE 1, WRAP 2, DESTROY 3 | CLAMP |
| tmode | COUNTDOWN 0, FREEZE 1, LIFETIME 2, SHIELD 3 | COUNTDOWN |
| dir | E 0, NE 1, N 2, NW 3, W 4, SW 5, S 6, SE 7 (RIGHT/LEFT/UP/DOWN also accepted) | E |
| hp, timer | `hp`, `timer` | 0 |
| mark | `mark` | false |
| cool | always 0 in the ROM | 0 |

`"repeat": {"nx": a, "ny": b, "dx": p, "dy": q}` turns one entry into a x b
records, row by row (iy outer, ix inner), at x + ix*p, y + iy*q. The engine
copies object i to object-RAM address i, so the order in the file is the
order in RAM (and the drawing order: higher index on top).

## Key mappings (1 word each)

| Field | From the JSON | Default |
|---|---|---|
| op | MOVE 1, SPAWN 2 | required |
| button | P1_UP 0, P1_DOWN 1, P1_LEFT 2, P1_RIGHT 3, P1_ACT 4, P2_UP 5, P2_DOWN 6, P2_LEFT 7, P2_RIGHT 8, P2_ACT 9 | required |
| trigger | HELD 0, PRESSED 1 | HELD |
| owner | NONE 0, P1 1, P2 2 | NONE |
| class | class number | required |
| param (MOVE) | dir (RIGHT 0, LEFT 1, DOWN 2, UP 3), set_facing, speed | set_facing false |
| param (SPAWN) | pool (class number of the shots), cooldown (frames) | cooldown 0 |

## Rules (2 words each)

| Field | From the JSON | Default |
|---|---|---|
| event | COLLIDE 0, EDGE 1 | required |
| self | class number | required |
| other | COLLIDE: class number of `other`; EDGE: mask of `edges` (LEFT 1, RIGHT 2, TOP 4, BOTTOM 8) | required |
| owner_rel | ANY 0, SAME 1, DIFFERENT 2 | ANY |
| last | `last` | false |
| motion | NONE 0, BOUNCE 1, STOP 2 | NONE |
| spin, copy_owner, copy_color, flip_x, flip_y | booleans | false |
| score_sel | `score.player`: NONE 0, SELF_OWNER 1, OTHER_OWNER 2, SELF_OPPONENT 3, OTHER_OPPONENT 4, P1 5, P2 6 | NONE |
| score_delta | `score.delta`, -8..7, two's complement in 4 bits | 0 |
| counter | `score.counter`: SCORE 0, LIVES 1 | SCORE |
| self_fate, other_fate | NONE 0, DAMAGE 1, DESTROY 2, RESPAWN 3, SPLIT 4 | NONE |
| split_class | class number of `split` (only with a SPLIT fate) | 0 |

## What the compiler checks

gamec.py rejects a file with a message naming the game, the entry and the
key when: a required key is missing or a key is unknown; a name (class,
colour, button...) is not defined; a value is out of the field's range; there
are more than 64 objects, 32 key mappings, 32 rules, 16 classes or 16
colours; the games do not fit in 2048 words; or the worst-case update could
overrun vertical blanking. It also prints that worst case for every game.
