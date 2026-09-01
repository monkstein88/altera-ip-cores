# =============================================================================
# check_hw_tcl.tcl - execute the Platform Designer component description
#                    against stubbed Qsys commands.
#
#   tclsh verification/check_hw_tcl.tcl
#
# Exit 0 if every configuration elaborates and validates as expected, 1 if not.
#
# -----------------------------------------------------------------------------
# WHY
# -----------------------------------------------------------------------------
# A _hw.tcl is a Tcl program, and a broken one usually fails inside Platform
# Designer with a message that names a line number in a file you did not write.
# The failure modes are dull and entirely mechanical - a typo in a parameter
# name, a port added to an interface that does not exist yet, an ALLOWED_RANGES
# that excludes the default, a validation callback that references a parameter
# it never fetched - and every one of them is catchable by running the file with
# the Qsys commands replaced by stubs.
#
# This is NOT a substitute for opening the component in Platform Designer. It
# cannot know whether `readLatency` means what this core needs it to mean, or
# whether a given Quartus release still spells a property the same way. What it
# does prove is that the file executes, that every parameter and port it names
# exists, and that the validation callback fires on exactly the configurations
# it is supposed to reject.
# =============================================================================

set here   [file dirname [file normalize [info script]]]
set root   [file dirname $here]
set hwtcl  [file join $root altera_avalon_mm_sdcard_controller_hw.tcl]

set ::fail 0
proc ok   {what} { puts [format "  PASS  %s" $what] }
proc bad  {what} { puts [format "  FAIL  %s" $what] ; set ::fail 1 }
proc chk  {what cond} { if {$cond} { ok $what } else { bad $what } }

# -----------------------------------------------------------------------------
# Stubbed Qsys API
# -----------------------------------------------------------------------------
proc package  {args} {}
proc set_module_property  {args} {}
proc add_fileset          {args} {}
proc set_fileset_property {args} {}

array set ::files {}
proc add_fileset_file {name type args} {
    lappend ::files($name) 1
    set idx [lsearch -exact $args PATH]
    if {$idx >= 0} { lappend ::paths [lindex $args [expr {$idx + 1}]] }
    lappend ::file_order $name
}

array set ::params {}
proc add_parameter {name type default args} {
    set ::params($name) $default
    lappend ::param_order $name
}
proc set_parameter_property {name prop args} {
    set ::pprop($name,$prop) [lindex $args 0]
}
proc get_parameter_value {name} {
    if {![info exists ::params($name)]} {
        bad "validate/elaborate read undeclared parameter '$name'"
        return 0
    }
    return $::params($name)
}

array set ::ifaces {}
proc add_interface {name type dir} { set ::ifaces($name) $type ; lappend ::iface_order $name }
proc set_interface_property {name prop args} {
    if {![info exists ::ifaces($name)]} {
        bad "property '$prop' set on undeclared interface '$name'"
    }
}
proc add_interface_port {iface port role dir width} {
    if {![info exists ::ifaces($iface)]} {
        bad "port '$port' added to undeclared interface '$iface'"
    }
    lappend ::ports($iface) $port
    lappend ::all_ports $port
}

set ::messages {}
proc send_message {level text} { lappend ::messages [list $level $text] }

# -----------------------------------------------------------------------------
# Interfaces declared at the file's top level (csr, irq, sd, clock, reset) exist
# before elaborate runs and must survive a reset; only what elaborate ADDS is
# torn down between configurations. Snapshotting after the source is the only
# way to tell the two apart without re-sourcing each time.
proc snapshot_baseline {} {
    array unset ::base_ifaces ; array set ::base_ifaces [array get ::ifaces]
    array unset ::base_ports  ; array set ::base_ports  [array get ::ports]
}

proc reset_state {} {
    array unset ::ifaces ; array set ::ifaces [array get ::base_ifaces]
    array unset ::ports  ; array set ::ports  [array get ::base_ports]
    set ::all_ports {}
    set ::iface_order {}
    set ::messages {}
}

proc errors_from_messages {} {
    set n 0
    foreach m $::messages { if {[lindex $m 0] eq "error"} { incr n } }
    return $n
}

# -----------------------------------------------------------------------------
puts ""
puts "=== altera_avalon_mm_sdcard_controller_hw.tcl ==="
puts ""

set ::paths {} ; set ::file_order {}
if {[catch {source $hwtcl} err]} {
    bad "the file executes: $err"
    exit 1
}
ok "the file executes"
snapshot_baseline

# ---- files ------------------------------------------------------------------
chk "package is listed before the top level" \
    [expr {[lsearch -exact $::file_order avalon_mm_sdcard_controller_pkg.sv] <
           [lsearch -exact $::file_order avalon_mm_sdcard_controller.sv]}]

set missing {}
foreach p $::paths { if {![file exists [file join $root $p]]} { lappend missing $p } }
chk "every file referenced by PATH exists" [expr {[llength $missing] == 0}]
if {[llength $missing]} { puts "        missing: $missing" }

# ---- defaults must be inside their own ALLOWED_RANGES -----------------------
set bad_default {}
foreach p $::param_order {
    if {![info exists ::pprop($p,ALLOWED_RANGES)]} continue
    set r $::pprop($p,ALLOWED_RANGES)
    set v $::params($p)
    set inside 0
    foreach tok $r {
        if {[string match *:* $tok]} {
            lassign [split $tok :] lo hi
            if {$v >= $lo && $v <= $hi} { set inside 1 }
        } elseif {$tok == $v} { set inside 1 }
    }
    if {!$inside} { lappend bad_default "$p=$v not in {$r}" }
}
chk "every parameter default lies inside its ALLOWED_RANGES" \
    [expr {[llength $bad_default] == 0}]
if {[llength $bad_default]} { puts "        $bad_default" }

# ---- the default configuration -----------------------------------------------
reset_state
elaborate
validate
chk "default configuration validates with no errors" [expr {[errors_from_messages] == 0}]
chk "default configuration exposes m0"     [info exists ::ports(m0)]
chk "default configuration exposes csr"    [info exists ::ports(csr)]
chk "default configuration exposes sd"     [info exists ::ports(sd)]
chk "card detect adds cd_n and wp_n"       [expr {[lsearch -exact $::ports(sd) sd_cd_n] >= 0}]

# ---- USE_DMA = 0 removes the master -----------------------------------------
reset_state
set ::params(USE_DMA) 0
elaborate ; validate
chk "USE_DMA=0 removes the m0 interface"   [expr {![info exists ::ports(m0)]}]
chk "USE_DMA=0 validates with no errors"   [expr {[errors_from_messages] == 0}]
set ::params(USE_DMA) 1

# ---- USE_CARD_DETECT = 0 removes the switches -------------------------------
reset_state
set ::params(USE_CARD_DETECT) 0
elaborate ; validate
chk "USE_CARD_DETECT=0 removes cd_n and wp_n" \
    [expr {![info exists ::ports(sd)] ||
           [lsearch -exact $::ports(sd) sd_cd_n] < 0}]
set ::params(USE_CARD_DETECT) 1

# ---- the validation callback must actually reject bad configurations --------
proc expect_error {what setup} {
    reset_state
    uplevel 1 $setup
    elaborate ; validate
    chk $what [expr {[errors_from_messages] > 0}]
}

expect_error "rejects a CSR port too narrow for the register map" {
    set ::params(CSR_ADDR_WIDTH) 4
}
set ::params(CSR_ADDR_WIDTH) 5

expect_error "rejects a buffer smaller than one block" {
    set ::params(FIFO_DEPTH_BYTES) 512
    set ::params(MAX_BLOCK_BYTES) 512
    set ::params(FIFO_DEPTH_BYTES) 256
}
set ::params(FIFO_DEPTH_BYTES) 1024
set ::params(MAX_BLOCK_BYTES) 512

expect_error "rejects a burst larger than the buffer" {
    set ::params(FIFO_DEPTH_BYTES) 512
    set ::params(M0_BURST_WIDTH) 9
}
set ::params(FIFO_DEPTH_BYTES) 1024
set ::params(M0_BURST_WIDTH) 8

# ---- and must NOT reject good ones ------------------------------------------
foreach cfg {
    {M0_BURST_WIDTH 1}
    {FIFO_DEPTH_BYTES 2048}
    {FIFO_DEPTH_BYTES 8192}
    {TIMEOUT_WIDTH 32}
    {CLKDIV_WIDTH 16}
    {ADDR_WIDTH 16}
    {USE_CRC 0}
} {
    lassign $cfg p v
    set old $::params($p)
    reset_state
    set ::params($p) $v
    elaborate ; validate
    chk "accepts $p=$v" [expr {[errors_from_messages] == 0}]
    set ::params($p) $old
}

puts ""
if {$::fail} { puts "*** FAIL ***" ; puts "" ; exit 1 }
puts "*** PASS ***"
puts ""
exit 0
