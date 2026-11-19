// Copyright 1986-2017 Xilinx, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2017.4 (win64) Build 2086221 Fri Dec 15 20:55:39 MST 2017
// Date        : Thu Nov 19 02:22:38 2026
// Host        : DESKTOP-8H87QI6 running 64-bit major release  (build 9200)
// Command     : write_verilog -force -mode synth_stub
//               C:/Users/sudan/Downloads/final_project/kit/asteroids_student/vivado_proj/asteroids.srcs/sources_1/ip/obj_ram_bmg/obj_ram_bmg_stub.v
// Design      : obj_ram_bmg
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7a35tcpg236-1
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
(* x_core_info = "blk_mem_gen_v8_4_1,Vivado 2017.4" *)
module obj_ram_bmg(clka, wea, addra, dina, douta, clkb, web, addrb, dinb, 
  doutb)
/* synthesis syn_black_box black_box_pad_pin="clka,wea[0:0],addra[5:0],dina[95:0],douta[95:0],clkb,web[0:0],addrb[5:0],dinb[95:0],doutb[95:0]" */;
  input clka;
  input [0:0]wea;
  input [5:0]addra;
  input [95:0]dina;
  output [95:0]douta;
  input clkb;
  input [0:0]web;
  input [5:0]addrb;
  input [95:0]dinb;
  output [95:0]doutb;
endmodule
