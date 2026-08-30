# =============================================================================
# run_sim.tcl - Questa/ModelSim regression for avalon_mm_sdram_controller.
#
#   vsim -c -do run_sim.tcl
#
# WHAT THIS ADDS OVER THE VERILATOR FLOW
# --------------------------------------
# simulation/verilator/run_sim.sh runs the same testbench across the same
# parameter sweep and needs no licence, so it is the flow to reach for first.
# Two things only Questa provides:
#
#   COVERAGE          statement, branch, condition, expression, FSM and toggle,
#                     merged across the sweep. The controller's scheduler is a
#                     priority chain, and the branches that never execute are
#                     exactly the ones worth knowing about.
#   NON-VACUITY       how many times each assertion passed for a real reason
#                     rather than because its antecedent never held. An
#                     assertion that only ever passes vacuously has verified
#                     nothing while reporting green, and no other flow here can
#                     tell you which ones those are.
#
# NOT VERIFIED IN THIS REPOSITORY'S DEVELOPMENT ENVIRONMENT. There is no Questa
# licence available here, so unlike the two firewall cores - whose Questa
# artefacts are committed and whose numbers are quoted from real runs - this
# file has been written to the same pattern but never executed. Treat it as a
# starting point rather than a known-good flow, and expect to adjust paths or
# switches for your installation.
# =============================================================================

transcript file run.log

if {[file exists work]} { file delete -force work }
vlib work
vmap work work

# +acc keeps the hierarchy visible for coverage and for the assertion debugger;
# +cover=sbceft is statement, branch, condition, expression, FSM, toggle.
vlog -sv +acc +cover=sbceft ../../rtl/avalon_mm_sdram_controller.sv
vlog -sv +acc +cover=sbceft ../../tb/sdram_device_model.sv
vlog -sv +acc +cover=sbceft ../../tb/sdram_timing_check.sv
vlog -sv +acc +cover=sbceft ../../tb/avalon_mm_sdram_controller_sva.sv
vlog -sv +acc +cover=sbceft ../../tb/avalon_mm_sdram_controller_tb.sv

# The same sweep the Verilator flow runs. CAS latency changes the read pipeline
# and the read-to-write turnaround, LOOKAHEAD is a whole scheduling path,
# FIFO_DEPTH changes the backpressure path, and ADDR_MAP puts every access in a
# different bank so the command-count expectations are re-checked against a
# different geometry.
proc run_one {cas look depth map ucdb} {
    set tag ${cas}_${look}_${depth}_${map}
    vopt avalon_mm_sdram_controller_tb -o tb_opt_$tag +acc -cover sbceft -assertdebug \
        -G/avalon_mm_sdram_controller_tb/CAS_LAT=$cas \
        -G/avalon_mm_sdram_controller_tb/LOOKAHEAD=$look \
        -G/avalon_mm_sdram_controller_tb/FIFO_DEPTH=$depth \
        -G/avalon_mm_sdram_controller_tb/ADDR_MAP=$map
    vsim tb_opt_$tag -coverage -assertdebug
    onfinish stop
    onbreak {resume}
    run -all
    # Non-vacuous pass counts, which is the number that matters.
    write report -assertions -append assert_report.txt
    coverage save $ucdb
    quit -sim
}

if {[file exists assert_report.txt]} { file delete -force assert_report.txt }

run_one 3 1 8  0 cov_c3_l1_d8_m0.ucdb
run_one 2 1 8  0 cov_c2_l1_d8_m0.ucdb
run_one 3 0 8  0 cov_c3_l0_d8_m0.ucdb
run_one 3 1 2  0 cov_c3_l1_d2_m0.ucdb
run_one 3 1 8  1 cov_c3_l1_d8_m1.ucdb

vcover merge coverage.ucdb \
    cov_c3_l1_d8_m0.ucdb cov_c2_l1_d8_m0.ucdb cov_c3_l0_d8_m0.ucdb \
    cov_c3_l1_d2_m0.ucdb cov_c3_l1_d8_m1.ucdb
vcover report -details -output coverage_report.txt coverage.ucdb

# ---- pass/fail, decided from the transcript rather than from exit codes -----
# A simulator that ran five configurations and printed four "all tests passed"
# has failed one of them, and will still exit 0.
proc run_passed {} {
    if {![file exists run.log]} { return 0 }
    set fh [open run.log r]
    set txt [read $fh]
    close $fh
    set n 0
    set idx 0
    while {[set idx [string first "all tests passed" $txt $idx]] >= 0} {
        incr n
        incr idx
    }
    if {$n < 5} { return 0 }
    if {[string first "Assertion error" $txt] >= 0}   { return 0 }
    if {[string first "TIMING VIOLATION" $txt] >= 0}  { return 0 }
    if {[string first "MODEL ERROR" $txt] >= 0}       { return 0 }
    return 1
}

if {[run_passed]} {
    puts "RESULT: PASSED - all five configurations, no assertion failures,"
    puts "                 no timing violations, no illegal device accesses"
} else {
    puts "RESULT: FAILED - see run.log"
}

quit -f
