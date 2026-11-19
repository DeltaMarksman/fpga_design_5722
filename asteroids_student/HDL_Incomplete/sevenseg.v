// sevenseg.v - Basys3 four-digit display: player 1 score on the left two
// digits, player 2 score on the right two, a decimal point between them.
// Anodes and segments are active low; one digit is lit at a time.
`default_nettype none
module sevenseg #(
    parameter REFRESH_BITS = 18     // full cycle = 2**18 clocks = 2.6 ms
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [6:0] score1,
    input  wire [6:0] score2,
    input  wire       hex_mode,     // 1: show hex_val instead of the scores
    input  wire [15:0] hex_val,
    input  wire       hex_dp,       // decimal point of the rightmost digit in hex mode
    output reg  [6:0] seg,          // {g,f,e,d,c,b,a}, active low
    output reg        dp,
    output reg  [3:0] an
);
    // binary -> BCD for both scores (Task 8). start is held high, so each
    // converter re-converts continuously; its outputs only change at the end
    // of a conversion, 15 clocks after a score changes.
    wire [3:0] s1_tens, s1_ones, s2_tens, s2_ones;
    binary2bcd u_bcd1 (.clk(clk), .rst(rst), .start(1'b1), .in(score1),
                       .bcd1(s1_tens), .bcd0(s1_ones), .done(), .count(), .state());
    binary2bcd u_bcd2 (.clk(clk), .rst(rst), .start(1'b1), .in(score2),
                       .bcd1(s2_tens), .bcd0(s2_ones), .done(), .count(), .state());

    function [6:0] seg7;            // bit 0 = a ... bit 6 = g, 1 = lit
        input [3:0] d;
        case (d)
            4'd0: seg7 = 7'h3F; 4'd1: seg7 = 7'h06; 4'd2: seg7 = 7'h5B; 4'd3: seg7 = 7'h4F;
            4'd4: seg7 = 7'h66; 4'd5: seg7 = 7'h6D; 4'd6: seg7 = 7'h7D; 4'd7: seg7 = 7'h07;
            4'd8: seg7 = 7'h7F; 4'd9: seg7 = 7'h6F; 4'd10: seg7 = 7'h77; 4'd11: seg7 = 7'h7C;
            4'd12: seg7 = 7'h39; 4'd13: seg7 = 7'h5E; 4'd14: seg7 = 7'h79; default: seg7 = 7'h71;
        endcase
    endfunction

    reg [REFRESH_BITS-1:0] cnt;
    wire [1:0] sel = cnt[REFRESH_BITS-1:REFRESH_BITS-2];

    always @(posedge clk) begin
        if (rst) begin
            cnt <= {REFRESH_BITS{1'b0}};
            seg <= 7'h7F; dp <= 1'b1; an <= 4'hF;
        end else begin
            cnt <= cnt + 1'b1;
            if (hex_mode) case (sel)
                2'd3: begin an <= 4'b0111; seg <= ~seg7(hex_val[15:12]); dp <= 1'b1; end
                2'd2: begin an <= 4'b1011; seg <= ~seg7(hex_val[11:8]);  dp <= 1'b0; end
                2'd1: begin an <= 4'b1101; seg <= ~seg7(hex_val[7:4]);   dp <= 1'b1; end
                default: begin an <= 4'b1110; seg <= ~seg7(hex_val[3:0]); dp <= ~hex_dp; end
            endcase else case (sel)
                2'd3: begin an <= 4'b0111; seg <= ~seg7(s1_tens); dp <= 1'b1; end
                2'd2: begin an <= 4'b1011; seg <= ~seg7(s1_ones); dp <= 1'b0; end
                2'd1: begin an <= 4'b1101; seg <= ~seg7(s2_tens); dp <= 1'b1; end
                default: begin an <= 4'b1110; seg <= ~seg7(s2_ones); dp <= 1'b1; end
            endcase
        end
    end
endmodule
`default_nettype wire
