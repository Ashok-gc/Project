////////////////////////////////////////////////////////////////////////////////
// Testbench:   tb_ZoomController
// Author:      Sisam Bhattarai
// Date:        2026-04-20
// Description: Self-checking testbench for the ZoomController module.
//              Verifies viewport parameter updates, render_trigger pulsing,
//              zoom/pan limit enforcement, and the julia_cr/julia_ci outputs.
//
//              The ZoomController uses rising-edge detection (no FSM).
//              Each task below asserts the input for one clock cycle so the
//              rising edge is detected exactly once, then releases.
//
//              Test cases:
//                1.  Reset state: initial viewport constants, render_trigger=0
//                2.  Julia outputs at reset: julia_cr=-785440, julia_ci=0
//                3.  Zoom in: x_scale halves, y_scale halves, zoom_level++
//                4.  render_trigger falls to 0 after zoom in
//                5.  Julia outputs stable after zoom: centre unchanged by zoom
//                6.  Zoom out: x_scale doubles, zoom_level decrements
//                7.  Zoom out at level 0: no change (min limit)
//                8.  Pan left: x_offset decreases
//                9.  Pan right: x_offset increases
//               10.  Pan up: y_offset decreases
//               11.  Pan down: y_offset increases
//               12.  Zoom to MAX_ZOOM_LEVEL, then one more press: no change
//
//              Clock period: 20 ns (50 MHz)
//              All parameters match MandelbrotTop defaults.
//
// Usage (ModelSim / Questa):
//   vlog ../rtl/ZoomController.v tb_ZoomController.v
//   vsim tb_ZoomController
//   run -all
////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

module tb_ZoomController;

    // =========================================================================
    // Parameters — match MandelbrotTop
    // =========================================================================
    localparam DW           = 24;
    localparam FB           = 20;
    localparam CLOCK_FREQ   = 50_000_000;
    localparam SCREEN_WIDTH = 240;
    localparam SCREEN_HEIGHT= 320;
    localparam PAN_PIXELS   = 32;
    localparam MAX_ZOOM     = 12;

    // Expected initial values (Q4.20 fixed-point)
    localparam signed [DW-1:0] X_OFF_INIT = -24'sd2621440;  // -2.5
    localparam signed [DW-1:0] Y_OFF_INIT = -24'sd1310720;  // -1.25
    localparam signed [DW-1:0] X_SC_INIT  =  24'sd15300;
    localparam signed [DW-1:0] Y_SC_INIT  =  24'sd8192;

    // Julia outputs at reset (viewport centre):
    //   zoom_dx = X_SC_INIT * 60 = 15300 * 60 = 918000
    //   zoom_dy = Y_SC_INIT * 80 = 8192  * 80 = 655360
    //   julia_cr = X_OFF_INIT + 2*918000 = -2621440 + 1836000 = -785440
    //   julia_ci = Y_OFF_INIT + 2*655360 = -1310720 + 1310720 =       0
    localparam signed [DW-1:0] JULIA_CR_INIT = -24'sd785440;
    localparam signed [DW-1:0] JULIA_CI_INIT =  24'sd0;

    // =========================================================================
    // DUT ports
    // =========================================================================
    reg                       clk;
    reg                       reset;
    reg                       key_zoom_in;
    reg                       key_zoom_out;
    reg  [3:0]                sw_pan;

    wire signed [DW-1:0]      x_offset;
    wire signed [DW-1:0]      y_offset;
    wire signed [DW-1:0]      x_scale;
    wire signed [DW-1:0]      y_scale;
    wire [3:0]                zoom_level;
    wire                      render_trigger;

    // Julia parameter outputs (viewport centre → Julia set c)
    wire signed [DW-1:0]      julia_cr;
    wire signed [DW-1:0]      julia_ci;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    ZoomController #(
        .CLOCK_FREQ    (CLOCK_FREQ   ),
        .DATA_WIDTH    (DW           ),
        .FRAC_BITS     (FB           ),
        .SCREEN_WIDTH  (SCREEN_WIDTH ),
        .SCREEN_HEIGHT (SCREEN_HEIGHT),
        .PAN_PIXELS    (PAN_PIXELS   ),
        .MAX_ZOOM_LEVEL(MAX_ZOOM     )
    ) dut (
        .clk           (clk          ),
        .reset         (reset        ),
        .key_zoom_in   (key_zoom_in  ),
        .key_zoom_out  (key_zoom_out ),
        .sw_pan        (sw_pan       ),
        .x_offset      (x_offset     ),
        .y_offset      (y_offset     ),
        .x_scale       (x_scale      ),
        .y_scale       (y_scale      ),
        .zoom_level    (zoom_level   ),
        .render_trigger(render_trigger),
        .julia_cr      (julia_cr     ),
        .julia_ci      (julia_ci     )
    );

    // =========================================================================
    // Clock generation: 50 MHz → 20 ns period
    // =========================================================================
    initial clk = 0;
    always #10 clk = ~clk;

    // =========================================================================
    // Test tracking
    // =========================================================================
    integer pass_count = 0;
    integer fail_count = 0;

    // =========================================================================
    // Helper tasks
    // =========================================================================
    task check_eq;
        input signed [DW-1:0] actual;
        input signed [DW-1:0] expected;
        input [255:0]          name;
        begin
            if (actual === expected) begin
                $display("  PASS: %s | val=%0d", name, $signed(actual));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %s | actual=%0d expected=%0d",
                         name, $signed(actual), $signed(expected));
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check_4bit;
        input [3:0] actual;
        input [3:0] expected;
        input [255:0] name;
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

    task check_bit;
        input        actual;
        input        expected;
        input [255:0] name;
        begin
            if (actual === expected) begin
                $display("  PASS: %s | val=%b", name, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %s | actual=%b expected=%b", name, actual, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // do_zoom_in: assert key_zoom_in for 1 cycle to produce one rising edge.
    //
    //   Cycle 1 (@posedge): align; key was 0, ki_prev latches 0
    //   Set key_zoom_in = 1
    //   Cycle 2 (@posedge): ki_rise = 1 & ~0 = 1 → action fires, outputs update
    //                        ki_prev latches 1; render_trigger <= 1
    //   Release key_zoom_in = 0
    //   Cycle 3 (@posedge): ki_rise = 0; render_trigger <= 0; ki_prev latches 0
    //
    //   After task: outputs stable with new values, render_trigger = 0.
    // -------------------------------------------------------------------------
    task do_zoom_in;
        begin
            @(posedge clk); #1;
            key_zoom_in = 1'b1;        // set key high (rising edge on next clk)
            @(posedge clk); #1;        // action fires; outputs registered
            key_zoom_in = 1'b0;        // release
            @(posedge clk); #1;        // render_trigger falls back to 0
        end
    endtask

    task do_zoom_out;
        begin
            @(posedge clk); #1;
            key_zoom_out = 1'b1;
            @(posedge clk); #1;
            key_zoom_out = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // do_pan: set sw_pan to pan_bits for one clock cycle to trigger one rising edge.
    task do_pan;
        input [3:0] pan_bits;
        begin
            @(posedge clk); #1;
            sw_pan = pan_bits;
            @(posedge clk); #1;        // sw_rise fires; offset updated
            sw_pan = 4'b0000;
            @(posedge clk); #1;        // render_trigger falls back to 0
        end
    endtask

    // =========================================================================
    // Test stimulus
    // =========================================================================
    initial begin
        $display("=================================================");
        $display("  ZoomController Testbench (with julia_cr/ci)");
        $display("=================================================");

        // Initialise inputs
        key_zoom_in  = 1'b0;
        key_zoom_out = 1'b0;
        sw_pan       = 4'b0000;
        reset        = 1'b1;

        // Apply reset for 3 clock cycles
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        reset = 1'b0;
        @(posedge clk); #1;  // first cycle after reset; render_trigger falls to 0

        // ==================================================================
        // TEST 1: Reset state — check initial viewport and render_trigger
        // ==================================================================
        $display("\n-- Test 1: Reset state --");
        check_eq  (x_offset,   X_OFF_INIT, "reset: x_offset=-2621440       ");
        check_eq  (y_offset,   Y_OFF_INIT, "reset: y_offset=-1310720       ");
        check_eq  (x_scale,    X_SC_INIT,  "reset: x_scale=15300           ");
        check_eq  (y_scale,    Y_SC_INIT,  "reset: y_scale=8192            ");
        check_4bit(zoom_level, 4'd0,       "reset: zoom_level=0            ");
        check_bit (render_trigger, 1'b0,   "post-reset: render_trigger=0   ");

        // ==================================================================
        // TEST 2: Julia outputs at reset
        //   Viewport centre = complex number ≈ (-0.749, 0.0)
        //   julia_cr = x_offset + 2*(x_scale*60) = -2621440 + 1836000 = -785440
        //   julia_ci = y_offset + 2*(y_scale*80) = -1310720 + 1310720 = 0
        // ==================================================================
        $display("\n-- Test 2: Julia outputs at reset --");
        check_eq(julia_cr, JULIA_CR_INIT, "reset: julia_cr=-785440        ");
        check_eq(julia_ci, JULIA_CI_INIT, "reset: julia_ci=0              ");

        // ==================================================================
        // TEST 3: Zoom in once
        //   zoom_dx = x_scale * 60 = 15300 * 60 = 918000
        //   zoom_dy = y_scale * 80 = 8192  * 80 = 655360
        //   x_offset_new = -2621440 + 918000 = -1703440
        //   y_offset_new = -1310720 + 655360 =  -655360
        //   x_scale_new  = 15300 >>> 1 = 7650
        //   y_scale_new  =  8192 >>> 1 = 4096
        //   zoom_level   = 1
        // ==================================================================
        $display("\n-- Test 3: Zoom in --");
        do_zoom_in;
        check_eq  (x_scale,    24'sd7650,    "zoom_in: x_scale=7650          ");
        check_eq  (y_scale,    24'sd4096,    "zoom_in: y_scale=4096          ");
        check_4bit(zoom_level, 4'd1,         "zoom_in: zoom_level=1          ");
        check_eq  (x_offset,   -24'sd1703440,"zoom_in: x_offset=-1703440     ");
        check_eq  (y_offset,   -24'sd655360, "zoom_in: y_offset=-655360      ");

        // ==================================================================
        // TEST 4: render_trigger pulsed exactly 1 cycle; check it is 0 now
        // ==================================================================
        $display("\n-- Test 4: render_trigger after zoom_in --");
        check_bit(render_trigger, 1'b0, "render_trigger=0 after zoom    ");

        // ==================================================================
        // TEST 5: Julia outputs after zoom in
        //   Zoom centres the view on the same complex point — julia_cr/ci
        //   must stay exactly equal to the pre-zoom values.
        //   new zoom_dx = 7650*60  = 459000
        //   new zoom_dy = 4096*80  = 327680
        //   julia_cr = -1703440 + 2*459000 = -1703440+918000 = -785440 (unchanged)
        //   julia_ci = -655360  + 2*327680 = -655360+655360  =       0 (unchanged)
        // ==================================================================
        $display("\n-- Test 5: Julia outputs unchanged after zoom --");
        check_eq(julia_cr, JULIA_CR_INIT, "zoom_in: julia_cr unchanged    ");
        check_eq(julia_ci, JULIA_CI_INIT, "zoom_in: julia_ci unchanged    ");

        // ==================================================================
        // TEST 6: Zoom out once (scale and level return to initial)
        //   zoom_dx (at x_scale=7650) = 7650*60 = 459000
        //   {zoom_dx[22:0], 1'b0} = 2*459000 = 918000
        //   x_offset_new = -1703440 - 918000 = -2621440  (back to init)
        //   zoom_dy (at y_scale=4096) = 4096*80 = 327680
        //   y_offset_new = -655360 - 655360 = -1310720   (back to init)
        //   x_scale_new  = 7650 <<< 1 = 15300
        //   y_scale_new  = 4096 <<< 1 = 8192
        //   zoom_level   = 0
        // ==================================================================
        $display("\n-- Test 6: Zoom out --");
        do_zoom_out;
        check_eq  (x_scale,    24'sd15300,  "zoom_out: x_scale=15300        ");
        check_eq  (y_scale,    24'sd8192,   "zoom_out: y_scale=8192         ");
        check_4bit(zoom_level, 4'd0,        "zoom_out: zoom_level=0         ");

        // ==================================================================
        // TEST 7: Zoom out at zoom_level=0 — must have no effect
        // ==================================================================
        $display("\n-- Test 7: Zoom out at min level --");
        begin : t7
            reg signed [DW-1:0] xs_before, ys_before;
            reg [3:0] zl_before;
            xs_before = x_scale;
            ys_before = y_scale;
            zl_before = zoom_level;
            do_zoom_out;
            check_eq  (x_scale,    xs_before, "min_zoom: x_scale unchanged    ");
            check_eq  (y_scale,    ys_before, "min_zoom: y_scale unchanged    ");
            check_4bit(zoom_level, zl_before, "min_zoom: zoom_level unchanged ");
        end

        // ==================================================================
        // TEST 8: Pan left — x_offset decreases by x_scale * PAN_PIXELS
        //   pan_dx = x_scale * 32 (lower 24 bits); x_scale = 15300
        //   Expected delta = 15300 * 32 = 489600
        // ==================================================================
        $display("\n-- Test 8: Pan left --");
        begin : t8
            reg signed [DW-1:0] xoff_before, xsc_now;
            reg signed [DW-1:0] expected_xoff;
            xoff_before   = x_offset;
            xsc_now       = x_scale;
            expected_xoff = xoff_before - (xsc_now * PAN_PIXELS);
            do_pan(4'b0001);  // sw_pan[0] = pan left
            check_eq(x_offset, expected_xoff, "pan_left: x_offset correct     ");
        end

        // ==================================================================
        // TEST 9: Pan right — x_offset increases
        // ==================================================================
        $display("\n-- Test 9: Pan right --");
        begin : t9
            reg signed [DW-1:0] xoff_before, xsc_now, expected_xoff;
            xoff_before   = x_offset;
            xsc_now       = x_scale;
            expected_xoff = xoff_before + (xsc_now * PAN_PIXELS);
            do_pan(4'b0010);  // sw_pan[1] = pan right
            check_eq(x_offset, expected_xoff, "pan_right: x_offset correct    ");
        end

        // ==================================================================
        // TEST 10: Pan up — y_offset decreases
        //   pan_dy = y_scale * 32 = 8192 * 32 = 262144
        // ==================================================================
        $display("\n-- Test 10: Pan up --");
        begin : t10
            reg signed [DW-1:0] yoff_before, ysc_now, expected_yoff;
            yoff_before   = y_offset;
            ysc_now       = y_scale;
            expected_yoff = yoff_before - (ysc_now * PAN_PIXELS);
            do_pan(4'b0100);  // sw_pan[2] = pan up
            check_eq(y_offset, expected_yoff, "pan_up: y_offset correct       ");
        end

        // ==================================================================
        // TEST 11: Pan down — y_offset increases
        // ==================================================================
        $display("\n-- Test 11: Pan down --");
        begin : t11
            reg signed [DW-1:0] yoff_before, ysc_now, expected_yoff;
            yoff_before   = y_offset;
            ysc_now       = y_scale;
            expected_yoff = yoff_before + (ysc_now * PAN_PIXELS);
            do_pan(4'b1000);  // sw_pan[3] = pan down
            check_eq(y_offset, expected_yoff, "pan_down: y_offset correct     ");
        end

        // ==================================================================
        // TEST 12: Zoom to MAX_ZOOM_LEVEL, then one more zoom-in: no change
        // Reset to clean state, then zoom in MAX_ZOOM times.
        // ==================================================================
        $display("\n-- Test 12: Zoom to max level --");
        reset = 1'b1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        reset = 1'b0;
        @(posedge clk); #1;

        begin : t12
            integer i;
            for (i = 0; i < MAX_ZOOM; i = i + 1) begin
                do_zoom_in;
            end
        end
        check_4bit(zoom_level, MAX_ZOOM[3:0], "max_zoom: zoom_level=12        ");

        // One more zoom in — should be blocked (zoom_level < 12 is false)
        begin : t12b
            reg signed [DW-1:0] xs_at_max;
            xs_at_max = x_scale;
            do_zoom_in;
            check_eq  (x_scale,    xs_at_max,      "max_zoom: x_scale unchanged    ");
            check_4bit(zoom_level, MAX_ZOOM[3:0],  "max_zoom: level still 12       ");
        end

        // =========================================================================
        $display("");
        $display("=================================================");
        $display("  TEST SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        if (fail_count == 0)
            $display("  ** ALL TESTS PASSED — ZoomController verified **");
        else
            $display("  ** FAILURES DETECTED — review output above **");
        $display("=================================================");
        $finish;
    end

endmodule
