# =============================================================================
# run_sim.tcl - Questa/ModelSim regression + coverage for the Avalon-MM Firewall
#
# Usage: open QuestaSim, cd into this directory, then:  do run_sim.tcl
#        or from a shell:  vsim -c -do run_sim.tcl
#
# Produces, all in this directory:
#   run.log              full transcript
#   coverage.ucdb        merged coverage database (both parameterisations)
#   coverage_report.txt  per-instance code coverage, PLUS the Assertion
#                        Coverage and Directive Coverage sections under the
#                        bound SVA instance
#
# The suite is elaborated TWICE, once per USE_WRITE_RESPONSE setting, and the
# two coverage databases are merged. Those are different designs on the write
# channel - different completion rule, different timeout scope, different
# response arbitration - and merging is what makes the assertion pass counts
# below cover both.
#
# READ THE PASS COUNT COLUMN, NOT JUST THE FAILURE COUNT. A property whose pass
# count is 0 and whose vacuous count is in the hundreds has never been
# evaluated; it is not evidence of anything. Two properties in this core's
# AXI4-Lite sibling sat in exactly that state through several releases.
# =============================================================================

transcript file run.log

if {[file exists work]} { file delete -force work }
vlib work
vmap work work

# avl_mm_firewall_pkg.sv MUST compile first - the other two import it.
vlog -sv +acc +cover=sbceft ../../rtl/avl_mm_firewall_pkg.sv
vlog -sv +acc +cover=sbceft ../../rtl/avl_mm_firewall_regs.sv
vlog -sv +acc +cover=sbceft ../../rtl/avl_mm_firewall_top.sv
vlog -sv +acc +cover=sbceft ../../tb/avl_mm_firewall_sva.sv
vlog -sv +acc +cover=sbceft ../../tb/avl_mm_firewall_tb.sv

proc run_one {wresp ucdb} {
    vopt avl_mm_firewall_tb -o tb_opt_$wresp +acc -cover sbceft -assertdebug \
        -G/avl_mm_firewall_tb/USE_WRITE_RESPONSE=$wresp
    vsim tb_opt_$wresp -coverage -assertdebug
    # The testbench ends with $finish, which by default terminates batch vsim
    # outright - taking `coverage save`, the second parameterisation, the merge
    # and the report with it, silently and with exit status 0. `onfinish stop`
    # is the control that prevents it; it is a command, not a variable, and it
    # is only accepted AFTER elaboration, so it belongs here rather than at the
    # top of the script.
    onfinish stop
    onbreak {resume}
    run -all
    coverage save $ucdb
    quit -sim
}

run_one 0 coverage_wresp0.ucdb
run_one 1 coverage_wresp1.ucdb

vcover merge coverage.ucdb coverage_wresp0.ucdb coverage_wresp1.ucdb

# ---------------------------------------------------------------------------
# Reports.
#
# `coverage report -details` includes Assertion Coverage and Directive
# Coverage sections alongside the code coverage, under the bound SVA instance.
#
# Do NOT try `puts $fh [assertion report ...]` to capture assertions
# separately: that command writes to the transcript and returns an empty
# string, so it produces a 1-byte file that looks exactly like the assertions
# never ran. If you want the report on its own, read run.log - `transcript
# file` is set at the top of this script for that reason.
#
# The old `-codeAll` switch selects code coverage only and silently omits both
# SVA sections. That is the one to avoid.
# ---------------------------------------------------------------------------
vcover report -details -output coverage_report.txt coverage.ucdb

# ---------------------------------------------------------------------------
# Pass/fail. $fatal in the testbench already makes a batch vsim exit non-zero;
# scan the transcript too so an interactive run reports clearly.
#
# Wrapped in procs so vsim's -do handling does not echo each command's return
# value into the transcript.
# ---------------------------------------------------------------------------
proc run_passed {} {
    if {![file exists run.log]} { return 0 }
    set fh [open run.log r]
    set txt [read $fh]
    close $fh
    # Both parameterisations must have printed the marker.
    set n 0
    set idx 0
    while {[set idx [string first "*** ALL TESTS PASSED ***" $txt $idx]] >= 0} {
        incr n
        incr idx
    }
    return [expr {$n >= 2}]
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
