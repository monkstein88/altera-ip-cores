package require -exact qsys 14.0

# =============================================================================
# avl_mm_firewall_hw.tcl
#
# Platform Designer / Qsys component description for avl_mm_firewall_top.
#
# Modelled on altera_avalon_mm_bridge's component, because that is the closest
# thing in the stock catalog to what this core is structurally: a transparent,
# burst-capable Avalon-MM pass-through with a slave on one side and a master on
# the other. The two properties that matter most are inherited from it:
#
#   bridgesToMaster   - tells Platform Designer that s0's address space IS m0's
#                       address space. Without it the firewall would be an
#                       ordinary slave needing its own address assignment, and
#                       the protected peripheral would move when you inserted
#                       the firewall in front of it. With it, dropping this
#                       core into an existing path changes no addresses at all.
#   addressUnits      - SYMBOLS (bytes) on the data path so rule base/limit
#                       values are the byte addresses software already knows,
#                       and WORDS on the CSR port, which is the Platform
#                       Designer default for a slave and what every stock
#                       Altera register peripheral uses.
#
# IMPORTANT: hand-written hw.tcl syntax has drifted across Quartus versions
# (Standard vs Pro, and release to release - see Intel's "_hw.tcl Command
# Reference" for your installed version). This file is a complete, best-effort
# starting point, not a guaranteed drop-in for every Quartus release.
#
# The robust way to package this component, recommended over trusting this file
# blindly:
#   1. In Platform Designer, Component Editor -> add the three files under
#      rtl/ as synthesis files, set avl_mm_firewall_top.sv as the top-level file,
#      then "Analyze Synthesis Files".
#   2. Because every port follows the s0_*/m0_*/csr_* convention with standard
#      Avalon-MM signal names, Platform Designer's signal analysis should
#      auto-group them into two Avalon-MM slaves, one Avalon-MM master, a
#      clock, a reset and an interrupt sender. Fix up anything it does not
#      infer in "Signals & Interfaces" - in particular set bridgesToMaster on
#      s0, which signal analysis cannot guess.
#   3. File -> Save / Export as hw.tcl Component to get a file guaranteed
#      correct for your exact installed version.
# =============================================================================

set_module_property NAME altera_avalon_mm_firewall
set_module_property DISPLAY_NAME "Avalon-MM Firewall"
set_module_property DESCRIPTION "Burst-capable access-control and fault-isolation firewall for an Avalon-MM slave, with a separate control/status port and an interrupt output."
set_module_property VERSION 1.0
set_module_property GROUP "Bridges and Adapters/Custom"
set_module_property AUTHOR "monkstein88"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE false
set_module_property ELABORATION_CALLBACK elaborate
set_module_property VALIDATION_CALLBACK validate

# -----------------------------------------------------------------------
# Files
#
# The TYPE argument must be SYSTEM_VERILOG, not VERILOG. The RTL uses `logic`,
# always_ff/always_comb, packed structs, enums and a package; declaring it as
# VERILOG makes Quartus analyse it with the Verilog-2001 parser, which fails on
# the first `logic` declaration.
#
# avl_mm_firewall_pkg.sv MUST be listed first - it defines the types the other
# two import. The SIM fileset is still named SIM_VERILOG; that is the
# fileset's name in Platform Designer, independent of the language of the
# files inside it.
# -----------------------------------------------------------------------
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH generate_synth_files ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL avl_mm_firewall_top
add_fileset_file avl_mm_firewall_pkg.sv  SYSTEM_VERILOG PATH rtl/avl_mm_firewall_pkg.sv
add_fileset_file avl_mm_firewall_regs.sv SYSTEM_VERILOG PATH rtl/avl_mm_firewall_regs.sv
add_fileset_file avl_mm_firewall_top.sv  SYSTEM_VERILOG PATH rtl/avl_mm_firewall_top.sv TOP_LEVEL_FILE

add_fileset SIM_VERILOG SIM_VERILOG generate_sim_files ""
set_fileset_property SIM_VERILOG TOP_LEVEL avl_mm_firewall_top
add_fileset_file avl_mm_firewall_pkg.sv  SYSTEM_VERILOG PATH rtl/avl_mm_firewall_pkg.sv
add_fileset_file avl_mm_firewall_regs.sv SYSTEM_VERILOG PATH rtl/avl_mm_firewall_regs.sv
add_fileset_file avl_mm_firewall_top.sv  SYSTEM_VERILOG PATH rtl/avl_mm_firewall_top.sv TOP_LEVEL_FILE

proc generate_synth_files {entity_name} { }
proc generate_sim_files {entity_name} { }

# -----------------------------------------------------------------------
# Parameters
# -----------------------------------------------------------------------
add_parameter ADDR_WIDTH INTEGER 32
set_parameter_property ADDR_WIDTH DISPLAY_NAME "Data-path address width"
set_parameter_property ADDR_WIDTH UNITS bits
set_parameter_property ADDR_WIDTH ALLOWED_RANGES {8:32}
set_parameter_property ADDR_WIDTH HDL_PARAMETER true
set_parameter_property ADDR_WIDTH DESCRIPTION "Byte address width of s0 and m0. Rule base/limit registers are this wide."

add_parameter DATA_WIDTH INTEGER 32
set_parameter_property DATA_WIDTH DISPLAY_NAME "Data-path data width"
set_parameter_property DATA_WIDTH UNITS bits
set_parameter_property DATA_WIDTH ALLOWED_RANGES {8 16 32 64 128 256 512 1024}
set_parameter_property DATA_WIDTH HDL_PARAMETER true

add_parameter BURST_WIDTH INTEGER 8
set_parameter_property BURST_WIDTH DISPLAY_NAME "Burstcount width"
set_parameter_property BURST_WIDTH UNITS bits
set_parameter_property BURST_WIDTH ALLOWED_RANGES {1:11}
set_parameter_property BURST_WIDTH HDL_PARAMETER true
set_parameter_property BURST_WIDTH DESCRIPTION "Maximum burst is 2^(BURST_WIDTH-1) beats. 1 means no bursting; 8 gives 128 beats, which matches a typical mSGDMA. Set this to match the master in front of the firewall - making it larger than the master needs only widens the range comparators."

add_parameter MAX_PENDING_READS INTEGER 4
set_parameter_property MAX_PENDING_READS DISPLAY_NAME "Maximum pending read transactions"
set_parameter_property MAX_PENDING_READS ALLOWED_RANGES {1:32}
set_parameter_property MAX_PENDING_READS HDL_PARAMETER true
set_parameter_property MAX_PENDING_READS DESCRIPTION "How many read bursts may be outstanding through the firewall at once. Sets the width of the outstanding-beat counter and is published to Platform Designer on both s0 and m0. 1 makes reads strictly non-pipelined."

add_parameter NUM_RULES INTEGER 8
set_parameter_property NUM_RULES DISPLAY_NAME "Number of address-range rules"
set_parameter_property NUM_RULES ALLOWED_RANGES {1:64}
set_parameter_property NUM_RULES HDL_PARAMETER true
set_parameter_property NUM_RULES DESCRIPTION "Rule lookup is combinational and all NUM_RULES comparators are in the critical path. Use the smallest number that covers your address map."

add_parameter TIMEOUT_WIDTH INTEGER 20
set_parameter_property TIMEOUT_WIDTH DISPLAY_NAME "Timeout counter width"
set_parameter_property TIMEOUT_WIDTH UNITS bits
set_parameter_property TIMEOUT_WIDTH ALLOWED_RANGES {8:32}
set_parameter_property TIMEOUT_WIDTH HDL_PARAMETER true
set_parameter_property TIMEOUT_WIDTH DESCRIPTION "Maximum programmable timeout is 2^TIMEOUT_WIDTH - 1 clock cycles. The timeout measures cycles WITHOUT PROGRESS, not total transaction length, so it does not need to be scaled by the longest burst."

add_parameter CSR_ADDR_WIDTH INTEGER 8
set_parameter_property CSR_ADDR_WIDTH DISPLAY_NAME "Control/status port address width"
set_parameter_property CSR_ADDR_WIDTH UNITS bits
set_parameter_property CSR_ADDR_WIDTH ALLOWED_RANGES {5:16}
set_parameter_property CSR_ADDR_WIDTH HDL_PARAMETER true
set_parameter_property CSR_ADDR_WIDTH DESCRIPTION "In WORDS, because the CSR port is word-addressed. Must cover word 0x10 + NUM_RULES*4, i.e. byte 0x40 + NUM_RULES*16."

add_parameter USE_RESPONSE INTEGER 1
set_parameter_property USE_RESPONSE DISPLAY_NAME "Expose the response signal"
set_parameter_property USE_RESPONSE ALLOWED_RANGES {0 1}
set_parameter_property USE_RESPONSE HDL_PARAMETER false
set_parameter_property USE_RESPONSE DESCRIPTION "Adds the 2-bit Avalon-MM response signal to s0 and m0, so a denied or timed-out access is reported to the master as DECODEERROR or SLAVEERROR. Without it a denied read still returns the right number of beats, but they read as zeros with no error indication - the violation is then visible only through the interrupt and STATUS. Turn this off only for a master that cannot accept response."

add_parameter USE_WRITE_RESPONSE INTEGER 0
set_parameter_property USE_WRITE_RESPONSE DISPLAY_NAME "Expose writeresponsevalid"
set_parameter_property USE_WRITE_RESPONSE ALLOWED_RANGES {0 1}
set_parameter_property USE_WRITE_RESPONSE HDL_PARAMETER true
set_parameter_property USE_WRITE_RESPONSE DESCRIPTION "Adds write responses. Requires USE_RESPONSE. Nios II does not use them; an mSGDMA can. With write responses off, a write is complete once its last beat is accepted, so the write timeout detects only a stuck waitrequest - which is the usual Avalon-MM hang anyway."

# -----------------------------------------------------------------------
# Clock / reset
# -----------------------------------------------------------------------
add_interface clock clock end
set_interface_property clock clockRate 0
add_interface_port clock clk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset reset_n reset_n Input 1

# -----------------------------------------------------------------------
# s0 - protected data-path slave (toward the master)
#
# readLatency 0 with readdatavalid present means "variable latency, pipelined"
# - the correct profile for a port whose latency is inherited from whatever is
# downstream. Wait-state properties are 0 because waitrequest carries the
# timing, which is also why waitrequest may be combinationally dependent on
# read/write here (the Avalon spec permits exactly this for a slave).
# -----------------------------------------------------------------------
add_interface s0 avalon end
set_interface_property s0 addressUnits SYMBOLS
set_interface_property s0 burstcountUnits WORDS
set_interface_property s0 associatedClock clock
set_interface_property s0 associatedReset reset
set_interface_property s0 bridgesToMaster m0
set_interface_property s0 linewrapBursts false
set_interface_property s0 burstOnBurstBoundariesOnly false
set_interface_property s0 constantBurstBehavior false
set_interface_property s0 alwaysBurstMaxBurst false
set_interface_property s0 holdTime 0
set_interface_property s0 readLatency 0
set_interface_property s0 readWaitTime 0
set_interface_property s0 writeWaitTime 0
set_interface_property s0 setupTime 0
set_interface_property s0 timingUnits Cycles

add_interface_port s0 s0_address      address      Input  ADDR_WIDTH
add_interface_port s0 s0_read         read         Input  1
add_interface_port s0 s0_write        write        Input  1
add_interface_port s0 s0_writedata    writedata    Input  DATA_WIDTH
add_interface_port s0 s0_byteenable   byteenable   Input  DATA_WIDTH/8
add_interface_port s0 s0_burstcount   burstcount   Input  BURST_WIDTH
add_interface_port s0 s0_waitrequest  waitrequest  Output 1
add_interface_port s0 s0_readdata     readdata     Output DATA_WIDTH
add_interface_port s0 s0_readdatavalid readdatavalid Output 1

# -----------------------------------------------------------------------
# m0 - protected data-path master (toward the peripheral being guarded)
# -----------------------------------------------------------------------
add_interface m0 avalon start
set_interface_property m0 addressUnits SYMBOLS
set_interface_property m0 burstcountUnits WORDS
set_interface_property m0 associatedClock clock
set_interface_property m0 associatedReset reset
set_interface_property m0 linewrapBursts false
set_interface_property m0 burstOnBurstBoundariesOnly false
set_interface_property m0 constantBurstBehavior false
set_interface_property m0 alwaysBurstMaxBurst false
set_interface_property m0 doStreamReads false
set_interface_property m0 doStreamWrites false
set_interface_property m0 holdTime 0
set_interface_property m0 readLatency 0
set_interface_property m0 readWaitTime 0
set_interface_property m0 writeWaitTime 0
set_interface_property m0 setupTime 0
set_interface_property m0 timingUnits Cycles

add_interface_port m0 m0_address      address      Output ADDR_WIDTH
add_interface_port m0 m0_read         read         Output 1
add_interface_port m0 m0_write        write        Output 1
add_interface_port m0 m0_writedata    writedata    Output DATA_WIDTH
add_interface_port m0 m0_byteenable   byteenable   Output DATA_WIDTH/8
add_interface_port m0 m0_burstcount   burstcount   Output BURST_WIDTH
add_interface_port m0 m0_waitrequest  waitrequest  Input  1
add_interface_port m0 m0_readdata     readdata     Input  DATA_WIDTH
add_interface_port m0 m0_readdatavalid readdatavalid Input 1

# -----------------------------------------------------------------------
# csr - control/status slave (rule table, status, irq enable, recovery)
#
# The classic Altera register-peripheral profile: word-addressed, 32-bit,
# fixed read latency of 1, no waitrequest, no readdatavalid. It is deliberately
# the dullest possible Avalon-MM port, because it has to stay reachable when
# the data path is isolated or wedged.
# -----------------------------------------------------------------------
add_interface csr avalon end
set_interface_property csr addressUnits WORDS
set_interface_property csr associatedClock clock
set_interface_property csr associatedReset reset
set_interface_property csr bridgesToMaster ""
set_interface_property csr holdTime 0
set_interface_property csr readLatency 1
set_interface_property csr readWaitTime 0
set_interface_property csr writeWaitTime 0
set_interface_property csr setupTime 0
set_interface_property csr timingUnits Cycles
set_interface_property csr maximumPendingReadTransactions 0

add_interface_port csr csr_address    address    Input  CSR_ADDR_WIDTH
add_interface_port csr csr_read       read       Input  1
add_interface_port csr csr_write      write      Input  1
add_interface_port csr csr_writedata  writedata  Input  32
add_interface_port csr csr_byteenable byteenable Input  4
add_interface_port csr csr_readdata   readdata   Output 32

# -----------------------------------------------------------------------
# irq - level interrupt, stays asserted until the causing STATUS bit(s) are
# cleared (write-1-to-clear) over the csr port
# -----------------------------------------------------------------------
add_interface irq interrupt end
set_interface_property irq associatedClock clock
set_interface_property irq associatedReset reset
set_interface_property irq associatedAddressablePoint csr
add_interface_port irq irq irq Output 1

# -----------------------------------------------------------------------
# Elaboration - everything whose presence, rather than width, depends on a
# parameter.
#
# response and writeresponsevalid are added here rather than declared
# unconditionally above because Platform Designer matches slave and master
# signal sets when it builds the interconnect. A slave advertising
# writeresponsevalid to a master that has no concept of it is a needless
# adapter at best; the stock altera_avalon_mm_bridge gates the same two
# signals on the same two parameters for the same reason.
#
# The HDL always drives s0_response and s0_writeresponsevalid. When they are
# not added here they are simply left dangling, which is harmless - the
# behaviour they describe (a denied read still returning the right number of
# beats) does not depend on anyone listening.
# -----------------------------------------------------------------------
proc elaborate {} {
    set use_resp  [get_parameter_value USE_RESPONSE]
    set use_wresp [get_parameter_value USE_WRITE_RESPONSE]
    set pending   [get_parameter_value MAX_PENDING_READS]

    # Published on both ports so the interconnect sizes its own pipelining to
    # match. The core tracks exactly this many read bursts' worth of beats and
    # backpressures s0 beyond it, so advertising a larger number upstream than
    # the core can absorb would just turn into avoidable stalling.
    set_interface_property s0 maximumPendingReadTransactions $pending
    set_interface_property m0 maximumPendingReadTransactions $pending

    if {$use_resp} {
        add_interface_port s0 s0_response response Output 2
        add_interface_port m0 m0_response response Input  2

        if {$use_wresp} {
            add_interface_port s0 s0_writeresponsevalid writeresponsevalid Output 1
            add_interface_port m0 m0_writeresponsevalid writeresponsevalid Input  1
        }
    }
}

# -----------------------------------------------------------------------
# Validation
#
# Three ways to configure this core into something that elaborates, simulates
# and is quietly wrong. All three are cheap to catch here and expensive to
# find on hardware.
# -----------------------------------------------------------------------
proc validate {} {
    set nr    [get_parameter_value NUM_RULES]
    set caw   [get_parameter_value CSR_ADDR_WIDTH]
    set aw    [get_parameter_value ADDR_WIDTH]
    set dw    [get_parameter_value DATA_WIDTH]
    set bw    [get_parameter_value BURST_WIDTH]
    set uresp [get_parameter_value USE_RESPONSE]
    set uwr   [get_parameter_value USE_WRITE_RESPONSE]

    # ---- 1. the CSR port must be able to reach every rule ----
    # Rule table starts at word 0x10 and takes 4 words per rule.
    set span [expr {0x10 + $nr * 4}]

    # Integer ceil-log2 by shifting, not int(ceil(log(x)/log(2))). The
    # floating-point form gives the right answer for every NUM_RULES in the
    # allowed range on the platforms tested, but it relies on log(x)/log(2)
    # never landing a hair above an integer for exact powers of two - a
    # property of the host libm, not of Tcl. Shifting has no such dependency.
    set need 0
    while {(1 << $need) < $span} { incr need }

    if {$caw < $need} {
        set last [expr {((1 << $caw) - 0x10) / 4 - 1}]
        send_message error \
            "CSR_ADDR_WIDTH=$caw is too small for NUM_RULES=$nr: the rule table ends at word $span and needs at least $need address bits. Rules above index $last would be unreachable."
    }

    # ---- 2. a maximum-length burst must fit inside the address space ----
    # The core computes last_byte = address + burstcount*bytes_per_beat - 1 in
    # ADDR_WIDTH+1 bits. If a single maximum burst can span the whole space,
    # that sum is meaningless and the range check silently stops protecting
    # anything.
    set beat_shift 0
    while {(1 << $beat_shift) < ($dw / 8)} { incr beat_shift }
    set need_addr [expr {$bw - 1 + $beat_shift}]
    if {$aw < $need_addr} {
        send_message error \
            "ADDR_WIDTH=$aw is too small: a maximum burst of [expr {1 << ($bw-1)}] beats x [expr {$dw/8}] bytes spans [expr {1 << $need_addr}] bytes, which needs at least $need_addr address bits."
    }

    # ---- 3. write responses need a response signal to travel on ----
    if {$uwr && !$uresp} {
        send_message error \
            "USE_WRITE_RESPONSE requires USE_RESPONSE: writeresponsevalid qualifies the response signal, and without response there is nothing for it to qualify."
    }

    # ---- advisory ----
    if {!$uresp} {
        send_message info \
            "USE_RESPONSE is off. Denied and timed-out accesses will complete silently - a denied read returns the correct number of beats, but reading as zeros with no error status. Violations will be visible only through the irq output and the STATUS register."
    }
    if {$bw == 1} {
        send_message info \
            "BURST_WIDTH is 1, so s0 and m0 are non-bursting. The RULE_PERM.BURST_ALLOW bit and the burst range check have no effect in this configuration."
    }
}
