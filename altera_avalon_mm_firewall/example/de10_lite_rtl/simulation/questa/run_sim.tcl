# =============================================================================
# run_sim.tcl - Questa/ModelSim regression for the DE10-Lite firewall demo
#
# Usage: cd into this directory, then:  do run_sim.tcl
#        or from a shell:  vsim -c -do "do run_sim.tcl; quit -f"
#
# This runs the BOARD-LEVEL testbench: it drives the DE10-Lite's pins and
# reads its LEDs and seven-segment displays. Passing here means the hardware
# demo behaves as documented, including all sixteen firewall scenarios.
#
# Produces run.log in this directory.
#
# For coverage of the IP core itself, use ../../../../simulation/questa/run_sim.tcl
# instead - that is the core's own suite, with the SVA bind and coverage
# collection. This one exercises the core through the demo, which is a
# different and complementary thing: it is the only place the core is driven
# by synthesisable hardware rather than by testbench tasks.
# =============================================================================

transcript file run.log

if {[file exists work]} { file delete -force work }
vlib work
vmap work work

set CORE   ../../../../rtl
set DEMO   ../../rtl
set COMMON ../../../common
set TB     ../../tb

# +define+DEMO_TRACE makes every failing check print its program counter,
# what was observed and what was expected. On the board a failure is one
# letter; here it should say why.
#
# avl_mm_firewall_pkg.sv MUST compile first - the other two import it.
vlog -sv -quiet +define+DEMO_TRACE $CORE/avl_mm_firewall_pkg.sv
vlog -sv -quiet +define+DEMO_TRACE $CORE/avl_mm_firewall_regs.sv
vlog -sv -quiet +define+DEMO_TRACE $CORE/avl_mm_firewall_top.sv
# The core's own assertions, bound into the demo's firewall instance by the
# testbench. Compile with +define+DEMO_NO_SVA to leave them out.
vlog -sv -quiet +define+DEMO_TRACE ../../../../tb/avl_mm_firewall_sva.sv
vlog -sv -quiet +define+DEMO_TRACE $COMMON/demo_target_slave.sv
vlog -sv -quiet +define+DEMO_TRACE $DEMO/demo_avl_mm_master.sv
vlog -sv -quiet +define+DEMO_TRACE $DEMO/demo_sequencer.sv
vlog -sv -quiet +define+DEMO_TRACE $DEMO/hex7seg.sv
vlog -sv -quiet +define+DEMO_TRACE $DEMO/key_debounce.sv
vlog -sv -quiet +define+DEMO_TRACE $DEMO/de10_lite_avl_mm_firewall_demo.sv
vlog -sv -quiet +define+DEMO_TRACE $TB/de10_lite_avl_mm_firewall_demo_tb.sv

vsim -c de10_lite_avl_mm_firewall_demo_tb

# The testbench ends with $finish, which by default terminates batch vsim
# outright. `onfinish stop` is the control that prevents it, and it is only
# accepted AFTER elaboration - so it belongs here, not at the top.
onfinish stop
onbreak {resume}

run -all
