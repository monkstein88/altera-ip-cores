# =============================================================================
# run_sim.tcl - Questa/ModelSim regression + coverage for the AXI4-Lite Firewall
#
# Usage: open QuestaSim, cd into this directory, then:  do run_sim.tcl
#        or from a shell:  vsim -c -do run_sim.tcl
#
# Produces, all in this directory:
#   run.log              full transcript, including the assertion report
#   coverage.ucdb        coverage database
#   coverage_report.txt  code coverage, per instance
#   assert_report.txt    assertion pass/fail counts and cover-directive hits
#
# NOTE: `coverage report -details` emits CODE coverage only. It does not
# include assertion results or cover directives - that omission is why an
# earlier revision of this repo shipped a coverage_report.txt with no
# assertion section while the README quoted cover-directive hit counts. The
# assertion data comes from `assertion report`, written separately below.
# =============================================================================

# Capture everything to a file as well as the console.
transcript file run.log

# Create and map working library
if {[file exists work]} { file delete -force work }
vlib work
vmap work work

# Compile design, SVA, and testbench with full coverage tracking
vlog -sv +acc +cover=sbceft ../../rtl/axi_firewall_regs.sv
vlog -sv +acc +cover=sbceft ../../rtl/axi_firewall_top.sv
vlog -sv +acc +cover=sbceft ../../tb/axi_firewall_sva.sv
vlog -sv +acc +cover=sbceft ../../tb/axi_firewall_tb.sv

# Optimize with assertion visibility and code coverage
vopt axi_firewall_tb -o tb_opt +acc -cover sbceft -assertdebug

# Execute
vsim tb_opt -coverage -assertdebug
set NoQuitOnFinish 1
onbreak {resume}
run -all

# Assertion + cover-directive results.
# Redirected explicitly: `assertion report` prints to the transcript, so
# without this the numbers only ever live in run.log.
set fh [open assert_report.txt w]
puts $fh [assertion report -verbose -recursive]
close $fh
assertion report -verbose -recursive

# Code coverage
coverage save coverage.ucdb
coverage report -details -output coverage_report.txt

# ---------------------------------------------------------------------------
# Pass/fail. $fatal in the testbench already makes a batch vsim exit non-zero,
# but scan the transcript too so an interactive run reports clearly.
# ---------------------------------------------------------------------------
set passed 0
if {[file exists run.log]} {
    set fh [open run.log r]
    set txt [read $fh]
    close $fh
    if {[string first "*** ALL TESTS PASSED ***" $txt] >= 0} { set passed 1 }
}

if {$passed} {
    puts "RESULT: PASSED - coverage.ucdb, coverage_report.txt, assert_report.txt written"
} else {
    puts "RESULT: FAILED - see run.log"
}

# Uncomment for batch use (returns a shell exit status):
# if {$passed} { quit -code 0 } else { quit -code 1 }
