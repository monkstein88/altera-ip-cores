# =============================================================================
# de10_lite_avl_mm_sdram_demo.sdc
#
# Timing constraints for the Avalon-MM SDRAM Controller demo on the DE10-Lite.
#
# Unlike the firewall demos in this repository, this design is NOT purely
# internal: sixteen data lines, thirteen address lines and six command lines
# leave the FPGA, cross a board trace and have to meet a real device's setup
# and hold windows. Those paths are the whole point of the -3 ns shifted
# DRAM_CLK, and they are constrained here.
#
# The board delay figures below come from Terasic's own DE10-Lite SDRAM
# demonstration SDC on the System CD v2.2.0, and describe THIS board's
# layout together with the ISSI IS42S16320D's timing. They are not generic.
# =============================================================================

# ---------------------------------------------------------------------------
# Clocks
# ---------------------------------------------------------------------------
create_clock -name {MAX10_CLK1_50} -period 20.000 [get_ports {MAX10_CLK1_50}]

# Both PLL outputs. derive_pll_clocks names them after the PLL's own pins, so
# everything downstream of the PLL is constrained without naming frequencies
# twice.
derive_pll_clocks

# DRAM_CLK is not a normal output. It is a CLOCK leaving the device, and the
# SDRAM's setup and hold windows are measured against it - so it has to exist
# as a clock in the timing model, sourced from the PLL output that drives it.
# clk[1] is the -3000 ps output; see rtl/sdram_pll.sv.
create_generated_clock \
    -source [get_pins {u_pll|altpll_component|auto_generated|pll1|clk[1]}] \
    -name clk_dram_ext [get_ports {DRAM_CLK}]

derive_clock_uncertainty

# ---------------------------------------------------------------------------
# SDRAM input delays - the chip driving read data back at us.
#
#   max = t_AC(max) + trace delay + clock skew  = 5.4 + 0.4 + 0.1 = 5.9 ns
#   min = t_OH(min) + trace delay - clock skew  = 2.7 + 0.4 - 0.1 = 3.0 ns
#
# t_AC 5.4 ns is the same access time given to the controller as its TAC
# parameter in qsys/build_system.tcl - the two have to agree.
# ---------------------------------------------------------------------------
set_input_delay -max -clock clk_dram_ext 5.9 [get_ports DRAM_DQ*]
set_input_delay -min -clock clk_dram_ext 3.0 [get_ports DRAM_DQ*]

# The shifted clock means read data launched by the SDRAM has more than one
# system clock period to arrive, so the setup analysis is relaxed by one
# cycle. Without this the -3 ns shift reads as a timing violation instead of
# as the fix it is.
set_multicycle_path -setup 2 \
    -from [get_clocks {clk_dram_ext}] \
    -to   [get_clocks {u_pll|altpll_component|auto_generated|pll1|clk[0]}]

# ---------------------------------------------------------------------------
# SDRAM output delays - us driving command, address and write data at the chip.
#
#   max = board delay + t_SU(external) + skew = 1.5 + 0.1 = 1.6 ns
#   min = board delay - t_H(external)  - skew = -0.8 - 0.1 = -0.9 ns
# ---------------------------------------------------------------------------
set_output_delay -max -clock clk_dram_ext  1.6 [get_ports {DRAM_DQ* DRAM_*DQM}]
set_output_delay -min -clock clk_dram_ext -0.9 [get_ports {DRAM_DQ* DRAM_*DQM}]
set_output_delay -max -clock clk_dram_ext  1.6 \
    [get_ports {DRAM_ADDR* DRAM_BA* DRAM_RAS_N DRAM_CAS_N DRAM_WE_N DRAM_CKE DRAM_CS_N}]
set_output_delay -min -clock clk_dram_ext -0.9 \
    [get_ports {DRAM_ADDR* DRAM_BA* DRAM_RAS_N DRAM_CAS_N DRAM_WE_N DRAM_CKE DRAM_CS_N}]

# ---------------------------------------------------------------------------
# Asynchronous board I/O.
#
# KEY and SW are asynchronous to everything; each goes through a two-flop
# synchroniser (KEY[0] additionally through key_debounce) before any logic
# uses it, so the input paths carry no real timing requirement.
#
# LEDR and HEX drive LEDs. There is no receiver with a setup window, so an
# output delay on them would be inventing a constraint to satisfy.
# ---------------------------------------------------------------------------
set_false_path -from [get_ports {KEY[*]}] -to [all_registers]
set_false_path -from [get_ports {SW[*]}]  -to [all_registers]
set_false_path -from * -to [get_ports {LEDR[*]}]
set_false_path -from * -to [get_ports {HEX0[*]}]
set_false_path -from * -to [get_ports {HEX1[*]}]
set_false_path -from * -to [get_ports {HEX2[*]}]
set_false_path -from * -to [get_ports {HEX3[*]}]
set_false_path -from * -to [get_ports {HEX4[*]}]
set_false_path -from * -to [get_ports {HEX5[*]}]
