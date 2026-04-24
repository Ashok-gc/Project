# FPGA Mandelbrot / Julia Set Explorer

**Module:** ELEC5566M — FPGA Design for System on Chip  
**Author:** Ashok
**Institution:** University of Leeds  
**Target Device:** Intel Cyclone V (5CSEMA5F31C6) — Terasic DE1-SoC  
**Display:** LT24 LCD Module (240×320 pixels, RGB565 colour)  
**Tool:** Intel Quartus Prime 22.1std, ModelSim-Intel FPGA Starter 2020.1

---

## Overview

This project implements a fully interactive Mandelbrot Set and Julia Set explorer on an FPGA. The design renders fractal images in real time on a 240×320 colour LCD display and allows the user to zoom in, zoom out, pan, switch colour palettes, control iteration depth, and toggle between Mandelbrot and Julia Set modes — all using the DE1-SoC's pushbuttons and slide switches.

**Mandelbrot mode** renders the classic Mandelbrot set using the iteration:

```
z₀ = 0,   z_{n+1} = z_n² + c      (c = pixel coordinate)
```

**Julia Set mode** (SW[2] = ON) renders the Julia set for the complex constant *c* equal to the current viewport centre, using:

```
z₀ = pixel coordinate,   z_{n+1} = z_n² + c      (c fixed = viewport centre)
```

This means you can zoom into an interesting Mandelbrot boundary region, flip SW[2], and instantly see the corresponding Julia set for that complex number — a mathematically meaningful connection between the two fractals.

All arithmetic uses **Q4.20 signed fixed-point** (24-bit), implemented in custom parameterised RTL IP. No floating-point hardware or HPS (ARM processor) is used — the entire computation runs in the FPGA fabric.

---

## Features

- Real-time Mandelbrot and Julia Set rendering (~19 fps typical at 50 MHz)
- Interactive zoom in / zoom out (up to 12 zoom levels, ~4096× magnification)
- Four-direction panning (left, right, up, down) via slide switches
- **Julia Set mode**: flip SW[2] to render the Julia set for the current viewport centre
- **Four colour palettes**: Blue-Gold, Fire, Ice, Electric — selected by SW[1:0]
- **Dynamic iteration depth**: 32 / 64 / 128 / 256 iterations via SW[9:8] — trade rendering speed for zoom detail
- **6-LED rendering progress bar**: LEDR[9:4] fill up left-to-right as each frame renders
- Zoom level displayed on HEX1:HEX0 (7-segment hex, 00–0C)
- Frame counter displayed on HEX3:HEX2 (wraps at FF)
- Rendering activity indicator on LEDR[0]
- Palette selection shown on LEDR[2:1]; Julia mode shown on LEDR[3]
- Fully parameterised design — screen size, iteration depth, zoom levels, and fixed-point width are all parameters

---

## User Controls

### Inputs

| Input | Action |
|-------|--------|
| KEY[0] (active-low) | System reset — returns to initial full Mandelbrot view |
| KEY[1] (active-low) | Zoom in (halves scale, keeps centre fixed) |
| KEY[2] (active-low) | Zoom out (doubles scale, keeps centre fixed) |
| SW[1:0] | Colour palette: 00=Blue-Gold  01=Fire  10=Ice  11=Electric |
| SW[2] | Julia Set mode: OFF=Mandelbrot, ON=Julia |
| SW[4] | Pan left |
| SW[5] | Pan right |
| SW[6] | Pan up |
| SW[7] | Pan down |
| SW[9:8] | Iteration depth: 00=32  01=64  10=128  11=256 |

> **Julia Set tip:** zoom into an interesting Mandelbrot boundary region (try zooming in 5–8 times near the cardioid boundary), then flip SW[2] to ON. The viewport centre becomes the Julia parameter *c*, revealing the Julia set for that complex number.

### Outputs

| Output | Meaning |
|--------|---------|
| LCD display | Live fractal rendering (Mandelbrot or Julia) |
| HEX1:HEX0 | Current zoom level (00 to 0C in hex) |
| HEX3:HEX2 | Completed frame count (00 to FF, wraps) |
| LEDR[0] | Lit while a frame is being rendered |
| LEDR[2:1] | Current palette selection (mirrors SW[1:0]) |
| LEDR[3] | Julia mode active (mirrors SW[2]) |
| LEDR[4] | Lit when rendering starts (row 0+) |
| LEDR[5] | Lit when rendering reaches row 53 (~16%) |
| LEDR[6] | Lit when rendering reaches row 106 (~33%) |
| LEDR[7] | Lit when rendering reaches row 160 (~50%) |
| LEDR[8] | Lit when rendering reaches row 213 (~66%) |
| LEDR[9] | Lit when rendering reaches row 266 (~83%) |

LEDR[4:9] form a 6-segment progress thermometer: they illuminate sequentially as the frame scan progresses top-to-bottom, giving real-time feedback on rendering speed at higher iteration depths.

---

## Colour Palettes

Four 16-entry RGB565 palettes are stored in FPGA block RAM and selected at runtime by SW[1:0]:

| SW[1:0] | Name | Description |
|---------|------|-------------|
| 00 | Blue-Gold | Classic Mandelbrot look: dark blue → cyan → gold → white |
| 01 | Fire | Black → dark red → orange → yellow → white |
| 10 | Ice | Black → navy → cyan → white (cool tones) |
| 11 | Electric | Black → purple → magenta → pink → white |

Points inside the fractal set always render as black regardless of palette.

---

## Iteration Depth

SW[9:8] selects the effective iteration limit at runtime:

| SW[9:8] | Iterations | Best for |
|---------|-----------|----------|
| 00 | 32 | Quick preview, low zoom levels |
| 01 | 64 | Default — good balance of speed and detail |
| 10 | 128 | Zoom levels 5–10 |
| 11 | 256 | Deep zoom quality, slower rendering |

At zoom level 0 (full view), 32 iterations is sufficient and renders fastest. Increase iterations when zoomed in to reveal finer boundary detail.

---

## Module Hierarchy

```
MandelbrotTop                      (top-level: DE1-SoC pin connections,
│                                   button debouncing, LED/7-seg wiring)
├── LT24Display                    (provided IP — LCD driver, T. Carpenter, UoL 2017)
├── MandelbrotCore                 (rendering FSM + computation engine)
│   ├── MandelbrotIterator         (one z→z²+c step, fully combinational)
│   │   └── FixedPointMult (×3)    (parameterised signed fixed-point multiplier)
│   └── ColourMapper               (iteration count → RGB565 colour, 4 palettes)
├── ZoomController                 (viewport manager: zoom/pan + Julia parameter output)
└── SevenSegDecoder (×2)           (parameterised hex to 7-segment decoder)
```

### Module Descriptions

**`FixedPointMult`** — Parameterised signed fixed-point multiplier. Computes `a × b` for Q_n.FRAC_BITS format by taking the full 2×DATA_WIDTH product and extracting the correctly scaled result bits. Maps to Cyclone V DSP blocks for single-cycle throughput.

**`MandelbrotIterator`** — Computes one step of the Mandelbrot / Julia iteration entirely combinationally: `z_r' = z_r² − z_i² + c_r`, `z_i' = 2·z_r·z_i + c_i`. Checks the escape condition `|z|² > 4` on the *input* z, giving a clean single-cycle decision. Uses three `FixedPointMult` instances.

**`ColourMapper`** — Maps an escape iteration count to an RGB565 colour via four 16-entry lookup palettes (Blue-Gold, Fire, Ice, Electric), selected by a 2-bit `palette_sel` input. A 2-bit `max_iter_sel` input adjusts the band-size calculation to match the runtime iteration limit, ensuring all 16 palette entries are used regardless of depth setting. All four palettes are stored in `initial` blocks and synthesise to FPGA block RAM. Points inside the set always map to black.

**`SevenSegDecoder`** — Parameterised N-digit hex decoder. Uses a `generate` loop to instantiate one decoder cell per digit. Outputs are active-low, matching the DE1-SoC hardware.

**`ZoomController`** — Viewport manager using rising-edge detection on all inputs. Manages the viewport registers (`x_offset`, `y_offset`, `x_scale`, `y_scale`) and zoom level. Zoom operations preserve the screen centre by adjusting the offset symmetrically. Combinationally computes and exposes the viewport centre as `julia_cr` / `julia_ci` — these directly become the Julia parameter *c* when SW[2] is set. Asserts `render_trigger` for one clock cycle whenever the viewport changes.

**`MandelbrotCore`** — Eight-state Moore FSM that drives the full raster scan. Supports both Mandelbrot mode (`z₀=0`, `c=pixel`) and Julia mode (`z₀=pixel`, `c=julia_cr/ci`), selected by the `julia_mode` input. Uses an *additive scan* strategy: `c_r` and `c_i` are accumulated by adding `x_scale` / `y_scale` each step, avoiding a multiply-per-pixel. The runtime `max_iter_sel` input sets the effective iteration limit (32/64/128/256). Drives the LT24Display pixel interface, updates `frame_count` on each completed frame, and exposes the current scan row as `render_row` for the progress-bar LEDs.

**`MandelbrotTop`** — Wires all submodules together and provides the DE1-SoC pin interface. A two-flip-flop synchroniser on KEY[1:2] safely crosses the asynchronous button domain. The `resetApp` output from `LT24Display` is used as the active-high synchronous reset for all application logic, ensuring the FPGA registers do not drive the LCD until it has been properly initialised.

---

## Fixed-Point Arithmetic

All fractal arithmetic uses **Q4.20 signed fixed-point** (24-bit total):

| Property | Value |
|----------|-------|
| Total bits | 24 |
| Integer bits (inc. sign) | 4 |
| Fractional bits | 20 |
| Representable range | −8.0 to +7.999999 |
| Precision (1 LSB) | ≈ 9.54 × 10⁻⁷ |
| Maximum useful zoom | ~13 levels before precision runs out |

The format was chosen because the Mandelbrot set fits within [−2.5, 1.0] × [−1.25, 1.25] — well within the ±8.0 range — and 20 fractional bits gives sufficient precision for 12 zoom levels (each halving the scale).

A multiplication `a × b` in Q4.20 produces a 48-bit intermediate result. The correctly scaled 24-bit output is extracted from bits [43:20] of the product:

```verilog
wire signed [47:0] product = a * b;         // full precision
assign result = product[43:20];              // extract Q4.20 result
```

This maps directly to Cyclone V's 18×18-bit DSP blocks (two blocks are chained for the 24×24 multiply).

---

## Initial Viewport

The initial view covers the full Mandelbrot set:

| Parameter | Value | Fixed-point raw |
|-----------|-------|----------------|
| x_offset (left edge) | −2.5 | −2,621,440 |
| y_offset (top edge) | −1.25 | −1,310,720 |
| x_scale (per column) | 3.5 / 240 ≈ 0.01458 | 15,300 |
| y_scale (per row) | 2.5 / 320 ≈ 0.00781 | 8,192 |

At the initial view, the viewport centre is approximately (−0.749, 0.0) — the initial Julia parameter when SW[2] is flipped. This point sits on the boundary of the Mandelbrot set and produces a classic connected Julia set.

Each zoom level halves `x_scale` and `y_scale`, doubling the magnification while keeping the viewport centre fixed.

---

## File Structure

```
MandelbrotFPGA/
├── MandelbrotFPGA.qpf          Quartus project file
├── MandelbrotFPGA.qsf          Pin assignments and source file list
├── MandelbrotFPGA.sdc          Timing constraints (50 MHz clock, false paths)
├── README.md                   This file
│
├── rtl/                        Synthesisable RTL source files
│   ├── MandelbrotTop.v         Top-level module (DE1-SoC pin interface)
│   ├── MandelbrotCore.v        Rendering FSM — Mandelbrot + Julia mode
│   ├── MandelbrotIterator.v    Single iteration step (combinational)
│   ├── FixedPointMult.v        Parameterised signed fixed-point multiplier
│   ├── ColourMapper.v          Iteration count → RGB565 (4 palettes, dynamic depth)
│   ├── ZoomController.v        Viewport manager + Julia parameter output
│   └── SevenSegDecoder.v       Parameterised hex to 7-segment display decoder
│
└── sim/                        Simulation testbenches
    ├── tb_FixedPointMult.v     12 self-checking tests for FixedPointMult
    ├── tb_MandelbrotIterator.v  8 self-checking tests for MandelbrotIterator
    ├── tb_ColourMapper.v       22 self-checking tests (4 palettes, depth selector)
    ├── tb_ZoomController.v     14 self-checking tests (zoom, pan, julia outputs)
    └── tb_MandelbrotCore.v     18 self-checking tests (Mandelbrot + Julia frames)
```

---

## Compilation (Quartus Prime)

### Requirements

- Intel Quartus Prime 22.1std or later (Lite edition is sufficient)
- DE1-SoC board with LT24 LCD module connected to GPIO-1

### Steps

1. Clone or copy the repository to your local machine.
2. Place the `ELEC5566M-Resources` folder at the same level as `MandelbrotFPGA/` (the QSF references `../ELEC5566M-Resources/...` for the LT24Display driver).
3. Open Quartus Prime.
4. **File → Open Project** → select `MandelbrotFPGA/MandelbrotFPGA.qpf`.
5. **Processing → Start Compilation** (Ctrl+L).
6. After compilation (~5–10 minutes), check the Messages panel:
   - The design fits with significant logic margin — Cyclone V 5CSEMA5F31C6 has 85K ALMs; this design uses less than 5%.
7. **Tools → Programmer** → connect DE1-SoC → select the generated `.sof` file from `output_files/` → click **Start**.

---

## Simulation (ModelSim / Questa)

Each testbench is self-checking: it prints `PASS` or `FAIL` for every test case and a final summary line. All five testbenches should report zero failures.

### First-time setup (create the `work` library)

```tcl
vlib work
vmap work work
```

### Running a testbench

From within ModelSim, change to the `sim/` directory:

```tcl
# FixedPointMult
vlog ../rtl/FixedPointMult.v tb_FixedPointMult.v
vsim tb_FixedPointMult
run -all

# MandelbrotIterator
vlog ../rtl/FixedPointMult.v ../rtl/MandelbrotIterator.v tb_MandelbrotIterator.v
vsim tb_MandelbrotIterator
run -all

# ColourMapper (4 palettes, dynamic depth)
vlog ../rtl/ColourMapper.v tb_ColourMapper.v
vsim tb_ColourMapper
run -all

# ZoomController (zoom, pan, julia outputs)
vlog ../rtl/ZoomController.v tb_ZoomController.v
vsim tb_ZoomController
run -all

# MandelbrotCore (4×4 pixel screen, Mandelbrot + Julia frames)
vlog ../rtl/FixedPointMult.v ../rtl/MandelbrotIterator.v \
     ../rtl/ColourMapper.v   ../rtl/MandelbrotCore.v \
     tb_MandelbrotCore.v
vsim tb_MandelbrotCore
run -all
```

### Expected results

All five testbenches print `** ALL TESTS PASSED **` on a clean run. The total simulation time for all five is under 2 minutes on a typical laptop.

---

## Design Decisions

### Why fixed-point instead of floating-point?

Floating-point units consume large amounts of FPGA logic and have long latency pipelines. For the Mandelbrot set, all coordinates lie within a bounded range (±8) and the required precision is known in advance (set by zoom depth). Q4.20 gives exactly the precision needed while mapping to DSP blocks efficiently.

### Why an additive scan for c_r / c_i?

A naive implementation would compute `c_r = x_offset + px * x_scale` for each pixel, requiring a multiplier in the scan loop. Instead, `c_r` is initialised to `x_offset` at the start of each row and incremented by `x_scale` for each column. This reduces the per-pixel computation to a single addition, freeing multiplier resources for the Mandelbrot iteration itself. The same registers serve double duty as the Julia z₀ initial values in Julia mode.

### Why does zooming keep the Julia parameter constant?

The Julia parameter `julia_cr / julia_ci` is always the viewport *centre*, computed combinationally as `x_offset + x_scale × (WIDTH/2)`. When zooming in, ZoomController shifts `x_offset` by exactly `x_scale × (WIDTH/4)` and halves `x_scale`, so the centre point in the complex plane is preserved. This means zooming into a Mandelbrot region and flipping to Julia mode always shows the Julia set for the exact point you were inspecting.

### Why is escaped checked on the input z, not the output?

The escape condition `|z|² > 4` is evaluated on the current z *before* computing the next step. This means the `iter` counter counts the number of completed iterations, and colour mapping is consistent regardless of pipeline depth. It also means the combinational path from z_r/z_i to the escaped flag is one level of logic shorter.

### Why Moore FSM throughout?

Moore FSMs (outputs depend only on current state, not inputs) produce glitch-free outputs on every clock edge. This is particularly important for the `pixelWrite` signal to LT24Display, which must be held stable while the LCD write cycle completes.

### How does the dynamic iteration depth work?

`max_iter_sel` is a 2-bit runtime input shared by both `MandelbrotCore` and `ColourMapper`. In `MandelbrotCore`, it sets `iter_limit` (32/64/128/256) — the COMPUTE state terminates when `iter == iter_limit − 1`. In `ColourMapper`, the same selector adjusts the bit-shift used to compute `palette_idx`, so the 16-colour palette always spans the full iteration range regardless of depth.

### LT24Display driver

The LCD driver (`LT24Display.v`) is a provided module by T. Carpenter, University of Leeds (2017). It is retrieved from the ELEC5566M module resources and used without modification. The `resetApp` output drives the active-high synchronous reset for all application logic, ensuring the FPGA registers do not drive the LCD until it has been properly initialised.

---

## References

1. T. Carpenter, *LT24Display Verilog Driver*, University of Leeds ELEC5566M Resources, 2017.
2. Terasic Technologies, *DE1-SoC User Manual*, Rev. F, 2014. Available at: https://www.terasic.com.tw
3. Intel Corporation, *Cyclone V Device Handbook*, 2018. Available at: https://www.intel.com/content/www/us/en/docs/programmable/683175
4. ILI Technology Corp., *ILI9341 TFT LCD Driver Datasheet*, V1.11, 2011.
5. Peitgen, H-O., Jürgens, H., Saupe, D., *Chaos and Fractals: New Frontiers of Science*, Springer, 2004. (Mandelbrot colouring algorithm reference.)

---

*Author: XXXX — ELEC5566M Mini-Project, University of Leeds, April 2026*
