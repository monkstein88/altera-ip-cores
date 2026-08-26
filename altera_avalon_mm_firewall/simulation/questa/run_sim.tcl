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

proc run_one {wresp reglk ucdb} {
    vopt avl_mm_firewall_tb -o tb_opt_${wresp}_${reglk} +acc -cover sbceft -assertdebug \
        -G/avl_mm_firewall_tb/USE_WRITE_RESPONSE=$wresp \
        -G/avl_mm_firewall_tb/REGISTER_LOOKUP=$reglk
    vsim tb_opt_${wresp}_${reglk} -coverage -assertdebug
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

# Four parameterisations, not two. REGISTER_LOOKUP changes the handshake
# timing of every command - a stall cycle that does not exist in the
# combinational build - so running only one of them leaves the entire stall
# path, and the two properties that had to be restated for it, unexercised.
run_one 0 0 coverage_w0_lk0.ucdb
run_one 1 0 coverage_w1_lk0.ucdb
run_one 0 1 coverage_w0_lk1.ucdb
run_one 1 1 coverage_w1_lk1.ucdb

vcover merge coverage.ucdb coverage_w0_lk0.ucdb coverage_w1_lk0.ucdb \
                           coverage_w0_lk1.ucdb coverage_w1_lk1.ucdb

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
    # All four parameterisations must have printed the marker.
    set n 0
    set idx 0
    while {[set idx [string first "*** ALL TESTS PASSED ***" $txt $idx]] >= 0} {
        incr n
        incr idx
    }
    if {$n < 4} { return 0 }

    # ...and no assertion may have fired.
    #
    # This is not belt and braces. The testbench counts its OWN checks; an SVA
    # failure prints "** Error: Assertion error." and does not touch that
    # count, so a run can report "163 passed, 0 failed" with properties failing
    # underneath it. That happened while REGISTER_LOOKUP was being brought up -
    # seven assertion failures behind a clean pass line - and this check is why
    # it cannot happen quietly again.
    if {[string first "Assertion error" $txt] >= 0} { return 0 }

    return 1
}

proc report_result {} {
    if {[run_passed]} {
        puts "RESULT: PASSED - all four parameterisations, no assertion failures"
        puts "        coverage.ucdb and coverage_report.txt written"
        puts "        (assertion + directive results are inside coverage_report.txt)"
    } else {
        puts "RESULT: FAILED - see run.log (check for 'Assertion error' too)"
    }
    return
}
report_result

# Uncomment for batch use (returns a shell exit status):
# if {[run_passed]} { quit -code 0 } else { quit -code 1 }
