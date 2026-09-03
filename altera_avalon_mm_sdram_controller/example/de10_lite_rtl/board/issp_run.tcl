# =============================================================================
# issp_run.tcl - drive the SDRAM demo over JTAG and check its result.
#
# Run through ../run_on_board.sh, or directly:
#     quartus_stp -t issp_run.tcl
#
# The demo reports on seven-segment displays, which a script cannot read, and
# it measures cycle counts, which the displays have no room for. The In-System
# Sources and Probes instance in the top level exposes both over the same USB
# cable used to program the board, so the whole thing is regression-testable
# from a script and the throughput comes out in MB/s.
#
#   probe[185:0] = { src_stable[8:0],      185:177
#                    perf_words[31:0],      176:145
#                    perf_rd_cycles[31:0],  144:113
#                    perf_wr_cycles[31:0],  112:81
#                    fail_actual[15:0],      80:65
#                    fail_expected[15:0],    64:49
#                    fail_addr[24:0],        48:24
#                    auto_eff,                  23
#                    err_code[2:0],          22:20
#                    done_count[3:0],        19:16
#                    pll_locked,                15
#                    running,                   14
#                    result_valid,              13
#                    result_pass,               12
#                    cur_scenario[3:0],       11:8
#                    pass_bitmap[7:0] }        7:0
#
#   source[8:0]  = { jtag_override, seq_reset, start, freeze, auto,
#                    select[3:0] }
#
#   jtag_override makes the design ignore the board's switches. This script
#   always asserts it: without it a switch left in the wrong position changes
#   what gets measured, and says nothing about having done so.
#
# NOTE: write_source_data treats its value as BINARY unless -value_in_hex is
# given. Writing 0x10 without it lands 0x02 in the source register, which
# looks exactly like the design ignoring you.
# =============================================================================

# Search EVERY cable for this board's device, not just the first one. With two
# USB-Blasters attached - the normal state of a bench that has both boards -
# taking the first cable picks whichever enumerated first, and then fails with
# "no 10M50 in the JTAG chain" on a perfectly healthy setup.
set hw ""
set dev ""
foreach h [get_hardware_names] {
    if {![string match "*USB-Blaster*" $h]} { continue }
    foreach d [get_device_names -hardware_name $h] {
        if {[string match "*10M50*" $d]} { set hw $h; set dev $d; break }
    }
    if {$dev ne ""} { break }
}
if {$dev eq ""} { puts "ERROR: no 10M50 on any USB-Blaster"; exit 1 }
puts "cable  : $hw"
puts "device : $dev"

if {[catch {start_insystem_source_probe -hardware_name $hw -device_name $dev} e]} {
    puts "ERROR: could not open the ISSP instance: $e"
    puts "       Is the demo programmed, and was it built with ENABLE_ISSP?"
    exit 1
}

proc probe {}    { return [read_probe_data -instance_index 0 -value_in_hex] }
# Every write asserts bit 8, JTAG OVERRIDE, so the physical switches are
# ignored for the duration of this script. Without it a board with its auto
# switch left up runs a full sweep for every scenario asked for and reports
# the last one's counters under every name - which is exactly what this board
# did, silently, before the override existed.
proc src   {hex} {
    # The substitution happens OUTSIDE the braces for the same reason `field`
    # does it that way: inside {} Tcl does not substitute $hex before parsing,
    # so 0x$hex is a bareword and expr rejects it.
    set v [expr 0x$hex]
    write_source_data -instance_index 0 \
        -value [format "%03X" [expr {$v | 0x100}]] -value_in_hex
}

# The probe is 177 bits wide, so the hex string does not fit a machine word.
# Tcl's expr promotes a hex literal of any length to a bignum, which `scan %x`
# would not - hence the deliberate substitution outside the braces.
proc field {hex hi lo} {
    set v [expr 0x$hex]
    return [expr {($v >> $lo) & ((1 << ($hi - $lo + 1)) - 1)}]
}

proc f_auto   {d} { return [field $d 23 23] }
proc f_bitmap {d} { return [field $d 7 0] }
proc f_scen   {d} { return [field $d 11 8] }
proc f_pass   {d} { return [field $d 12 12] }
proc f_valid  {d} { return [field $d 13 13] }
proc f_run    {d} { return [field $d 14 14] }
proc f_lock   {d} { return [field $d 15 15] }
proc f_done   {d} { return [field $d 19 16] }
proc f_err    {d} { return [field $d 22 20] }
proc f_faddr  {d} { return [field $d 48 24] }
proc f_fexp   {d} { return [field $d 64 49] }
proc f_fact   {d} { return [field $d 80 65] }
proc f_wrcyc  {d} { return [field $d 112 81] }
proc f_rdcyc  {d} { return [field $d 144 113] }
proc f_words  {d} { return [field $d 176 145] }
# Words this scenario actually COMPARED against the expected pattern.
# pass_acc starts true, so a scenario that issued nothing would report a
# pass on an optimistic default. The design refuses to pass a scenario
# that verified zero words; this is the host-side cross-check that it
# verified as many as it claimed to write.
proc f_chk    {d} { return [field $d 217 186] }
# What the design is actually acting on, after its stability filter. Reading
# this back is how you tell "the board ignored me" from "the board did what I
# asked and the answer is genuinely wrong".
proc f_src    {d} { return [field $d 185 177] }

set ERRNAME(0) "none"
set ERRNAME(1) "data mismatch"
set ERRNAME(2) "watchdog timeout"
set ERRNAME(3) "scenario verified nothing"
# An unknown code must not crash the reporter - that is how a failing
# run turned into a Tcl stack trace with the result buried above it.
for {set e 4} {$e < 8} {incr e} { set ERRNAME($e) "unknown code $e" }

# 16 bits per word at 100 MHz -> bytes/s = words * 2 / (cycles * 10ns).
# MB/s here means 10^6 bytes/s.
proc mbps {words cycles} {
    if {$cycles == 0} { return 0.0 }
    return [expr {double($words) * 200.0 / double($cycles)}]
}

# ---------------------------------------------------------------------------
# Run one scenario and wait for it to finish.
#
# The wait is on done_count MOVING, not on `running` going high and then low.
# A level has a race: read it a moment after the start pulse and it has not
# risen yet, so "not running" reads as "already finished" and the host takes
# the PREVIOUS scenario's result - a wrong answer that looks like a real
# failure. A counter that only ever increments has no such window. The RTL
# provides done_count for exactly this reason.
# ---------------------------------------------------------------------------
proc run_scenario {sel {tries 200}} {
    set before [f_done [probe]]
    # Select first, and let the design's stability filter accept it before the
    # start edge arrives. The filter needs 256 clocks; this is far more, and
    # it costs nothing at human speed.
    src [format "%02X" $sel]
    after 50
    if {([f_src [probe]] & 0xFF) != $sel} {
        # The design is not acting on what was written. Say so plainly rather
        # than reporting whatever the wrong scenario produced.
        puts [format "    WARNING: wrote select=%X, design has source=%02X" \
              $sel [expr {[f_src [probe]] & 0xFF}]]
    }
    # Hold start asserted until the design acts on it, then release. Holding is
    # safe: the design triggers on the RISING edge only, so a held level
    # cannot start a second run.
    src [format "%02X" [expr {0x40 | $sel}]]
    set started 0
    for {set i 0} {$i < 40} {incr i} {
        after 50
        set d [probe]
        if {[f_run $d] == 1 || [f_done $d] != $before} { set started 1; break }
    }
    src [format "%02X" $sel]
    after 50
    if {!$started} { return 0 }
    for {set i 0} {$i < $tries} {incr i} {
        after 100
        if {[f_done [probe]] != $before} {
            # Ran SOMETHING. Check it ran the right thing: an auto sweep, or a
            # select that did not take, produces a full set of plausible
            # numbers belonging to a different scenario.
            set d [probe]
            if {[f_scen $d] != $sel} {
                puts [format "    WARNING: asked for scenario %d, design ran %d%s" \
                      $sel [f_scen $d] \
                      [expr {[f_auto $d] ? " (auto mode is on)" : ""}]]
                return 0
            }
            return 1
        }
    }
    return 0
}

proc show {tag} {
    set d [probe]
    puts [format "  %-22s bitmap=%02X scen=%X pass=%d valid=%d run=%d done=%X err=%d" \
          $tag [f_bitmap $d] [f_scen $d] [f_pass $d] [f_valid $d] \
          [f_run $d] [f_done $d] [f_err $d]]
}

set NAME(0) "0 data bus walk"
set NAME(1) "1 address bus walk"
set NAME(2) "2 byte enables"
set NAME(3) "3 column sweep"
set NAME(4) "4 bank toggle"
set NAME(5) "5 row thrash"
set NAME(6) "6 refresh retention"
set NAME(7) "7 full 64 MB march"

set rc 0

# ---------------------------------------------------------------------------
# Put the sequencer in a known state first.
#
# source bit 7 forces the state machine back to IDLE regardless of what it was
# doing. Nothing below can be confused by a run left over from a previous
# session, and a board that has somehow wedged does not need re-programming to
# be usable again - which is a fault this repository's firewall demo has and
# this one deliberately does not.
# ---------------------------------------------------------------------------
src 80
after 200
src 00
after 200

set d [probe]
puts "\n--- state at power-up ---"
show "idle"
if {[f_lock $d] != 1} {
    puts "ERROR: the PLL is not locked. Nothing below would mean anything."
    end_insystem_source_probe
    exit 1
}
puts "  PLL locked, sequencer idle"

# ---------------------------------------------------------------------------
# Auto sweep: every scenario, in order, from a cleared bitmap.
# ---------------------------------------------------------------------------
puts "\n--- auto sweep: all 8 scenarios ---"
puts "    (scenario 7 writes and verifies all 33,554,432 words, so this takes"
puts "     a few seconds)"
set before [f_done [probe]]
src 10                                          ;# auto
after 50
src 50                                          ;# auto + start
after 100
src 10                                          ;# release start
set ok 0
for {set i 1} {$i <= 600} {incr i} {
    after 250
    set d [probe]
    if {[f_run $d] == 0 && [f_done $d] != $before} {
        # The sweep ends with the machine back in IDLE.
        if {[f_bitmap $d] == 255} { set ok 1 }
        break
    }
}
src 00
show "after sweep"
set d [probe]
set bm [f_bitmap $d]
puts "\n  per-scenario result:"
for {set s 0} {$s < 8} {incr s} {
    set bit [expr {($bm >> $s) & 1}]
    puts [format "    %-22s %s" $NAME($s) [expr {$bit ? "PASS" : "FAIL"}]]
}
if {!$ok} {
    puts [format "\n  first failure: addr=0x%07X expected=0x%04X actual=0x%04X (%s)" \
          [f_faddr $d] [f_fexp $d] [f_fact $d] $ERRNAME([f_err $d])]
}

# ---------------------------------------------------------------------------
# Throughput. Three scenarios that differ ONLY in how their addresses map onto
# the chip's banks and rows, so the numbers isolate the cost of a row miss.
# ---------------------------------------------------------------------------
puts "\n--- throughput, measured on silicon ---"
puts [format "  %-22s %10s %10s %12s %12s" "scenario" "words" "wr cyc" "write MB/s" "read MB/s"]
foreach s {3 4 5 7} {
    if {![run_scenario $s 600]} {
        puts [format "  %-22s did not finish" $NAME($s)]
        set rc 1
        continue
    }
    set d [probe]
    set w  [f_words $d]
    set wc [f_wrcyc $d]
    set rdc [f_rdcyc $d]
    set ck [f_chk $d]
    puts [format "  %-22s %10d %10d %12.1f %12.1f" \
          $NAME($s) $w $wc [mbps $w $wc] [mbps $w $rdc]]
    if {[f_pass $d] != 1} { set rc 1 }
    # These four are block scenarios: they write t_count words and then read
    # and compare exactly the same number. Anything else means the read pass
    # did not run to completion, and "passed" would be an optimistic default.
    # Both halves matter. A scenario that does nothing reports 0 and 0, so
    # equality alone is satisfied trivially - the design's own gate is what
    # catches that case, and this is the cross-check that it is still armed.
    if {$ck == 0 || $w == 0} {
        puts [format "    FAIL: %s verified %d words of %d - it did nothing" \
              $NAME($s) $ck $w]
        set rc 1
    } elseif {$ck != $w} {
        puts [format "    FAIL: verified %d words but the scenario covers %d" $ck $w]
        set rc 1
    }
}
puts "\n  Scenario 3 stays inside one bank and one row; scenario 5 forces a"
puts "  PRECHARGE and ACTIVATE before every single word. The gap between them"
puts "  is what a row miss costs on this controller."

# ---------------------------------------------------------------------------
# Refresh retention, on its own, because it is the one scenario whose result
# depends on the controller doing something while nobody is asking it to.
# ---------------------------------------------------------------------------
puts "\n--- scenario 6 on its own: refresh retention (12 s idle) ---"
if {[run_scenario 6 400]} {
    set d [probe]
    if {[f_pass $d] == 1} {
        puts "  PASS: 8 MByte survived 12 s of no access at all"
    } else {
        puts [format "  FAIL: addr=0x%07X expected=0x%04X actual=0x%04X" \
              [f_faddr $d] [f_fexp $d] [f_fact $d]]
        set rc 1
    }
} else {
    puts "  FAIL: scenario 6 did not finish"
    set rc 1
}

src 00
end_insystem_source_probe

puts "\n============================================================"
if {$ok} {
    puts "PASS: all 8 scenarios passed in the sweep (bitmap = FF)"
} else {
    puts [format "FAIL: the sweep finished with bitmap = %02X, expected FF" $bm]
    set rc 1
}
puts [expr {$rc == 0 ? "RESULT: PASSED ON HARDWARE" : "RESULT: FAILED"}]
exit $rc
