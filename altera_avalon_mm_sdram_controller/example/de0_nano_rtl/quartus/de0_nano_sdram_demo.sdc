# =============================================================================
# de0_nano_sdram_demo.sdc
#
# Timing constraints for the Avalon-MM SDRAM Controller demo on the DE0-Nano.
#
# WHERE THESE NUMBERS COME FROM, AND WHICH ONE IS AN ASSUMPTION
# -------------------------------------------------------------
# Unlike the DE10-Lite, Terasic's DE0-Nano demonstrations DO NOT constrain the
# SDRAM interface at all: their DE0_Nano.sdc creates CLOCK_50, calls
# derive_pll_clocks and derive_clock_uncertainty, and stops. There is no
# generated clock on DRAM_CLK and no I/O delay on any DRAM pin, so their
# SDRAM paths are simply unanalysed. There was nothing to copy.
#
# So the device half is derived from the ISSI IS42S16160B datasheet on the
# board's own System CD, at CAS 3 and the -7 speed grade:
#
#     tAC3 (max)  5.4 ns     access time from CLK
#     tOH3 (min)  2.7 ns     output data hold
#     tDS         1.5 ns     input setup at the chip
#     tDH         0.8 ns     input hold at the chip
#
# Those four are identical to the DE10-Lite's IS42S16320D-7, which is why the
# figures below come out the same as that board's - not because they were
# copied across.
#
# THE BOARD HALF IS NOT MEASURED. The 0.4 ns trace delay and 0.1 ns skew are
# carried over from the DE10-Lite constraints, because no DE0-Nano equivalent
# exists to take them from. They are plausible for a board this small, and the
# SDRAM sits beside the FPGA, but they are an assumption and not a datasheet
# figure. Before trusting timing closure on real hardware, confirm them
# against the board layout - and note that the PLL phase shift below is the
# first thing to re-derive if reads come back corrupted.
# =============================================================================

# ---------------------------------------------------------------------------
# Clocks
# ---------------------------------------------------------------------------
create_clock -name {CLOCK_50} -period 20.000 [get_ports {CLOCK_50}]

derive_pll_clocks

# DRAM_CLK is a CLOCK leaving the device, not an ordinary output: the SDRAM's
# setup and hold windows are measured against it, so it has to exist as a
# clock in the timing model. clk[1] is the -1667 ps output; see rtl/sdram_pll.sv.
create_generated_clock \
    -source [get_pins {u_pll|altpll_component|auto_generated|pll1|clk[1]}] \
    -name clk_dram_ext [get_ports {DRAM_CLK}]

derive_clock_uncertainty

# ---------------------------------------------------------------------------
# SDRAM input delays - the chip driving read data back at us.
#
#   max = tAC3(max) + trace delay + clock skew  = 5.4 + 0.4 + 0.1 = 5.9 ns
#   min = tOH3(min) + trace delay - clock skew  = 2.7 + 0.4 - 0.1 = 3.0 ns
# ---------------------------------------------------------------------------
set_input_delay -max -clock clk_dram_ext 5.9 [get_ports DRAM_DQ*]
set_input_delay -min -clock clk_dram_ext 3.0 [get_ports DRAM_DQ*]

# The shifted clock means read data launched by the SDRAM has more than one
# system clock period to arrive, so the setup analysis is relaxed by one
# cycle. Without this the phase shift reads as a timing violation instead of
# as the fix it is.
set_multicycle_path -setup 2 \
    -from [get_clocks {clk_dram_ext}] \
    -to   [get_clocks {u_pll|altpll_component|auto_generated|pll1|clk[0]}]

# ---------------------------------------------------------------------------
# SDRAM output delays - us driving command, address and write data at the chip.
#
#   max = board delay + tDS + skew =  1.5 + 0.1 =  1.6 ns
#   min = board delay - tDH - skew = -0.8 - 0.1 = -0.9 ns
# ---------------------------------------------------------------------------
set_output_delay -max -clock clk_dram_ext  1.6 [get_ports {DRAM_DQ* DRAM_DQM*}]
set_output_delay -min -clock clk_dram_ext -0.9 [get_ports {DRAM_DQ* DRAM_DQM*}]
set_output_delay -max -clock clk_dram_ext  1.6 \
    [get_ports {DRAM_ADDR* DRAM_BA* DRAM_RAS_N DRAM_CAS_N DRAM_WE_N DRAM_CKE DRAM_CS_N}]
set_output_delay -min -clock clk_dram_ext -0.9 \
    [get_ports {DRAM_ADDR* DRAM_BA* DRAM_RAS_N DRAM_CAS_N DRAM_WE_N DRAM_CKE DRAM_CS_N}]

# ---------------------------------------------------------------------------
# Asynchronous board I/O.
#
# KEY and SW are asynchronous to everything; each goes through a two-flop
# synchroniser (KEY[0] additionally through key_debounce) before any logic
# uses it. LED drives an LED - there is no receiver with a setup window.
# ---------------------------------------------------------------------------
set_false_path -from [get_ports {KEY[*]}] -to [all_registers]
set_false_path -from [get_ports {SW[*]}]  -to [all_registers]
set_false_path -from * -to [get_ports {LED[*]}]
