// game_rom.v - the game-definition ROM: 2048 x 32 bits of block RAM.
//
// A thin wrapper around the Block Memory Generator core game_rom_bmg that you
// create in Vivado (see the handout, "Game Memories"):
//   Single Port ROM, width 32, depth 2048, Always Enabled, no output
//   registers (read latency exactly 1 clock), remaining memory locations
//   filled with 0, init file game_data/game.coe.
// MEM_FILE is accepted only so the parent modules need no change; it is
// ignored - the contents come from the .coe file inside the IP.
`default_nettype none
module game_rom #(
    parameter AW       = 11,
    parameter MEM_FILE = "games.mem"     // unused in this version
) (
    input  wire          clk,
    input  wire [AW-1:0] addr,
    output wire [31:0]   dout
);
    game_rom_bmg u_bmg (
        .clka  (clk),
        .addra (addr),
        .douta (dout)
    );
endmodule
`default_nettype wire
