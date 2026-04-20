////////////////////////////////////////////////////////////////////////////////
// Testbench:   tb_ColourMapper
// Author:      Sisam Bhattarai
// Date:        2026-04-20
// Description: Self-checking testbench for the extended ColourMapper module.
//              Tests all four colour palettes, the inside-set colour override,
//              the dynamic iteration-depth (max_iter_sel) logic, and the
//              256-entry smooth Blue→Red→Yellow→Purple interior palette.
//
//              Test cases:
//                1.  escaped=0 (inside set) → smooth_cycle[0]=0x001F Blue (Blue-Gold)
//                2.  escaped=0 (inside set) → smooth_cycle[0]=0x001F Blue (Fire)
//
//                Blue-Gold palette (palette_sel=00), max_iter_sel=01 (64 iters):
//                3.  palette_idx=0  → 0x0000 (black band 0)
//                4.  palette_idx=1  → 0x0010 (dark blue)
//                5.  palette_idx=7  → 0x07FF (aqua)
//                6.  palette_idx=10 → 0xFFE0 (gold)
//                7.  palette_idx=15 → 0xFFFF (white, near-boundary)
//
//                Fire palette (palette_sel=01), max_iter_sel=01 (64 iters):
//                8.  palette_idx=0  → 0x0000 (black)
//                9.  palette_idx=1  → 0x1000 (dark red)
//               10.  palette_idx=6  → 0xF800 (pure red)
//               11.  palette_idx=13 → 0xFFE0 (yellow)
//               12.  palette_idx=15 → 0xFFFF (white)
//
//                Ice palette (palette_sel=10), max_iter_sel=01 (64 iters):
//               13.  palette_idx=0  → 0x0000 (black)
//               14.  palette_idx=7  → 0x07FF (pure cyan)
//               15.  palette_idx=15 → 0xFFFF (white)
//
//                Electric palette (palette_sel=11), max_iter_sel=01 (64 iters):
//               16.  palette_idx=0  → 0x0000 (black)
//               17.  palette_idx=7  → 0xF81F (magenta)
//               18.  palette_idx=15 → 0xFFFF (white)
//
//               19.  iter_count >= iter_limit (64) → palette_idx forced to 0
//               20.  max_iter_sel=00 (32 iters): iter_count=4 → palette_idx=2
//                    max_iter_sel=01 (64 iters): iter_count=4 → palette_idx=1
//               21.  Live palette switch (same iter_count, palette_sel changes)
//               22.  Live palette switch confirmed (second palette check)
//
//              All expected values derived from palette arrays in ColourMapper.v.
//
// Usage (ModelSim / Questa):
//   vlog tb_ColourMapper.v ../rtl/ColourMapper.v
//   vsim tb_ColourMapper
//   run -all
////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

module tb_ColourMapper;

    // =========================================================================
    // Parameters — match DUT
    // =========================================================================
    localparam MAX_ITER  = 256;
    localparam ITER_BITS = 9;   // $clog2(256+1) = 9

    // =========================================================================
    // DUT ports
    // =========================================================================
    reg  [ITER_BITS-1:0] iter_count;
    reg                  escaped;
    reg  [1:0]           palette_sel;
    reg  [1:0]           max_iter_sel;
    reg  [7:0]           cycle_count;    // frame counter → interior colour cycling
    wire [15:0]          colour;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    ColourMapper #(
        .MAX_ITER(MAX_ITER)
    ) dut (
        .iter_count  (iter_count  ),
        .escaped     (escaped     ),
        .palette_sel (palette_sel ),
        .max_iter_sel(max_iter_sel),
        .cycle_count (cycle_count ),
        .colour      (colour      )
    );

    // =========================================================================
    // Test tracking
    // =========================================================================
    integer pass_count = 0;
    integer fail_count = 0;

    // =========================================================================
    // Helper task
    // =========================================================================
    task check_colour;
        input [15:0]  expected;
        input [255:0] test_name;
        begin
            #1; // Allow combinational logic to settle
            if (colour === expected) begin
                $display("  PASS: %s | colour=0x%04X", test_name, colour);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %s | colour=0x%04X expected=0x%04X",
                         test_name, colour, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Test stimulus
    //
    // max_iter_sel=01 → iter_limit=64, band_size=4, palette_idx = iter_count[5:2]
    //   palette_idx N → iter_count = N*4
    //   e.g. idx=7 → iter_count=28, idx=15 → iter_count=60
    //
    // max_iter_sel=00 → iter_limit=32, band_size=2, palette_idx = iter_count[4:1]
    //   palette_idx N → iter_count = N*2
    //   e.g. iter_count=4 → palette_idx = iter_count[4:1] = 2
    // =========================================================================
    initial begin
        $display("=================================================");
        $display("  ColourMapper Testbench (MAX_ITER=256, RGB565)");
        $display("  4 palettes, dynamic depth, smooth Blue/Red/Yellow/Purple interior");
        $display("=================================================");

        // Set defaults: 64 iterations, cycle phase 0
        max_iter_sel = 2'b01;
        cycle_count  = 8'h00;   // interior_idx=0 → smooth_cycle[0]=0x001F (blue)

        // ------------------------------------------------------------------
        // Tests 1–2: Inside the set — escaped=0 → smooth interior colour
        //   cycle_count=0x00 → interior_idx=0 → 0x001F (blue, seg-0 start)
        //   Colour is independent of palette_sel when escaped=0.
        // ------------------------------------------------------------------
        $display("\n-- Tests 1-2: Inside set (escaped=0) → smooth cycle colour --");

        escaped = 1'b0; palette_sel = 2'b00; iter_count = 9'd20;
        check_colour(16'h001F, "inside set (pal=Blue-Gold): 0x001F blue");

        escaped = 1'b0; palette_sel = 2'b01; iter_count = 9'd60;
        check_colour(16'h001F, "inside set (pal=Fire):      0x001F blue");

        // ------------------------------------------------------------------
        // Tests 3–7: Blue-Gold palette (palette_sel=00), escaped=1
        //   [0]=0x0000  [1]=0x0010  [2]=0x0031  [3]=0x0053  [4]=0x0494
        //   [5]=0x04B6  [6]=0x07F7  [7]=0x07FF  [8]=0x3FFF  [9]=0xBFE0
        //   [10]=0xFFE0 [11]=0xFD20 [12]=0xFC00 [13]=0xFB80 [14]=0xF800
        //   [15]=0xFFFF
        // ------------------------------------------------------------------
        $display("\n-- Tests 3-7: Blue-Gold palette (pal=00, depth=64) --");
        escaped = 1'b1; palette_sel = 2'b00;

        iter_count = 9'd0;   // idx=0 → 0x0000
        check_colour(16'h0000, "BG idx=0 : 0x0000 (black)      ");

        iter_count = 9'd4;   // idx=1 → 0x0010
        check_colour(16'h0010, "BG idx=1 : 0x0010 (dark blue)  ");

        iter_count = 9'd28;  // idx=7 → 0x07FF
        check_colour(16'h07FF, "BG idx=7 : 0x07FF (aqua)       ");

        iter_count = 9'd40;  // idx=10 → 0xFFE0
        check_colour(16'hFFE0, "BG idx=10: 0xFFE0 (gold)       ");

        iter_count = 9'd60;  // idx=15 → 0xFFFF
        check_colour(16'hFFFF, "BG idx=15: 0xFFFF (white)      ");

        // ------------------------------------------------------------------
        // Tests 8–12: Fire palette (palette_sel=01), escaped=1
        //   [0]=0x0000  [1]=0x1000  [2]=0x2000  [3]=0x4000  [4]=0x8000
        //   [5]=0xA000  [6]=0xF800  [7]=0xF980  [8]=0xFB00  [9]=0xFC00
        //   [10]=0xFD00 [11]=0xFE00 [12]=0xFF00 [13]=0xFFE0 [14]=0xFFF0
        //   [15]=0xFFFF
        // ------------------------------------------------------------------
        $display("\n-- Tests 8-12: Fire palette (pal=01, depth=64) --");
        escaped = 1'b1; palette_sel = 2'b01;

        iter_count = 9'd0;   // idx=0 → 0x0000
        check_colour(16'h0000, "Fire idx=0 : 0x0000 (black)    ");

        iter_count = 9'd4;   // idx=1 → 0x1000
        check_colour(16'h1000, "Fire idx=1 : 0x1000 (dark red) ");

        iter_count = 9'd24;  // idx=6 → 0xF800
        check_colour(16'hF800, "Fire idx=6 : 0xF800 (pure red) ");

        iter_count = 9'd52;  // idx=13 → 0xFFE0
        check_colour(16'hFFE0, "Fire idx=13: 0xFFE0 (yellow)   ");

        iter_count = 9'd60;  // idx=15 → 0xFFFF
        check_colour(16'hFFFF, "Fire idx=15: 0xFFFF (white)    ");

        // ------------------------------------------------------------------
        // Tests 13–15: Ice palette (palette_sel=10), escaped=1
        //   [0]=0x0000  [7]=0x07FF (pure cyan)  [15]=0xFFFF (white)
        // ------------------------------------------------------------------
        $display("\n-- Tests 13-15: Ice palette (pal=10, depth=64) --");
        escaped = 1'b1; palette_sel = 2'b10;

        iter_count = 9'd0;   // idx=0 → 0x0000
        check_colour(16'h0000, "Ice idx=0 : 0x0000 (black)     ");

        iter_count = 9'd28;  // idx=7 → 0x07FF
        check_colour(16'h07FF, "Ice idx=7 : 0x07FF (cyan)      ");

        iter_count = 9'd60;  // idx=15 → 0xFFFF
        check_colour(16'hFFFF, "Ice idx=15: 0xFFFF (white)     ");

        // ------------------------------------------------------------------
        // Tests 16–18: Electric palette (palette_sel=11), escaped=1
        //   [0]=0x0000  [7]=0xF81F (magenta)    [15]=0xFFFF (white)
        // ------------------------------------------------------------------
        $display("\n-- Tests 16-18: Electric palette (pal=11, depth=64) --");
        escaped = 1'b1; palette_sel = 2'b11;

        iter_count = 9'd0;   // idx=0 → 0x0000
        check_colour(16'h0000, "Elec idx=0 : 0x0000 (black)    ");

        iter_count = 9'd28;  // idx=7 → 0xF81F
        check_colour(16'hF81F, "Elec idx=7 : 0xF81F (magenta)  ");

        iter_count = 9'd60;  // idx=15 → 0xFFFF
        check_colour(16'hFFFF, "Elec idx=15: 0xFFFF (white)    ");

        // ------------------------------------------------------------------
        // Test 19: iter_count >= iter_limit → palette_idx forced to 0
        //   max_iter_sel=01 → iter_limit=64; iter_count=64 → idx=0
        //   Blue-Gold[0]=0x0000  (even with escaped=1, idx=0 is 0x0000)
        // ------------------------------------------------------------------
        $display("\n-- Test 19: iter_count at iter_limit boundary --");
        escaped = 1'b1; palette_sel = 2'b00; max_iter_sel = 2'b01;
        iter_count = 9'd64;   // >= 64 → palette_idx=0 → blue_gold[0]=0x0000
        check_colour(16'h0000, "iter=64 (>=limit), esc=1: idx=0");

        // ------------------------------------------------------------------
        // Tests 20: max_iter_sel affects palette_idx for same iter_count
        //   iter_count=4, Blue-Gold palette, escaped=1:
        //   max_iter_sel=00 (32 iters): palette_idx = iter_count[4:1] = 0b00010 = 2
        //     → blue_gold[2] = 0x0031
        //   max_iter_sel=01 (64 iters): palette_idx = iter_count[5:2] = 0b000001 = 1
        //     → blue_gold[1] = 0x0010
        // ------------------------------------------------------------------
        $display("\n-- Test 20: max_iter_sel changes palette_idx --");
        escaped = 1'b1; palette_sel = 2'b00; iter_count = 9'd4;

        max_iter_sel = 2'b00;  // 32 iters; idx = iter_count[4:1] = 4>>1 = 2
        check_colour(16'h0031, "depth=32: iter=4 → idx=2 (0x0031)");

        max_iter_sel = 2'b01;  // 64 iters; idx = iter_count[5:2] = 4>>2 = 1
        check_colour(16'h0010, "depth=64: iter=4 → idx=1 (0x0010)");

        // ------------------------------------------------------------------
        // Tests 21–22: Live palette switch — output responds combinationally
        //   iter_count=28 → palette_idx=7 (with max_iter_sel=01)
        //   Blue-Gold[7]=0x07FF (aqua),  Ice[7]=0x07FF (cyan — same value!)
        //   Try idx=6 instead: iter_count=24
        //   Blue-Gold[6]=0x07F7,  Fire[6]=0xF800 — clearly different
        // ------------------------------------------------------------------
        $display("\n-- Tests 21-22: Live palette switch (combinatorial) --");
        escaped = 1'b1; max_iter_sel = 2'b01; iter_count = 9'd24; // palette_idx=6

        palette_sel = 2'b00;  // Blue-Gold[6] = 0x07F7
        #1;
        if (colour === 16'h07F7) begin
            $display("  PASS: palette switch → Blue-Gold[6]=0x07F7");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: palette switch BG: 0x%04X (exp 0x07F7)", colour);
            fail_count = fail_count + 1;
        end

        palette_sel = 2'b01;  // Fire[6] = 0xF800
        #1;
        if (colour === 16'hF800) begin
            $display("  PASS: palette switch → Fire[6]=0xF800");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: palette switch Fire: 0x%04X (exp 0xF800)", colour);
            fail_count = fail_count + 1;
        end

        // ------------------------------------------------------------------
        // Tests 23–25: Interior smooth Blue→Red→Yellow→Purple cycle (escaped=0)
        //
        //   interior_idx = cycle_count (full 8-bit, 256-entry palette)
        //   smooth_cycle[  0] = 0x001F — Blue   (seg-0 start: R=0,  G=0,  B=31)
        //   smooth_cycle[ 64] = 0xF800 — Red    (seg-1 start: R=31, G=0,  B=0 )
        //   smooth_cycle[128] = 0xFFE0 — Yellow (seg-2 start: R=31, G=63, B=0 )
        //   (All entries are bright — no black in the interior cycle)
        // ------------------------------------------------------------------
        $display("\n-- Tests 23-25: Interior smooth colour cycle (escaped=0) --");
        escaped = 1'b0; palette_sel = 2'b00; max_iter_sel = 2'b01;

        cycle_count = 8'h00;   // smooth_cycle[0]   → Blue  0x001F
        check_colour(16'h001F, "cycle idx=0  : 0x001F blue  ");

        cycle_count = 8'h40;   // smooth_cycle[64]  → Red   0xF800
        check_colour(16'hF800, "cycle idx=64 : 0xF800 red   ");

        cycle_count = 8'h80;   // smooth_cycle[128] → Yellow 0xFFE0
        check_colour(16'hFFE0, "cycle idx=128: 0xFFE0 yellow");

        // Restore cycle_count to 0
        cycle_count = 8'h00;

        // =========================================================================
        $display("");
        $display("=================================================");
        $display("  TEST SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        if (fail_count == 0)
            $display("  ** ALL TESTS PASSED — ColourMapper verified **");
        else
            $display("  ** FAILURES DETECTED — review output above **");
        $display("=================================================");
        $finish;
    end

endmodule
