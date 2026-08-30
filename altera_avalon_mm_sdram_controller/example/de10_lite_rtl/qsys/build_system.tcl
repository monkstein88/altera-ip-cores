# =============================================================================
# build_system.tcl - Platform Designer system for the SDRAM controller example.
#
#   ../build.sh qsys
#
# The system is deliberately small: a PLL and the SDRAM controller, nothing
# else. There is no CPU. The Avalon-MM slave `s1` is exported to the top level
# so that plain RTL can drive it, which is what sdram_test_seq.sv does.
#
# ---------------------------------------------------------------------------
# WHERE THESE SETTINGS COME FROM
# ---------------------------------------------------------------------------
# Every geometry and timing value below is taken from Terasic's own
# DE10-Lite SDRAM_Nios_Test design on the board's System CD, which drives the
# same chip with the same Intel controller. They are not derived, guessed or
# copied from a datasheet by hand.
#
# The board carries an ISSI IS42S16320D: 64 MB, organised 32M x 16.
#     4 banks x 8192 rows x 1024 columns x 16 bits = 512 Mbit = 64 MB
#
# ---------------------------------------------------------------------------
# THE PLL IS AT THE TOP LEVEL, NOT IN HERE
# ---------------------------------------------------------------------------
# The SDRAM needs two clocks: the controller runs on 100 MHz at 0 degrees, and
# the chip itself is clocked by the same 100 MHz shifted -3 ns. That shift
# compensates for the round trip through the FPGA's output register, the board
# trace and the chip's input setup; without it the SDRAM samples the
# controller's outputs at the wrong moment and reads come back as garbage that
# looks like a bad memory. -3000 ps is Terasic's value for this board.
#
# ALTPLL's second output cannot be enabled from a Qsys script: writing
# PORT_clk1 = PORT_USED is silently reverted by the megafunction's own
# validation (it reads back PORT_UNUSED), so `c1` never appears as an
# interface to export. Terasic's own RTL demo hits the same wall and puts the
# PLL in the top level instead, which is what rtl/sdram_pll.sv does. This
# system therefore takes a ready-made 100 MHz clock.
# =============================================================================

package require -exact qsys 14.0

create_system sdram_perbank_sys
set_project_property DEVICE_FAMILY {MAX 10}
set_project_property DEVICE {10M50DAF484C7G}
set_project_property HIDE_FROM_IP_CATALOG {false}

# ---------------------------------------------------------------------------
# Clock and reset in
# ---------------------------------------------------------------------------
# 100 MHz, supplied from the top level. The PLL lives OUTSIDE this system -
# see the note above - so what arrives here is already the system clock.
add_instance clk clock_source
set_instance_parameter_value clk {clockFrequency} {100000000.0}
set_instance_parameter_value clk {resetSynchronousEdges} {DEASSERT}

# ---------------------------------------------------------------------------
# The IP under demonstration.
# ---------------------------------------------------------------------------
# The component under demonstration. Its geometry and timing come from the
# preset rather than from eighteen hand-typed parameter values - which is the
# point of shipping a preset, and the only way the numbers in a design and the
# numbers in a datasheet stay the same numbers.
add_instance sdram altera_avalon_mm_sdram_controller
apply_preset sdram "ISSI IS42S16320D-7 - DE10-Lite 64 MByte"

# The clock is NOT a parameter of this component: it is taken from the clock
# source connected below, so the controller cannot be configured for one
# frequency and clocked at another.

add_connection clk.clk       sdram.clk
add_connection clk.clk_reset sdram.reset

# ---------------------------------------------------------------------------
# Exports.
#
# `s1` is exported rather than connected: there is no master in this system.
# The test sequencer at the top level is the master, which keeps the whole
# demo synthesisable RTL with no CPU and no software - the same shape as the
# firewalls' de10_lite_rtl examples.
# ---------------------------------------------------------------------------
set_interface_property clk_in     EXPORT_OF clk.clk_in
set_interface_property reset_in   EXPORT_OF clk.clk_in_reset
set_interface_property sdram_s1   EXPORT_OF sdram.s1
set_interface_property sdram_wire EXPORT_OF sdram.wire

save_system sdram_perbank_sys.qsys
puts "=== system saved ==="
