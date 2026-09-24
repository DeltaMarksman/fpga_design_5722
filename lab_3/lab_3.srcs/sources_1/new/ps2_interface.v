`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/24/2026 11:49:51 AM
// Design Name: 
// Module Name: ps2_interface
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module ps2_interface(
    input   wire        clk,
    input   wire        btnC,
    input   wire        PS2Clk,
    input   wire        PS2Data,
    output  reg [15:0]  led    
    );
    
    // Genereate btnC logic
    reg btnC_ff_1;
    reg btnC_ff_2;
    
    always @(posedge clk) begin
        btnC_ff_1 <= btnC;
        btnC_ff_2 <= btnC_ff_1;
    end
    
    
    // PS2 decoding
    (* ASYNC_REG = "TRUE" *) reg [1:0] ps2clk_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ps2data_sync;
    wire ps2clk_s = ps2clk_sync[1];
    wire ps2data_s = ps2data_sync[1];
    
    reg  ps2clk_prev;
    wire ps2_falling_edge = ps2clk_prev && !ps2clk_s;

    
    always @(posedge clk) begin
        ps2clk_sync <= {ps2clk_sync[0], PS2Clk};
        ps2data_sync <= {ps2data_sync[0], PS2Data};
    end
        
    always @(posedge clk) begin
        ps2clk_prev <= ps2clk_s;
    end

    
    
    // Main logic
    reg [3:0]   bit_count;
    reg [7:0]   scan_code;
    reg         parity_bit;
    
    always @(posedge clk) begin
        if (btnC) begin
            bit_count <= 4'd0;
            scan_code <= 8'd0;
            parity_bit <= 1'b0;
            led <= 16'h0000;
        end else begin
            if (ps2_falling_edge) begin
                case (bit_count)
                    4'd0: begin
                        if (ps2data_s == 1'b0)
                            bit_count <= 4'd1;
                    end
                    4'd1: begin 
                        scan_code[0] <= ps2data_s; 
                        bit_count <= 4'd2;
                    end
                    4'd2: begin 
                        scan_code[1] <= ps2data_s; 
                        bit_count <= 4'd3;
                    end
                    4'd3: begin 
                        scan_code[2] <= ps2data_s; 
                        bit_count <= 4'd4;
                    end
                    4'd4: begin 
                        scan_code[3] <= ps2data_s; 
                        bit_count <= 4'd5;
                    end
                    4'd5: begin 
                        scan_code[4] <= ps2data_s; 
                        bit_count <= 4'd6;
                    end
                    4'd6: begin 
                        scan_code[5] <= ps2data_s; 
                        bit_count <= 4'd7;
                    end
                    4'd7: begin 
                        scan_code[6] <= ps2data_s; 
                        bit_count <= 4'd8;
                    end
                    4'd8: begin 
                        scan_code[7] <= ps2data_s; 
                        bit_count <= 4'd9;
                    end
                    4'd9: begin 
                        parity_bit <= ps2data_s; 
                        bit_count <= 4'd10;
                    end                                                                                                                                            
                    4'd10: begin
                        bit_count <= 4'd0;
                        if (ps2data_s && ((^scan_code) ^ parity_bit)) begin
                            case (scan_code)
                                8'h45: led <= 16'h0000;
                                8'h16: led <= 16'h0001;
                                8'h1E: led <= 16'h0002;
                                8'h26: led <= 16'h0003;
                                8'h25: led <= 16'h0004;
                                8'h2E: led <= 16'h0005;
                                8'h36: led <= 16'h0006;
                                8'h3D: led <= 16'h0007;
                                8'h3E: led <= 16'h0008;
                                8'h46: led <= 16'h0009;
                                default: led <= 16'hFFFF;
                            endcase
                        end
                    end
                    default: bit_count <= 4'd0;
                endcase
            end
        end
    end
endmodule
