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
# probe[35:0] = { done_count[3:0], status[8:0], running, result_valid,
#                 result_pass, scenario[3:0], pass_bitmap[15:0] }
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
proc running {} { scan [probe] %x v; return [expr {($v >> 22) & 1}] }
proc done_ct {} { scan [probe] %x v; return [expr {($v >> 32) & 0xF}] }

# Poll rather than sleep a fixed time. A fixed delay that happens to be long
# enough today silently stops being long enough when a scenario's length
# changes - with the programmed timeout, or with the build.
proc wait_for {want {tries 200}} {
    for {set i 0} {$i < $tries} {incr i} {
        after 50
        if {[running] == $want} { return 1 }
    }
    return 0
}
proc wait_idle {{tries 200}} { return [wait_for 0 $tries] }

# Run one scenario in step mode. `sel` is the scenario number; the source
# register carries { -, start, freeze, auto, select[3:0] }.
#
# Two separate hazards are handled here, and they are not the same thing.
#
# 1. THE SOURCE REGISTER IS NOT WRITTEN ATOMICALLY. altsource_probe shifts the
#    value in over JTAG bit by bit and it reaches the fabric as it lands, so a
#    start edge can arrive while the select bits are still half-updated - and
#    a DIFFERENT scenario runs than the one asked for. The design now filters
#    the source word (see src_stable in the top level); writing the select
#    first, and letting it settle, is the other half of that.
#
# 2. `running` IS A LEVEL AND CANNOT BE RELIED ON. A JTAG probe read takes
#    tens of milliseconds while most scenarios finish in microseconds, so the
#    host frequently never observes `running` high at all - it asks "did it
#    start?" and the answer is already "it finished". Waiting on that edge is
#    racing by construction.
#
#    So the wait is on done_count MOVING instead. It increments once per
#    completed scenario and never decrements, which has no such window.
proc run_scenario {sel {tries 200}} {
    set before [done_ct]
    src [format "%02X" $sel]
    wait_idle
    after 200
    src [format "%02X" [expr {0x40 | $sel}]]     ;# start, held
    set started 0
    for {set i 0} {$i < 40} {incr i} {
        after 50
        if {[running] == 1 || [done_ct] != $before} { set started 1; break }
    }
    src [format "%02X" $sel]                     ;# release start
    if {!$started} { return 0 }
    for {set i 0} {$i < $tries} {incr i} {
        after 50
        if {[done_ct] != $before && [running] == 0} { after 100; return 1 }
    }
    return 0
}

proc show  {tag} {
    set d [probe]
    puts [format "  %-16s bitmap=%04X scenario=%X pass=%d valid=%d running=%d status=%03X" \
          $tag [field $d 15 0] [field $d 19 16] [field $d 20 20] [field $d 21 21] \
          [field $d 22 22] [field $d 31 23]]
}

puts "\n--- state at power-up ---"
show "idle"
puts "  (scenario 0 runs by itself so a hand-picked scenario finds a"
puts "   programmed rule table; bitmap 0001 is correct here)"

puts "\n--- auto sweep, driven over JTAG ---"
src 10
after 200
set ok 0
for {set i 1} {$i <= 100} {incr i} {
    after 250
    if {[field [probe] 15 0] == 65535} { set ok 1; break }
}
show "after sweep"
src 00
wait_idle

# Step mode: run one scenario on demand and confirm only that one ran.
puts "\n--- step mode: run scenario 9 (timeout) on its own ---"
set started [run_scenario 9]
show "scenario 9"
set scen [field [probe] 19 16]
set pass [field [probe] 20 20]
if {!$started} { puts "  (the design never acknowledged the start request)" }
src 00
end_insystem_source_probe

puts "\n============================================================"
set rc 0
if {$ok} { puts "PASS: all 16 scenarios passed in the sweep (bitmap = FFFF)" } \
else     { puts "FAIL: the sweep never reached FFFF"; set rc 1 }
if {$started && $scen == 9 && $pass == 1} { puts "PASS: step mode ran exactly scenario 9, and it passed" } \
else                          { puts "FAIL: step mode ran scenario $scen, pass=$pass"; set rc 1 }
puts [expr {$rc == 0 ? "RESULT: PASSED ON HARDWARE" : "RESULT: FAILED"}]
exit $rc
