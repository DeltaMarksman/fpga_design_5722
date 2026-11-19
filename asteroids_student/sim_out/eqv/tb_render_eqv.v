// tb_render_eqv - runs the original renderer (vga_render_orig) and the
// pipelined one (vga_render) side by side on the same random object tables
// and checks that every VGA output is identical on every clock.
`include "ge_defs.vh"
module tb_render_eqv;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    wire pix_ce, hs, vs, act, ft, st;
    wire [9:0] hc, vc, sy;
    vga_timing u_t (.clk(clk), .rst(rst), .pix_ce(pix_ce), .hcount(hc), .vcount(vc),
                    .hsync_n(hs), .vsync_n(vs), .active(act), .frame_tick(ft),
                    .scan_tick(st), .scan_y(sy));

    reg [95:0] mem [0:63];
    wire [5:0] a_new, a_old;
    reg  [95:0] q_new, q_old;
    always @(posedge clk) begin q_new <= mem[a_new]; q_old <= mem[a_old]; end

    reg        pal_we = 0;
    reg [3:0]  pal_idx = 0;
    reg [11:0] pal_rgb = 0;
    reg [6:0]  sc1 = 37, sc2 = 85;
    reg [1:0]  gstate = 0;

    wire [3:0] r_n, g_n, b_n, r_o, g_o, b_o;
    wire hs_n, vs_n, ov_n, hs_o, vs_o, ov_o;

    vga_render u_new (.clk(clk), .rst(rst), .pix_ce(pix_ce), .hcount(hc), .vcount(vc),
        .hsync_n_in(hs), .vsync_n_in(vs), .active_in(act), .scan_tick(st), .scan_y(sy),
        .ob_addr(a_new), .ob_q(q_new), .pal_we(pal_we), .pal_idx(pal_idx), .pal_rgb(pal_rgb),
        .hud_en(1'b1), .hud_p1_x(10'd40), .hud_p2_x(10'd560), .hud_y(9'd8),
        .score1(sc1), .score2(sc2), .lives1(4'd3), .lives2(4'd2), .init_lives(4'd3),
        .mark_color(4'd3), .gstate(gstate), .clr_flags(1'b0),
        .vga_r(r_n), .vga_g(g_n), .vga_b(b_n), .hsync_n(hs_n), .vsync_n(vs_n), .line_overflow(ov_n));
    vga_render_orig u_old (.clk(clk), .rst(rst), .pix_ce(pix_ce), .hcount(hc), .vcount(vc),
        .hsync_n_in(hs), .vsync_n_in(vs), .active_in(act), .scan_tick(st), .scan_y(sy),
        .ob_addr(a_old), .ob_q(q_old), .pal_we(pal_we), .pal_idx(pal_idx), .pal_rgb(pal_rgb),
        .hud_en(1'b1), .hud_p1_x(10'd40), .hud_p2_x(10'd560), .hud_y(9'd8),
        .score1(sc1), .score2(sc2), .lives1(4'd3), .lives2(4'd2), .init_lives(4'd3),
        .mark_color(4'd3), .gstate(gstate), .clr_flags(1'b0),
        .vga_r(r_o), .vga_g(g_o), .vga_b(b_o), .hsync_n(hs_o), .vsync_n(vs_o), .line_overflow(ov_o));

    integer i, errors = 0, frames = 0, lit = 0, nobj;
    reg [95:0] o;

    // random table: nobj enabled objects, some partly off screen, some with markers
    task fill;
        input integer n;
        begin
            for (i = 0; i < 64; i = i + 1) begin
                o = 96'd0;
                o[`OBJ_X]       = $random % 700 - 30;
                o[`OBJ_Y]       = $random % 520 - 20;
                o[`OBJ_W]       = 1 + ({$random} % 60);
                o[`OBJ_H]       = 1 + ({$random} % 60);
                o[`OBJ_COLOR]   = {$random} % 16;
                o[`OBJ_ENABLED] = (i < n);
                o[`OBJ_DIR]     = $random;
                o[`OBJ_MARK]    = $random;
                o[`OBJ_TMODE]   = $random;
                o[`OBJ_TIMER]   = $random;
                mem[i] = o;
            end
        end
    endtask

    always @(negedge clk) if (!rst) begin
        if ({r_n, g_n, b_n, hs_n, vs_n, ov_n} !== {r_o, g_o, b_o, hs_o, vs_o, ov_o}) begin
            errors = errors + 1;
            if (errors < 10)
                $display("DIFF frame %0d h=%0d v=%0d new=%h%h%h old=%h%h%h ov %b/%b",
                         frames, hc, vc, r_n, g_n, b_n, r_o, g_o, b_o, ov_n, ov_o);
        end
        if (r_n | g_n | b_n) lit = lit + 1;
    end

    always @(posedge clk) if (ft) begin
        frames = frames + 1;
        nobj = (frames % 4 == 0) ? 64 : 8 + {$random} % 40;    // every 4th frame overflows slots
        fill(nobj);
    end

    initial begin
        fill(20);
        repeat (4) @(posedge clk);
        rst = 0;
        for (i = 0; i < 16; i = i + 1) begin                    // palette
            @(negedge clk); pal_we = 1; pal_idx = i; pal_rgb = 12'h111 * i + 12'h05A;
        end
        @(negedge clk); pal_we = 0;
        wait (frames == 9);
        $display("lit pixel-clocks seen: %0d", lit);
        if (errors == 0) $display("tb_render_eqv: PASS (8 frames identical)");
        else             $display("tb_render_eqv: FAIL (%0d differing clocks)", errors);
        $finish;
    end
endmodule
