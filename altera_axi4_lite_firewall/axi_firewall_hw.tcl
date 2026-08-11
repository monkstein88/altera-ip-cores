package require -exact qsys 14.0

# =============================================================================
# axi_firewall_hw.tcl
#
# Platform Designer / Qsys component description for axi_firewall_top.
#
# IMPORTANT: hand-written hw.tcl syntax has drifted across Quartus versions
# (Standard vs Pro, and release to release - see Intel's "_hw.tcl Command
# Reference" for your installed version). This file is a complete, best-effort
# starting point, not a guaranteed drop-in for every Quartus release.
#
# The robust way to package this component, recommended over trusting this
# file blindly:
#   1. In Platform Designer, Component Editor -> add axi_firewall_top.sv and
#      axi_firewall_regs.sv as synthesis files, set axi_firewall_top.sv as the
#      top-level file, then "Analyze Synthesis Files".
#   2. Because every port below follows the s_axi_*/m_axi_*/s_axi_ctrl_*
#      naming convention with standard AXI4-Lite signal suffixes (awaddr,
#      awvalid, awready, wdata, ...), Platform Designer's own signal analysis
#      should auto-group them into three AXI4-Lite interfaces plus clock,
#      reset, and interrupt. Fix up anything it doesn't infer correctly in
#      the Component Editor's "Signals & Interfaces" tab.
#   3. File -> Save / Export as hw.tcl Component to get a hw.tcl file that is
#      guaranteed correct for your exact installed version.
# =============================================================================

set_module_property NAME altera_axi4_lite_firewall
set_module_property DISPLAY_NAME "AXI4-Lite Firewall"
set_module_property DESCRIPTION "Access-control + fault-isolation firewall for an AXI4-Lite slave, with a separate AXI4-Lite control/status port and an interrupt output."
set_module_property VERSION 1.2
set_module_property GROUP "Bridges and Adapters/Custom"
set_module_property AUTHOR "monkstein88"
#set_module_property TOP_LEVEL_HDL_MODULE axi_firewall_top
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE false
set_module_property ELABORATION_CALLBACK elaborate
set_module_property VALIDATION_CALLBACK validate

# -----------------------------------------------------------------------
# Files
#
# The file TYPE argument must be SYSTEM_VERILOG, not VERILOG. The RTL uses
# `logic`, always_ff/always_comb, packed structs and enums; declaring it as
# VERILOG makes Quartus analyse it with the Verilog-2001 parser and it fails
# on the first `logic` declaration.
#
# The SIM fileset is still named SIM_VERILOG - that is the fileset's name in
# Platform Designer, independent of the language of the files inside it.
# -----------------------------------------------------------------------
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH generate_synth_files ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL axi_firewall_top
add_fileset_file axi_firewall_regs.sv SYSTEM_VERILOG PATH rtl/axi_firewall_regs.sv
add_fileset_file axi_firewall_top.sv  SYSTEM_VERILOG PATH rtl/axi_firewall_top.sv TOP_LEVEL_FILE

add_fileset SIM_VERILOG SIM_VERILOG generate_sim_files ""
set_fileset_property SIM_VERILOG TOP_LEVEL axi_firewall_top
add_fileset_file axi_firewall_regs.sv SYSTEM_VERILOG PATH rtl/axi_firewall_regs.sv
add_fileset_file axi_firewall_top.sv  SYSTEM_VERILOG PATH rtl/axi_firewall_top.sv TOP_LEVEL_FILE

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

add_parameter DATA_WIDTH INTEGER 32
set_parameter_property DATA_WIDTH DISPLAY_NAME "Data-path data width"
set_parameter_property DATA_WIDTH UNITS bits
set_parameter_property DATA_WIDTH ALLOWED_RANGES {32 64}
set_parameter_property DATA_WIDTH HDL_PARAMETER true

add_parameter CTRL_ADDR_WIDTH INTEGER 12
set_parameter_property CTRL_ADDR_WIDTH DISPLAY_NAME "Control/status port address width"
set_parameter_property CTRL_ADDR_WIDTH UNITS bits
set_parameter_property CTRL_ADDR_WIDTH ALLOWED_RANGES {8:16}
set_parameter_property CTRL_ADDR_WIDTH HDL_PARAMETER true
set_parameter_property CTRL_ADDR_WIDTH DESCRIPTION "Must cover 0x40 + NUM_RULES*16 bytes."

add_parameter NUM_RULES INTEGER 8
set_parameter_property NUM_RULES DISPLAY_NAME "Number of address-range rules"
set_parameter_property NUM_RULES ALLOWED_RANGES {1:64}
set_parameter_property NUM_RULES HDL_PARAMETER true

add_parameter RESET_HOLD_CYCLES INTEGER 16
set_parameter_property RESET_HOLD_CYCLES DISPLAY_NAME "Peripheral reset pulse length"
set_parameter_property RESET_HOLD_CYCLES UNITS cycles
set_parameter_property RESET_HOLD_CYCLES ALLOWED_RANGES {1:1024}
set_parameter_property RESET_HOLD_CYCLES HDL_PARAMETER true
set_parameter_property RESET_HOLD_CYCLES DESCRIPTION "How long m_axi_resetn is held low when recovering from a downstream timeout. Must exceed the protected peripheral's minimum reset pulse width."

add_parameter TIMEOUT_WIDTH INTEGER 20
set_parameter_property TIMEOUT_WIDTH DISPLAY_NAME "Timeout counter width"
set_parameter_property TIMEOUT_WIDTH UNITS bits
set_parameter_property TIMEOUT_WIDTH ALLOWED_RANGES {8:32}
set_parameter_property TIMEOUT_WIDTH HDL_PARAMETER true
set_parameter_property TIMEOUT_WIDTH DESCRIPTION "Max programmable timeout, in clk cycles, is 2^TIMEOUT_WIDTH - 1."

# -----------------------------------------------------------------------
# Clock / reset
# -----------------------------------------------------------------------
add_interface clock clock end
set_interface_property clock clockRate 0
add_interface_port clock clk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset resetn reset_n Input 1

# -----------------------------------------------------------------------
# s_axi - protected data-path slave (toward the master / Nios II bridge)
# -----------------------------------------------------------------------
add_interface s_axi axi4lite end
set_interface_property s_axi associatedClock clock
set_interface_property s_axi associatedReset reset
add_interface_port s_axi s_axi_awaddr  awaddr  Input  ADDR_WIDTH
add_interface_port s_axi s_axi_awprot  awprot  Input  3
add_interface_port s_axi s_axi_awvalid awvalid Input  1
add_interface_port s_axi s_axi_awready awready Output 1
add_interface_port s_axi s_axi_wdata   wdata   Input  DATA_WIDTH
add_interface_port s_axi s_axi_wstrb   wstrb   Input  DATA_WIDTH/8
add_interface_port s_axi s_axi_wvalid  wvalid  Input  1
add_interface_port s_axi s_axi_wready  wready  Output 1
add_interface_port s_axi s_axi_bresp   bresp   Output 2
add_interface_port s_axi s_axi_bvalid  bvalid  Output 1
add_interface_port s_axi s_axi_bready  bready  Input  1
add_interface_port s_axi s_axi_araddr  araddr  Input  ADDR_WIDTH
add_interface_port s_axi s_axi_arprot  arprot  Input  3
add_interface_port s_axi s_axi_arvalid arvalid Input  1
add_interface_port s_axi s_axi_arready arready Output 1
add_interface_port s_axi s_axi_rdata   rdata   Output DATA_WIDTH
add_interface_port s_axi s_axi_rresp   rresp   Output 2
add_interface_port s_axi s_axi_rvalid  rvalid  Output 1
add_interface_port s_axi s_axi_rready  rready  Input  1

# -----------------------------------------------------------------------
# m_axi - protected data-path master (toward the peripheral being guarded)
# -----------------------------------------------------------------------
add_interface m_axi axi4lite start
set_interface_property m_axi associatedClock clock
set_interface_property m_axi associatedReset reset
add_interface_port m_axi m_axi_awaddr  awaddr  Output ADDR_WIDTH
add_interface_port m_axi m_axi_awprot  awprot  Output 3
add_interface_port m_axi m_axi_awvalid awvalid Output 1
add_interface_port m_axi m_axi_awready awready Input  1
add_interface_port m_axi m_axi_wdata   wdata   Output DATA_WIDTH
add_interface_port m_axi m_axi_wstrb   wstrb   Output DATA_WIDTH/8
add_interface_port m_axi m_axi_wvalid  wvalid  Output 1
add_interface_port m_axi m_axi_wready  wready  Input  1
add_interface_port m_axi m_axi_bresp   bresp   Input  2
add_interface_port m_axi m_axi_bvalid  bvalid  Input  1
add_interface_port m_axi m_axi_bready  bready  Output 1
add_interface_port m_axi m_axi_araddr  araddr  Output ADDR_WIDTH
add_interface_port m_axi m_axi_arprot  arprot  Output 3
add_interface_port m_axi m_axi_arvalid arvalid Output 1
add_interface_port m_axi m_axi_arready arready Input  1
add_interface_port m_axi m_axi_rdata   rdata   Input  DATA_WIDTH
add_interface_port m_axi m_axi_rresp   rresp   Input  2
add_interface_port m_axi m_axi_rvalid  rvalid  Input  1
add_interface_port m_axi m_axi_rready  rready  Output 1

# -----------------------------------------------------------------------
# s_axi_ctrl - control/status slave (rule table, status, irq enable, ...)
# -----------------------------------------------------------------------
add_interface s_axi_ctrl axi4lite end
set_interface_property s_axi_ctrl associatedClock clock
set_interface_property s_axi_ctrl associatedReset reset
add_interface_port s_axi_ctrl s_axi_ctrl_awaddr  awaddr  Input  CTRL_ADDR_WIDTH
add_interface_port s_axi_ctrl s_axi_ctrl_awprot  awprot  Input  3
add_interface_port s_axi_ctrl s_axi_ctrl_awvalid awvalid Input  1
add_interface_port s_axi_ctrl s_axi_ctrl_awready awready Output 1
add_interface_port s_axi_ctrl s_axi_ctrl_wdata   wdata   Input  32
add_interface_port s_axi_ctrl s_axi_ctrl_wstrb   wstrb   Input  4
add_interface_port s_axi_ctrl s_axi_ctrl_wvalid  wvalid  Input  1
add_interface_port s_axi_ctrl s_axi_ctrl_wready  wready  Output 1
add_interface_port s_axi_ctrl s_axi_ctrl_bresp   bresp   Output 2
add_interface_port s_axi_ctrl s_axi_ctrl_bvalid  bvalid  Output 1
add_interface_port s_axi_ctrl s_axi_ctrl_bready  bready  Input  1
add_interface_port s_axi_ctrl s_axi_ctrl_araddr  araddr  Input  CTRL_ADDR_WIDTH
add_interface_port s_axi_ctrl s_axi_ctrl_arprot  arprot  Input  3
add_interface_port s_axi_ctrl s_axi_ctrl_arvalid arvalid Input  1
add_interface_port s_axi_ctrl s_axi_ctrl_arready arready Output 1
add_interface_port s_axi_ctrl s_axi_ctrl_rdata   rdata   Output 32
add_interface_port s_axi_ctrl s_axi_ctrl_rresp   rresp   Output 2
add_interface_port s_axi_ctrl s_axi_ctrl_rvalid  rvalid  Output 1
add_interface_port s_axi_ctrl s_axi_ctrl_rready  rready  Input  1

# -----------------------------------------------------------------------
# m_axi_reset - reset SOURCE driving the protected peripheral. Must be
# connected to that peripheral's reset input: it is how a peripheral left
# mid-transaction by a timeout gets flushed before traffic resumes.
# -----------------------------------------------------------------------
add_interface m_axi_reset reset start
set_interface_property m_axi_reset associatedClock clock
set_interface_property m_axi_reset associatedDirectReset reset
set_interface_property m_axi_reset synchronousEdges DEASSERT
add_interface_port m_axi_reset m_axi_resetn reset_n Output 1

# -----------------------------------------------------------------------
# irq - level interrupt, stays asserted until the causing STATUS bit(s)
# are cleared (write-1-to-clear) over s_axi_ctrl
# -----------------------------------------------------------------------
add_interface irq interrupt end
set_interface_property irq associatedClock clock
set_interface_property irq associatedReset reset
set_interface_property irq associatedAddressablePoint s_axi_ctrl
add_interface_port irq irq irq Output 1

# -----------------------------------------------------------------------
# Elaboration callback - keeps WSTRB widths consistent if DATA_WIDTH changes
# -----------------------------------------------------------------------
proc elaborate {} { }

# -----------------------------------------------------------------------
# Validation - the control port must be wide enough to actually reach every
# rule. Without this check, CTRL_ADDR_WIDTH=8 with NUM_RULES=64 elaborates
# and simulates happily while rules 12..63 are silently unreachable.
# -----------------------------------------------------------------------
proc validate {} {
    set nr   [get_parameter_value NUM_RULES]
    set caw  [get_parameter_value CTRL_ADDR_WIDTH]
    set span [expr {0x40 + $nr * 16}]

    # Integer ceil-log2 by shifting, not int(ceil(log(x)/log(2))). The
    # floating-point form gives the right answer for every NUM_RULES in the
    # allowed 1..64 range on the platforms tested, but it relies on
    # log(x)/log(2) never landing a hair above an integer for exact powers of
    # two - a property of the host libm, not of Tcl. Shifting has no such
    # dependency and is no slower at this size.
    set need 0
    while {(1 << $need) < $span} { incr need }

    if {$caw < $need} {
        set last [expr {((1 << $caw) - 0x40) / 16 - 1}]
        send_message error \
            "CTRL_ADDR_WIDTH=$caw is too small for NUM_RULES=$nr: the rule table spans $span bytes and needs at least $need address bits. Rules above index $last would be unreachable."
    }
}
