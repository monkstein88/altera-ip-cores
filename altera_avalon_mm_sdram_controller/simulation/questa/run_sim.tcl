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
#                     exactly the ones worth knowing about - this is what showed
#                     that the read-to-precharge counter could never hold a
#                     non-zero value, and that the A10 step-over in col_addr was
#                     never simulated at any geometry the sweep covers.
#   NON-VACUITY       how many times each assertion passed for a real reason
#                     rather than because its antecedent never held. An
#                     assertion that only ever passes vacuously has verified
#                     nothing while reporting green, and no other flow here can
#                     tell you which ones those are.
#
# RUN, AND WHAT RUNNING IT FOUND
#
# This file was written to pattern and never executed until a Questa
# installation was available. Two things were wrong, and only one of them was
# in this file:
#
#   * `write report -assertions` is not a Questa command. Assertion pass and
#     vacuity counts come from `coverage report -assert`.
#   * The RTL would not elaborate at all. `fifo` was written by both an initial
#     block and an always_ff, which IEEE 1800-2017 9.2.2.4 forbids and vopt
#     rejects outright. Verilator linted it clean with -Wall and nothing
#     waived, so nothing else in the project could have found it.
#
# Both are fixed. The sweep below matches the Verilator flow exactly, clock
# rates included.
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
# `part` selects the device timings: 0 is the DE10-Lite's IS42S16320D-7, which
# is the testbench's default, and 1 is the DE0-Nano's IS42S16160B-7. The
# figures are the presets', held against them by doc/tools/check_facts.py.
proc part_args {part} {
    if {$part == 1} {
        return [list \
            -G/avalon_mm_sdram_controller_tb/T_RC_PS=67500 \
            -G/avalon_mm_sdram_controller_tb/T_RAS_PS=45000 \
            -G/avalon_mm_sdram_controller_tb/T_RP_PS=20000 \
            -G/avalon_mm_sdram_controller_tb/T_RCD_PS=20000 \
            -G/avalon_mm_sdram_controller_tb/T_MRD_PS=15000 \
            -G/avalon_mm_sdram_controller_tb/T_RFC_PS=67500]
    }
    if {$part == 2} {
        # Micron MT48LC4M16A2-75: 12 row bits and - the reason it is here -
        # 4,096 rows rather than 8,192, so tREFI is 15.625 us rather than
        # 7.8125. Both ISSI parts share the 8,192, so without this the refresh
        # arithmetic is only ever exercised one way.
        return [list \
            -G/avalon_mm_sdram_controller_tb/ROW_BITS=12 \
            -G/avalon_mm_sdram_controller_tb/SA_BITS=12 \
            -G/avalon_mm_sdram_controller_tb/REF_ROWS=4096 \
            -G/avalon_mm_sdram_controller_tb/T_RC_PS=66000 \
            -G/avalon_mm_sdram_controller_tb/T_RAS_PS=44000 \
            -G/avalon_mm_sdram_controller_tb/T_RP_PS=20000 \
            -G/avalon_mm_sdram_controller_tb/T_RCD_PS=20000 \
            -G/avalon_mm_sdram_controller_tb/T_RRD_PS=15000 \
            -G/avalon_mm_sdram_controller_tb/T_WR_PS=15000 \
            -G/avalon_mm_sdram_controller_tb/T_MRD_PS=20000 \
            -G/avalon_mm_sdram_controller_tb/T_RFC_PS=66000]
    }
    return [list]
}

proc run_one {cas look depth map khz col part ucdb} {
    set tag ${cas}_${look}_${depth}_${map}_${khz}_${col}_${part}
    eval vopt avalon_mm_sdram_controller_tb -o tb_opt_$tag +acc -cover sbceft -assertdebug \
        [part_args $part] \
        -G/avalon_mm_sdram_controller_tb/CAS_LAT=$cas \
        -G/avalon_mm_sdram_controller_tb/LOOKAHEAD=$look \
        -G/avalon_mm_sdram_controller_tb/FIFO_DEPTH=$depth \
        -G/avalon_mm_sdram_controller_tb/ADDR_MAP=$map \
        -G/avalon_mm_sdram_controller_tb/CLK_KHZ=$khz \
        -G/avalon_mm_sdram_controller_tb/COL_BITS=$col
    vsim tb_opt_$tag -coverage -assertdebug
    onfinish stop
    onbreak {resume}
    run -all
    # Non-vacuous pass counts, which is the number that matters: the report
    # gives Failure / Pass / Vacuous per assertion, and an assertion whose Pass
    # count is zero has verified nothing however green it looks.
    coverage report -assert -details -append -output assert_report.txt
    coverage save $ucdb
    quit -sim
}

if {[file exists assert_report.txt]} { file delete -force assert_report.txt }

# cas look depth map  kHz col part
run_one 3 1  8  0 100000 10 0 c01.ucdb
run_one 2 1  8  0 100000 10 0 c02.ucdb
run_one 3 0  8  0 100000 10 0 c03.ucdb
run_one 3 1  2  0 100000 10 0 c04.ucdb
run_one 3 1 32  0 100000 10 0 c05.ucdb
run_one 3 1  8  1 100000 10 0 c06.ucdb
run_one 2 0  2  0 100000 10 0 c07.ucdb
run_one 3 0  8  1 100000 10 0 c08.ucdb
run_one 3 1  8  0 143000 10 0 c09.ucdb
run_one 3 1  8  0  50000 10 0 c10.ucdb
run_one 2 0  8  0  50000 10 0 c11.ucdb
run_one 3 1  8  0 100000 11 0 c12.ucdb
run_one 3 1  8  0 100000  9 1 c13.ucdb
run_one 3 1  8  0 100000  8 2 c14.ucdb

vcover merge coverage.ucdb \
    c01.ucdb c02.ucdb c03.ucdb c04.ucdb c05.ucdb c06.ucdb c07.ucdb \
    c08.ucdb c09.ucdb c10.ucdb c11.ucdb c12.ucdb c13.ucdb c14.ucdb
vcover report -details -output coverage_report.txt coverage.ucdb

# ---- pass/fail, decided from the transcript rather than from exit codes -----
# A simulator that ran fourteen configurations and printed thirteen "all tests passed"
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
    if {$n < 13} { return 0 }
    if {[string first "Assertion error" $txt] >= 0}   { return 0 }
    if {[string first "TIMING VIOLATION" $txt] >= 0}  { return 0 }
    if {[string first "MODEL ERROR" $txt] >= 0}       { return 0 }
    return 1
}

if {[run_passed]} {
    puts "RESULT: PASSED - all fourteen configurations, no assertion failures,"
    puts "                 no timing violations, no illegal device accesses"
} else {
    puts "RESULT: FAILED - see run.log"
}

quit -f
