// obj_ram.v - writable runtime object state: 64 records x 96 bits.
//
// A thin wrapper around the Block Memory Generator core obj_ram_bmg that you
// create in Vivado (see the handout, "Game Memories"):
//   True Dual Port RAM, width 96 and depth 64 on both ports, Always Enabled,
//   operating mode READ_FIRST, no output registers (1 clock), no init file.
//   port A : read/write, used by the loader and the engine
//   port B : read only, used by the renderer (web tied to 0)
`default_nettype none
module obj_ram #(
    parameter AW = 6,
    parameter DW = 96
) (
    input  wire          clk,
    input  wire          a_we,
    input  wire [AW-1:0] a_addr,
    input  wire [DW-1:0] a_din,
    output wire [DW-1:0] a_dout,
    input  wire [AW-1:0] b_addr,
    output wire [DW-1:0] b_dout
);
    obj_ram_bmg u_bmg (
        .clka  (clk),
        .wea   (a_we),
        .addra (a_addr),
        .dina  (a_din),
        .douta (a_dout),
        .clkb  (clk),
        .web   (1'b0),
        .addrb (b_addr),
        .dinb  ({DW{1'b0}}),
        .doutb (b_dout)
    );
endmodule
`default_nettype wire
