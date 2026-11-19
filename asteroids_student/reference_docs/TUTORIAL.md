# Tutorial: building a data-driven game engine in hardware

This tutorial explains the design from first principles, in the order you
would build it with students. Each lesson names the file to read, the idea to
take away, and the test that proves it. The last part traces four complete
scenarios through the hardware clock by clock.

Reading order for the code: `rtl/ge_defs.vh` (the vocabulary), `games/asteroids.json`
(a game), `rtl/ge_units.v` (the operations), `rtl/game_engine.v` (the
sequencer), `rtl/vga_render.v` (the picture), then the rest.

## The idea in one page

A conventional FPGA game is a state machine written for that game. This
project separates two things:

- **What can happen at all** is hardware: an object can move, stop at the
  arena edge, bounce, wrap, be destroyed, overlap another object, be pushed
  out of it, change owner, change a score, lose a hit point, respawn, or
  launch a pooled object, split into pooled fragments, or bring a whole wave
  back. That list is fixed in the RTL.
- **What does happen in this game** is data: which objects exist, which key
  moves which class of object, and which of the operations above are switched
  on when a shot meets a rock. That is in block RAM.

The engine is a `for` loop over tables, implemented as a state machine. It is
not a processor: a rule is not an instruction that is decoded and executed,
it is a row of switches for a fixed sequence of steps. There is no program
counter, no branch, no arithmetic chosen by the data. Compare:

| Soft CPU | This engine |
|---|---|
| ROM holds instructions | ROM holds records (objects, mappings, rules) |
| The program decides what is read next | The sequencer always reads the same tables in the same order |
| Behaviour is unbounded | Behaviour is the fixed operation list; the compiler can bound the cost of any game |
| A new game is a new program | A new game is a new table |

The game number is used in exactly one place: the loader reads directory word
`game` to find that game's header. After that, no module knows which game is
running. Search the RTL for `game_id` to confirm it: it only drives two LEDs
and the restart request.

## Lesson 1: block RAM answers one clock late

File: `rtl/game_rom.v`, `rtl/obj_ram.v`. Test: `sim/tb_mem.v`.

Block RAM is synchronous. The address is captured at a clock edge and the
data appears after it:

```
            ___     ___     ___     ___
clk     ___|   |___|   |___|   |___|   |___
addr    ---< A0    >< A1    >-----------------
dout    ------------< mem[A0] >< mem[A1] >----
                    ^ usable in the clock AFTER the one that presented A0
```

Two rules follow, and every memory user in this design obeys them:

1. *Present, then capture.* A state machine needs one state that drives the
   address and a following state that takes the data.
2. *Keep the index with the data.* When the data arrives you must still know
   which record it is. Here the index register simply does not change
   between the two states.

`tb_mem.v` checks the latency explicitly: it changes the address and checks
that the output still shows the old word just before the clock edge and the
new word after it.

The ROM is written so that Vivado infers block RAM: an array, an `initial
$readmemh`, and a read that is registered and nothing else. An asynchronous
read (`assign dout = mem[addr]`) would turn 65 kbit into LUTs.

## Lesson 2: VGA is two counters and a deadline

File: `rtl/vga_timing.v`. Test: `sim/tb_core.v`.

A 640 x 480 picture is 800 x 525 pixel slots; the extra ones are the blanking
during which the monitor's beam (historically) flew back. We run on 100 MHz
and count pixels on a clock enable that is true every fourth clock, so one
line is 3 200 clocks and one frame is 1 680 000.

Blanking is not wasted time. It is where this design does all of its work:

- **Horizontal blanking** (160 pixels = 640 clocks, every line): the renderer
  reads the object RAM and prepares the next line.
- **Vertical blanking** (45 lines = 144 000 clocks, every frame): the engine
  updates the game.

`tb_core.v` does not look inside the design to find pixels. It behaves like a
monitor: it measures the sync pulses on the pins and takes the pixel 48
pixel-times after HSYNC ends as x = 0. If the picture and the sync signals
were delayed by different amounts, the captured frame would be shifted and
the comparison with the expected picture would fail.

## Lesson 3: inputs are not synchronous, and buttons bounce

Files: `rtl/buttons.v`, `rtl/ps2_rx.v`, `rtl/kbd_state.v`.
Tests: `sim/tb_buttons.v`, `sim/tb_ps2.v`.

**Synchronise.** A pin that changes near a clock edge can leave a flip-flop
undecided for a moment. Two flip-flops in a row give that moment a whole
clock to resolve. Every external input goes through such a pair first.

**Debounce.** A push button makes and breaks contact several times within a
few milliseconds. `button_debounce` accepts a new level only after the input
has disagreed with the current level for 2^20 clocks (10.5 ms) without
interruption.

**One-shot.** "Load game 1" must happen once, not 60 times a second while the
button is held. The debouncer emits `press` for exactly one clock when the
level goes from 0 to 1.

**Priority.** The one-shots set bits in a pending mask that is cleared when
the game logic takes the request at the next frame boundary. If several bits
are set, the order is fixed: btnU, btnR, btnD, btnL, then btnC. So two
buttons pressed within the same frame always resolve the same way, and a
select beats a restart. Presses that fall into different frames are served
one after the other, so the later one is what you end up with.

**PS/2.** The keyboard drives both lines. For each byte it sends 11 bits,
least significant data bit first, and each bit is valid when the keyboard's
clock falls:

```
start(0)  d0 d1 d2 d3 d4 d5 d6 d7  parity(odd)  stop(1)
```

The W key is scan code 0x1D = 0001 1101. On the wire: `0  1 0 1 1 1 0 0 0  1  1`
(start, the eight data bits LSB first, parity 1 because 0x1D has four ones,
stop). `ps2_rx` filters the clock line (a change must last 1.28 us), shifts a
bit in on each falling edge, checks start, parity and stop, and gives up on a
frame that stalls for 2.6 ms.

**Scan codes.** In scan code set 2 a key sends its *make* code when it goes
down, repeats it while held, and sends `F0` followed by the code when it is
released. Some keys have an `E0` prefix: the Up arrow is `E0 75`, its release
`E0 F0 75`. Without the prefix `75` is the keypad 8, so the prefix must be
part of the comparison.

**Key state, not last key.** `kbd_state` keeps one bit per game key and sets
or clears exactly that bit, so any number of keys can be held. The ten bits
are also on LEDs 0 to 9, which is the quickest way to test a keyboard.

**Rollover limits.** Three different things can stop a key from being seen
while others are held:

1. *The keyboard's key matrix.* Cheap keyboards cannot detect some
   combinations of three or more keys (blocking / ghosting). Two keys always
   work; W A S D and the arrow cluster are usually wired to work together,
   but "usually" is all one can say.
2. *The USB link.* On the Basys3 the keyboard is a USB keyboard and a
   microcontroller on the board translates it to PS/2. A USB keyboard in the
   basic ("boot") mode reports at most six ordinary keys at once. Two players
   each holding two directions and their action key is exactly six.
3. *Sampling.* The engine looks at the keys once per frame. A key pressed and
   released entirely between two looks is not seen (about 17 ms; real taps
   are longer).

The PS/2 protocol itself has no limit: every key reports its own press and
release. If a release is lost (keyboard unplugged while a key is down) the
bit stays set until the key is pressed and released again; the self-test
code `AA` that a keyboard sends when it is plugged in clears all ten bits.

## Lesson 4: describe a game as tables

Files: `games/*.json`, `docs/MEMORY_FORMAT.md`, `tools/gamec.py`.
Test: `tests/test_compiler.py`.

Open `games/asteroids.json`. It has four parts:

- **classes**: names for kinds of object (`SHIP`, `SHOT`, `ROCK_L`, `ROCK_M`,
  `ROCK_S`). `SHIP` is `controlled`: it stands still unless a key moves it.
- **objects**: rectangles with a class, an owner, a velocity and a few modes.
  Shots and rock fragments are *pools*: disabled objects waiting to be used.
- **inputs**: "while P1_UP is held, ships owned by P1 move up at speed 3 and
  face the way they move"; "when P1_ACT is pressed, launch a SHOT".
- **rules**: "when a SHOT collides with a ROCK_L: destroy the shot, SPLIT the
  rock into two ROCK_M, one point to the shot's owner".

Plus a few header settings: three lives each, the end conditions, which
classes form a wave.

The compiler turns names into numbers, checks everything it can (ranges,
references, capacities, behaviours the hardware does not have, the number of
rectangles that can share a scanline, the worst-case update time) and packs
the records into 32-bit words. Section 13 of MEMORY_FORMAT.md follows one
rule all the way from JSON to the action it causes.

Design decisions worth discussing with students:

- *Rules are switches, not code.* Word 1 of a rule has a field per action
  step. Adding a step (SPLIT was added for this game) means adding hardware
  and a field, which keeps the cost of every game predictable.
- *Pools instead of allocation.* Shots and fragments exist from the start,
  disabled. "Creating" one means finding a disabled slot of the right class
  and owner and reloading it from ROM. The number of rocks that can ever be on
  screen is then known in advance, which is what lets the compiler prove the
  scanline limit.
- *Scores belong to players, ownership belongs to objects.* "Points to the
  player who fired" needs no special hardware: a shot carries its owner, and a
  rule gives a point to `SELF_OWNER`.
- *Generic, not Asteroids-shaped.* None of the new operations knows about
  rocks: SPLIT replaces any object by two pooled ones, the wave reload watches
  any classes. The four games of the first version still run (`tests/legacy`).

## Lesson 5: the sequencer

File: `rtl/game_engine.v`. Tests: `tests/directed.py`, co-simulation.

Read the state list at the top of the file as a program outline:

```
S_IDLE                         wait for the frame boundary, sample the keys
S_P1_ADDR/LOAD/EXEC/WR         pass 1: for each object: timer, zero velocity
S_IN_ADDR/LOAD/CHK             pass 2: for each input mapping: is its key condition true?
  S_IT_ADDR/LOAD/EXEC/WR         for each object: does it match? MOVE
  S_SP_ADDR/LOAD/CHK/PLACE/WRB   SPAWN: find a free pool slot, place it
S_MV_ADDR/LOAD/CHK/ADD/EDGE/POST pass 3: for each object: move, arena edges
  S_CO_ADDR/LOAD/PEN/CHK/POST    for each other object: overlap?
S_A_WR                           write the object back
S_RS_ADDR/W0/W1/CHK/ACT1/ACT2/SELF/OTHER/NEXT   scan the rules for one event
S_RL_0..3                      reload one record from the ROM
S_END                          win / lose / draw
```

Every `_ADDR` state drives a memory address and every `_LOAD` (or `_W0`,
`_W1`) state captures the data: Lesson 1 applied about ten times. The rule
scan and the record reload are used from several places; the state to
continue with afterwards is kept in a register (`rs_ret`, `rl_ret`).

The engine keeps the object it is working on in `a_rec` and the other object
in `b_rec`, both whole 96-bit records, and writes them back when it has
finished with them. All arithmetic reads those registers.

## Lesson 6: the operations

File: `rtl/ge_units.v`. Test: `tests/directed.py`.

Each block is a small pure function. The one worth working through on the
board is the collision test, because it also decides *how* the objects
collided:

```
dl = A.right  - B.left      dr = B.right  - A.left
dt = A.bottom - B.top       db = B.bottom - A.top
overlap    = all four > 0
x depth    = min(dl, dr)    y depth = min(dt, db)
axis       = x if x depth <= y depth else y
A's side   = low if (on x: dl <= dr) (on y: dt <= db)
```

Example (`tests/directed.py`, scenario `bounce_x`): an 8 x 8 ball at x = 118
moving right, a wall from x = 120 to 130. dl = 126 - 120 = 6, dr = 130 - 118
= 12, and vertically 28 and 30. They overlap; x depth 6 is smaller than y
depth 28, so the collision is on x and the ball is on the low side. BOUNCE
puts the ball at 120 - 8 = 112 and makes its x velocity negative.

The directed tests are written exactly like this: a tiny game, a handful of
frames, and expected numbers with the arithmetic in the comments. They are a
good source of exercises ("predict frame 3, then run it").

## Lesson 7: drawing rectangles without a frame buffer

File: `rtl/vga_render.v`. Test: the render step of `sim/run_all.py`.

A 640 x 480 frame buffer at 4 bits per pixel is 1.2 Mbit, two thirds of the
block RAM on the chip. We do not need one: the object table *is* the picture.

Checking 64 objects for every pixel is impossible (four clocks per pixel),
but few objects cross any one line. So, once per line, during horizontal
blanking, the renderer reads all 64 records and copies those that cross the
next line into 32 *line slots*: start x, end x, colour. During the line, 32
comparator pairs watch the pixel counter. This is the scheme classic video
game hardware used for sprites.

If more than 32 rectangles cross one line, the extra ones are missing on
that line and LED 14 lights. The compiler proves for each game that this
cannot happen (it counts, for the worst line, the objects that can never
leave their row plus every object that can move vertically).

## Lesson 8: when may the state change?

File: `rtl/game_logic.v`. Read with ARCHITECTURE.md section 5.

If the engine moved the ball while the renderer was half way down the screen,
the top of the ball could be drawn at the old position and the bottom at the
new one. The usual cure is two copies of the state. Here timing does the job
with one copy: the engine runs only in vertical blanking, the renderer reads
only for visible lines, and a game select is held back until the next frame
boundary. The compiler's cycle bound is what turns "it is fast enough" into a
checked statement.

## Lesson 9: trust, but verify with a model

Files: `tools/gemodel.py`, `sim/cosim.py`, `tests/fuzz.py`.

`gemodel.py` is the specification as a 400-line Python program: same ROM in,
same object records out, frame by frame. The testbench dumps the hardware's
whole object RAM after every frame and the two are compared as text. Scripted
players produce real matches; a generator produces random games that use
every feature of the format. When the hardware and the model disagree, one of
them is wrong about the specification, and either way you have found
something. `tests/mutate.py` shows the other half of the argument: it breaks
the RTL in deliberate ways and checks that the tests notice
(`build/mutation_report.txt` has the last run).

## Four traces

The numbers below are from the shipped image (`build/games.lst`). Traces 1
and 2 are checked by `sim/tb_top.v`, trace 3 uses the arithmetic checked by
the `split` scenario in `tests/directed.py`, trace 4 by the render tests.

### Trace 1: a player presses and releases a movement key

Asteroids Versus, player 1's ship at (200, 233), player 1 presses W.

1. **Wire.** The keyboard sends 0x1D as eleven bits, about 0.9 ms in total.
2. **`ps2_rx`.** Both lines pass the synchronisers and the glitch filters;
   one bit is shifted in per falling clock edge. At the eleventh edge the
   frame is `stop=1, parity=1, data=0x1D, start=0`; `valid` pulses with
   `code = 0x1D`.
3. **`kbd_state`.** `{ext, code}` = `0x01D` selects bit 0, no `F0` came first,
   so `keys[0] <= 1`. LED 0 lights. Nothing in the game has changed yet.
4. **Frame boundary.** At the next `frame_tick` (at most 16.8 ms later) the
   engine leaves `S_IDLE` with `btn_now = 0000000001`.
5. **Pass 1.** The ship (object 0, class SHIP, "controlled") has its velocity
   set to 0 and its timers counted down.
6. **Pass 2, mapping 0.**

   | Clock | State | Memory | What happens |
   |---|---|---|---|
   | 1 | `S_IN_ADDR` | `rom_addr = inp_base + 0 = 0x075` | address presented |
   | 2 | `S_IN_LOAD` | `rom_q = 0x10100037` | captured into `m_rec` |
   | 3 | `S_IN_CHK` | | op 1 MOVE, button 0, trigger HELD, owner 1, class 0; `btn_now[0]` = 1: applies |
   | 4 | `S_IT_ADDR` (i = 0) | `ram_addr = 0` | |
   | 5 | `S_IT_LOAD` | `ram_q` = ship record | captured into `a_rec` |
   | 6 | `S_IT_EXEC` | | class 0, owner 1: match. Parameter 0x0037: axis UP, speed 3, set_facing: `vy <= -3` |
   | 7 | `S_IT_FACE` | | velocity (0, -3): heading N (2) |
   | 8 | `S_IT_WR` | `ram_we`, address 0 | record written back |
   | 9.. | `S_IT_ADDR` ... (i = 1 ...) | | player 2's ship has owner 2: no match; the others are other classes |

   Mapping 1 (S, 0x076) is fetched and rejected in three clocks, and so on.
7. **Pass 3, object 0.** `S_MV_CHK`: enabled, not frozen, moving.
   `S_MV_ADD`: y = 233 - 3 = 230. `S_MV_EDGE`: WRAP, nothing is outside.
   SHIP is a collider class and the shield has run out, so the ship is tested
   against the 28 other objects (`S_CO_*`), then written back (`S_A_WR`).
8. **Picture.** From line 524 the renderer reads the new record. The next
   frame shows the ship 3 pixels higher, with its marker on the top edge.

Release: `F0`, then `1D`, clears `keys[0]`. At the next update pass 1 zeroes
the velocity as always and mapping 0 no longer applies: the ship stops and
keeps heading N. Holding W and D together gives (3, -3) and heading NE,
whichever mapping comes first. `tb_top` checks all of this on the pins.

### Trace 2: a board button selects another game

Versus is running; a player presses btnR (Swarm, slot 1).

1. The raw pin bounces. After the pin has been high for 10.5 ms without a
   break, `button_debounce` raises `press` for one clock.
2. `game_select` sets pending bit 1: `load_req` = 1, `load_game` = 1. The game
   continues; LEDs 11:10 still show 0.
3. At the next `frame_tick` the frame controller starts the loader instead of
   an engine update and pulses `load_ack`, which clears the pending mask.
4. The loader, clock by clock at the start:

   | Clock | State | `rom_addr` | `rom_q` | Stored |
   |---|---|---|---|---|
   | 1 | `L_DIR` | 0x001 | | |
   | 2 | `L_DIRW` | | 0x8002008F | valid, version 2, header at 0x08F |
   | 3 | `L_HDR` | 0x08F | | |
   | 4 | `L_HDRW` | | 0xA51A0A06 | magic A5; 26 objects, 10 mappings, 6 rules |
   | 5 | `L_HDR` | 0x090 | | |
   | 6 | `L_HDRW` | | 0x00F700A9 | objects at 0x0A9, mappings at 0x0F7 |
   | ... | | | | eight more header words (arena, end conditions, display, masks, lives 3, wave classes) |
   | | `L_PAL` / `L_PALW` x16 | 0x099.. | colours | palette RAM |
   | | `L_OBJ`, `L_OBJW` x3, `L_OBJWR` | 0x0A9.. | W0, W1, W2 | one 96-bit write per object, 26 times |
   | | `L_OBJ`, `L_OBJWR` x38 | | | slots 26..63 written as 0 |
   | | `L_FIN` | | | `done` |

   A little over 300 clocks, about 3 microseconds.
5. `done` sets both scores to 0, both lives to 3, the round state to PLAYING,
   and remembers the keys held now. LEDs 11:10 show 1.
6. During line 524 the renderer reads the object RAM again; the next frame
   is Swarm.

### Trace 3: a collision generates an event and triggers a BRAM rule

Versus. Player 1's first shot (object 2, owner P1, moving east) has just
moved to (98, 80). The first large rock (object 8, 32 x 32, velocity (2, 1))
is at (100, 70).

Depths: dl = 98 + 4 - 100 = 2, dr = 100 + 32 - 98 = 34, dt = 80 + 4 - 70 = 14,
db = 70 + 32 - 80 = 22. All positive: the boxes overlap.

| Clock | State | Memory | What happens |
|---|---|---|---|
| 1 | `S_CO_ADDR` (j = 8) | `ram_addr = 8` | the rock's address is presented |
| 2 | `S_CO_LOAD` | `ram_q` = rock record | captured into `b_rec` |
| 3 | `S_CO_PEN` | | `ge_collide` registers dl, dr, dt, db |
| 4 | `S_CO_CHK` | | overlap: COLLIDE event, `r = 0` |
| 5 | `S_RS_ADDR` | `rom_addr = 0x07F` | rule 0, word 0 |
| 6 | `S_RS_W0` | `rom_q = 0x01200000`, `rom_addr = 0x080` | `r0` captured |
| 7 | `S_RS_W1` | `rom_q = 0x03221100` | `r1` captured |
| 8 | `S_RS_CHK` | | COLLIDE, self SHOT (1), other ROCK_L (2), any owner: **match** |
| 9 | `S_RS_ACT1` | | no motion, no ownership change |
| 10 | `S_RS_ACT2` | | score counter, SELF_OWNER = player 1: score1 + 1. Self fate DESTROY: shot disabled, its turn ends after this rule |
| 11 | `S_RS_OTHER` | | other fate SPLIT: parent = (100, 70, 32 x 32, v (2, 1), no owner) remembered, rock disabled |
| 12 | `S_SPL_WB` | `ram_we`, address 8 | disabled rock written back |
| 13-45 | `S_SPL_ADDR/LOAD/CHK` k = 0..10 | `ram_addr = k` | ships, shots, large rocks: not a free ROCK_M |
| 46-48 | k = 11 | | first medium-rock slot: disabled, class ROCK_M, no owner: found |
| 49-52 | `S_RL_0..3` | `rom_addr = obj_base + 33..35` | template record into `b_rec` |
| 53 | `S_SPL_PLACE` | | x = 100 + (32 - 16) / 2 = 108, y = 78, v = (2 - 1, 1 + 2) = (1, 3), enabled |
| 54 | `S_SPL_WR` | `ram_we`, address 11 | fragment 0 written |
| 55 | `S_SPL_NEXT` | | second fragment, search from 0 again |
| 56-100 | | | slot 12 found (slot 11 is now in use); placed at (108, 78) with v = (2 + 1, 1 - 2) = (3, -1), written |
| 101 | `S_SPL_NEXT` | | done: the rule scan stops |
| 102-103 | `S_RS_NEXT`, `S_RS_ADDR` | | scan finished |
| 104 | `S_CO_POST` | | nothing to write (the rock was written in clock 12) |
| 105 | `S_A_WR` | `ram_we`, address 2 | disabled shot written back; the next object follows |

In the next frame the large rock is gone and two medium rocks fly apart from
its centre, 45 degrees either side of its old path.

### Trace 4: runtime object state determines a pixel's colour

Versus, player 1's ship at (200, 233), 14 x 14, colour 1, heading E, `mark`
set, shield expired. Which colour are pixels (205, 239) and (211, 239)?

The marker is 4 x 4 inside the ship on the side it faces: x = 200 + 14 - 4 =
210, y = 233 + (14 - 4) / 2 = 238, so it covers columns 210..213 and lines
238..241.

**During line 238, in horizontal blanking**: `scan_tick` with `scan_y` = 239.

| Clock after `scan_tick` | `ob_addr` | `ob_q` | `ob_r` | Slot action |
|---|---|---|---|---|
| 1 | 0 | | | |
| 2 | 1 | record 0 | | |
| 3 | 2 | record 1 | record 0 | ship covers lines 233..246: **slot 0** = {200, 214, colour 1}; marker covers 238..241: **slot 1** = {210, 214, mark_color 3} |
| 4 | 3 | record 2 | record 1 | the other ship, if on this line, goes into slot 2 |
| ... 66 | | | | records 2..63: shots and rocks that cross line 239 |

**During line 239** (pixel clock enables, four clocks apart), for x = 211:

| `pix_ce` | Counter | Stage 1 | Stage 2 | Stage 3 (pins) |
|---|---|---|---|---|
| n | `hcount` = 211 | | | |
| n+1 | 212 | slots 0 and 1 hit | | |
| n+2 | 213 | | the hit slot filled last wins: slot 1, colour 3 | |
| n+3 | 214 | | | RGB = palette[3] = FFF (white) |

For x = 205 only slot 0 hits: palette[1] = F64, orange-red. HSYNC and VSYNC
went through the same three stages, so on the monitor these really are
columns 205 and 211 of line 239. While the shield runs and bit 2 of the
timer is 1, the scan skips the ship record entirely, which is the blink.

## Budgets

Details are in ARCHITECTURE.md sections 8 and 9.

**Memory.** ROM 2048 x 32 = 65 536 bits (two RAMB36), 511 words used by the
four variants. Object RAM 64 x 96 = 6 144 bits. Palette 192 bits of LUT RAM.
Line slots 768 flip-flops. The chip has 1 800 000 bits of block RAM.

**Time.** The update must fit in the 44 blanking lines before the renderer
needs the RAM: 140 800 clocks. Compiler-proven worst cases: Versus and Sudden
Death 13 182, Swarm 10 045, Duel 9 452 clocks.

## Exercises

1. Change `"lives"` in `games/asteroids.json`, recompile, and predict which
   ROM word changes (`build/games.lst` before and after).
2. Add an extra-small rock (4 x 4) that small rocks split into. What else has
   to change, and what does the compiler say about the scanline budget?
3. Make the two players' shots destroy each other. One rule; which owner
   relation?
4. Add a point bonus for clearing a wave. Which existing operation could
   carry it, or what new one is needed?
5. Real Asteroids ships rotate and drift. List the record fields and
   operations that inertia would need (hint: sub-pixel position).
6. Fragments always fly 45 degrees either side. Design a pseudo-random
   variant (a linear-feedback shift register in the engine) and explain how
   the reference model stays bit-identical with the hardware.
7. Write a directed test for a ship touching two rocks in the same frame and
   compute the result by hand first. Which rock breaks?
8. Timing: where would you add a pipeline stage if the 13-bit add-and-compare
   in `ge_boundary` missed 10 ns? What happens to the cycle bound?

## A possible four-to-six week plan

| Week | Build | Milestone test |
|---|---|---|
| 1 | VGA timing, a hard-wired rectangle, buttons | `tb_core` timing numbers on a monitor model |
| 2 | Block RAM, the format, the compiler, the loader | `tb_mem`, loader dump equals the compiler's records |
| 3 | Renderer with line slots, palette, score digits | pixel-exact start frames of all four games |
| 4 | Engine passes 1 and 3 without rules, then the rule scan | directed movement and collision scenarios |
| 5 | PS/2, input mappings, SPAWN; the four game files | co-simulation of scripted matches |
| 6 | Board bring-up, timing closure, write-up | play it |
