// buttons.v - board push-button handling.
//
//   button_debounce : synchroniser + debouncer + one-shot for one button
//   game_select     : turns the five one-shots into a pending load request
`default_nettype none

// ---------------------------------------------------------------------------
// The raw pin goes through two flip-flops, then must differ from the accepted
// level for 2**CNT_BITS consecutive clocks (10.5 ms at 100 MHz) before the
// level changes. press is high for exactly one clock when the level goes
// from 0 to 1, however long the button is held.
//
// *** TASK 2: complete button_debounce. game_select below is provided.
// ---------------------------------------------------------------------------
module button_debounce #(
    parameter CNT_BITS = 20
) (
    input  wire clk,
    input  wire rst,
    input  wire btn,
    output reg  level,
    output reg  press
);
    reg [1:0] meta;                 // two-flip-flop synchroniser
    reg [CNT_BITS-1:0] cnt;         // how long the input has disagreed with 'level'

    // ---------------------------------------------------------------------
    // TASK 2 - insert the synchroniser, debouncer and one-shot here.
    //   * meta: shift btn through two flip-flops every clock
    //   * while meta[1] == level, hold cnt at 0
    //   * while meta[1] != level, count up; when cnt is all ones, accept
    //     the new level
    //   * press is high for exactly ONE clock, on the clock where level
    //     changes from 0 to 1
    //   * rst (synchronous) clears level and cnt
    // ---------------------------------------------------------------------
    always @(posedge clk) begin
        meta  <= {meta[0], btn};            // synchroniser runs every clock
        press <= 1'b0;                      // one-clock pulse by default
        if (rst) begin
            level <= 1'b0;
            cnt   <= {CNT_BITS{1'b0}};
        end else if (meta[1] == level) begin
            cnt   <= {CNT_BITS{1'b0}};      // input agrees: restart the count
        end else if (&cnt) begin
            level <= meta[1];               // disagreed for 2**CNT_BITS clocks
            cnt   <= {CNT_BITS{1'b0}};
            press <= meta[1];               // 0 -> 1 only
        end else begin
            cnt   <= cnt + 1'b1;
        end
    end
    // ------------------------------------------------------ END TASK 2 ----
endmodule

// ---------------------------------------------------------------------------
// Button presses are collected in a 5-bit pending mask until the game logic
// takes the request at the next frame boundary (load_ack). When more than one
// button is pending, the priority is fixed:
//
//     btnU (game 0) > btnR (game 1) > btnD (game 2) > btnL (game 3) > btnC
//
// so presses that arrive within the same frame (16.7 ms) always resolve the
// same way, and a game select beats a restart. btnC alone reloads the game
// that is currently running. After reset the mask requests game 0.
// ---------------------------------------------------------------------------
module game_select (
    input  wire       clk,
    input  wire       rst,
    input  wire       press_u,
    input  wire       press_r,
    input  wire       press_d,
    input  wire       press_l,
    input  wire       press_c,
    input  wire [1:0] cur_game,
    input  wire       load_ack,
    output wire       load_req,
    output wire [1:0] load_game
);
    reg [4:0] pend;     // {C, L, D, R, U}

    always @(posedge clk) begin
        if (rst)
            pend <= 5'b00001;
        else
            pend <= (load_ack ? 5'b00000 : pend) |
                    {press_c, press_l, press_d, press_r, press_u};
    end

    assign load_req  = |pend;
    assign load_game = pend[0] ? 2'd0 :
                       pend[1] ? 2'd1 :
                       pend[2] ? 2'd2 :
                       pend[3] ? 2'd3 : cur_game;
endmodule
`default_nettype wire
