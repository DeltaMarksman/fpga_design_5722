# Architecture

One Basys3 bitstream, one engine, a two-player Asteroids game in four
variants. The engine is a fixed sequencer around a handful of fixed datapath
blocks (move, boundary, box overlap, bounce/stop, spawn, split, counters,
damage, wave reload). It has no instruction set and no
program counter. The game number never reaches the engine: it is used once,
by the loader, as an index into the ROM directory. Everything that differs
between games is data in block RAM, described in
[MEMORY_FORMAT.md](MEMORY_FORMAT.md).

## 1. Assumptions

- Digilent Basys3 (XC7A35T-1CPG236C), 100 MHz oscillator, Vivado.
- A USB keyboard on the board's USB-HID port; the on-board PIC24 presents it
  to the FPGA as a PS/2 keyboard sending scan code set 2. The FPGA only
  listens; it never sends commands to the keyboard.
- A monitor that accepts 640 x 480 with a 25.000 MHz pixel rate (59.52 Hz).
- Solid rectangles only, 16 colours per game, whole-pixel motion.
- One clock domain. No reset button (all five buttons have game functions);
  a power-on reset counter starts the design.
- The four variants are in the bitstream. Loading new definitions at run time is
  out of scope.

## 2. Modules

```
top_basys3                   board pins, power-on reset, LEDs
├─ button_debounce x5        2-FF synchroniser, 10.5 ms debounce, one-shot
├─ game_select               pending-request mask with fixed priority
├─ ps2_rx                    PS/2 frame receiver (sync, glitch filter, parity, time-out)
├─ kbd_state                 scan code set 2 -> ten "key is held" bits
├─ sevenseg                  scores on the board's four digits
└─ game_core                 everything below works without the board
   ├─ vga_timing             pixel enable, counters, sync, frame_tick, scan_tick
   ├─ game_logic             frame controller + memories
   │  ├─ game_rom            2048 x 32 block RAM, read only   (all four variants)
   │  ├─ obj_ram             64 x 96 true dual-port block RAM (live objects)
   │  ├─ game_loader         ROM -> configuration registers, palette, object RAM
   │  └─ game_engine         the per-frame update sequencer
   │     ├─ ge_boundary      arena edge handling (CLAMP/BOUNCE/WRAP/DESTROY)
   │     ├─ ge_collide       box overlap + penetration axis
   │     ├─ ge_response      BOUNCE / STOP / SPIN
   │     ├─ ge_spawn         placement of a pooled object (8 headings)
   │     └─ ge_split         placement and velocity of a fragment
   └─ vga_render             line slots, markers, score digits, life squares, end frame,
      ├─ hud_digits          palette, pixel pipeline
      └─ hud_pips
```

| File | Lines of interest |
|---|---|
| `rtl/ge_defs.vh` | generated bit positions and enumerations (never edited by hand) |
| `rtl/game_engine.v` | the update sequencer; one state per memory access or datapath step |
| `rtl/ge_units.v` | the four datapath blocks, each purely a function of records |
| `rtl/game_loader.v` | the load sequence |
| `rtl/vga_render.v` | scanline scan and pixel pipeline |

### Interfaces that matter

| Signal | From -> to | Meaning |
|---|---|---|
| `keys[9:0]` | `kbd_state` -> engine | bit n = logical button n is held (clean, synchronous) |
| `load_req`, `load_game[1:0]` | `game_select` -> `game_logic` | level: a load is pending, and which slot |
| `load_ack` | `game_logic` -> `game_select` | one clock: request taken at this frame boundary |
| `frame_tick` | `vga_timing` -> `game_logic` | one clock: vertical blanking begins, state may change |
| `scan_tick`, `scan_y` | `vga_timing` -> `vga_render` | one clock: prepare the slots for line `scan_y` |
| `rom_addr` / `rom_q` | loader or engine <-> ROM | 11-bit address, 32-bit data one clock later |
| `ram_*` (port A) | loader or engine <-> object RAM | read/write, 96-bit records |
| `ob_addr` / `ob_q` (port B) | renderer <-> object RAM | read only |
| `pal_we`, `pal_idx`, `pal_rgb` | loader -> renderer | palette write during a load |
| `score1/2`, `lives1/2`, `gstate` | engine -> renderer, board | 0..99 and 0..9 each; 0 playing, 1/2 winner, 3 draw |

The loader and the engine share the ROM port and RAM port A through a plain
multiplexer selected by `loader busy`; the frame controller never starts one
while the other is running.

## 3. Clocking, reset and timing enables

Everything is clocked by the 100 MHz board clock. There is no MMCM and no
second clock domain, which is why the whole design simulates in any Verilog
simulator without vendor libraries.

- `pix_ce` is high one clock in four. VGA counters and the pixel pipeline
  advance only on `pix_ce`.
- `frame_tick` is one clock per frame; the engine runs at most once per
  frame, at full clock speed, and is idle for the remaining 98 % of it.
- Reset: registers have defined power-up values in the bitstream; a 16-clock
  counter then releases a synchronous reset. `game_select` comes out of reset
  requesting slot 0, so game 0 loads at the first frame boundary (within
  16.8 ms).
- The asynchronous inputs (five buttons, PS/2 clock and data) each pass
  through two flip-flops before any logic sees them.

## 4. VGA timing

| | Visible | Front porch | Sync | Back porch | Total |
|---|---|---|---|---|---|
| Horizontal (pixels) | 640 | 16 | 96 | 48 | 800 |
| Vertical (lines) | 480 | 10 | 2 | 33 | 525 |

Pixel rate 25.000 MHz (40 ns), line 32.0 us (31.25 kHz), frame 16.8 ms
(59.52 Hz). HSYNC and VSYNC are active low. RGB is 4 bits per colour and is
forced to 0 whenever the pixel is outside the 640 x 480 window.

The renderer's pipeline is three pixel clocks deep. RGB, HSYNC and VSYNC all
pass through the same three stages, so on the pins the first visible pixel of
a line comes exactly 48 pixels after HSYNC rises, and the first visible line
exactly 33 lines after VSYNC rises. The testbench `sim/tb_core.v` rebuilds
the picture from the pins using only those two numbers.

## 5. The frame, and why no frame buffer is needed

```
line   0 .. 479    visible. Renderer owns the object RAM (port B), engine idle.
line 480, pixel 0  frame_tick: the loader or the engine starts.
line 480 .. 523    update window: 44 lines = 140 800 clocks.
                   Measured worst case in gameplay co-simulation: 1 731 clocks (1.2 %).
line 524, pixel 640  scan_tick for line 0: renderer reads the object RAM again.
```

**Strategy: one copy of the state, changed only at the frame boundary.** The
engine writes the object RAM only between `frame_tick` and its `done`; the
renderer reads it only in the horizontal blanking of lines 524 and 0..478.
The two activities are separated by at least 43 lines, so the renderer can
never see a half-updated frame and there is nothing to double-buffer.
Palette, configuration and scores also change only in that window (loads are
deferred to `frame_tick` for the same reason).

Two guards make a violated assumption visible instead of silent: LED 15 is
set if the engine or loader is still busy when a `scan_tick` or the next
`frame_tick` arrives, and the compiler refuses games whose proven worst case
exceeds the 140 800-clock window.

**Input-to-screen delay.** Keys are sampled at `frame_tick`. The result is on
screen from the top of the very next frame, 1.4 ms later, and fully drawn
16.8 ms after that.

## 6. Update sequence

One update is three passes over the object table plus an optional wave check
(the precise semantics are in MEMORY_FORMAT.md sections 11 and 12; this is
the hardware view).

| When | What | States in `game_engine.v` |
|---|---|---|
| `start` | sample keys, compute newly-pressed keys | `S_IDLE` |
| pass 1 | timers, cooldowns, LIFETIME expiry, zero controlled velocities | `S_P1_*` |
| pass 2 | for each input mapping whose key condition holds, MOVE (and heading) or SPAWN on matching objects | `S_IN_*`, `S_IT_*` (incl. `S_IT_FACE`), `S_SP_*` |
| pass 3 | per object: add velocity, arena edges (EDGE event), collisions with every other object (COLLIDE events) unless frozen or shielded | `S_MV_*`, `S_CO_*`, `S_A_WR` |
| per event | scan the rule table, run the fixed action steps for each match | `S_RS_*` |
| SPLIT | write the parent back, search the pool twice, place two fragments | `S_SPL_*` |
| RESPAWN / SPAWN / SPLIT / wave | re-read one 3-word record from the ROM | `S_RL_0..3` |
| wave | is any watched object left? if not, reload the wave classes | `S_WV_*`, `S_WR_*` |
| end | win / lose / draw, remember keys | `S_END` |

The sequencer has 58 states. SPLIT needs two extra index-like registers: `k`
for the fragment search (the collision loop's `j` must survive it) and the
remembered parent `p_x, p_y, p_w, p_h, p_vx, p_vy, p_owner`, because `b_rec`
is reused for the fragments.

The working registers `a_rec` (self) and `b_rec` (other) hold whole 96-bit
records. Datapath blocks see those registers, never a memory output, so every
arithmetic path starts at a flip-flop.

### Memory latency in the sequencer

Every memory access is two states:

```
clock n    state X_ADDR   address driven (combinationally from the state and an index)
           rising edge:   the memory samples the address
clock n+1  state X_LOAD   data is on rom_q / ram_q; it is copied into a register
clock n+2  ...            logic works on the register
```

The index (`i`, `j`, `m` or `r`) is not changed between the two states, so
data and index stay paired without a separate tag pipeline. Where two words
are read back to back (rule words, record reload) the second address is
driven in the same clock in which the first data word is captured:

```
          S_RS_ADDR      S_RS_W0          S_RS_W1        S_RS_CHK
rom_addr  rule_base+2r   rule_base+2r+1   -              -
rom_q     -              word 0           word 1         -
action    -              r0 <= rom_q      r1 <= rom_q    match on r0
```

## 7. Renderer

- **Scan** (once per line, in horizontal blanking, for the next line): the
  64 records are read one per clock. Two clocks later each is tested against
  the line number; a visible hit is copied, clipped to 0..640, into the next
  free of 32 *line slots* `{x_start, x_end, colour}`. An object with the
  `mark` bit also fills the following slot with its 4 x 4 facing marker
  (`mark_color`), so the marker is drawn on top of it. A SHIELD object whose
  timer has bit 2 set is skipped (it blinks). 64 + 3 clocks out of the 640
  available.

  ```
  clock n    ob_addr = k
  clock n+1  ob_q  = record k   -> ob_r          (no logic directly after the RAM)
  clock n+2  ob_r  = record k   -> hit test, slot written at the clock edge
  ```
- **Pixel pipeline** (on `pix_ce`):
  1. each slot compares `x_start <= hcount < x_end`; score-digit and border
     hits are computed from `hcount`, `vcount`;
  2. priority: end-of-round frame, then score digits, then the hit slot that
     was filled last (so a higher object index is drawn on top), then
     background (index 0);
  3. palette lookup; black outside the visible window.
- **Scores** are drawn as seven-segment shapes made of rectangles
  (20 x 36 pixel cells), in palette colours 1 and 2; when the game has lives,
  one 6 x 6 square per life sits 40 pixels below each score (`hud_pips`).

## 8. Memory budget

| Memory | Bits | Implementation | Yosys mapping |
|---|---|---|---|
| Game ROM, 2048 x 32 | 65 536 | inferred block RAM | 2 RAMB36E1 |
| Object RAM, 64 x 96 dual port | 6 144 | inferred block RAM | 3 RAMB36E1 (one per 32 data bits) |
| Palette, 16 x 12 | 192 | distributed RAM | 2 RAM32M |
| Line slots, 32 x 24 | 768 | flip-flops | |
| Working records, rule and mapping words, SPLIT parent | 340 | flip-flops | |
| Configuration | about 220 | flip-flops | |

The XC7A35T has 50 RAMB36 (1 800 kbit); this design uses 5 in the Yosys
mapping, of which only 4 % of the bits are occupied. Vivado may pack the
small object RAM differently (for example into RAMB18s); the scripts print
what it chose. ROM occupancy is 511 of 2048 words for the four variants;
four games at full capacity (64 objects, 32 mappings, 32 rules each) need
1 260 words.

## 9. Cycle budget

Clocks per step, from the state sequence:

| Step | Clocks |
|---|---|
| pass 1, per object | 3, or 4 if the record is written back |
| pass 2, per mapping | 3 to fetch and test, + 1 at the end if it triggered |
| pass 2, per object tested | 3; + 1 for a MOVE (+ 1 more with `set_facing`); a SPAWN adds 3 per pool slot examined, + 7 on success |
| pass 3, per object | 3 if idle, 7 if it moved |
| pass 3, per other object tested | 3 if disabled, 4 if no overlap, 5 + rule scan if overlapping |
| rule scan | 4 per rule + 1; a rule that fires adds 4, + 5 for a self RESPAWN, + 4 for an other RESPAWN, + 2 + 2 x (3 n + 7) for a SPLIT |
| wave | 3 per object to look, then 3 per object + 5 per reloaded record |
| end | 1 |

The compiler turns this into a guaranteed bound for each game
(`cycle_bound()` in `tools/gamec.py`, printed in `build/memory_map.txt`). It
assumes every key is active, every object is enabled, every collider overlaps
every other object at once, and every rule that could match fires with its
most expensive fates. The one saving it takes is guaranteed by the hardware:
when every rule for a class pair disables or respawns the self object, at
most one of those pairs can fire per object per frame. The real cost is far
lower; both are shown, with the measured maximum taken over the whole
gameplay co-simulation:

| Variant | Objects | Colliders | Bound (clocks) | Share of the 140 800 budget | Measured max |
|---|---|---|---|---|---|
| Versus | 29 | 8 | 13 182 | 9.4 % | 1 731 |
| Swarm | 26 | 8 | 10 045 | 7.1 % | 1 478 |
| Duel | 17 | 10 | 9 452 | 6.7 % | 1 222 |
| Sudden Death | 29 | 8 | 13 182 | 9.4 % | 1 657 |

A load takes at most 332 clocks (measured over the 32 loads of the game-switching test). The pathological case the compiler guards
against is a game with dozens of collider objects: 64 colliders with 32 rules
would be bounded at about 560 000 clocks and is rejected.

## 10. Block RAM and Vivado

**Primary implementation: inferred block RAM.** No IP is needed.

- `rtl/game_rom.v`: `reg [31:0] mem [0:2047]`, `initial $readmemh("games.mem", mem)`,
  one registered read, `(* rom_style = "block" *)`.
- `rtl/obj_ram.v`: one array, port A `if (we) mem[a] <= d; q <= mem[a];`
  (read-first), port B `q <= mem[a];`, `(* ram_style = "block" *)`; initial
  contents zero.
- Read latency of both: exactly 1 clock. No output register, no enable.

Initialisation: `scripts/create_project.tcl` adds `build/games.mem` to the
project as a *Memory Initialization File*, which is what lets
`$readmemh("games.mem")` resolve in synthesis and in xsim. The contents become
part of the bitstream.

**How to check that block RAM was inferred.**
`scripts/build_bitstream.tcl` lists every RAMB cell after synthesis and
prints an error if none belongs to `u_rom` or `u_obj_ram`. By hand: in the
synthesis log look for the "Block RAM: Preliminary Mapping Report" table, or
run `report_utilization` and read the "Block RAM Tile" row. If the ROM shows
up as LUTs instead, the usual causes are a read that is not registered or an
asynchronous reset on the output register; neither is present here.

**`.mem` and `.coe`.** The compiler writes both with identical words.
`.mem` is the plain hex format `$readmemh` reads. `.coe` is the Block Memory
Generator's own format (it has a radix header and comma-separated values);
`$readmemh` cannot read it, and it is only useful if you choose the IP flow.

**BRAM IP flow.** `scripts/create_project_ip.tcl` (or
`scripts/create_bram_ip.tcl` inside an open project) builds both memories
from the Block Memory Generator and defines `GE_USE_BMG_IP`, which makes
`game_rom.v` and `obj_ram.v` instantiate the cores instead of the inferred
arrays. Nothing else in the RTL changes.

| Setting | `game_rom_bmg` | `obj_ram_bmg` |
|---|---|---|
| Memory type | Single Port ROM | True Dual Port RAM |
| Width x depth | 32 x 2048 | 96 x 64 (both ports) |
| Enables | Always Enabled | Always Enabled (both ports) |
| Primitive / core output registers | off / off | off / off (both ports) |
| Read latency | 1 clock | 1 clock |
| Operating mode | - | READ_FIRST |
| Port use | read | A read/write (loader, engine); B read only (renderer, `web` tied 0) |
| Init | `build/games.coe`, remaining locations 0 | none (all 0) |

The simulation suite checks the wiring of this variant (step 13 of
`run_all.py`) with behavioural stand-ins for the two cores
(`sim/bmg_models.v`); it cannot run Xilinx's own IP models, and the IP
scripts have not been run in Vivado.

## 11. Timing closure

The RTL was written so that no long path crosses a memory output:

- every memory output goes straight into a register (`a_rec`, `b_rec`, `r0`,
  `r1`, `m_rec`, `ob_r`); the one exception is the loader, which stores ROM
  fields directly and compares the 8-bit magic;
- the box overlap test is split over two clocks (`ge_collide` registers the
  four differences);
- the pixel pipeline has three stages, each with one comparison or one
  multiplexer level.

The longest remaining paths are two chained 13-bit additions and a
comparison. That should be comfortable at 10 ns on a -1 Artix-7, but **it has
not been confirmed**: no Vivado timing run was available. If timing fails,
the pixel-pipeline registers only change on `pix_ce` and can be given a
multicycle constraint of 4, and any engine path can take one more state
without affecting behaviour (the cycle budget has a factor of 100 in hand).

## 12. Inputs: buttons and keyboard

**Buttons.** Each of the five pins: two-flip-flop synchroniser, then a
debouncer that accepts a new level after it has been stable for 2^20 clocks
(10.5 ms), then a one-clock `press` pulse on the 0-to-1 change. `game_select`
collects the pulses in a pending mask `{C, L, D, R, U}` until the game logic
acknowledges at the next frame boundary. Priority among pending presses is
fixed: **btnU > btnR > btnD > btnL > btnC**. A select therefore always beats
a restart requested in the same frame, and btnC alone reloads the slot that
is currently loaded. Presses in different frames are served in order.

**Keyboard.** `ps2_rx` receives 11-bit frames (start, 8 data bits LSB first,
odd parity, stop) sampled on the falling edge of the filtered PS/2 clock,
drops frames with a wrong start, parity or stop bit, and resynchronises if a
frame stalls for 2.6 ms. `kbd_state` follows scan code set 2: a make code
sets the key's bit, `F0` + code clears it, an `E0` prefix selects the
extended keys (the arrows), repeated make codes while a key is held change
nothing. One bit per key is kept, so any combination of the ten game keys
can be held together; the engine samples the ten bits once per frame.

| Bit | Button | Key | Scan code |
|---|---|---|---|
| 0 | P1_UP | W | 1D |
| 1 | P1_DOWN | S | 1B |
| 2 | P1_LEFT | A | 1C |
| 3 | P1_RIGHT | D | 23 |
| 4 | P1_ACT | F | 2B |
| 5 | P2_UP | Up | E0 75 |
| 6 | P2_DOWN | Down | E0 72 |
| 7 | P2_LEFT | Left | E0 6B |
| 8 | P2_RIGHT | Right | E0 74 |
| 9 | P2_ACT | Enter (main) | 5A |

**Rollover limits.** The receiver and the key-state logic impose none. The
limits are outside the FPGA: (1) a keyboard's key matrix may be unable to
report some combinations of three or more keys; (2) a USB keyboard in its
basic report mode carries at most six ordinary keys at once, and on the
Basys3 the keyboard reaches the FPGA through a USB-to-PS/2 bridge, so six
simultaneous keys (two directions and the action key for both players) is
the most that should be relied on; (3) a key pressed and released entirely
between two frame samples is not seen. A lost release code leaves the bit
set until the key is pressed again; the keyboard's power-up code `AA` clears
all bits. LEDs 0 to 9 show the ten bits, which is the quick way to find out
what a particular keyboard can do.
