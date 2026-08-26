# =============================================================================
# demo_avl_mm_target_slave_hw.tcl
#
# Platform Designer component wrapper for demo_avl_mm_target_slave.sv - the peripheral
# the Avalon-MM Firewall protects in the DE10-Lite examples.
#
# Used by the Nios II example, which needs the peripheral as a Qsys component
# so the generated interconnect can wire it to the firewall's m0 port. The
# pure-RTL example instantiates the module directly and does not need this.
#
# The fault-injection inputs and the software-controlled reset are exported as
# conduits, so the Nios II system can drive them from PIOs exactly as a driver
# would drive a real peripheral's reset line.
# =============================================================================

package require -exact qsys 16.0

set_module_property NAME         demo_avl_mm_target_slave
set_module_property DISPLAY_NAME "Demo Target Slave (Avalon-MM, burst capable)"
set_module_property VERSION      1.0
set_module_property GROUP        "Bridges and Adapters/Custom"
set_module_property DESCRIPTION  "Burst-capable Avalon-MM scratchpad with injectable faults, for demonstrating the Avalon-MM Firewall"
set_module_property AUTHOR       "altera-ip-cores"
set_module_property EDITABLE                    false
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property VALIDATION_CALLBACK         validate

add_fileset synth_fileset QUARTUS_SYNTH generate_synth_files
set_fileset_property synth_fileset TOP_LEVEL demo_avl_mm_target_slave
add_fileset_file demo_avl_mm_target_slave.sv SYSTEM_VERILOG PATH demo_avl_mm_target_slave.sv TOP_LEVEL_FILE

add_fileset sim_verilog_fileset SIM_VERILOG generate_sim_files
set_fileset_property sim_verilog_fileset TOP_LEVEL demo_avl_mm_target_slave
add_fileset_file demo_avl_mm_target_slave.sv SYSTEM_VERILOG PATH demo_avl_mm_target_slave.sv TOP_LEVEL_FILE

proc generate_synth_files {entity_name} { }
proc generate_sim_files   {entity_name} { }

# -----------------------------------------------------------------------
# Parameters
# -----------------------------------------------------------------------
add_parameter ADDR_WIDTH INTEGER 12
set_parameter_property ADDR_WIDTH DISPLAY_NAME "Address width (bits)"
set_parameter_property ADDR_WIDTH ALLOWED_RANGES {8:32}
set_parameter_property ADDR_WIDTH HDL_PARAMETER true

add_parameter DATA_WIDTH INTEGER 32
set_parameter_property DATA_WIDTH DISPLAY_NAME "Data width (bits)"
set_parameter_property DATA_WIDTH ALLOWED_RANGES {8 16 32 64 128}
set_parameter_property DATA_WIDTH HDL_PARAMETER true

add_parameter BURST_WIDTH INTEGER 8
set_parameter_property BURST_WIDTH DISPLAY_NAME "Burstcount width (bits)"
set_parameter_property BURST_WIDTH ALLOWED_RANGES {1:11}
set_parameter_property BURST_WIDTH HDL_PARAMETER true

add_parameter MEM_WORDS INTEGER 64
set_parameter_property MEM_WORDS DISPLAY_NAME "Scratchpad depth (words)"
set_parameter_property MEM_WORDS ALLOWED_RANGES {4:1024}
set_parameter_property MEM_WORDS HDL_PARAMETER true

add_parameter USE_WRITE_RESPONSE INTEGER 1
set_parameter_property USE_WRITE_RESPONSE DISPLAY_NAME "Return write responses"
set_parameter_property USE_WRITE_RESPONSE ALLOWED_RANGES {0 1}
set_parameter_property USE_WRITE_RESPONSE HDL_PARAMETER true

# -----------------------------------------------------------------------
# Clock and resets
#
# Two reset sinks, and they are not interchangeable. `reset` is the system
# reset that Platform Designer ties into its reset network. `soft_reset` is the
# PERIPHERAL's own reset, under software control - a reset bridge or a PIO bit
# in a real system. Recovering the firewall from a timeout requires resetting
# the peripheral, and the core deliberately does not do that for you.
# -----------------------------------------------------------------------
add_interface clock clock end
set_interface_property clock clockRate 0
add_interface_port clock clk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset resetn reset_n Input 1

# -----------------------------------------------------------------------
# Avalon-MM slave
#
# readLatency 0 with readdatavalid present means variable latency, pipelined -
# the profile a bursting slave needs. linewrapBursts false matches the
# firewall's own declaration on both its ports.
# -----------------------------------------------------------------------
add_interface s0 avalon end
set_interface_property s0 associatedClock clock
set_interface_property s0 associatedReset reset
set_interface_property s0 addressUnits         SYMBOLS
set_interface_property s0 bridgesToMaster      ""
set_interface_property s0 burstOnBurstBoundariesOnly false
set_interface_property s0 linewrapBursts       false
set_interface_property s0 explicitAddressSpan  0
set_interface_property s0 holdTime             0
set_interface_property s0 readLatency          0
set_interface_property s0 maximumPendingReadTransactions 1
set_interface_property s0 setupTime            0
set_interface_property s0 timingUnits          Cycles

add_interface_port s0 s_address            address            Input  ADDR_WIDTH
add_interface_port s0 s_read               read               Input  1
add_interface_port s0 s_write              write              Input  1
add_interface_port s0 s_writedata          writedata          Input  DATA_WIDTH
add_interface_port s0 s_byteenable         byteenable         Input  DATA_WIDTH/8
add_interface_port s0 s_burstcount         burstcount         Input  BURST_WIDTH
add_interface_port s0 s_waitrequest        waitrequest        Output 1
add_interface_port s0 s_readdata           readdata           Output DATA_WIDTH
add_interface_port s0 s_readdatavalid      readdatavalid      Output 1
add_interface_port s0 s_response           response           Output 2

# -----------------------------------------------------------------------
# Fault injection conduit
#
# Driven from a PIO in the Nios II system. Two bits, and the difference
# between them is the whole reason this peripheral exists: `hang` alone wedges
# the command handshake (-> *_CMD_STUCK), `hang` with `hang_late` accepts the
# command and then never answers (-> *_BUSY).
# -----------------------------------------------------------------------
# The software-controlled peripheral reset rides on this conduit rather than
# being a reset sink. It has to be pokeable by software - recovering the
# firewall from a timeout means resetting the peripheral, and the core
# deliberately does not do that for you - so it is driven from a PIO bit, and
# Platform Designer cannot wire a PIO output into a reset sink.
add_interface fault conduit end
set_interface_property fault associatedClock clock
set_interface_property fault associatedReset reset
add_interface_port fault hang        hang        Input 1
add_interface_port fault hang_late   hang_late   Input 1
add_interface_port fault soft_resetn soft_resetn Input 1

# -----------------------------------------------------------------------
# Elaboration and validation
# -----------------------------------------------------------------------
proc elaborate {} {
    if {[get_parameter_value USE_WRITE_RESPONSE]} {
        add_interface_port s0 s_writeresponsevalid writeresponsevalid Output 1
        # Platform Designer will not generate an interface that carries
        # writeresponsevalid but advertises no pending-write capacity. One is
        # the truth here: this peripheral answers a write burst before it will
        # accept another.
        set_interface_property s0 maximumPendingWriteTransactions 1
    }
}
set_module_property ELABORATION_CALLBACK elaborate

proc validate {} {
    set mw [get_parameter_value MEM_WORDS]
    set aw [get_parameter_value ADDR_WIDTH]
    set dw [get_parameter_value DATA_WIDTH]

    # The scratchpad depth must be a power of two: the word index is a plain
    # bit slice of the address, so a non-power-of-two depth would alias part of
    # the map onto itself rather than shrinking it.
    if {$mw & ($mw - 1)} {
        send_message error "MEM_WORDS must be a power of two (the word index is an address bit slice)."
    }

    # The address port has to be able to reach every word.
    set shift 0
    while {(1 << $shift) < ($dw / 8)} { incr shift }
    set need 0
    while {(1 << $need) < $mw} { incr need }
    if {$aw < ($need + $shift)} {
        send_message error \
            "ADDR_WIDTH=$aw cannot address MEM_WORDS=$mw words of $dw bits: at least [expr {$need + $shift}] bits are needed."
    }
}
