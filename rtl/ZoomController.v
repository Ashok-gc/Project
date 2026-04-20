////////////////////////////////////////////////////////////////////////////////
// Module:      ZoomController
// Author:      Ashok GC
// Date:        2026-04-20
// Description: Viewport manager for the Mandelbrot / Julia Set explorer.
//              Uses rising-edge detection on each input — one press = one action.
//
//              KEY rising edge (active-high after synchroniser):
//                key_zoom_in  → halve scale (zoom in),  zoom_level++
//                key_zoom_out → double scale (zoom out), zoom_level--
//
//              SW rising edge (switch flipped ON):
//                sw_pan[0] → pan left   (x_offset -= x_scale * PAN_PIXELS)
//                sw_pan[1] → pan right  (x_offset += x_scale * PAN_PIXELS)
//                sw_pan[2] → pan up     (y_offset -= y_scale * PAN_PIXELS)
//                sw_pan[3] → pan down   (y_offset += y_scale * PAN_PIXELS)
//
//              render_trigger pulses 1 cycle on every viewport change.
//              On reset the initial viewport is restored and render_trigger=1.
//
//              julia_cr / julia_ci (combinatorial outputs):
//                Expose the current viewport centre as a complex number.
//                When Julia mode is enabled (SW[2]), these become the Julia
//                parameter c, showing the Julia set for the screen centre point.
//
//                julia_cr = x_offset + x_scale*(SCREEN_WIDTH/2)
//                         = x_offset + 2*zoom_dx[DW-1:0]
//                julia_ci = y_offset + y_scale*(SCREEN_HEIGHT/2)
//                         = y_offset + 2*zoom_dy[DW-1:0]
////////////////////////////////////////////////////////////////////////////////

module ZoomController #(
    parameter CLOCK_FREQ     = 50_000_000,
    parameter DATA_WIDTH     = 24,
    parameter FRAC_BITS      = 20,
    parameter SCREEN_WIDTH   = 240,
    parameter SCREEN_HEIGHT  = 320,
    parameter PAN_PIXELS     = 32,
    parameter MAX_ZOOM_LEVEL = 12
)(
    input  wire                         clk,
    input  wire                         reset,

    input  wire                         key_zoom_in,
    input  wire                         key_zoom_out,
    input  wire [3:0]                   sw_pan,

    output reg  signed [DATA_WIDTH-1:0] x_offset,
    output reg  signed [DATA_WIDTH-1:0] y_offset,
    output reg  signed [DATA_WIDTH-1:0] x_scale,
    output reg  signed [DATA_WIDTH-1:0] y_scale,
    output reg  [3:0]                   zoom_level,
    output reg                          render_trigger,

    // Viewport centre — forwarded to MandelbrotCore as Julia parameter
    output wire signed [DATA_WIDTH-1:0] julia_cr,
    output wire signed [DATA_WIDTH-1:0] julia_ci
);

    // -------------------------------------------------------------------------
    // Initial viewport (Q4.20, 2^20 = 1_048_576)
    // -------------------------------------------------------------------------
    localparam signed [DATA_WIDTH-1:0] X_OFFSET_INIT = -24'sd2621440;
    localparam signed [DATA_WIDTH-1:0] Y_OFFSET_INIT = -24'sd1310720;
    localparam signed [DATA_WIDTH-1:0] X_SCALE_INIT  =  24'sd15300;
    localparam signed [DATA_WIDTH-1:0] Y_SCALE_INIT  =  24'sd8192;

    // -------------------------------------------------------------------------
    // Rising-edge detection
    // -------------------------------------------------------------------------
    reg ki_prev;
    reg ko_prev;
    reg [3:0] sw_prev;

    wire ki_rise       = key_zoom_in  & ~ki_prev;
    wire ko_rise       = key_zoom_out & ~ko_prev;
    wire [3:0] sw_rise = sw_pan & ~sw_prev;

    // -------------------------------------------------------------------------
    // Combinational pan / zoom deltas
    //   pan_dx  = x_scale * 32
    //   zoom_dx = x_scale * 60  (= x_scale * SCREEN_WIDTH/4)
    //   2*zoom_dx = x_scale * SCREEN_WIDTH/2 = x_scale * 120 (centre offset)
    // -------------------------------------------------------------------------
    wire signed [DATA_WIDTH+7:0] pan_dx;
    wire signed [DATA_WIDTH+7:0] pan_dy;
    wire signed [DATA_WIDTH+7:0] zoom_dx;
    wire signed [DATA_WIDTH+7:0] zoom_dy;

    assign pan_dx  = {{8{x_scale[DATA_WIDTH-1]}}, x_scale} * $signed(8'sd32);
    assign pan_dy  = {{8{y_scale[DATA_WIDTH-1]}}, y_scale} * $signed(8'sd32);
    assign zoom_dx = {{8{x_scale[DATA_WIDTH-1]}}, x_scale} * $signed(8'sd60);
    assign zoom_dy = {{8{y_scale[DATA_WIDTH-1]}}, y_scale} * $signed(8'sd80);

    // -------------------------------------------------------------------------
    // Viewport centre (combinatorial) — Julia parameter
    //   {zoom_dx[DW-2:0], 1'b0} = lower DW bits of (zoom_dx * 2)
    // -------------------------------------------------------------------------
    assign julia_cr = x_offset + $signed({zoom_dx[DATA_WIDTH-2:0], 1'b0});
    assign julia_ci = y_offset + $signed({zoom_dy[DATA_WIDTH-2:0], 1'b0});

    // -------------------------------------------------------------------------
    // Viewport update (single always block, rising-edge detection)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            x_offset       <= X_OFFSET_INIT;
            y_offset       <= Y_OFFSET_INIT;
            x_scale        <= X_SCALE_INIT;
            y_scale        <= Y_SCALE_INIT;
            zoom_level     <= 4'd0;
            render_trigger <= 1'b1;
            ki_prev        <= 1'b0;
            ko_prev        <= 1'b0;
            sw_prev        <= 4'b0000;
        end else begin
            ki_prev <= key_zoom_in;
            ko_prev <= key_zoom_out;
            sw_prev <= sw_pan;

            render_trigger <= 1'b0;

            if (ki_rise && zoom_level < MAX_ZOOM_LEVEL[3:0]) begin
                x_offset       <= x_offset + zoom_dx[DATA_WIDTH-1:0];
                y_offset       <= y_offset + zoom_dy[DATA_WIDTH-1:0];
                x_scale        <= x_scale >>> 1;
                y_scale        <= y_scale >>> 1;
                zoom_level     <= zoom_level + 4'd1;
                render_trigger <= 1'b1;

            end else if (ko_rise && zoom_level > 4'd0) begin
                x_offset       <= x_offset - {zoom_dx[DATA_WIDTH-2:0], 1'b0};
                y_offset       <= y_offset - {zoom_dy[DATA_WIDTH-2:0], 1'b0};
                x_scale        <= x_scale <<< 1;
                y_scale        <= y_scale <<< 1;
                zoom_level     <= zoom_level - 4'd1;
                render_trigger <= 1'b1;

            end else if (sw_rise[0]) begin
                x_offset       <= x_offset - pan_dx[DATA_WIDTH-1:0];
                render_trigger <= 1'b1;

            end else if (sw_rise[1]) begin
                x_offset       <= x_offset + pan_dx[DATA_WIDTH-1:0];
                render_trigger <= 1'b1;

            end else if (sw_rise[2]) begin
                y_offset       <= y_offset - pan_dy[DATA_WIDTH-1:0];
                render_trigger <= 1'b1;

            end else if (sw_rise[3]) begin
                y_offset       <= y_offset + pan_dy[DATA_WIDTH-1:0];
                render_trigger <= 1'b1;
            end
        end
    end

endmodule
