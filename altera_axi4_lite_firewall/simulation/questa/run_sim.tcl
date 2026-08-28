# =============================================================================
# run_sim.tcl - Questa/ModelSim regression + coverage for the AXI4-Lite Firewall
#
# Usage: open QuestaSim, cd into this directory, then:  do run_sim.tcl
#        or from a shell:  vsim -c -do run_sim.tcl
#
# Produces, all in this directory:
#   run.log              full transcript
#   coverage.ucdb        coverage database
#   coverage_report.txt  per-instance code coverage, PLUS the Assertion
#                        Coverage and Directive Coverage sections under the
#                        bound SVA instance
#
# Read the assertion table's Pass Count column, not just Failure Count. A
# property whose pass count is 0 and whose vacuous count is in the hundreds
# has never been evaluated - it is not evidence of anything. Two of these
# were in exactly that state until v1.2; see the README.
# =============================================================================

# Capture everything to a file as well as the console.
transcript file run.log

# Create and map working library
if {[file exists work]} { file delete -force work }
vlib work
vmap work work

# Compile design, SVA, and testbench with full coverage tracking
vlog -sv +acc +cover=sbceft ../../rtl/axi4_lite_firewall_regs.sv
vlog -sv +acc +cover=sbceft ../../rtl/axi4_lite_firewall_top.sv
vlog -sv +acc +cover=sbceft ../../tb/axi4_lite_firewall_sva.sv
vlog -sv +acc +cover=sbceft ../../tb/axi4_lite_firewall_tb.sv

# Optimize with assertion visibility and code coverage
vopt axi4_lite_firewall_tb -o tb_opt +acc -cover sbceft -assertdebug

# Execute
vsim tb_opt -coverage -assertdebug
set NoQuitOnFinish 1
onbreak {resume}
run -all

# ---------------------------------------------------------------------------
# Reports.
#
# `coverage report -details` includes Assertion Coverage and Directive
# Coverage sections alongside the code coverage, under the bound SVA
# instance. Verified on Questa 2024.1: 12 assertions and 5 cover directives
# appear in coverage_report.txt.
#
# Do NOT try `puts $fh [assertion report ...]` to capture assertions
# separately: `assertion report` writes to the transcript and returns an
# empty string, so that produces a 1-byte file and looks like the assertions
# never ran. If you want the report on its own, use `transcript file` (set at
# the top of this script) and read run.log.
#
# The old `-codeAll` switch selects code coverage only and silently omits
# both SVA sections - that is what to avoid.
# ---------------------------------------------------------------------------
coverage save coverage.ucdb
coverage report -details -output coverage_report.txt

# ---------------------------------------------------------------------------
# Pass/fail. $fatal in the testbench already makes a batch vsim exit non-zero;
# scan the transcript too so an interactive run reports clearly.
#
# Wrapped in a proc so vsim's -do handling doesn't echo each command's return
# value into the transcript.
# ---------------------------------------------------------------------------
proc run_passed {} {
    if {![file exists run.log]} { return 0 }
    set fh [open run.log r]
    set txt [read $fh]
    close $fh
    return [expr {[string first "*** ALL TESTS PASSED ***" $txt] >= 0}]
}

proc report_result {} {
    if {[run_passed]} {
        puts "RESULT: PASSED - coverage.ucdb and coverage_report.txt written"
        puts "        (assertion + directive results are inside coverage_report.txt)"
    } else {
        puts "RESULT: FAILED - see run.log"
    }
    return
}
report_result

# Uncomment for batch use (returns a shell exit status):
# if {[run_passed]} { quit -code 0 } else { quit -code 1 }
