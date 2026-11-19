// tb_vga_timing - self-checking testbench (Task 10).
// Runs a little over two full frames and checks: pix_ce exactly one clock in
// four; hsync_n low for 96 pixels per line; vsync_n low for 2 lines per frame;
// active only inside 640 x 480; one frame_tick per frame at (0, 480); 480
// scan_ticks per frame, each at pixel 640 with the right scan_y.
module tb_vga_timing;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    wire       pix_ce, hsync_n, vsync_n, active, frame_tick, scan_tick;
    wire [9:0] hcount, vcount, scan_y;

    vga_timing dut (.clk(clk), .rst(rst), .pix_ce(pix_ce), .hcount(hcount), .vcount(vcount),
                    .hsync_n(hsync_n), .vsync_n(vsync_n), .active(active),
                    .frame_tick(frame_tick), .scan_tick(scan_tick), .scan_y(scan_y));

    integer errors = 0;
    integer clk_n = 0, last_ce = -1;
    integer hs_pix = 0, vs_lines = 0, scans = 0, frames = 0;

    task fail;
        input [8*48-1:0] msg;
        begin
            errors = errors + 1;
            if (errors < 20)
                $display("MISMATCH at h=%0d v=%0d: %0s", hcount, vcount, msg);
        end
    endtask

    // sample on the falling edge, where all outputs are stable
    always @(negedge clk) if (!rst) begin
        clk_n = clk_n + 1;

        // pix_ce: exactly one clock in four
        if (pix_ce) begin
            if (last_ce >= 0 && clk_n - last_ce != 4) fail("pix_ce not 1 in 4");
            last_ce = clk_n;
        end

        // active region
        if (active !== (hcount < 640 && vcount < 480)) fail("active wrong");

        if (pix_ce) begin
            // hsync: count low pixels in each line
            if (!hsync_n) begin
                hs_pix = hs_pix + 1;
                if (hcount < 656 || hcount >= 752) fail("hsync low outside 656..751");
            end
            if (hcount == 799) begin
                if (hs_pix != 96) fail("hsync_n not low for 96 pixels");
                hs_pix = 0;
            end
            // vsync: count low lines in each frame
            if (hcount == 0 && !vsync_n) begin
                vs_lines = vs_lines + 1;
                if (vcount < 490 || vcount >= 492) fail("vsync low outside lines 490..491");
            end
        end

        // frame_tick
        if (frame_tick) begin
            if (!(pix_ce && hcount == 0 && vcount == 480)) fail("frame_tick not at (0,480)");
            if (frames > 0) begin                       // full frames only
                if (scans != 480) begin
                    fail("scan_tick count per frame != 480");
                    $display("         counted %0d scan_ticks", scans);
                end
                if (vs_lines != 2) fail("vsync_n not low for 2 lines");
            end
            frames = frames + 1;
            scans = 0;
            vs_lines = 0;
        end

        // scan_tick
        if (scan_tick) begin
            scans = scans + 1;
            if (!(pix_ce && hcount == 640 && (vcount == 524 || vcount < 479)))
                fail("scan_tick at wrong place");
            if (scan_y !== ((vcount == 524) ? 10'd0 : vcount + 10'd1))
                fail("scan_y wrong");
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk);
        if (hcount !== 0 || vcount !== 0) fail("reset did not clear counters");
        rst = 0;
        wait (frames == 3);     // frame_ticks 1->2 and 2->3 bound two full frames
        @(negedge clk);
        if (errors == 0) $display("tb_vga_timing: PASS (%0d frame_ticks)", frames);
        else             $display("tb_vga_timing: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
