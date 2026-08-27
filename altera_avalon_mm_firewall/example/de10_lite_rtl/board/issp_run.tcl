# =============================================================================
# issp_run.tcl - drive the RTL demo over JTAG and check its result.
#
# Run through ../run_on_board.sh, or directly:
#     quartus_stp -t issp_run.tcl
#
# The demo reports on seven-segment displays, which a script cannot read. The
# In-System Sources and Probes instance in the top level exposes the same
# state over JTAG, so the whole thing can be regression-tested on hardware
# without anyone looking at the board.
#
# probe[32:0] = { status[9:0], running, result_valid, result_pass,
#                 scenario[3:0], pass_bitmap[15:0] }
#
# Ten status bits, not nine: RD_CMD_STUCK is bit 9, and scenario C is the only
# thing that sets it. A 32-bit probe could not carry it.
# source[7:0] = { -, start, freeze, auto_mode, select[3:0] }
#
# NOTE: write_source_data treats its value as BINARY unless -value_in_hex is
# given. Writing 0x10 without it lands 0x02 in the source register, which
# looks exactly like the design ignoring you.
# =============================================================================

set hw ""
foreach h [get_hardware_names] { if {[string match "*USB-Blaster*" $h]} { set hw $h; break } }
if {$hw eq ""} { puts "ERROR: no USB-Blaster found"; exit 1 }

set dev ""
foreach d [get_device_names -hardware_name $hw] { if {[string match "*10M50*" $d]} { set dev $d; break } }
if {$dev eq ""} { puts "ERROR: no 10M50 in the JTAG chain"; exit 1 }
puts "cable  : $hw"
puts "device : $dev"

if {[catch {start_insystem_source_probe -hardware_name $hw -device_name $dev} e]} {
    puts "ERROR: could not open the ISSP instance: $e"
    puts "       Is the RTL demo programmed, and was it built with ENABLE_ISSP?"
    exit 1
}

proc probe {}      { return [read_probe_data -instance_index 0 -value_in_hex] }
proc src   {hex}   { write_source_data -instance_index 0 -value $hex -value_in_hex }
proc field {hex hi lo} { scan $hex %x v; return [expr {($v >> $lo) & ((1 << ($hi-$lo+1)) - 1)}] }
# Wait until the sequencer is idle, or until the budget runs out. Polling
# rather than sleeping a fixed time: the scenarios' wall-clock length depends
# on the build (REGISTER_LOOKUP adds a cycle to every transaction) and on the
# programmed timeout, and a fixed delay that happens to be long enough today
# silently stops being long enough later. That is exactly how this script
# first failed against the registered-lookup build.
proc running {} { scan [probe] %x v; return [expr {($v >> 22) & 1}] }

proc wait_for {want {tries 200}} {
    for {set i 0} {$i < $tries} {incr i} {
        after 50
        if {[running] == $want} { return 1 }
    }
    return 0
}
proc wait_idle {{tries 200}} { return [wait_for 0 $tries] }

# Run one scenario in step mode and wait for it to finish. `sel` is the
# scenario number; the source register carries
# { -, start, freeze, auto, select[3:0] }.
#
# Two separate hazards are handled here, and they are not the same thing.
#
# 1. THE SOURCE REGISTER IS NOT WRITTEN ATOMICALLY. altsource_probe shifts the
#    value in over JTAG bit by bit and it reaches the fabric as it lands, so a
#    start edge can arrive while the select bits are still half-updated - and
#    a DIFFERENT scenario runs than the one asked for. The design now filters
#    the source word (see src_stable in the top level), and the write of the
#    select value is separated from the start edge here so the filter has
#    settled before start rises. This was the cause of the intermittent
#    behaviour previously recorded in this example's README as unexplained.
#
# 2. `running` is a LEVEL, and it is still 0 for a moment after the start
#    pulse. Waiting for idle without first seeing busy returns instantly and
#    samples the PREVIOUS scenario's result. So start is held until the design
#    acknowledges by going busy, and only then released.
proc run_scenario {sel} {
    src [format "%02X" $sel]
    wait_idle
    after 100
    src [format "%02X" [expr {0x40 | $sel}]]     ;# start, held
    set started [wait_for 1 40]
    src [format "%02X" $sel]                     ;# release start
    if {!$started} { return 0 }
    wait_idle
    after 100
    return 1
}

proc show  {tag} {
    set d [probe]
    puts [format "  %-16s bitmap=%04X scenario=%X pass=%d valid=%d running=%d status=%03X" \
          $tag [field $d 15 0] [field $d 19 16] [field $d 20 20] [field $d 21 21] \
          [field $d 22 22] [field $d 32 23]]
}

# ---------------------------------------------------------------------------
# Refuse to test a board that is already wedged.
#
# The intermittent wedge this guard was written for has since been root-caused
# and fixed - see "Resolved" in this example's README, and src_stable in the
# top level. The guard is kept anyway: it costs one probe read, and it turns
# any future "the sequencer was already busy" state into an instruction rather
# than four misleading FAIL lines about wrong scenarios and wrong STATUS.
#
# `src 00` first, so a leftover auto-sweep or start bit from a previous session
# is not mistaken for a wedge, and the wait allows for the scenario 0 that runs
# by itself at power-up.
# ---------------------------------------------------------------------------
src 00
if {![wait_idle 60]} {
    puts ""
    puts "ERROR: the sequencer is still busy (running=1) before any command was"
    puts "       sent, so the board is in a stale state and nothing below would"
    puts "       mean anything. This is NOT a firewall failure."
    puts ""
    puts "       Re-program the board and try again - run run_on_board.sh"
    puts "       WITHOUT --no-program."
    end_insystem_source_probe
    exit 1
}

puts "\n--- state at power-up ---"
show "idle"
puts "  (scenario 0 runs by itself so a hand-picked scenario finds a"
puts "   programmed rule table; bitmap 0001 is correct here)"

puts "\n--- auto sweep, driven over JTAG ---"
src 10
set ok 0
for {set i 1} {$i <= 200} {incr i} {
    after 250
    if {[field [probe] 15 0] == 65535} { set ok 1; break }
}
show "after sweep"
src 00
wait_idle

# Step mode: run one scenario on demand and confirm only that one ran.
#
# Scenario b is the write timeout with the command never accepted. It leaves a
# known STATUS behind - TIMEOUT_ERROR | ISOLATED | BLOCKED | WR_CMD_STUCK =
# 0x134 - so the status field below is a real reading off silicon, not a
# formality.
puts "\n--- step mode: run scenario b (write timeout) on its own ---"
run_scenario 11
show "scenario b"
set scen   [field [probe] 19 16]
set pass   [field [probe] 20 20]
set status [field [probe] 32 23]

# Scenario C ends on a starved READ, which is the only way RD_CMD_STUCK gets
# set. Checking it here is what proves STATUS bit 9 reaches real silicon.
puts "\n--- step mode: run scenario C (read timeout, both shapes) ---"
run_scenario 12
show "scenario C"
set cscen  [field [probe] 19 16]
set cpass  [field [probe] 20 20]
set cstat  [field [probe] 32 23]
src 00
end_insystem_source_probe

puts "\n============================================================"
set rc 0
if {$ok} { puts "PASS: all 16 scenarios passed in the sweep (bitmap = FFFF)" } \
else     { puts "FAIL: the sweep never reached FFFF"; set rc 1 }
if {$scen == 11 && $pass == 1} { puts "PASS: step mode ran exactly scenario b, and it passed" } \
else                           { puts "FAIL: step mode ran scenario $scen, pass=$pass"; set rc 1 }
if {$status == 0x134} { puts "PASS: STATUS after the write timeout is 0x134 (TIMEOUT|ISOLATED|BLOCKED|WR_CMD_STUCK)" } \
else                  { puts [format "FAIL: STATUS after the write timeout is 0x%03X, expected 0x134" $status]; set rc 1 }
if {$cscen == 12 && $cpass == 1} { puts "PASS: step mode ran exactly scenario C, and it passed" } \
else                             { puts "FAIL: step mode ran scenario $cscen, pass=$cpass"; set rc 1 }
if {$cstat == 0x234} { puts "PASS: STATUS after the read timeout is 0x234 - RD_CMD_STUCK (bit 9) set on silicon" } \
else                 { puts [format "FAIL: STATUS after the read timeout is 0x%03X, expected 0x234" $cstat]; set rc 1 }
puts [expr {$rc == 0 ? "RESULT: PASSED ON HARDWARE" : "RESULT: FAILED"}]
exit $rc
