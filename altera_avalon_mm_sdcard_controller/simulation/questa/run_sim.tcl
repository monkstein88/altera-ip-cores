# =============================================================================
# run_sim.tcl - Questa/ModelSim regression for avalon_mm_sdcard_controller.
#
#   cd simulation/questa && vsim -c -do run_sim.tcl
#
# WHAT THIS ADDS OVER THE VERILATOR FLOW
# --------------------------------------
# simulation/verilator/run_sim.sh runs the same three testbenches across the
# same five-way configuration sweep on an open-source simulator, so it is the
# flow to reach for first. Two things only Questa provides:
#
#   COVERAGE          statement, branch, condition, expression, FSM and toggle,
#                     merged across the sweep. This core's sequencer is a
#                     twenty-state machine whose error paths are reached only
#                     by fault injection, and whose stall timeouts are reachable
#                     ONLY in the PIO configuration - with a master attached the
#                     DMA always supplies, so the branch never executes. FSM
#                     coverage is the flow that says which of those states and
#                     arcs the sweep genuinely visited rather than merely
#                     compiled.
#   NON-VACUITY       how many times each of the 24 assertions passed for a real
#                     reason rather than because its antecedent never held. That
#                     distinction has already cost this core once:
#                     verification/check_assertions_fire.sh found that the
#                     `!hold_v` term in the shifter's idle output guards a state
#                     the sequencer cannot enter, because S_PRE_BUSY free-runs
#                     0xFF before every send. An assertion that only ever passes
#                     vacuously has verified nothing while reporting green, and
#                     no other flow here can tell you which ones those are.
#
# NOT YET RUN
# -----------
# This file is written to the pattern of the sibling cores' flows and has NOT
# been executed against a Questa installation. Treat the first run as part of
# the work, not as a formality. The SDRAM controller's equivalent file records
# what its own first run turned up, and both faults are worth knowing about
# here:
#
#   * `write report -assertions` is not a Questa command. Assertion pass and
#     vacuity counts come from `coverage report -assert`, which is what is used
#     below.
#   * Its RTL would not elaborate at all, because a variable was written by both
#     an initial block and an always_ff - forbidden by IEEE 1800-2017 9.2.2.4,
#     rejected by vopt, and linted clean by Verilator with -Wall and nothing
#     waived. That specific trap does not apply here: this core's RTL contains
#     no initial blocks at all. It is the class of fault to expect, though -
#     something Verilator accepts and vopt does not.
#
# The sweep below matches simulation/verilator/run_sim.sh exactly, so a
# disagreement between the two flows is a real disagreement between simulators
# and not a difference in what was run.
# =============================================================================

transcript file run.log

if {[file exists work]} { file delete -force work }
vlib work
vmap work work

# +acc keeps the hierarchy visible for coverage and for the assertion debugger;
# +cover=sbceft is statement, branch, condition, expression, FSM, toggle.
#
# Compile order is not free: the package defines the register map and the
# protocol constants that every other file elaborates against, and the CRC file
# defines a second package used by both the sequencer and the testbench.
set RTL ../../rtl/avalon_mm_sdcard_controller
foreach f [list ${RTL}_pkg.sv ${RTL}_crc.sv ${RTL}_clkgen.sv ${RTL}_spi_phy.sv \
                ${RTL}_fifo.sv ${RTL}_dma.sv ${RTL}_seq.sv ${RTL}_regs.sv \
                ${RTL}.sv] {
    vlog -sv +acc +cover=sbceft $f
}

# Testbench sources. The card model and the memory model are compiled without
# coverage instrumentation: they are stimulus, and counting their branches
# inflates the totals with numbers nobody should act on.
vlog -sv +acc ../../tb/spi_card_model.sv
vlog -sv +acc ../../tb/avalon_mm_mem_model.sv
vlog -sv +acc ../../tb/avalon_mm_sdcard_controller_sva.sv
vlog -sv +acc ../../tb/avalon_mm_sdcard_controller_spi_phy_tb.sv
vlog -sv +acc ../../tb/avalon_mm_sdcard_controller_fifo_tb.sv
vlog -sv +acc ../../tb/avalon_mm_sdcard_controller_tb.sv

if {[file exists assert_report.txt]} { file delete -force assert_report.txt }

# -----------------------------------------------------------------------------
# One run of a testbench that takes no parameters.
# -----------------------------------------------------------------------------
proc run_unit {top tag ucdb} {
    vopt $top -o opt_$tag +acc -cover sbceft -assertdebug
    vsim opt_$tag -coverage -assertdebug
    onfinish stop
    onbreak {resume}
    run -all
    coverage report -assert -details -append -output assert_report.txt
    coverage save $ucdb
    quit -sim
}

# -----------------------------------------------------------------------------
# One run of the full-core testbench.
#
# These are not cosmetic variations. Each is a different design or a different
# card, and each reaches something the others cannot:
#
#   dma       the reference configuration
#   pio       USE_DMA=0. No master at all; software moves every word through the
#             DATA window, on a deadline. The only configuration in which the
#             shifter can be starved by the CPU rather than by the interconnect,
#             and therefore the only one that reaches the stall timeouts.
#   sdsc      a standard-capacity card, which is BYTE addressed. On an SDHC card
#             the block-to-address conversion is the identity, so this is the
#             only configuration in which it is executed at all.
#   tight     one block of buffer instead of two, so nothing overlaps and the
#             data path refills mid-transfer.
#   noburst   single-beat Avalon transactions throughout.
# -----------------------------------------------------------------------------
proc run_core {dma hicap fifob burstw tag ucdb} {
    set T /avalon_mm_sdcard_controller_tb
    vopt avalon_mm_sdcard_controller_tb -o opt_$tag +acc -cover sbceft -assertdebug \
        -G$T/TB_USE_DMA=$dma \
        -G$T/TB_HIGH_CAPACITY=$hicap \
        -G$T/TB_FIFO_B=$fifob \
        -G$T/TB_BURST_W=$burstw
    vsim opt_$tag -coverage -assertdebug
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

run_unit avalon_mm_sdcard_controller_spi_phy_tb phy  c01.ucdb
run_unit avalon_mm_sdcard_controller_fifo_tb    fifo c02.ucdb

#        dma hicap fifob burstw  tag      ucdb
run_core   1     1   1024      8  dma     c03.ucdb
run_core   0     1   1024      8  pio     c04.ucdb
run_core   1     0   1024      8  sdsc    c05.ucdb
run_core   1     1    512      8  tight   c06.ucdb
run_core   1     1   1024      1  noburst c07.ucdb

vcover merge coverage.ucdb \
    c01.ucdb c02.ucdb c03.ucdb c04.ucdb c05.ucdb c06.ucdb c07.ucdb
vcover report -details -output coverage_report.txt coverage.ucdb

# ---- pass/fail, decided from the transcript rather than from exit codes -----
# A simulator that ran seven configurations and printed six "*** PASS ***" has
# failed one of them, and will still exit 0.
proc run_passed {} {
    if {![file exists run.log]} { return 0 }
    set fh [open run.log r]
    set txt [read $fh]
    close $fh
    set n 0
    set idx 0
    while {[set idx [string first "*** PASS ***" $txt $idx]] >= 0} {
        incr n
        incr idx
    }
    if {$n < 7} { return 0 }
    # The testbenches count their own failures and print the tally either way,
    # so a non-zero failure count is caught even if the PASS line is absent for
    # some other reason.
    if {[regexp {checks, [1-9][0-9]* failures} $txt]}  { return 0 }
    if {[string first "Assertion error" $txt] >= 0}    { return 0 }
    if {[string first "SVA FAIL" $txt] >= 0}           { return 0 }
    if {[string first "CARD MODEL ERROR" $txt] >= 0}   { return 0 }
    return 1
}

if {[run_passed]} {
    puts "RESULT: PASSED - all seven configurations, no assertion failures,"
    puts "                 no protocol violations at the card model"
} else {
    puts "RESULT: FAILED - see run.log"
}

quit -f
