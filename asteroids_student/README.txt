EEL 5722 - FPGA DESIGN FINAL PROJECT
Two-Player Asteroids on a BRAM-Programmable Game Engine (Digilent Basys3)
=========================================================================

Start with FINAL_PROJECT_STUDENT.pdf.

Folders
-------
HDL_Incomplete/   the Verilog for the Basys 3. Tasks 1-9 are left for you;
                  search the files for "TASK". Every file builds as given.
                  basys3.xdc is the constraints file.
game_data/        game.coe  - the ROM image for the Block Memory Generator:
                              game 0 (Asteroids Versus) only; directory
                              slots 1-3 point to empty memory and are
                              refused by the loader
                  game.mem  - the same words as a $readmemh file
                  game.lst  - every ROM word of game.coe with its meaning
                  memory_map.txt - worst-case update time of game 0
                  asteroids.json - the game description of game 0
tools/            gamec.py    - compiler: game descriptions -> games.coe/.mem
                  coe_view.py / coe_visual.ipynb - decode a .coe file and
                                draw the objects held in chosen lines
                  rommap.py   - prints which ROM address holds what
                  geformat.py - the bit layout of every record
                  gemodel.py  - reference model of the engine (Python): you
                                may use it to work out expected values for
                                your testbenches
scripts/          create_game_rom_bmg.tcl, create_obj_ram_bmg.tcl - create
                  the two Block Memory Generator cores from the Vivado Tcl
                  console
images/           frames of the finished game, captured in simulation.
reference_docs/   GAME_DESCRIPTION.md (JSON -> ROM fields), MEMORY_FORMAT.md
                  (bit-exact ROM format), GAME_RULES.md,
                  ARCHITECTURE.md, TUTORIAL.md. They refer to files as
                  rtl/<name>.v; in this kit those are in HDL_Incomplete/.

Changing the game (changeability demonstration, difficulty-level bonus)
-------------------------------------------------------------------------
  python3 tools/gamec.py game_data/asteroids.json -o build --name game

writes build/game.coe (and .mem, .lst). More game description files after
the first fill slots 1-3 (btnR, btnD, btnL). Copy the new game.coe into
game_data/, run scripts/create_game_rom_bmg.tcl again (or regenerate
game_rom_bmg in the IP catalog) and rebuild the bitstream.
