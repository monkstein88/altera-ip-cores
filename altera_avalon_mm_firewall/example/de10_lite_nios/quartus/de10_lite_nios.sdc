# =============================================================================
# de10_lite_nios.sdc
#
# Timing constraints for the Nios II Avalon-MM Firewall example.
#
# The board's 50 MHz oscillator is the only real clock; everything in the
# system runs on the PLL's 100 MHz output, which derive_pll_clocks generates
# from it. That is the clock the firewall, the CPU and the interconnect are
# analysed against, and it is why REGISTER_LOOKUP is on in the system - the
# combinational rule lookup does not close at 100 MHz on this part.
# =============================================================================

create_clock -name {MAX10_CLK1_50} -period 20.000 [get_ports {MAX10_CLK1_50}]

derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# Asynchronous board I/O. KEY is a bare pin, synchronised in RTL; LEDR drives
# LEDs, which have no setup window to constrain against.
# ---------------------------------------------------------------------------
set_false_path -from [get_ports {KEY[*]}] -to [all_registers]
set_false_path -from [get_ports {SW[*]}]  -to [all_registers]
set_false_path -from * -to [get_ports {LEDR[*]}]
