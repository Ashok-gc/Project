////////////////////////////////////////////////////////////////////////////////
// Module:      ColourMapper
// Author:      Ashok G C
// Date:        2026-04-20
// Description: Maps a Mandelbrot/Julia iteration count to an RGB565 colour.
//
//              Four colour palettes selectable via palette_sel[1:0]:
//                0 — Blue-Gold  : dark blue → cyan → gold → white  (classic)
//                1 — Fire       : black → red → orange → yellow → white
//                2 — Ice        : black → navy → cyan → white      (cool)
//                3 — Electric   : black → purple → magenta → pink → white
//
//              Dynamic iteration depth via max_iter_sel[1:0]:
//                00 → effective MAX_ITER = 32   (fast, low detail)
//                01 → effective MAX_ITER = 64   (default)
//                10 → effective MAX_ITER = 128  (more detail)
//                11 → effective MAX_ITER = 256  (deep zoom quality)
//
//              The 16-entry palette is indexed by dividing iter_count into
//              bands of size (iter_limit / 16).  Points inside the set
//              (escaped = 0) cycle through a 256-entry smooth interior palette
//              driven by the full cycle_count[7:0] from a free-running timer.
//
//              Interior smooth cycle (256 entries, ~10.7 s full cycle at 50 MHz):
//                Blue (0x001F) → Red (0xF800) → Yellow (0xFFE0) →
//                Purple (0x8010) → Blue  (linear interpolation, 64 steps each)
//              No black entries — the interior is always visibly coloured.
//
// Parameters:
//   MAX_ITER   - Compile-time maximum supported iterations (default 256)
//                Must match MandelbrotCore's MAX_ITER parameter.
//
// Ports:
//   iter_count  [input]  - Iteration count at escape (or MAX_ITER if inside)
//   escaped     [input]  - 1 = pixel escaped, 0 = inside set
//   palette_sel [input]  - 2-bit palette selector (0-3)
//   max_iter_sel[input]  - 2-bit iteration depth selector (00-11)
//   cycle_count [input]  - 8-bit free-running counter driving interior colour
//   colour      [output] - RGB565 colour for the LT24 LCD
////////////////////////////////////////////////////////////////////////////////

module ColourMapper #(
    parameter MAX_ITER = 256
)(
    input  wire [$clog2(MAX_ITER+1)-1:0] iter_count,
    input  wire                          escaped,
    input  wire [1:0]                    palette_sel,    // 4 palettes
    input  wire [1:0]                    max_iter_sel,   // effective depth
    input  wire [7:0]                    cycle_count,    // frame_count → interior colour
    output reg  [15:0]                   colour
);

    // -------------------------------------------------------------------------
    // Derive effective iteration limit from selector
    // -------------------------------------------------------------------------
    wire [8:0] iter_limit;
    assign iter_limit = (max_iter_sel == 2'b00) ? 9'd32  :
                        (max_iter_sel == 2'b01) ? 9'd64  :
                        (max_iter_sel == 2'b10) ? 9'd128 : 9'd256;

    // -------------------------------------------------------------------------
    // Palette index [0..15]:
    //   iter_count / (iter_limit/16) = iter_count >> log2(iter_limit/16)
    //   Shift amounts: depth=32→1, depth=64→2, depth=128→3, depth=256→4
    //   Points at or beyond iter_limit map to index 0.
    // -------------------------------------------------------------------------
    wire [3:0] palette_idx;
    assign palette_idx = (iter_count >= iter_limit) ? 4'd0 :
                         (max_iter_sel == 2'b00)    ? iter_count[4:1] :
                         (max_iter_sel == 2'b01)    ? iter_count[5:2] :
                         (max_iter_sel == 2'b10)    ? iter_count[6:3] :
                                                      iter_count[7:4];

    // -------------------------------------------------------------------------
    // RGB565 colour palettes  (synthesise to block RAM on Cyclone V)
    // Format: [15:11]=R(5) [10:5]=G(6) [4:0]=B(5)
    // -------------------------------------------------------------------------
    reg [15:0] blue_gold [0:15];
    reg [15:0] fire      [0:15];
    reg [15:0] ice       [0:15];
    reg [15:0] electric  [0:15];

    // Palette 0 — Blue-Gold (classic Mandelbrot look)
    initial begin
        blue_gold[ 0] = 16'h0000; // Black
        blue_gold[ 1] = 16'h0010; // Very dark blue
        blue_gold[ 2] = 16'h0031; // Dark blue
        blue_gold[ 3] = 16'h0053; // Medium blue
        blue_gold[ 4] = 16'h0494; // Blue-cyan
        blue_gold[ 5] = 16'h04B6; // Cyan
        blue_gold[ 6] = 16'h07F7; // Bright cyan
        blue_gold[ 7] = 16'h07FF; // Aqua
        blue_gold[ 8] = 16'h3FFF; // Light cyan-white
        blue_gold[ 9] = 16'hBFE0; // Light gold
        blue_gold[10] = 16'hFFE0; // Gold / yellow
        blue_gold[11] = 16'hFD20; // Orange-gold
        blue_gold[12] = 16'hFC00; // Orange
        blue_gold[13] = 16'hFB80; // Deep orange
        blue_gold[14] = 16'hF800; // Red-orange
        blue_gold[15] = 16'hFFFF; // White (near-boundary highlight)
    end

    // Palette 1 — Fire (black → dark red → orange → yellow → white)
    initial begin
        fire[ 0] = 16'h0000; // Black
        fire[ 1] = 16'h1000; // Very dark red
        fire[ 2] = 16'h2000; // Dark red
        fire[ 3] = 16'h4000; // Medium dark red
        fire[ 4] = 16'h8000; // Red
        fire[ 5] = 16'hA000; // Bright red
        fire[ 6] = 16'hF800; // Pure red
        fire[ 7] = 16'hF980; // Red-orange
        fire[ 8] = 16'hFB00; // Orange-red
        fire[ 9] = 16'hFC00; // Orange
        fire[10] = 16'hFD00; // Deep orange
        fire[11] = 16'hFE00; // Orange-yellow
        fire[12] = 16'hFF00; // Yellow-orange
        fire[13] = 16'hFFE0; // Yellow
        fire[14] = 16'hFFF0; // Pale yellow
        fire[15] = 16'hFFFF; // White
    end

    // Palette 2 — Ice (black → deep navy → cyan → white)
    initial begin
        ice[ 0] = 16'h0000; // Black
        ice[ 1] = 16'h0012; // Deep navy
        ice[ 2] = 16'h0035; // Navy
        ice[ 3] = 16'h0098; // Royal blue
        ice[ 4] = 16'h01FB; // Steel blue
        ice[ 5] = 16'h051F; // Cornflower blue
        ice[ 6] = 16'h059F; // Blue-cyan
        ice[ 7] = 16'h07FF; // Pure cyan
        ice[ 8] = 16'h2FFF; // Light cyan
        ice[ 9] = 16'h5FFF; // Pale cyan
        ice[10] = 16'h9FFF; // Very pale cyan
        ice[11] = 16'hAFFF; // Near-white cyan
        ice[12] = 16'hCFFF; // Ice blue
        ice[13] = 16'hDFFF; // Pale ice
        ice[14] = 16'hEFFF; // Near white blue
        ice[15] = 16'hFFFF; // White
    end

    // Palette 3 — Electric (black → purple → magenta → pink → white)
    initial begin
        electric[ 0] = 16'h0000; // Black
        electric[ 1] = 16'h1001; // Dark purple
        electric[ 2] = 16'h2003; // Purple
        electric[ 3] = 16'h4807; // Violet
        electric[ 4] = 16'h800F; // Deep violet
        electric[ 5] = 16'hA00F; // Bright violet
        electric[ 6] = 16'hC01F; // Purple-magenta
        electric[ 7] = 16'hF81F; // Magenta
        electric[ 8] = 16'hF83F; // Pink-magenta
        electric[ 9] = 16'hFC5F; // Hot pink
        electric[10] = 16'hFD9F; // Light pink
        electric[11] = 16'hFEBF; // Pale pink
        electric[12] = 16'hFF9F; // Lavender-pink
        electric[13] = 16'hFFBF; // Light lavender
        electric[14] = 16'hFFDF; // Near white pink
        electric[15] = 16'hFFFF; // White
    end

    // -------------------------------------------------------------------------
    // Interior smooth colour cycling palette (256 entries).
    // Indexed by the full cycle_count[7:0] from a free-running 29-bit timer
    // (each step ≈ 41.9 ms; full 256-step cycle ≈ 10.7 s at 50 MHz).
    //
    // Linear interpolation across 4 colour stops (64 steps per segment):
    //   Seg 0 [  0.. 63]: Blue   (R= 0,G= 0,B=31) → Red    (R=31,G= 0,B= 0)
    //   Seg 1 [ 64..127]: Red    (R=31,G= 0,B= 0) → Yellow (R=31,G=63,B= 0)
    //   Seg 2 [128..191]: Yellow (R=31,G=63,B= 0) → Purple (R=16,G= 0,B=16)
    //   Seg 3 [192..255]: Purple (R=16,G= 0,B=16) → Blue   (R= 0,G= 0,B=31)
    //
    // RGB565: [15:11]=R(5 bits), [10:5]=G(6 bits), [4:0]=B(5 bits)
    // No black entries — interior is always visibly coloured.
    // -------------------------------------------------------------------------
    reg [15:0] smooth_cycle [0:255];

    initial begin : gen_smooth_palette
        integer i;
        integer r, g, b;

        // Segment 0: Blue → Red  (R: 0→31, G: 0, B: 31→0)
        for (i = 0; i < 64; i = i + 1) begin
            r = (31 * i) / 63;
            g = 0;
            b = 31 - (31 * i) / 63;
            smooth_cycle[i] = {r[4:0], g[5:0], b[4:0]};
        end

        // Segment 1: Red → Yellow  (R: 31, G: 0→63, B: 0)
        for (i = 0; i < 64; i = i + 1) begin
            r = 31;
            g = (63 * i) / 63;
            b = 0;
            smooth_cycle[64 + i] = {r[4:0], g[5:0], b[4:0]};
        end

        // Segment 2: Yellow → Purple  (R: 31→16, G: 63→0, B: 0→16)
        for (i = 0; i < 64; i = i + 1) begin
            r = 31 - (15 * i) / 63;
            g = 63 - (63 * i) / 63;
            b = (16 * i) / 63;
            smooth_cycle[128 + i] = {r[4:0], g[5:0], b[4:0]};
        end

        // Segment 3: Purple → Blue  (R: 16→0, G: 0, B: 16→31)
        for (i = 0; i < 64; i = i + 1) begin
            r = 16 - (16 * i) / 63;
            g = 0;
            b = 16 + (15 * i) / 63;
            smooth_cycle[192 + i] = {r[4:0], g[5:0], b[4:0]};
        end
    end

    // -------------------------------------------------------------------------
    // Colour output:
    //   escaped=0 → smooth Blue→Red→Yellow→Purple cycling (interior, both modes)
    //   escaped=1 → escape-time palette lookup
    // -------------------------------------------------------------------------
    wire [7:0] interior_idx = cycle_count;  // full 8-bit index → 256-entry palette

    always @(*) begin
        if (!escaped) begin
            colour = smooth_cycle[interior_idx];
        end else begin
            case (palette_sel)
                2'b00: colour = blue_gold[palette_idx];
                2'b01: colour = fire     [palette_idx];
                2'b10: colour = ice      [palette_idx];
                2'b11: colour = electric [palette_idx];
            endcase
        end
    end

endmodule
