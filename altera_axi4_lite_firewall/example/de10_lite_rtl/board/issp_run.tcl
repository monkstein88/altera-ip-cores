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
# probe[31:0] = { status[8:0], running, result_valid, result_pass,
#                 scenario[3:0], pass_bitmap[15:0] }
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
set ok 0
for {set i 1} {$i <= 100} {incr i} {
    after 250
    if {[field [probe] 15 0] == 65535} { set ok 1; break }
}
show "after sweep"
src 00

# Step mode: run one scenario on demand and confirm only that one ran.
puts "\n--- step mode: run scenario 9 (timeout) on its own ---"
src 09
after 200
src 49
after 200
src 09
after 1500
show "scenario 9"
set scen [field [probe] 19 16]
set pass [field [probe] 20 20]
src 00
end_insystem_source_probe

puts "\n============================================================"
set rc 0
if {$ok} { puts "PASS: all 16 scenarios passed in the sweep (bitmap = FFFF)" } \
else     { puts "FAIL: the sweep never reached FFFF"; set rc 1 }
if {$scen == 9 && $pass == 1} { puts "PASS: step mode ran exactly scenario 9, and it passed" } \
else                          { puts "FAIL: step mode ran scenario $scen, pass=$pass"; set rc 1 }
puts [expr {$rc == 0 ? "RESULT: PASSED ON HARDWARE" : "RESULT: FAILED"}]
exit $rc
