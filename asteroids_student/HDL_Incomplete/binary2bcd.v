// binary2bcd.v - algorithmic (shift-and-add-3, "double dabble") conversion of
// a 7-bit binary number 0..99 into two binary-coded decimal digits.
//
//   start  : sampled in IDLE; when high, 'in' is latched and a conversion
//            begins (holding start high converts continuously)
//   bcd1   : tens digit  } registered; they change only when a conversion
//   bcd0   : ones digit  } finishes, so they never show a half-done value
//   done   : one clock when bcd1 / bcd0 have just been updated
//   count, state : exposed for testbenches only
//
// A conversion must finish within 64 clocks of start (the scores are drawn
// on screen; they change during vertical blanking, which is far longer).
//
// *** TASK 8: complete this module. Keep the port list exactly as it is.
// Inputs above 99 are outside the specification (the tens digit would need
// more than 4 bits); the engine saturates every score at 99.
`default_nettype none
module binary2bcd (
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [6:0] in,
    output reg  [3:0] bcd1,
    output reg  [3:0] bcd0,
    output reg        done,
    output wire [2:0] count,
    output wire [1:0] state
);
    // ---------------------------------------------------------------------
    // TASK 8 - design the converter here (see the handout, "Binary to BCD").
    // Requirements:
    //   * algorithmic: shift-and-add-3 ("double dabble"), one shift per
    //     state-machine step - NOT a lookup table or a / and % operator
    //   * a state machine with an idle state that waits for start
    //   * bcd1 / bcd0 are registers that change ONLY when a conversion has
    //     finished (they are drawn on the screen while you work)
    //   * done pulses for one clock when bcd1 / bcd0 have been updated
    //   * rst is synchronous and clears bcd1 / bcd0 to 0
    //   * count and state show your step counter and state register
    // Also write tb_binary2bcd.v (required, see the rubric).
    // ---------------------------------------------------------------------
    // States: IDLE -> (ADD -> SHIFT) x7 -> DONE -> IDLE.  One conversion takes
    // 1 + 7*2 + 1 = 16 clocks, well inside the 64-clock limit.
    localparam S_IDLE  = 2'd0,
               S_ADD   = 2'd1,
               S_SHIFT = 2'd2,
               S_DONE  = 2'd3;

    reg [1:0] st;
    reg [2:0] n;            // shifts done so far, 0..7
    reg [6:0] bin;          // binary bits still to shift out (MSB first)
    reg [3:0] t1, t0;       // working tens / ones digits

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            st   <= S_IDLE;
            n    <= 3'd0;
            bin  <= 7'd0;
            t1   <= 4'd0;
            t0   <= 4'd0;
            bcd1 <= 4'd0;
            bcd0 <= 4'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (start) begin
                        bin <= in;
                        t1  <= 4'd0;
                        t0  <= 4'd0;
                        n   <= 3'd0;
                        st  <= S_ADD;
                    end
                end
                S_ADD: begin                // add 3 to every digit >= 5
                    if (t1 >= 4'd5) t1 <= t1 + 4'd3;
                    if (t0 >= 4'd5) t0 <= t0 + 4'd3;
                    st <= S_SHIFT;
                end
                S_SHIFT: begin              // {t1, t0, bin} <<= 1
                    t1  <= {t1[2:0], t0[3]};
                    t0  <= {t0[2:0], bin[6]};
                    bin <= {bin[5:0], 1'b0};
                    if (n == 3'd6) begin
                        n  <= 3'd0;
                        st <= S_DONE;
                    end else begin
                        n  <= n + 3'd1;
                        st <= S_ADD;
                    end
                end
                S_DONE: begin               // publish the finished result
                    bcd1 <= t1;
                    bcd0 <= t0;
                    done <= 1'b1;
                    st   <= S_IDLE;
                end
            endcase
        end
    end

    assign count = n;
    assign state = st;
    // ------------------------------------------------------ END TASK 8 ----
endmodule
`default_nettype wire
