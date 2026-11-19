// ps2_rx.v - PS/2 device-to-host receiver.
//
// A PS/2 frame is 11 bits, sent by the keyboard LSB first, each bit valid on
// the falling edge of the keyboard's clock (10 - 16.7 kHz):
//     start(0)  d0 d1 d2 d3 d4 d5 d6 d7  parity(odd)  stop(1)
//
// Both lines are asynchronous to the 100 MHz clock, so each one goes through
//   1. a two-flip-flop synchroniser (metastability)
//   2. a glitch filter: the filtered value changes only after the input has
//      been stable for 2**FILTER_BITS clocks (1.28 us by default)
// Data is sampled on the falling edge of the filtered clock.
//
// A frame with a wrong start, parity or stop bit is dropped (frame_err).
// If the clock stops in the middle of a frame for 2**TIMEOUT_BITS clocks
// (2.6 ms) the bit counter is cleared, so one lost edge cannot shift every
// later frame.
//
// *** TASK 3: the synchronisers, glitch filters and edge detector are
//     provided; you write the frame receiver at the end of the module.
`default_nettype none
module ps2_rx #(
    parameter FILTER_BITS  = 7,
    parameter TIMEOUT_BITS = 18
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       ps2_clk,
    input  wire       ps2_data,
    output reg  [7:0] code,
    output reg        valid,        // one clock: code holds a good byte
    output reg        frame_err     // one clock: a frame was dropped
);
    // synchronisers
    reg [1:0] c_meta, d_meta;
    always @(posedge clk) begin
        c_meta <= {c_meta[0], ps2_clk};
        d_meta <= {d_meta[0], ps2_data};
    end

    // glitch filters
    reg c_f, d_f;
    reg [FILTER_BITS-1:0] c_cnt, d_cnt;
    always @(posedge clk) begin
        if (rst) begin
            c_f <= 1'b1; d_f <= 1'b1;
            c_cnt <= {FILTER_BITS{1'b0}}; d_cnt <= {FILTER_BITS{1'b0}};
        end else begin
            if (c_meta[1] == c_f)
                c_cnt <= {FILTER_BITS{1'b0}};
            else begin
                c_cnt <= c_cnt + 1'b1;
                if (&c_cnt) c_f <= c_meta[1];
            end
            if (d_meta[1] == d_f)
                d_cnt <= {FILTER_BITS{1'b0}};
            else begin
                d_cnt <= d_cnt + 1'b1;
                if (&d_cnt) d_f <= d_meta[1];
            end
        end
    end

    reg c_prev;
    wire c_fall = c_prev & ~c_f;

    reg [3:0]  nbits;                   // bits received so far, 0..10
    reg [9:0]  sh;                      // the previous 10 bits, oldest in sh[0]
    reg [TIMEOUT_BITS-1:0] idle;        // clocks since the last falling edge

    // ---------------------------------------------------------------------
    // TASK 3 - insert the frame receiver here (see the handout, "PS/2
    // Receiver"). Every clock:
    //   * valid and frame_err default to 0 (they are one-clock pulses)
    //   * c_prev <= c_f
    //   * on c_fall: clear idle, shift d_f into sh from the top, and
    //       - if this is the 11th bit (nbits == 10): check start = 0,
    //         odd parity, stop = 1 on the frame {d_f, sh}; on success
    //         load code and pulse valid, otherwise pulse frame_err;
    //         set nbits back to 0
    //       - otherwise count nbits up
    //   * no edge but a frame in progress: count idle up; when it is all
    //     ones, set nbits to 0 and pulse frame_err (resynchronise)
    //   * rst (synchronous) clears c_prev to 1 and everything else to 0
    // Adapted from the lab receiver (shift on falling edge, idle time-out),
    // with start / parity / stop checking added.
    // ---------------------------------------------------------------------
    wire [10:0] frame = {d_f, sh};      // [0] start, [8:1] data, [9] parity, [10] stop

    always @(posedge clk) begin
        if (rst) begin
            valid     <= 1'b0;
            frame_err <= 1'b0;
            c_prev    <= 1'b1;
            nbits     <= 4'd0;
            sh        <= 10'd0;
            idle      <= {TIMEOUT_BITS{1'b0}};
            code      <= 8'd0;
        end else begin
            valid     <= 1'b0;
            frame_err <= 1'b0;
            c_prev    <= c_f;

            if (c_fall) begin
                idle <= {TIMEOUT_BITS{1'b0}};
                sh   <= {d_f, sh[9:1]};
                if (nbits == 4'd10) begin
                    nbits <= 4'd0;
                    if ((frame[0] == 1'b0) && (frame[10] == 1'b1) && (^frame[9:1])) begin
                        code  <= frame[8:1];
                        valid <= 1'b1;
                    end else begin
                        frame_err <= 1'b1;
                    end
                end else begin
                    nbits <= nbits + 4'd1;
                end
            end else if (nbits != 4'd0) begin
                if (&idle) begin
                    nbits     <= 4'd0;
                    frame_err <= 1'b1;
                end else begin
                    idle <= idle + 1'b1;
                end
            end
        end
    end
    // ------------------------------------------------------ END TASK 3 ----
endmodule
`default_nettype wire
