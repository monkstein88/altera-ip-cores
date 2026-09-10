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
# WHAT THE FIRST RUN FOUND
# -----------------------
# It was run, against Questa 2024.1, and the header's own warning was right:
# treating the first run as part of the work rather than a formality turned up
# four faults, three of them in this file and one in the RTL.
#
#   * The RTL would not compile. `cmd_byte_val` was consumed in u_crc7's port
#     connection some fifty lines before it was declared; with no
#     `default_nettype none` that use creates an implicit 1-bit net and the
#     later `logic [7:0]` is a duplicate declaration. vlog rejected it outright.
#     Verilator resolved it to the 8-bit signal and linted clean under -Wall.
#     This is the same class of fault the SDRAM controller hit - something
#     Verilator accepts and vopt does not - and it had a sharper edge here: a
#     tool taking the implicit-net reading would have fed CRC7 one bit of every
#     command frame instead of eight.
#
#   * NONE OF THE ASSERTIONS WERE RUNNING. The binds sit at compilation-unit
#     scope, so without -mfcu -cuname vlog compiled the four SVA modules, warned
#     once (vlog-2650) and elaborated none of them. Seven configurations passed
#     reporting "no assertion failures" because there were no assertions. The
#     assertion report was zero bytes and nothing looked wrong.
#
#   * So the verdict now REQUIRES the assertions by name before it may report a
#     pass - see check_assertions_reported. Absence of a failure is not
#     evidence; presence of the assertion is.
#
#     That gate was then fault-injected against itself, the same way
#     verification/check_assertions_fire.sh treats the assertions: drop the
#     -mfcu -cuname above and the sva_cu top below, and the run reproduces the
#     original fault exactly - seven configurations printing *** PASS ***, a
#     zero-byte assertion report, and no complaint from any simulator. The gate
#     reports RESULT: FAILED and names all 24 missing assertions. A gate that
#     has not been shown to fail is worth no more than the assertions it is
#     there to protect.
#
#   * `write report -assertions` is indeed not a Questa command; pass and
#     vacuity counts come from `coverage report -assert`, which additionally
#     needs vsim -assertcounts. Without it the report is empty even once the
#     binds elaborate.
#
# And then the non-vacuity data earned its keep immediately, which is the whole
# argument for this flow existing:
#
#   * a_no_push_when_full had a consequent of literal 1'b1. It could not fail
#     whatever the design did - its name promised it caught a push into a full
#     FIFO and its body permitted exactly that. Both simulators had always
#     called it green. Repaired to `mem_push |-> !mem_full`, it now passes for a
#     real reason 258 times, so the property does hold.
#
#   * a_waitrequest_holds_read never once passed non-vacuously - 0 against 765k
#     attempts - while its write-side twin passed 254 times. The memory model
#     stalled only AFTER accepting a command, and a read burst presents `read`
#     for exactly one accepted cycle, so waitrequest was never asserted while
#     read was high. The model now stalls the first beat of every command too.
#
# STILL OPEN: the sequencer reaches all 20 states but only 32 of its 58
# transitions. The gaps are the soft-reset escape from nearly every state, and
# the timeout paths into S_ABORT from S_PRE_BUSY, S_PRE_BUSY_W, S_R1B_BUSY,
# S_RD_DATA, S_WR_DATA and S_WR_CRC. Those branches exist and are lint-clean and
# nothing in the regression takes them.
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
# -mfcu -cuname is what makes the BINDS take effect, and it is not optional.
# The bind statements sit at compilation-unit scope, and without a named unit
# vlog compiles the four SVA modules, warns once (vlog-2650), and elaborates
# none of them - so every assertion is silently absent and the run reports "no
# assertion failures" because there were no assertions. That is precisely the
# failure this flow exists to detect, and it went unnoticed until the assertion
# report came back empty. `sva_cu` is then named as a top alongside each
# testbench below.
vlog -sv +acc -mfcu -cuname sva_cu ../../tb/avalon_mm_sdcard_controller_sva.sv
vlog -sv +acc ../../tb/avalon_mm_sdcard_controller_spi_phy_tb.sv
vlog -sv +acc ../../tb/avalon_mm_sdcard_controller_fifo_tb.sv
vlog -sv +acc ../../tb/avalon_mm_sdcard_controller_tb.sv

if {[file exists assert_report.txt]} { file delete -force assert_report.txt }

# -----------------------------------------------------------------------------
# One run of a testbench that takes no parameters.
# -----------------------------------------------------------------------------
proc run_unit {top tag ucdb} {
    # sva_cu carries binds for all four RTL modules; a unit testbench contains
    # only one of them, so the other three bind targets are legitimately absent.
    # vopt-10717 and vsim-12036 are those unresolved references. Suppressing
    # them is safe ONLY because check_assertions_reported below then requires
    # the assertions that SHOULD be there to appear in the report - absence of
    # an error is not evidence, presence of the assertion is.
    vopt $top sva_cu -o opt_$tag +acc -cover sbceft -assertdebug \
        -suppress vopt-10717
    vsim opt_$tag -coverage -assertdebug -assertcounts -suppress vsim-12036
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
    # The pio configuration builds with USE_DMA=0, where the DMA is not
    # instantiated at all, so its bind target genuinely does not exist - hence
    # the same suppression as run_unit.
    vopt avalon_mm_sdcard_controller_tb sva_cu -o opt_$tag +acc -cover sbceft -assertdebug \
        -suppress vopt-10717 \
        -G$T/TB_USE_DMA=$dma \
        -G$T/TB_HIGH_CAPACITY=$hicap \
        -G$T/TB_FIFO_B=$fifob \
        -G$T/TB_BURST_W=$burstw
    vsim opt_$tag -coverage -assertdebug -assertcounts -suppress vsim-12036
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
# The assertions are the whole reason this flow exists, and they are the one
# thing here that can go missing without anything looking wrong: a bind that
# does not elaborate produces no error, no failure and no assertion - just a
# green run over an empty report. So the report is required to contain the
# assertions, by name, before the run may be called a pass.
#
# Counting is not enough on its own either. An assertion whose Pass count is
# zero was never evaluated for a real reason - either its antecedent never held
# in any configuration, or its consequent is a tautology - and it has verified
# nothing however green it looks. Those are listed rather than failed, because
# some antecedents are genuinely unreachable in a given configuration and only
# the merged view across the sweep is meaningful.
proc check_assertions_reported {} {
    if {![file exists assert_report.txt]} {
        puts "ASSERTIONS: assert_report.txt was never written"
        return 0
    }
    set fh [open assert_report.txt r]
    set txt [read $fh]
    close $fh

    # Every assertion in tb/avalon_mm_sdcard_controller_sva.sv, by name.
    set expected {
        a_burstcount_nonzero a_byte_port_follows_direction a_byte_read_follows_direction
        a_clock_parks_low a_cs_only_while_busy a_done_only_while_busy
        a_fifo_one_direction a_idle_means_empty a_no_invented_bytes
        a_no_pop_when_empty a_no_push_when_full a_no_spontaneous_start
        a_no_zero_byteenable_read a_pending_is_busy a_pop_matches_accept
        a_pop_only_when_nonempty a_queued_byte_not_dropped a_request_never_dropped
        a_send_state_never_idles a_start_only_when_phy_idle a_tx_we_needs_ready
        a_waitrequest_holds_command a_waitrequest_holds_read a_write_has_data
    }

    set missing {}
    foreach a $expected {
        if {[string first $a $txt] < 0} { lappend missing $a }
    }
    if {[llength $missing] > 0} {
        puts "ASSERTIONS: [llength $missing] never appeared in the report:"
        foreach a $missing { puts "    $a" }
        return 0
    }

    # Report, but do not fail on, assertions that never passed for a real
    # reason. The report gives a name line, a file(line) line, then a counts
    # line: Failure Pass Vacuous Disable Attempt ... - so the name is carried
    # forward until its counts arrive. Names recur across the report's two
    # sections and across the merged configurations, so the BEST pass count
    # seen for each name is the one that matters: an antecedent unreachable in
    # one configuration may well be exercised in another.
    array set best {}
    set pending ""
    foreach line [split $txt "\n"] {
        if {[regexp {/(a_\w+)\s*$} $line -> nm]} {
            set pending $nm
            if {![info exists best($nm)]} { set best($nm) 0 }
        } elseif {$pending ne ""} {
            if {[regexp {^\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)} \
                        $line -> nfail npass nvac ndis natt]} {
                if {$npass > $best($pending)} { set best($pending) $npass }
                set pending ""
            }
        }
    }

    set never {}
    foreach a $expected {
        if {[info exists best($a)] && $best($a) == 0} { lappend never $a }
    }

    puts "ASSERTIONS: all [llength $expected] present in the report"
    if {[llength $never] > 0} {
        puts "ASSERTIONS: [llength $never] never passed non-vacuously across the whole sweep -"
        puts "            each has verified nothing, however green the run looks:"
        foreach a $never { puts "    $a" }
    } else {
        puts "ASSERTIONS: every one passed non-vacuously somewhere in the sweep"
    }
    return 1
}

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

# Wrapped in a proc so the verdict does not echo the procs' return values into
# the transcript ahead of the lines they belong to.
proc report_result {} {
    set sim_ok    [run_passed]
    set assert_ok [check_assertions_reported]

    if {$sim_ok && $assert_ok} {
        puts "RESULT: PASSED - all seven configurations, no assertion failures,"
        puts "                 no protocol violations at the card model"
    } elseif {$sim_ok && !$assert_ok} {
        # Deliberately NOT a pass. The simulations agreeing with each other
        # while the assertions were absent is the exact shape of a green run
        # that checked less than it claimed.
        puts "RESULT: FAILED - the simulations passed but the assertions did not"
        puts "                 all run; see the ASSERTIONS lines above"
    } else {
        puts "RESULT: FAILED - see run.log"
    }
}
report_result

quit -f
