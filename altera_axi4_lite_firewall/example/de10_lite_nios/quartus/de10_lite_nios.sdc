# =============================================================================
# de10_lite_nios.sdc - timing constraints for the Nios II/f firewall example.
#
# The board supplies 50 MHz on MAX10_CLK1_50. Everything downstream runs at
# 100 MHz from an ALTPLL inside the Platform Designer system; the PLL output
# clock is created automatically by derive_pll_clocks, so it must not also be
# declared by hand here.
# =============================================================================

create_clock -name {MAX10_CLK1_50} -period 20.000 [get_ports {MAX10_CLK1_50}]

# Creates the PLL's 100 MHz output clock from the ALTPLL's own parameters.
derive_pll_clocks
derive_clock_uncertainty

# JTAG, for the Nios II debug module and the JTAG UART. Without these the
# analyser reports unconstrained paths through the JTAG chain on every build.
create_clock -name {altera_reserved_tck} -period 100.000 [get_ports {altera_reserved_tck}]
set_clock_groups -asynchronous -group {altera_reserved_tck}

# ---------------------------------------------------------------------------
# Asynchronous board I/O. KEY is a push button and LEDR drives LEDs; neither
# has a timing relationship worth constraining, and inventing one would only
# produce failing paths that mean nothing.
# ---------------------------------------------------------------------------
set_false_path -from [get_ports {KEY[*]}] -to [all_registers]
set_false_path -from [get_ports {SW[*]}]  -to [all_registers]
set_false_path -from * -to [get_ports {LEDR[*]}]
