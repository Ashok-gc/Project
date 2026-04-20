////////////////////////////////////////////////////////////////////////////////
// Testbench:   tb_MandelbrotCore
// Author:      Sisam Bhattarai
// Date:        2026-04-20
// Description: Self-checking testbench for the extended MandelbrotCore module.
//              Uses a minimal screen size (4×4 pixels) to keep simulation fast
//              while exercising the full FSM cycle, Julia mode, and the new
//              max_iter_sel dynamic iteration depth control.
//
//              Test cases:
//                1.  Post-reset: IDLE state, rendering=0, frame_count=0,
//                    pixelWrite=0, pixelRawMode=0
//                2.  IDLE: no pixelWrite while no render_trigger
//                3.  render_trigger starts a frame: rendering goes high
//                4.  Full Mandelbrot frame renders; frame_count increments to 1
//                5.  pixelWrite fired exactly W*H times (one rising edge per pixel)
//                6.  All pixel addresses (xAddr 0..W-1, yAddr 0..H-1) were seen
//                7.  Second render_trigger starts second Mandelbrot frame;
//                    frame_count increments to 2
//                8.  Julia mode frame: set julia_mode=1 and render third frame;
//                    frame_count increments to 3 and all pixels addressed
//
//              Implementation notes:
//                MAX_ITER = 32 so that the 6-bit iter counter can reach the
//                termination condition (iter == iter_limit-1 = 31) when
//                max_iter_sel=2'b00.  Using iter_limit from max_iter_sel ensures
//                the COMPUTE state always exits even if no pixel escapes.
//
//                The testbench acts as a simple LT24 model: it asserts pixelReady
//                two clock cycles after pixelWrite goes high.
//
// Usage (ModelSim / Questa):
//   vlog tb_MandelbrotCore.v ../rtl/MandelbrotCore.v \
//        ../rtl/MandelbrotIterator.v ../rtl/FixedPointMult.v \
//        ../rtl/ColourMapper.v
//   vsim tb_MandelbrotCore
//   run -all
////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

module tb_MandelbrotCore;

    // =========================================================================
    // Tiny screen for simulation speed
    // =========================================================================
    localparam DW     = 24;
    localparam FB     = 20;
    localparam W      = 4;
    localparam H      = 4;
    localparam MI     = 32;    // MAX_ITER; matches max_iter_sel=00 iter_limit=32
    localparam NPIX   = W * H; // 16 pixels per frame

    // Viewport: small window centred near (-0.5, -0.5) in the complex plane.
    // x_scale/y_scale are large enough for interesting coordinates but the
    // testbench only checks FSM behaviour, not pixel colours.
    //
    // x_offset = -524288  (-0.5 in Q4.20)
    // y_offset = -524288  (-0.5 in Q4.20)
    // x_scale  =  131072  ( 0.125 in Q4.20)
    // y_scale  =  131072  ( 0.125 in Q4.20)
    localparam signed [DW-1:0] X_OFF = -24'sd524288;
    localparam signed [DW-1:0] Y_OFF = -24'sd524288;
    localparam signed [DW-1:0] X_SC  =  24'sd131072;
    localparam signed [DW-1:0] Y_SC  =  24'sd131072;

    // =========================================================================
    // DUT ports
    // =========================================================================
    reg                    clk;
    reg                    reset;
    reg                    render_trigger;
    reg  signed [DW-1:0]   x_offset, y_offset, x_scale, y_scale;

    // Mode controls
    reg                    julia_mode;      // 0=Mandelbrot  1=Julia
    reg  signed [DW-1:0]   julia_cr;        // Julia parameter (real)
    reg  signed [DW-1:0]   julia_ci;        // Julia parameter (imag)
    reg  [1:0]             palette_sel;     // 2-bit (4 palettes)
    reg  [1:0]             max_iter_sel;    // 00=32 01=64 10=128 11=256
    reg  [7:0]             cycle_count;     // free-running timer (interior colour)
    reg                    burning_ship;    // 0=Mandelbrot/Julia  1=Burning Ship

    wire [7:0]             xAddr;
    wire [8:0]             yAddr;
    wire [15:0]            pixelData;
    wire                   pixelWrite;
    reg                    pixelReady;
    wire                   pixelRawMode;
    wire                   rendering;
    wire [7:0]             frame_count;
    wire [8:0]             render_row;      // current row for progress bar

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    MandelbrotCore #(
        .CLOCK_FREQ   (50_000_000),
        .DATA_WIDTH   (DW        ),
        .FRAC_BITS    (FB        ),
        .MAX_ITER     (MI        ),
        .SCREEN_WIDTH (W         ),
        .SCREEN_HEIGHT(H         )
    ) dut (
        .clk           (clk          ),
        .reset         (reset        ),
        .render_trigger(render_trigger),
        .x_offset      (x_offset     ),
        .y_offset      (y_offset     ),
        .x_scale       (x_scale      ),
        .y_scale       (y_scale      ),
        .julia_mode    (julia_mode   ),
        .julia_cr      (julia_cr     ),
        .julia_ci      (julia_ci     ),
        .palette_sel   (palette_sel  ),
        .max_iter_sel  (max_iter_sel ),
        .cycle_count   (cycle_count  ),
        .burning_ship  (burning_ship ),
        .xAddr         (xAddr        ),
        .yAddr         (yAddr        ),
        .pixelData     (pixelData    ),
        .pixelWrite    (pixelWrite   ),
        .pixelReady    (pixelReady   ),
        .pixelRawMode  (pixelRawMode ),
        .rendering     (rendering    ),
        .frame_count   (frame_count  ),
        .render_row    (render_row   )
    );

    // =========================================================================
    // Clock: 50 MHz → 20 ns period
    // =========================================================================
    initial clk = 0;
    always #10 clk = ~clk;

    // =========================================================================
    // Simple LT24 model: asserts pixelReady 2 cycles after pixelWrite rises
    // =========================================================================
    reg [1:0] rdy_delay;
    always @(posedge clk) begin
        if (reset) begin
            rdy_delay  <= 2'b00;
            pixelReady <= 1'b0;
        end else begin
            rdy_delay  <= {rdy_delay[0], pixelWrite};
            pixelReady <= rdy_delay[1]; // Ready 2 cycles after pixelWrite
        end
    end

    // =========================================================================
    // Pixel address tracking — capture (xAddr, yAddr) on the rising edge of
    // pixelWrite (fires exactly once per pixel regardless of pixelReady timing).
    // =========================================================================
    integer pix_write_count;
    integer bad_addr_count;
    reg seen [0:W-1][0:H-1];   // Which (x,y) positions were written
    integer xi, yi;
    reg pixelWrite_prev;

    always @(posedge clk) begin
        if (reset) begin
            pix_write_count <= 0;
            bad_addr_count  <= 0;
            pixelWrite_prev <= 1'b0;
        end else begin
            pixelWrite_prev <= pixelWrite;
            // Rising edge of pixelWrite — fires exactly once per pixel
            if (pixelWrite && !pixelWrite_prev) begin
                pix_write_count <= pix_write_count + 1;
                if (xAddr < W && yAddr < H)
                    seen[xAddr][yAddr] <= 1'b1;
                else
                    bad_addr_count <= bad_addr_count + 1;
            end
        end
    end

    // =========================================================================
    // Test tracking
    // =========================================================================
    integer pass_count;
    integer fail_count;

    task check_bit;
        input        actual;
        input        expected;
        input [255:0] name;
        begin
            if (actual === expected) begin
                $display("  PASS: %s", name);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %s | actual=%b expected=%b", name, actual, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check_int;
        input integer actual;
        input integer expected;
        input [255:0]  name;
        begin
            if (actual === expected) begin
                $display("  PASS: %s | val=%0d", name, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %s | actual=%0d expected=%0d", name, actual, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Helper: wait up to max_cycles for rendering to drop; record cycles taken
    // =========================================================================
    integer timeout_cycles;

    task wait_for_rendering_low;
        input integer max_cycles;
        begin
            timeout_cycles = 0;
            while (rendering && timeout_cycles < max_cycles) begin
                @(posedge clk); #1;
                timeout_cycles = timeout_cycles + 1;
            end
        end
    endtask

    // Pixel tracking reset helper (tasks can't reset arrays in Verilog-2001;
    // use a manual loop in the initial block instead).

    // =========================================================================
    // Main test
    // =========================================================================
    initial begin
        // Initialise
        pass_count      = 0;
        fail_count      = 0;
        pix_write_count = 0;
        bad_addr_count  = 0;

        for (xi = 0; xi < W; xi = xi + 1)
            for (yi = 0; yi < H; yi = yi + 1)
                seen[xi][yi] = 1'b0;

        // Control defaults
        render_trigger = 1'b0;
        julia_mode     = 1'b0;          // Mandelbrot mode
        julia_cr       = 24'sd0;
        julia_ci       = 24'sd0;
        palette_sel    = 2'b00;         // Blue-Gold
        max_iter_sel   = 2'b00;         // 32 iterations (matches MI)
        cycle_count    = 8'd0;          // interior colour phase (cosmetic)
        burning_ship   = 1'b0;          // Mandelbrot mode default
        x_offset       = X_OFF;
        y_offset       = Y_OFF;
        x_scale        = X_SC;
        y_scale        = Y_SC;

        $display("=================================================");
        $display("  MandelbrotCore Testbench (%0dx%0d, MI=%0d)", W, H, MI);
        $display("  Julia mode + dynamic iter depth (max_iter_sel)");
        $display("=================================================");

        // Apply reset
        reset = 1'b1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        reset = 1'b0;
        @(posedge clk); #1;

        // ==================================================================
        // Test 1: Post-reset state
        // ==================================================================
        $display("\n-- Test 1: Reset state --");
        check_bit(rendering,    1'b0, "reset: rendering=0             ");
        check_int(frame_count,     0, "reset: frame_count=0           ");
        check_bit(pixelWrite,   1'b0, "reset: pixelWrite=0            ");
        check_bit(pixelRawMode, 1'b0, "reset: pixelRawMode=0          ");

        // ==================================================================
        // Test 2: Idle — no pixelWrite while no render_trigger
        // ==================================================================
        $display("\n-- Test 2: IDLE (no trigger) --");
        @(posedge clk); #1;
        @(posedge clk); #1;
        check_bit(pixelWrite, 1'b0, "idle: no pixelWrite            ");
        check_bit(rendering,  1'b0, "idle: rendering=0              ");

        // ==================================================================
        // Test 3: Start frame 1 with render_trigger
        // ==================================================================
        $display("\n-- Test 3: render_trigger starts Mandelbrot frame --");
        @(posedge clk); #1;
        render_trigger = 1'b1;
        @(posedge clk); #1;   // IDLE latches pending_render=1; rendering=1
        render_trigger = 1'b0;
        @(posedge clk); #1;   // transitions to INIT_FRAME
        check_bit(rendering, 1'b1, "after trigger: rendering=1     ");

        // ==================================================================
        // Test 4: Let the full frame render; frame_count must reach 1
        //   Budget: MI iterations per pixel × W×H pixels × overhead + margin
        // ==================================================================
        $display("\n-- Test 4: Full Mandelbrot frame; frame_count→1 --");
        wait_for_rendering_low(MI * W * H * 20 + 400);

        if (timeout_cycles < MI * W * H * 20 + 400) begin
            $display("  PASS: frame 1 done in %0d cycles", timeout_cycles);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: frame 1 timed out");
            fail_count = fail_count + 1;
        end

        check_bit(rendering,   1'b0, "after frame 1: rendering=0     ");
        check_int(frame_count,    1, "after frame 1: frame_count=1   ");

        // ==================================================================
        // Test 5: pixelWrite fired exactly NPIX times
        // ==================================================================
        $display("\n-- Test 5: Pixel write count --");
        check_int(pix_write_count, NPIX, "frame 1: pixelWrite=W*H        ");

        // ==================================================================
        // Test 6: All pixel addresses (x 0..W-1, y 0..H-1) were written
        // ==================================================================
        $display("\n-- Test 6: All pixel addresses written --");
        begin : t6
            integer all_seen;
            integer xc, yc;
            all_seen = 1;
            for (xc = 0; xc < W; xc = xc + 1) begin
                for (yc = 0; yc < H; yc = yc + 1) begin
                    if (!seen[xc][yc]) begin
                        $display("  NOTE: pixel (%0d,%0d) not seen", xc, yc);
                        all_seen = 0;
                    end
                end
            end
            check_int(all_seen,       1, "frame 1: all pixels addressed  ");
            check_int(bad_addr_count, 0, "frame 1: no out-of-range addrs ");
        end

        // ==================================================================
        // Test 7: Second render_trigger → second Mandelbrot frame
        //         Reset pixel tracking for frame 2.
        // ==================================================================
        $display("\n-- Test 7: Second Mandelbrot frame --");
        pix_write_count = 0;
        for (xi = 0; xi < W; xi = xi + 1)
            for (yi = 0; yi < H; yi = yi + 1)
                seen[xi][yi] = 1'b0;

        @(posedge clk); #1;
        render_trigger = 1'b1;
        @(posedge clk); #1;   // IDLE latches pending_render=1
        render_trigger = 1'b0;
        @(posedge clk); #1;   // IDLE transitions to INIT_FRAME, rendering=1
        @(posedge clk); #1;   // rendering stable

        wait_for_rendering_low(MI * W * H * 20 + 400);
        check_int(frame_count,  2, "frame 2: frame_count=2         ");
        check_bit(rendering, 1'b0, "frame 2: rendering=0           ");
        check_int(pix_write_count, NPIX, "frame 2: pixelWrite=W*H        ");

        // ==================================================================
        // Test 8: Julia mode — render a frame with julia_mode=1
        //   Use a well-known Julia parameter: c = (-0.7, 0.27i)
        //   julia_cr = -24'sd734003 (≈ -0.7 in Q4.20)
        //   julia_ci =  24'sd283115 (≈ 0.27 in Q4.20)
        //   The FSM behaviour (all pixels written, frame_count increments)
        //   must be identical to Mandelbrot mode — only the maths differs.
        // ==================================================================
        $display("\n-- Test 8: Julia mode frame --");
        pix_write_count = 0;
        for (xi = 0; xi < W; xi = xi + 1)
            for (yi = 0; yi < H; yi = yi + 1)
                seen[xi][yi] = 1'b0;

        julia_mode = 1'b1;
        julia_cr   = -24'sd734003;   // ≈ -0.7 in Q4.20
        julia_ci   =  24'sd283115;   // ≈ +0.27 in Q4.20

        @(posedge clk); #1;
        render_trigger = 1'b1;
        @(posedge clk); #1;
        render_trigger = 1'b0;
        @(posedge clk); #1;
        @(posedge clk); #1;

        wait_for_rendering_low(MI * W * H * 20 + 400);
        check_int(frame_count,  3, "Julia frame: frame_count=3     ");
        check_bit(rendering, 1'b0, "Julia frame: rendering=0       ");
        check_int(pix_write_count, NPIX, "Julia frame: pixelWrite=W*H    ");

        begin : t8_addrs
            integer all_seen_j;
            integer xj, yj;
            all_seen_j = 1;
            for (xj = 0; xj < W; xj = xj + 1)
                for (yj = 0; yj < H; yj = yj + 1)
                    if (!seen[xj][yj]) all_seen_j = 0;
            check_int(all_seen_j, 1, "Julia frame: all pixels written");
        end

        // =========================================================================
        $display("");
        $display("=================================================");
        $display("  TEST SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        if (fail_count == 0)
            $display("  ** ALL TESTS PASSED — MandelbrotCore verified **");
        else
            $display("  ** FAILURES DETECTED — review output above **");
        $display("=================================================");
        $finish;
    end

endmodule
