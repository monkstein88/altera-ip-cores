package require -exact qsys 14.0

# =============================================================================
# demo_target_slave_hw.tcl
#
# Platform Designer component for demo_target_slave - the peripheral the
# firewall protects in the Nios II example.
#
# It exists as a component (rather than the example just using an on-chip RAM)
# for one reason: a fault-isolation demo needs a peripheral that can stop
# responding on command. An on-chip RAM always answers, so it can demonstrate
# access control and nothing else. The `fault` conduit below is what makes
# the timeout, isolation and recovery scenarios reachable from software.
#
# The two resets are deliberate; see the header of demo_target_slave.sv.
# `reset` is a genuine reset sink tied to the system reset network, and
# `soft_resetn` arrives on the conduit from a PIO, so software can reset this
# peripheral without resetting the rest of the system. Recovery from a
# firewall timeout requires exactly that.
# =============================================================================

set_module_property NAME demo_target_slave
set_module_property DISPLAY_NAME "Demo Target Slave (protected peripheral)"
set_module_property DESCRIPTION "AXI4-Lite scratchpad with injectable faults, for demonstrating the AXI4-Lite Firewall."
set_module_property VERSION 1.0
set_module_property GROUP "Bridges and Adapters/Custom"
set_module_property AUTHOR "monkstein88"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE false
set_module_property VALIDATION_CALLBACK validate

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH generate_synth_files ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL demo_target_slave
add_fileset_file demo_target_slave.sv SYSTEM_VERILOG PATH demo_target_slave.sv TOP_LEVEL_FILE

add_fileset SIM_VERILOG SIM_VERILOG generate_sim_files ""
set_fileset_property SIM_VERILOG TOP_LEVEL demo_target_slave
add_fileset_file demo_target_slave.sv SYSTEM_VERILOG PATH demo_target_slave.sv TOP_LEVEL_FILE

proc generate_synth_files {name} {}
proc generate_sim_files   {name} {}

# -----------------------------------------------------------------------
# Parameters
# -----------------------------------------------------------------------
add_parameter          ADDR_WIDTH INTEGER 32
set_parameter_property ADDR_WIDTH DISPLAY_NAME "Address width"
set_parameter_property ADDR_WIDTH ALLOWED_RANGES {4:32}
set_parameter_property ADDR_WIDTH HDL_PARAMETER true

add_parameter          DATA_WIDTH INTEGER 32
set_parameter_property DATA_WIDTH DISPLAY_NAME "Data width"
set_parameter_property DATA_WIDTH ALLOWED_RANGES {32 64}
set_parameter_property DATA_WIDTH HDL_PARAMETER true

add_parameter          MEM_WORDS INTEGER 16
set_parameter_property MEM_WORDS DISPLAY_NAME "Scratchpad words"
set_parameter_property MEM_WORDS ALLOWED_RANGES {2 4 8 16 32 64 128 256}
set_parameter_property MEM_WORDS HDL_PARAMETER true

# The scratchpad decodes only enough address bits to cover MEM_WORDS, so an
# address span wider than the scratchpad would alias rather than fail. Qsys
# sizes an AXI slave's span from its address width, so catch the mismatch here
# instead of letting it become a silent wrap at run time.
proc validate {} {
    set aw    [get_parameter_value ADDR_WIDTH]
    set words [get_parameter_value MEM_WORDS]
    set need  0
    while {(1 << $need) < $words} { incr need }
    set span_bits [expr {$need + 2}]
    if {$aw > $span_bits} {
        send_message warning \
            "ADDR_WIDTH=$aw gives a [expr {1 << $aw}]-byte span but MEM_WORDS=$words only decodes [expr {1 << $span_bits}] bytes; addresses above that alias back onto the scratchpad. Set ADDR_WIDTH to $span_bits, or raise MEM_WORDS."
    }
}

# -----------------------------------------------------------------------
# Clock and reset
# -----------------------------------------------------------------------
add_interface clock clock end
add_interface_port clock clk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset resetn reset_n Input 1

# -----------------------------------------------------------------------
# s0 - the AXI4-Lite slave the firewall's m_axi drives
# -----------------------------------------------------------------------
add_interface s0 axi4lite end
set_interface_property s0 associatedClock clock
set_interface_property s0 associatedReset reset
add_interface_port s0 s_awaddr  awaddr  Input  ADDR_WIDTH
add_interface_port s0 s_awprot  awprot  Input  3
add_interface_port s0 s_awvalid awvalid Input  1
add_interface_port s0 s_awready awready Output 1
add_interface_port s0 s_wdata   wdata   Input  DATA_WIDTH
add_interface_port s0 s_wstrb   wstrb   Input  DATA_WIDTH/8
add_interface_port s0 s_wvalid  wvalid  Input  1
add_interface_port s0 s_wready  wready  Output 1
add_interface_port s0 s_bresp   bresp   Output 2
add_interface_port s0 s_bvalid  bvalid  Output 1
add_interface_port s0 s_bready  bready  Input  1
add_interface_port s0 s_araddr  araddr  Input  ADDR_WIDTH
add_interface_port s0 s_arprot  arprot  Input  3
add_interface_port s0 s_arvalid arvalid Input  1
add_interface_port s0 s_arready arready Output 1
add_interface_port s0 s_rdata   rdata   Output DATA_WIDTH
add_interface_port s0 s_rresp   rresp   Output 2
add_interface_port s0 s_rvalid  rvalid  Output 1
add_interface_port s0 s_rready  rready  Input  1

# -----------------------------------------------------------------------
# fault - exported to the top level and driven by a PIO, so software can
# break this peripheral on purpose and reset it afterwards
# -----------------------------------------------------------------------
add_interface fault conduit end
set_interface_property fault associatedClock clock
set_interface_property fault associatedReset reset
add_interface_port fault hang        hang        Input 1
add_interface_port fault hang_late   hang_late   Input 1
add_interface_port fault soft_resetn soft_resetn Input 1
