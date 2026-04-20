////////////////////////////////////////////////////////////////////////////////
// Module:      MandelbrotCore
// Author:      Ashok GC
// Date:        2026-04-20
// Description: Mandelbrot / Julia Set computation and rendering engine.
//              Drives the LT24 LCD pixel-by-pixel via a raster scan FSM.
//
//              Two rendering modes selectable at runtime:
//
//              Mandelbrot mode (julia_mode = 0):
//                For each pixel coord c = (c_r, c_i):
//                  z₀ = 0;  z_{n+1} = z_n² + c
//
//              Julia mode (julia_mode = 1):
//                For each pixel coord z₀ = (c_r, c_i),
//                using fixed parameter c = (julia_cr, julia_ci):
//                  z_{n+1} = z_n² + c
//                The viewport centre passed from ZoomController becomes c
//                when the user zooms to an interesting Mandelbrot region and
//                flips SW[2], revealing the corresponding Julia set.
//
//              Additive raster scan (no per-pixel multiply):
//                c_r starts at x_offset, increments by x_scale each column.
//                c_i starts at y_offset, increments by y_scale each row.
//                In Julia mode these become the initial z values; the fixed
//                Julia parameter (julia_cr, julia_ci) is the iteration c.
//
//              Dynamic iteration depth via max_iter_sel (2-bit):
//                00 = 32 iters (fast, low zoom detail)
//                01 = 64 iters (default)
//                10 = 128 iters (good for zoom > 8)
//                11 = 256 iters (deep zoom quality)
//
//              Rendering progress output:
//                render_row — current pixel row being computed (0..SCREEN_HEIGHT-1)
//                Used by MandelbrotTop to drive a 6-LED progress thermometer.
//
//              FSM states (Moore):
//                IDLE        → INIT_FRAME  → INIT_ROW  → INIT_PIXEL
//                COMPUTE     → WRITE_PIXEL → NEXT_PIXEL → NEXT_ROW
//                NEXT_ROW loops back to INIT_ROW or IDLE.
//
// Parameters:
//   CLOCK_FREQ    - System clock Hz         (default 50_000_000)
//   DATA_WIDTH    - Fixed-point bit width   (default 24)
//   FRAC_BITS     - Fractional bits         (default 20)
//   MAX_ITER      - Maximum supported iters (default 256)
//   SCREEN_WIDTH  - LCD width in pixels     (default 240)
//   SCREEN_HEIGHT - LCD height in pixels    (default 320)
////////////////////////////////////////////////////////////////////////////////

module MandelbrotCore #(
    parameter CLOCK_FREQ    = 50_000_000,
    parameter DATA_WIDTH    = 24,
    parameter FRAC_BITS     = 20,
    parameter MAX_ITER      = 256,
    parameter SCREEN_WIDTH  = 240,
    parameter SCREEN_HEIGHT = 320
)(
    input  wire                         clk,
    input  wire                         reset,

    // Render control
    input  wire                         render_trigger,
    input  wire signed [DATA_WIDTH-1:0] x_offset,
    input  wire signed [DATA_WIDTH-1:0] y_offset,
    input  wire signed [DATA_WIDTH-1:0] x_scale,
    input  wire signed [DATA_WIDTH-1:0] y_scale,

    // Mode controls
    input  wire                         julia_mode,     // 0=Mandelbrot 1=Julia
    input  wire signed [DATA_WIDTH-1:0] julia_cr,       // Julia set parameter (real)
    input  wire signed [DATA_WIDTH-1:0] julia_ci,       // Julia set parameter (imag)
    input  wire [1:0]                   palette_sel,    // 4 palettes (2-bit)
    input  wire [1:0]                   max_iter_sel,   // 00=32 01=64 10=128 11=256
    input  wire [7:0]                   cycle_count,    // free-running timer → interior colour
    input  wire                         burning_ship,   // 0=Mandelbrot/Julia 1=Burning Ship

    // LT24 pixel interface
    output reg  [7:0]                   xAddr,
    output reg  [8:0]                   yAddr,
    output wire [15:0]                  pixelData,
    output reg                          pixelWrite,
    input  wire                         pixelReady,
    output wire                         pixelRawMode,

    // Status outputs
    output reg                          rendering,
    output reg  [7:0]                   frame_count,
    output wire [8:0]                   render_row      // current row for LED progress bar
);

    // -------------------------------------------------------------------------
    // Constant outputs
    // -------------------------------------------------------------------------
    assign pixelRawMode = 1'b0;  // addressed pixel mode

    // -------------------------------------------------------------------------
    // Derive effective iteration limit from runtime selector
    // -------------------------------------------------------------------------
    wire [8:0] iter_limit;
    assign iter_limit = (max_iter_sel == 2'b00) ? 9'd32  :
                        (max_iter_sel == 2'b01) ? 9'd64  :
                        (max_iter_sel == 2'b10) ? 9'd128 : 9'd256;

    // -------------------------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------------------------
    reg [$clog2(SCREEN_WIDTH)-1:0]  px;       // Current column (0..SCREEN_WIDTH-1)
    reg [$clog2(SCREEN_HEIGHT)-1:0] py;       // Current row    (0..SCREEN_HEIGHT-1)
    reg [$clog2(MAX_ITER+1)-1:0]    iter;     // Iteration counter

    // Pixel scan coordinates (accumulated additively each pixel/row)
    reg signed [DATA_WIDTH-1:0] c_r, c_i;

    // Iteration variables
    reg signed [DATA_WIDTH-1:0] z_r, z_i;       // Current z value
    reg signed [DATA_WIDTH-1:0] iter_cr, iter_ci; // Fixed c for this pixel

    // Colour mapping inputs (captured at escape)
    reg [$clog2(MAX_ITER+1)-1:0] iter_final;
    reg                          escaped_final;

    // Latch render_trigger pulses that arrive while a frame is in progress
    reg pending_render;

    // Expose current row for LED progress bar (zero-extends py automatically)
    assign render_row = py;

    // -------------------------------------------------------------------------
    // MandelbrotIterator — one combinational z → z²+c step
    // -------------------------------------------------------------------------
    wire signed [DATA_WIDTH-1:0] z_r_next, z_i_next;
    wire                         iter_escaped;

    MandelbrotIterator #(
        .DATA_WIDTH(DATA_WIDTH),
        .FRAC_BITS (FRAC_BITS)
    ) iterator (
        .z_r         (z_r         ),
        .z_i         (z_i         ),
        .c_r         (iter_cr     ),   // Mandelbrot: pixel coord; Julia: fixed c
        .c_i         (iter_ci     ),
        .burning_ship(burning_ship),   // enables |z_r|*|z_i| cross term
        .z_r_out     (z_r_next    ),
        .z_i_out     (z_i_next    ),
        .escaped     (iter_escaped)
    );

    // -------------------------------------------------------------------------
    // ColourMapper — iter count → RGB565
    // -------------------------------------------------------------------------
    ColourMapper #(
        .MAX_ITER(MAX_ITER)
    ) colour_map (
        .iter_count  (iter_final   ),
        .escaped     (escaped_final),
        .palette_sel (palette_sel  ),
        .max_iter_sel(max_iter_sel ),
        .cycle_count (cycle_count  ),  // free-running timer drives interior colour
        .colour      (pixelData    )
    );

    // -------------------------------------------------------------------------
    // FSM state encoding
    // -------------------------------------------------------------------------
    localparam [2:0] IDLE        = 3'b000,
                     INIT_FRAME  = 3'b001,
                     INIT_ROW    = 3'b010,
                     INIT_PIXEL  = 3'b011,
                     COMPUTE     = 3'b100,
                     WRITE_PIXEL = 3'b101,
                     NEXT_PIXEL  = 3'b110,
                     NEXT_ROW    = 3'b111;

    reg [2:0] state;

    // -------------------------------------------------------------------------
    // FSM — synchronous active-high reset
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            state          <= IDLE;
            rendering      <= 1'b0;
            frame_count    <= 8'd0;
            pixelWrite     <= 1'b0;
            xAddr          <= 8'd0;
            yAddr          <= 9'd0;
            iter_final     <= {($clog2(MAX_ITER+1)){1'b0}};
            escaped_final  <= 1'b0;
            pending_render <= 1'b0;
        end else begin

            // Latch any render_trigger pulse, even while busy.
            if (render_trigger)
                pending_render <= 1'b1;

            case (state)

                // -------------------------------------------------------------
                IDLE: begin
                    rendering  <= 1'b0;
                    pixelWrite <= 1'b0;
                    if (pending_render) begin
                        pending_render <= 1'b0;
                        state          <= INIT_FRAME;
                        rendering      <= 1'b1;
                    end
                end

                // -------------------------------------------------------------
                INIT_FRAME: begin
                    c_i   <= y_offset;
                    py    <= {($clog2(SCREEN_HEIGHT)){1'b0}};
                    state <= INIT_ROW;
                end

                // -------------------------------------------------------------
                INIT_ROW: begin
                    c_r   <= x_offset;
                    px    <= {($clog2(SCREEN_WIDTH)){1'b0}};
                    state <= INIT_PIXEL;
                end

                // -------------------------------------------------------------
                // INIT_PIXEL: Set up z and iteration constant for this pixel.
                //
                //   Mandelbrot mode (julia_mode=0):
                //     z starts at (0, 0); c = current pixel coordinate (c_r, c_i)
                //
                //   Julia mode (julia_mode=1):
                //     z starts at pixel coordinate (c_r, c_i);
                //     c = fixed Julia parameter (julia_cr, julia_ci)
                // -------------------------------------------------------------
                INIT_PIXEL: begin
                    if (julia_mode) begin
                        z_r     <= c_r;      // pixel coord becomes z₀
                        z_i     <= c_i;
                        iter_cr <= julia_cr; // fixed Julia c
                        iter_ci <= julia_ci;
                    end else begin
                        z_r     <= {DATA_WIDTH{1'b0}};  // z₀ = 0
                        z_i     <= {DATA_WIDTH{1'b0}};
                        iter_cr <= c_r;                 // pixel coord is c
                        iter_ci <= c_i;
                    end
                    iter  <= {($clog2(MAX_ITER+1)){1'b0}};
                    state <= COMPUTE;
                end

                // -------------------------------------------------------------
                // COMPUTE: One Mandelbrot/Julia iteration per clock cycle.
                //   MandelbrotIterator is combinational — z_r_next, z_i_next,
                //   and iter_escaped are valid every cycle.
                //   Terminates at escape OR when iter reaches iter_limit - 1.
                // -------------------------------------------------------------
                COMPUTE: begin
                    if (iter_escaped || (iter == iter_limit - 9'd1)) begin
                        iter_final    <= iter;
                        escaped_final <= iter_escaped;
                        xAddr         <= px;  // zero-extend (Verilog auto)
                        yAddr         <= py;  // zero-extend
                        state         <= WRITE_PIXEL;
                    end else begin
                        z_r  <= z_r_next;
                        z_i  <= z_i_next;
                        iter <= iter + 1;
                    end
                end

                // -------------------------------------------------------------
                // WRITE_PIXEL: Hold pixelWrite high until LT24 asserts pixelReady.
                // -------------------------------------------------------------
                WRITE_PIXEL: begin
                    pixelWrite <= 1'b1;
                    if (pixelReady) begin
                        pixelWrite <= 1'b0;
                        state      <= NEXT_PIXEL;
                    end
                end

                // -------------------------------------------------------------
                NEXT_PIXEL: begin
                    if (px == SCREEN_WIDTH - 1) begin
                        state <= NEXT_ROW;
                    end else begin
                        px    <= px + 1;
                        c_r   <= c_r + x_scale;
                        state <= INIT_PIXEL;
                    end
                end

                // -------------------------------------------------------------
                NEXT_ROW: begin
                    if (py == SCREEN_HEIGHT - 1) begin
                        frame_count <= frame_count + 8'd1;
                        if (pending_render) begin
                            pending_render <= 1'b0;
                            state          <= INIT_FRAME;
                            rendering      <= 1'b1;
                        end else begin
                            rendering <= 1'b0;
                            state     <= IDLE;
                        end
                    end else begin
                        py    <= py + 1;
                        c_i   <= c_i + y_scale;
                        state <= INIT_ROW;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
