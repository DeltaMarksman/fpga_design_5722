`timescale 1ns / 1ps
module lab5_top(
    input CLK100MHZ,
    input btnC,
    input PS2Clk,
    input PS2Data,
    output [3:0] vgaRed,
    output [3:0] vgaGreen,
    output [3:0] vgaBlue,
    output Hsync,
    output Vsync,
    output [15:0] led
);
    wire clk = CLK100MHZ;

    //button sync
    reg [1:0] btn_s = 0;
    always @(posedge clk) btn_s <= {btn_s[0], btnC};
    wire clr = btn_s[1];

    //filter and buffer control
    reg front = 0;
    reg [7:0] cnt = 0;
    wire done;
    wire key0_press;
    wire busy;
    wire [15:0] lpf_addr;
    wire [7:0] lpf_wdata;
    wire lpf_we;
    wire [7:0] lpf_rdata;

    always @(posedge clk) begin
        if (done) front <= ~front;
        if (clr) cnt <= 0;
        else if (done) cnt <= cnt + 1;
    end
    assign led = {cnt, 8'b0};

    //ps2 key 0
    ps2_key0 u_kb(.clk(clk), .ps2c(PS2Clk), .ps2d(PS2Data), .key0_press(key0_press));

    //filter engine
    lpf_engine u_lpf(
        .clk(clk), .start(key0_press), .rdata(lpf_rdata),
        .addr(lpf_addr), .wdata(lpf_wdata), .we(lpf_we),
        .busy(busy), .done(done));

    //ping-pong buffers
    wire [15:0] disp_addr;
    wire [7:0] douta0, douta1, doutb0, doutb1;

    block_mem buf0(
        .clka(clk), .wea(lpf_we & front), .addra(lpf_addr), .dina(lpf_wdata), .douta(douta0),
        .clkb(clk), .web(1'b0), .addrb(disp_addr), .dinb(8'h00), .doutb(doutb0));
    block_mem buf1(
        .clka(clk), .wea(lpf_we & ~front), .addra(lpf_addr), .dina(lpf_wdata), .douta(douta1),
        .clkb(clk), .web(1'b0), .addrb(disp_addr), .dinb(8'h00), .doutb(doutb1));

    assign lpf_rdata = front ? douta1 : douta0;
    wire [7:0] disp_pix = front ? doutb1 : doutb0;

    //vga
    vga_img u_vga(
        .clk(clk), .pix(disp_pix), .addr(disp_addr),
        .r(vgaRed), .g(vgaGreen), .b(vgaBlue), .hs(Hsync), .vs(Vsync));
endmodule

//vga timing and image window
module vga_img(
    input clk,
    input [7:0] pix,
    output [15:0] addr,
    output reg [3:0] r = 0,
    output reg [3:0] g = 0,
    output reg [3:0] b = 0,
    output reg hs = 1,
    output reg vs = 1
);
    reg [1:0] ph = 0;
    reg [9:0] hc = 0;
    reg [9:0] vc = 0;
    wire pix_tick = (ph == 2'd3);

    wire in_img = (hc >= 192) && (hc < 448) && (vc >= 112) && (vc < 368);
    wire [9:0] col = hc - 10'd192;
    wire [9:0] row = vc - 10'd112;
    assign addr = {row[7:0], col[7:0]};

    always @(posedge clk) begin
        ph <= ph + 1;
        if (pix_tick) begin
            //register outputs from stable counters
            hs <= ~((hc >= 656) && (hc < 752));
            vs <= ~((vc >= 490) && (vc < 492));
            if (in_img) begin
                r <= pix[7:4];
                g <= pix[7:4];
                b <= pix[7:4];
            end else begin
                r <= 0;
                g <= 0;
                b <= 0;
            end
            if (hc == 799) begin
                hc <= 0;
                vc <= (vc == 524) ? 10'd0 : vc + 1;
            end else hc <= hc + 1;
        end
    end
endmodule

//ps2 receiver and key 0 decoder
module ps2_key0(
    input clk,
    input ps2c,
    input ps2d,
    output reg key0_press = 0
);
    reg [2:0] c_s = 3'b111;
    reg d_s = 1;
    always @(posedge clk) begin
        c_s <= {c_s[1:0], ps2c};
        d_s <= ps2d;
    end
    wire ps2_falling_edge = c_s[2] & ~c_s[1];

    reg [10:0] sh = 0;
    reg [3:0] n = 0;
    reg [14:0] idle = 0;
    reg scan_valid = 0;
    reg [7:0] scan = 0;

    always @(posedge clk) begin
        scan_valid <= 0;
        if (ps2_falling_edge) begin
            idle <= 0;
            sh <= {d_s, sh[10:1]};
            if (n == 4'd10) begin
                n <= 0;
                scan <= sh[9:2];
                scan_valid <= 1;
            end else n <= n + 1;
        end else begin
            if (!idle[14]) idle <= idle + 1;
            else n <= 0;
        end
    end

    reg brk = 0;
    reg ext = 0;
    reg key_dn = 0;
    always @(posedge clk) begin
        key0_press <= 0;
        if (scan_valid) begin
            if (scan == 8'hF0) brk <= 1;
            else if (scan == 8'hE0) ext <= 1;
            else begin
                brk <= 0;
                ext <= 0;
                if (!ext && (scan == 8'h45 || scan == 8'h70)) begin
                    if (brk) key_dn <= 0;
                    else if (!key_dn) begin
                        key_dn <= 1;
                        key0_press <= 1;
                    end
                end
            end
        end
    end
endmodule

//3x3 low-pass filter engine
module lpf_engine(
    input clk,
    input start,
    input [7:0] rdata,
    output [15:0] addr,
    output [7:0] wdata,
    output we,
    output busy,
    output reg done = 0
);
    localparam S_IDLE = 3'd0, S_READ = 3'd1, S_LAST = 3'd2, S_DIV = 3'd3, S_WRITE = 3'd4;
    reg [2:0] st = S_IDLE;
    reg [15:0] pos = 0;
    reg [3:0] tap = 0;
    reg [11:0] sum = 0;
    reg [7:0] avg = 0;

    wire [7:0] row = pos[15:8];
    wire [7:0] col = pos[7:0];

    //tap offsets with edge clamp
    wire [1:0] dr = (tap >= 6) ? 2'd2 : (tap >= 3) ? 2'd1 : 2'd0;
    wire [1:0] dc = (tap == 0 || tap == 3 || tap == 6) ? 2'd0 :
                    (tap == 1 || tap == 4 || tap == 7) ? 2'd1 : 2'd2;
    wire [7:0] trow = (dr == 0) ? ((row == 0) ? 8'd0 : row - 1) :
                      (dr == 1) ? row :
                                  ((row == 255) ? 8'd255 : row + 1);
    wire [7:0] tcol = (dc == 0) ? ((col == 0) ? 8'd0 : col - 1) :
                      (dc == 1) ? col :
                                  ((col == 255) ? 8'd255 : col + 1);

    assign addr = (st == S_WRITE) ? pos : {trow, tcol};
    assign wdata = avg;
    assign we = (st == S_WRITE);
    assign busy = (st != S_IDLE);

    //sum*3641>>15 is sum/9
    wire [23:0] product = sum * 12'd3641;

    always @(posedge clk) begin
        done <= 0;
        case (st)
            S_IDLE: begin
                pos <= 0;
                tap <= 0;
                sum <= 0;
                if (start) st <= S_READ;
            end
            S_READ: begin
                if (tap != 0) sum <= sum + rdata;
                if (tap == 8) st <= S_LAST;
                else tap <= tap + 1;
            end
            S_LAST: begin
                sum <= sum + rdata;
                st <= S_DIV;
            end
            S_DIV: begin
                avg <= product[22:15];
                st <= S_WRITE;
            end
            S_WRITE: begin
                sum <= 0;
                tap <= 0;
                if (pos == 16'hFFFF) begin
                    done <= 1;
                    st <= S_IDLE;
                end else begin
                    pos <= pos + 1;
                    st <= S_READ;
                end
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule

/*
#run in vivado project; set coe path first
set coe [file normalize lena_256.coe]
create_ip -name blk_mem_gen -vendor xilinx.com -library ip -module_name block_mem
set_property -dict [list \
  CONFIG.Memory_Type True_Dual_Port_RAM \
  CONFIG.Write_Width_A 8 CONFIG.Read_Width_A 8 CONFIG.Write_Depth_A 65536 \
  CONFIG.Operating_Mode_A WRITE_FIRST CONFIG.Enable_A Always_Enabled \
  CONFIG.Write_Width_B 8 CONFIG.Read_Width_B 8 CONFIG.Enable_B Always_Enabled \
  CONFIG.Register_PortA_Output_of_Memory_Primitives false \
  CONFIG.Register_PortB_Output_of_Memory_Primitives false \
  CONFIG.Load_Init_File true CONFIG.Coe_File $coe] [get_ips block_mem]
generate_target all [get_ips block_mem]
*/
