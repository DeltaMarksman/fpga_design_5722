// kbd_state.v - PS/2 scan code set 2 decoder that keeps one "is held" bit for
// each of the ten game keys. Several keys can be held at the same time; the
// module does not remember "the last key", it tracks every key separately.
//
//   make  code        : key went down      e.g. 1D          (W)
//   break code        : F0, then the code  e.g. F0 1D
//   extended make     : E0, then the code  e.g. E0 75       (Up arrow)
//   extended break    : E0 F0, then code   e.g. E0 F0 75
//   typematic repeat  : the make code again while held - harmless here
//
//   bit  button     key          code
//    0   P1_UP      W            1D
//    1   P1_DOWN    S            1B
//    2   P1_LEFT    A            1C
//    3   P1_RIGHT   D            23
//    4   P1_ACT     F            2B
//    5   P2_UP      Up arrow     E0 75
//    6   P2_DOWN    Down arrow   E0 72
//    7   P2_LEFT    Left arrow   E0 6B
//    8   P2_RIGHT   Right arrow  E0 74
//    9   P2_ACT     Enter        5A      (main Enter; keypad Enter is E0 5A)
//
// Arrows and Enter are accepted with or without E0: on the Basys3 the arrows
// were seen not to work when E0 was required (the USB-to-PS/2 bridge may drop
// it), so keypad 8/2/4/6 and keypad Enter also act as player 2's keys.
// W A S D F must arrive without E0. Codes that are not in the table only clear the prefix
// flags. AA (keyboard self-test passed, sent after power-up or re-plug)
// clears all keys, because any break codes were lost with the power.
//
// *** TASK 4: complete the decoder and the key-state register.
`default_nettype none
module kbd_state (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] code,
    input  wire       valid,
    output reg  [9:0] keys
);
    reg ext;        // E0 seen (the next code is an extended key)
    reg brk;        // F0 seen (the next code is a key release)

    reg [3:0] idx;  // which of the ten keys 'code' is (0..9)
    reg       hit;  // 1 if 'code' (with ext) is one of the ten game keys

    // ---------------------------------------------------------------------
    // TASK 4a - combinational decoder: from {ext, code} set hit and idx
    // using the table at the top of this file. Remember that the arrows
    // and Enter must be accepted with OR without the E0 prefix.
    // ---------------------------------------------------------------------
    always @* begin
        hit = 1'b1;
        idx = 4'd0;
        case ({ext, code})
            9'h01D:          idx = 4'd0;    // W        (no E0 only)
            9'h01B:          idx = 4'd1;    // S
            9'h01C:          idx = 4'd2;    // A
            9'h023:          idx = 4'd3;    // D
            9'h02B:          idx = 4'd4;    // F
            9'h175, 9'h075:  idx = 4'd5;    // Up    / keypad 8
            9'h172, 9'h072:  idx = 4'd6;    // Down  / keypad 2
            9'h16B, 9'h06B:  idx = 4'd7;    // Left  / keypad 4
            9'h174, 9'h074:  idx = 4'd8;    // Right / keypad 6
            9'h05A, 9'h15A:  idx = 4'd9;    // Enter / keypad Enter
            default:         hit = 1'b0;
        endcase
    end
    // ----------------------------------------------------- END TASK 4a ----

    // ---------------------------------------------------------------------
    // TASK 4b - key-state register. Only act when valid is high:
    //   E0          -> remember ext
    //   F0          -> remember brk
    //   other code  -> if hit: keys[idx] becomes 1 for a make, 0 for a
    //                  break; else if it is AA with no prefix: clear all
    //                  keys; in every case clear ext and brk
    //   rst (synchronous) clears keys, ext and brk
    // Same E0 / F0 flag idea as the lab decoder, extended to ten keys.
    // ---------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            keys <= 10'd0;
            ext  <= 1'b0;
            brk  <= 1'b0;
        end else if (valid) begin
            if (code == 8'hE0) begin
                ext <= 1'b1;
            end else if (code == 8'hF0) begin
                brk <= 1'b1;
            end else begin
                if (hit)
                    keys[idx] <= ~brk;
                else if ((code == 8'hAA) && !ext && !brk)
                    keys <= 10'd0;
                ext <= 1'b0;
                brk <= 1'b0;
            end
        end
    end
    // ----------------------------------------------------- END TASK 4b ----
endmodule
`default_nettype wire
