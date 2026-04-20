# ------------------------------------------------------------------------------
# Timing Constraints — MandelbrotFPGA
# Author:  Ashok GC
# Device:  Intel Cyclone V (5CSEMA5F31C6) — DE1-SoC
# Clock:   50 MHz on PIN_AF14 (CLOCK_50)
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Primary clock: 50 MHz system clock
# ------------------------------------------------------------------------------
create_clock -name {CLOCK_50} -period 20.000 -waveform {0.000 10.000} [get_ports {CLOCK_50}]

# ------------------------------------------------------------------------------
# Generated clocks: none (no PLL used in this design)
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Clock uncertainty (account for jitter on DE1-SoC oscillator)
# ------------------------------------------------------------------------------
set_clock_uncertainty -rise_from [get_clocks {CLOCK_50}] \
                      -rise_to   [get_clocks {CLOCK_50}] 0.020
set_clock_uncertainty -fall_from [get_clocks {CLOCK_50}] \
                      -fall_to   [get_clocks {CLOCK_50}] 0.020

# ------------------------------------------------------------------------------
# Input/output delay constraints for the LT24 LCD interface
# The LT24 is a synchronous write bus driven from CLOCK_50.
# Conservative setup/hold: 3 ns setup, 1 ns hold (based on ILI9341 datasheet
# minimum write cycle 66 ns — LT24Display.v handles write-enable timing).
# ------------------------------------------------------------------------------
set_input_delay  -clock {CLOCK_50} -max 3.0 [get_ports {LT24Data[*]}]
set_input_delay  -clock {CLOCK_50} -min 1.0 [get_ports {LT24Data[*]}]

set_output_delay -clock {CLOCK_50} -max 3.0 [get_ports {LT24Data[*]}]
set_output_delay -clock {CLOCK_50} -min 1.0 [get_ports {LT24Data[*]}]

set_output_delay -clock {CLOCK_50} -max 3.0 [get_ports {LT24Wr_n}]
set_output_delay -clock {CLOCK_50} -min 1.0 [get_ports {LT24Wr_n}]
set_output_delay -clock {CLOCK_50} -max 3.0 [get_ports {LT24Rd_n}]
set_output_delay -clock {CLOCK_50} -min 1.0 [get_ports {LT24Rd_n}]
set_output_delay -clock {CLOCK_50} -max 3.0 [get_ports {LT24CS_n}]
set_output_delay -clock {CLOCK_50} -min 1.0 [get_ports {LT24CS_n}]
set_output_delay -clock {CLOCK_50} -max 3.0 [get_ports {LT24RS}]
set_output_delay -clock {CLOCK_50} -min 1.0 [get_ports {LT24RS}]
set_output_delay -clock {CLOCK_50} -max 3.0 [get_ports {LT24Reset_n}]
set_output_delay -clock {CLOCK_50} -min 1.0 [get_ports {LT24Reset_n}]
set_output_delay -clock {CLOCK_50} -max 3.0 [get_ports {LT24LCDOn}]
set_output_delay -clock {CLOCK_50} -min 1.0 [get_ports {LT24LCDOn}]

# ------------------------------------------------------------------------------
# False paths: asynchronous inputs (pushbuttons and switches)
# KEY and SW are registered through a 2-FF synchroniser inside MandelbrotTop,
# so there is no meaningful setup/hold relationship from the board pins.
# ------------------------------------------------------------------------------
set_false_path -from [get_ports {KEY[*]}]
set_false_path -from [get_ports {SW[*]}]

# ------------------------------------------------------------------------------
# False paths: output-only ports (LEDs, 7-segment displays)
# These are display outputs — tight timing at the board pin is not required.
# ------------------------------------------------------------------------------
set_false_path -to [get_ports {LEDR[*]}]
set_false_path -to [get_ports {HEX0[*]}]
set_false_path -to [get_ports {HEX1[*]}]
set_false_path -to [get_ports {HEX2[*]}]
set_false_path -to [get_ports {HEX3[*]}]
set_false_path -to [get_ports {HEX4[*]}]
set_false_path -to [get_ports {HEX5[*]}]

# ------------------------------------------------------------------------------
# End of constraints
# ------------------------------------------------------------------------------
