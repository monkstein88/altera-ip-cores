# =============================================================================
# run_sim.tcl - Questa/ModelSim regression for the DE10-Lite firewall demo
#
# Usage: cd into this directory, then:  do run_sim.tcl
#        or from a shell:  vsim -c -do run_sim.tcl
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

set CORE ../../../../rtl
set DEMO ../../rtl
set COMMON ../../../common
set TB   ../../tb

# +define+DEMO_TRACE makes every failing check print its program counter,
# what was observed and what was expected. On the board a failure is one
# letter; here it should say why.
vlog -sv -quiet +define+DEMO_TRACE $CORE/axi_firewall_regs.sv
vlog -sv -quiet +define+DEMO_TRACE $CORE/axi_firewall_top.sv
vlog -sv -quiet +define+DEMO_TRACE $DEMO/demo_axi_lite_master.sv
vlog -sv -quiet +define+DEMO_TRACE $COMMON/demo_target_slave.sv
vlog -sv -quiet +define+DEMO_TRACE $DEMO/demo_sequencer.sv
vlog -sv -quiet +define+DEMO_TRACE $DEMO/hex7seg.sv
vlog -sv -quiet +define+DEMO_TRACE $DEMO/key_debounce.sv
vlog -sv -quiet +define+DEMO_TRACE $DEMO/de10_lite_firewall_demo.sv
vlog -sv -quiet +define+DEMO_TRACE $TB/de10_lite_firewall_demo_tb.sv

vsim -c de10_lite_firewall_demo_tb
set NoQuitOnFinish 1
onbreak {resume}

run -all

quit -f
