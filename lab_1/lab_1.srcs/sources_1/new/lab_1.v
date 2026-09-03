`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/03/2026 12:03:43 PM
// Design Name: 
// Module Name: lab_1
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


module lab_1(
        input   wire        clk,
        input   wire        btnU,
        input   wire        btnD,
        input   wire        btnC,
        output  reg  [3:0]  an,
        output  reg  [6:0]  seg                
    );
    
    reg [3:0]   ones = 0;
    reg [3:0]   tens = 0;
    reg [3:0]   current_digit = 0;
    reg [16:0]  counter = 0;
    
    // Genereate btnU pulse logic
    reg btnU_ff_1;
    reg btnU_ff_2;
    reg btnU_ff_prev;
    
    always @(posedge clk) begin
        btnU_ff_1 <= btnU;
        btnU_ff_2 <= btnU_ff_1;
        btnU_ff_prev <= btnU_ff_2;
    end
    
    wire btnU_pulse = btnU_ff_2 & ~btnU_ff_prev;
    
    // Genereate btnD pulse logic
    reg btnD_ff_1;
    reg btnD_ff_2;
    reg btnD_ff_prev;
    
    always @(posedge clk) begin
        btnD_ff_1 <= btnD;
        btnD_ff_2 <= btnD_ff_1;
        btnD_ff_prev <= btnD_ff_2;
    end
    
    wire btnD_pulse = btnD_ff_2 & ~btnD_ff_prev;
    
    // Genereate btnC logic
    reg btnC_ff_1;
    reg btnC_ff_2;
    
    always @(posedge clk) begin
        btnC_ff_1 <= btnC;
        btnC_ff_2 <= btnC_ff_1;
    end
    
    initial begin
        an = 4'b1110;
    end
    
    // Main logic
    always @(posedge clk) begin
    
        // Reset
        if (btnC_ff_2) begin
            tens <= 4'b0;
            ones <= 4'b0;
        end
        
        // Buttons
        if (btnD_pulse) begin
            if (ones == 9) begin
                ones <= 0;
                if (tens == 9) begin
                    tens <= 0;
                end else begin
                    tens <= tens + 1;
                end
            end else begin
                ones <= ones + 1;
            end
        end
        
        if (btnU_pulse) begin
            if (tens == 9) begin
                tens <= 0;
            end else begin
                tens <= tens + 1;
            end 
        end
        
        // Driving
        if (counter[16] == 1) begin
            counter <= 0;
            if (an == 4'b1110) begin
                an <= 4'b1101;
            end else begin
                an <= 4'b1110;
            end
        end else begin
            counter <= counter + 1;
        end 
        
        // Drive current digit
        if (an == 4'b1110) begin
            current_digit <= ones;
        end else begin
            current_digit <= tens;
        end
        
        case (current_digit)
            4'd0: seg <= 7'b1000000;
            4'd1: seg <= 7'b1111001;
            4'd2: seg <= 7'b0100100;
            4'd3: seg <= 7'b0110000;
            4'd4: seg <= 7'b0011001;
            4'd5: seg <= 7'b0010010;
            4'd6: seg <= 7'b0000010;
            4'd7: seg <= 7'b1111000;
            4'd8: seg <= 7'b0000000;
            4'd9: seg <= 7'b0011000;
            default: seg = 7'b1111111;
        endcase
    end
endmodule
