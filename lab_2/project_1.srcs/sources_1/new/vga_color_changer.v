`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/17/2026 11:53:34 AM
// Design Name: 
// Module Name: vga_color_changer
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


module vga_color_changer(
        input   wire        clk,
        input   wire        btnU,
        input   wire        btnC,
        output  wire        v_sync,
        output  wire        h_sync,
        output  wire [3:0]  vga_red,
        output  wire [3:0]  vga_green,
        output  wire [3:0]  vga_blue
    );
    
    // Genereate btnU pulse logic
    (* ASYNC_REG = "TRUE" *) reg btnU_ff_1;
    (* ASYNC_REG = "TRUE" *) reg btnU_ff_2;
    (* ASYNC_REG = "TRUE" *) reg btnU_ff_prev;
    
    always @(posedge clk) begin
        btnU_ff_1 <= btnU;
        btnU_ff_2 <= btnU_ff_1;
        btnU_ff_prev <= btnU_ff_2;
    end
    
    wire btnU_pulse = btnU_ff_2 & ~btnU_ff_prev;
    
    
    // Genereate btnC logic
    reg btnC_ff_1;
    reg btnC_ff_2;
    
    always @(posedge clk) begin
        btnC_ff_1 <= btnC;
        btnC_ff_2 <= btnC_ff_1;
    end
    
    
    // VGA Values
    reg [2:0] color = 0;
    reg [9:0] horizontal_pixel = 0;
    reg [9:0] vertical_pixel = 0;
    reg [1:0] pixel_div = 0;
    wire pixel_tick = (pixel_div == 3);
    wire visible;
    
    // Main Logic
    always @(posedge clk) begin : vga_driver
    
        // Reset
        if (btnC_ff_2) begin
            color <= 0;
        end
        
        if (btnU_pulse) begin
            color <= color + 1;
        end
                
    
        // Run on every 4th tick
        pixel_div <= pixel_div + 1;
        if (pixel_tick) begin
            // End of horizontal
            if (horizontal_pixel == 799) begin
            
                // Reset horizontal
                horizontal_pixel <= 0;
                
                if (vertical_pixel == 524) begin
                    // Reset vertical
                    vertical_pixel <= 0;
                end else begin
                    vertical_pixel <= vertical_pixel + 1;
                end
            end else begin
                horizontal_pixel <= horizontal_pixel + 1;
            end
        end
    end
    
    assign h_sync = ~((horizontal_pixel > 656) && (horizontal_pixel < 752));
    assign v_sync = ~((vertical_pixel > 490) && (vertical_pixel < 492));
    
    assign visible = (horizontal_pixel < 640) && (vertical_pixel < 480);
    
    assign vga_red      = (color[0] & visible) ? 4'b1111 : 4'b0000;
    assign vga_green    = (color[1] & visible) ? 4'b1111 : 4'b0000;
    assign vga_blue     = (color[2] & visible) ? 4'b1111 : 4'b0000;
    
    
    
endmodule
