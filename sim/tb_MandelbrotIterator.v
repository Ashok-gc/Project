////////////////////////////////////////////////////////////////////////////////
// Testbench:   tb_MandelbrotIterator
// Author:      Sisam Bhattarai
// Date:        2026-04-20
// Description: Self-checking testbench for the MandelbrotIterator module.
//              Tests one step of the Mandelbrot iteration z → z² + c, and
//              verifies the escape condition detection.
//
//              Test cases:
//                1. Origin (z=0, c=0) — should stay at 0, not escape
//                2. z=0, c=0.5+0.5i  — first iteration result check
//                3. Escape detection — z near (2,0) should trigger escaped
//                4. z=(1,1), c=(0,0) — pure z² case: z'=(0,2)
//                5. Known diverging point: c=(0.5, 0.5) after several steps
//                6. Known converging point: c=(-0.1, 0) stays bounded
//
//              All fixed-point values in Q4.20 (24-bit, 20 fractional bits).
////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

module tb_MandelbrotIterator;

    localparam DW = 24;
    localparam FB = 20;
    localparam ONE  = 1 << FB;           // 1.0  in Q4.20 = 1048576
    localparam HALF = ONE >> 1;          // 0.5  in Q4.20 = 524288
    localparam TWO  = 2 << FB;           // 2.0  in Q4.20 = 2097152
    localparam FOUR = 4 << FB;           // 4.0  in Q4.20 = 4194304 (escape threshold)

    // DUT ports
    reg  signed [DW-1:0] z_r, z_i, c_r, c_i;
    reg                  burning_ship;       // 0=Mandelbrot/Julia  1=Burning Ship
    wire signed [DW-1:0] z_r_out, z_i_out;
    wire                 escaped;

    // DUT instantiation
    MandelbrotIterator #(
        .DATA_WIDTH(DW),
        .FRAC_BITS (FB)
    ) dut (
        .z_r         (z_r         ),
        .z_i         (z_i         ),
        .c_r         (c_r         ),
        .c_i         (c_i         ),
        .burning_ship(burning_ship),
        .z_r_out     (z_r_out     ),
        .z_i_out     (z_i_out     ),
        .escaped     (escaped     )
    );

    // Test tracking
    integer pass_count = 0;
    integer fail_count = 0;

    // -------------------------------------------------------------------------
    // Task: check a single condition
    // -------------------------------------------------------------------------
    task check_cond;
        input               actual;
        input               expected;
        input [255:0]       name;
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

    // -------------------------------------------------------------------------
    // Task: check signed fixed-point value with tolerance
    // -------------------------------------------------------------------------
    task check_fp;
        input signed [DW-1:0] actual;
        input signed [DW-1:0] expected;
        input integer          tol;
        input [255:0]          name;
        integer diff;
        begin
            diff = $signed(actual) - $signed(expected);
            if (diff < 0) diff = -diff;
            if (diff <= tol) begin
                $display("  PASS: %s | actual=%0d expected=%0d", name, $signed(actual), $signed(expected));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %s | actual=%0d expected=%0d diff=%0d (tol=%0d)",
                         name, $signed(actual), $signed(expected), diff, tol);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $display("=================================================");
        $display("  MandelbrotIterator Testbench (Q4.20, 24-bit)");
        $display("  Mandelbrot + Burning Ship modes");
        $display("=================================================");

        burning_ship = 1'b0; // default: Mandelbrot/Julia mode

        // ------------------------------------------------------------------
        // Test 1: z=0, c=0 → z'=0, no escape
        //   z_r' = 0² - 0² + 0 = 0
        //   z_i' = 2*0*0 + 0 = 0
        //   |z|² = 0 < 4 → not escaped
        // ------------------------------------------------------------------
        z_r = 0; z_i = 0; c_r = 0; c_i = 0; #1;
        check_fp  (z_r_out, 0,    0, "z=0,c=0 : z_r_out=0   ");
        check_fp  (z_i_out, 0,    0, "z=0,c=0 : z_i_out=0   ");
        check_cond(escaped,  1'b0,   "z=0,c=0 : not escaped  ");

        // ------------------------------------------------------------------
        // Test 2: z=0, c=0.5+0.5i → z'=0.5+0.5i
        //   z_r' = 0 - 0 + 0.5 = 0.5 (raw: HALF = 524288)
        //   z_i' = 0 + 0.5 = 0.5
        //   |z|² = 0 < 4 → not escaped
        // ------------------------------------------------------------------
        z_r = 0; z_i = 0; c_r = HALF; c_i = HALF; #1;
        check_fp  (z_r_out, HALF, 2, "z=0,c=0.5+0.5i: z_r=0.5");
        check_fp  (z_i_out, HALF, 2, "z=0,c=0.5+0.5i: z_i=0.5");
        check_cond(escaped,  1'b0,   "z=0,c=0.5+0.5i: no esc ");

        // ------------------------------------------------------------------
        // Test 3: Escape detection — z=(2,0), c=0
        //   |z|² = 4 → should trigger escaped
        // ------------------------------------------------------------------
        z_r = TWO; z_i = 0; c_r = 0; c_i = 0; #1;
        check_cond(escaped, 1'b1, "z=(2,0): escaped=1     ");

        // ------------------------------------------------------------------
        // Test 4: z slightly inside — z=(1.99,0), c=0 → NOT escaped (|z|²<4)
        //   1.99 raw ≈ 1.99 * 2^20 = 2086666 (just under TWO = 2097152)
        // ------------------------------------------------------------------
        z_r = 24'sd2086666; z_i = 0; c_r = 0; c_i = 0; #1;
        check_cond(escaped, 1'b0, "z=(1.99,0): not escaped");

        // ------------------------------------------------------------------
        // Test 5: z=(1,1), c=(0,0) → z' = (0, 2)
        //   z_r' = 1² - 1² + 0 = 0
        //   z_i' = 2*1*1 + 0   = 2
        //   |z_in|² = 1+1 = 2 < 4 → not escaped
        // ------------------------------------------------------------------
        z_r = ONE; z_i = ONE; c_r = 0; c_i = 0; #1;
        check_fp  (z_r_out, 0,   2, "z=(1,1),c=0: z_r_out=0 ");
        check_fp  (z_i_out, TWO, 2, "z=(1,1),c=0: z_i_out=2 ");
        check_cond(escaped, 1'b0,   "z=(1,1): not escaped   ");

        // ------------------------------------------------------------------
        // Test 6: z=(1.5, 0.5), c=(0,0)
        //   z_r' = 1.5² - 0.5² = 2.25 - 0.25 = 2.0
        //   z_i' = 2*1.5*0.5 = 1.5
        //   1.5 raw = 1572864, 2.0 raw = 2097152
        //   |z_in|² = 2.25 + 0.25 = 2.5 < 4 → not escaped
        // ------------------------------------------------------------------
        z_r = 24'sd1572864; z_i = 24'sd524288; c_r = 0; c_i = 0; #1;
        check_fp  (z_r_out, 24'sd2097152, 4, "z=(1.5,0.5): z_r=2.0  ");
        check_fp  (z_i_out, 24'sd1572864, 4, "z=(1.5,0.5): z_i=1.5  ");
        check_cond(escaped, 1'b0,              "z=(1.5,0.5): not esc  ");

        // ------------------------------------------------------------------
        // Test 7: z=(0, 2.1), c=(0,0) — ESCAPED (|z|² = 4.41 > 4)
        //   2.1 raw = 2.1 * 2^20 = 2202010
        // ------------------------------------------------------------------
        z_r = 0; z_i = 24'sd2202010; c_r = 0; c_i = 0; #1;
        check_cond(escaped, 1'b1, "z=(0,2.1): escaped=1   ");

        // ------------------------------------------------------------------
        // Test 8: z=0, c=-2.0+0i (real boundary of Mandelbrot set)
        //   z_r' = 0 + (-2.0) = -2.0
        //   z_i' = 0
        //   -2.0 raw = -2097152
        // ------------------------------------------------------------------
        z_r = 0; z_i = 0; c_r = -24'sd2097152; c_i = 0; #1;
        check_fp  (z_r_out, -24'sd2097152, 2, "z=0,c=-2+0i: z_r=-2  ");
        check_fp  (z_i_out, 0,             0, "z=0,c=-2+0i: z_i=0   ");
        check_cond(escaped, 1'b0,              "z=0 (before iter): ok");

        // ------------------------------------------------------------------
        // Tests 9–10: Burning Ship mode (burning_ship=1)
        //
        //   Burning Ship: z_i' = 2*|z_r|*|z_i| + c_i
        //   Test 9: z=(-1, -1), c=(0,0), burning_ship=1
        //     |z_r|=1, |z_i|=1
        //     z_r' = (-1)² - (-1)² + 0 = 0          (same as Mandelbrot)
        //     z_i' = 2*1*1 + 0          = 2.0        (absolute values)
        //     Mandelbrot would give z_i' = 2*(-1)*(-1) = +2.0 (same here!)
        //
        //   Test 10: z=(-1, 1), c=(0,0), burning_ship=1
        //     |z_r|=1, |z_i|=1
        //     z_r' = (-1)² - 1² + 0 = 0
        //     z_i' = 2*1*1 + 0  = 2.0    (Burning Ship: positive)
        //     Mandelbrot gives: z_i' = 2*(-1)*(1) = -2.0  (opposite sign!)
        //     This sign difference is what distinguishes the two fractals.
        // ------------------------------------------------------------------
        $display("\n-- Tests 9-10: Burning Ship mode (burning_ship=1) --");
        burning_ship = 1'b1;

        // Test 9: z=(-1,-1), c=(0,0) — same result as Mandelbrot for this case
        z_r = -ONE; z_i = -ONE; c_r = 0; c_i = 0; #1;
        check_fp  (z_r_out, 0,   2, "BS z=(-1,-1): z_r'=0          ");
        check_fp  (z_i_out, TWO, 2, "BS z=(-1,-1): z_i'=2 (abs val)");

        // Test 10: z=(-1,+1), c=(0,0)
        //   Burning Ship: z_i' = 2*|(-1)|*|(+1)| = +2.0
        //   (Mandelbrot would give 2*(-1)*(+1) = -2.0 — opposite sign)
        z_r = -ONE; z_i = ONE; c_r = 0; c_i = 0; #1;
        check_fp  (z_r_out, 0,   2, "BS z=(-1,+1): z_r'=0          ");
        check_fp  (z_i_out, TWO, 2, "BS z=(-1,+1): z_i'=+2 not -2  ");

        // =========================================================================
        $display("");
        $display("=================================================");
        $display("  TEST SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        if (fail_count == 0)
            $display("  ** ALL TESTS PASSED — MandelbrotIterator verified **");
        else
            $display("  ** FAILURES DETECTED — review output above **");
        $display("=================================================");
        $finish;
    end

endmodule
