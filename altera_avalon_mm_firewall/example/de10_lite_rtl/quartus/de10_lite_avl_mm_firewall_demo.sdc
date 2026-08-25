# =============================================================================
# de10_lite_avl_mm_firewall_demo.sdc
#
# Timing constraints for the Avalon-MM Firewall demo on the DE10-Lite.
#
# The design is single-clock and fully synchronous: everything runs on the
# board's 50 MHz oscillator. The only things crossing into it are the switches
# and push buttons, which are resynchronised in RTL and cut here so the timing
# analyser does not try to close a path from a human finger.
# =============================================================================

create_clock -name {MAX10_CLK1_50} -period 20.000 [get_ports {MAX10_CLK1_50}]

derive_clock_uncertainty

# ---------------------------------------------------------------------------
# Asynchronous board I/O.
#
# KEY and SW are asynchronous to everything; each goes through a two-flop
# synchroniser (KEY0 additionally through key_debounce) before any logic uses
# it, so the input paths carry no real timing requirement.
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
