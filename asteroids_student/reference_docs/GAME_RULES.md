# Asteroids Versus: exact simplified rules

Two players share one screen and one keyboard. Both shoot the rocks for
points, and they can shoot each other. Everything in this file is data in
`games/*.json`; none of it is in the Verilog.

| | Player 1 | Player 2 |
|---|---|---|
| Colour | orange-red | light blue |
| Move (8 directions) | W A S D | arrow keys |
| Fire | F | Enter |

Board buttons: **btnU / btnR / btnD / btnL** load variant 0 / 1 / 2 / 3,
**btnC** restarts the current one. Game 0 loads by itself at power-up.

## The standard game (slot 0, `games/asteroids.json`)

**Screen.** 640 x 480 and it wraps on all four sides: anything that leaves
on one side comes back on the other, ships, rocks and shots alike.

**Ships.** 14 x 14 squares. A ship moves only while a direction key is held,
3 pixels per frame on each axis; two keys at once give a diagonal. The ship
faces the way it last moved, and a small white square on its edge shows that
direction (one of eight). When it stops it keeps facing the same way.

**Shooting.** One shot per press of the fire key, out of the side or corner
the ship faces, 6 pixels per frame on each axis. At most one shot every 8
frames, and at most three of a player's shots in flight. A shot lives 45
frames (it wraps too). A player's shots pass through their own ship and
through the other player's shots.

**Rocks.** Squares in three sizes: large 32, medium 16, small 8. A wave
starts with three large rocks near the edges of the screen.

| A shot hits | What happens | Points for the shooter |
|---|---|---|
| a large rock | the shot is gone; the rock breaks into two medium rocks | 1 |
| a medium rock | the shot is gone; the rock breaks into two small rocks | 2 |
| a small rock | both are gone | 3 |
| the other ship | the shot is gone; that ship loses a life | 5 |

Fragments appear at the centre of the broken rock and fly off 45 degrees to
either side of its old path, a little faster (if the rock moved at (vx, vy),
the fragments move at (vx - vy, vy + vx) and (vx + vy, vy - vx)).

**Losing a life.** A ship that touches any rock, or is hit by the other
player's shot, loses a life and restarts at its start position. A rock it
touches breaks exactly as if it had been shot, but nobody scores for it.
After every start the ship is shielded for 60 frames (one second): it blinks,
it can move and shoot, and nothing can hit it.

**Waves.** As soon as no rock of any size is left, the three large rocks
return to their starting places and the next wave begins.

**End.** Each player starts with **3 lives** (squares under the score). The
round ends at the end of a frame in which a player reaches **60 points**
(that player wins) or a player has **0 lives** (the other player wins). Both
at once is a draw. The picture freezes and a frame in the winner's colour
appears (half and half for a draw).

## The variants

The provided ROM (game_data/game.coe) holds only the standard game in slot 0.
The variants below are examples of what the same engine can run; they are
a starting point for the difficulty-level bonus.

The same engine and the same rules, different data:

| Slot | Name | What is different |
|---|---|---|
| 0 | Asteroids Versus | the standard game above |
| 1 | Asteroids Swarm | each wave is six fast medium rocks (no large ones) |
| 2 | Asteroids Duel | one large rock per wave, 5 lives, four shots each, a shot every 6 frames, a ship hit is worth 7 points, first to 40 |
| 3 | Asteroids Sudden Death | 1 life, faster large rocks, no points target: the last ship flying wins |

## What was simplified and why

| Classic Asteroids | Here | Reason |
|---|---|---|
| Rotate, thrust, inertia | 8-way movement at constant speed | Chosen for this project (much simpler, no trigonometry) |
| Diagonal speed equal to straight speed | Diagonal is about 1.4 times faster | Each axis gets the full speed; avoids multiplication |
| Outlined, irregular rocks | Solid squares | Rectangles only; sprites are a possible extension |
| Random fragment directions and wave layouts | Fixed rules (45 degrees either side) and the same start positions every wave | No random-number generator in the engine; play still varies with the players' moves |
| Ship explosion and respawn delay | Instant restart with a one-second blinking shield | Reuses the per-object timer |
| Shots collide with each other, ships collide with each other | They pass through | Fewer rules; keeps the ships' fight about shooting |
| Hyperspace, flying saucers | Not included | Out of scope |

## Earlier games

The four games of the first version of this project (Pong, Competitive
Breakout, Tank Duel, Obstacle Race) are kept in `tests/legacy/`. They are not
in the ROM image, but the test suite compiles them and runs them on the
extended engine to show that the new operations did not break anything.
