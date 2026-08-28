# =============================================================================
# build_system.tcl - constructs the Platform Designer system for the Nios II
# AXI4-Lite Firewall example, and generates its HDL.
#
#   cd qsys && ./build.sh          (or see the command in build.sh)
#
# The system is built by script rather than committed as a .qsys file because a
# .qsys is generated XML: you cannot review a diff of it, and it pins the
# Quartus version that wrote it. This script is the source of truth; the .qsys
# and everything under firewall_sys/ are build artifacts.
#
# ---------------------------------------------------------------------------
# ADDRESSES, AND WHY THEY ARE ASSIGNED BY HAND
# ---------------------------------------------------------------------------
# The firewall forwards a transaction's address to m_axi unchanged. Platform
# Designer presents an AXI slave the offset within its own span, so the
# firewall sees 0x000..0xFFF on s_axi and drives the same value onto m_axi.
# For the protected peripheral to answer, its base in the m_axi address space
# must therefore be 0 - which is what the explicit base assignment below does.
# Leaving Qsys to auto-assign works too, but only by luck, and a later
# regeneration can move it.
#
# The firewall's rules are written in terms of the address the CORE sees, i.e.
# the offset within s_axi's span - not the CPU-side address. That is what
# makes FW_REGION_* in the software independent of where Qsys puts s_axi.
# =============================================================================

package require -exact qsys 14.0

create_system firewall_sys
set_project_property DEVICE_FAMILY {MAX 10}
set_project_property DEVICE {10M50DAF484C7G}
set_project_property HIDE_FROM_IP_CATALOG {false}

# ---------------------------------------------------------------------------
# Clock and reset
#
# The board supplies 50 MHz; the system runs at 100 MHz from a PLL. The PLL is
# inside the Qsys system rather than in the top-level wrapper so that Platform
# Designer knows the real system frequency: ALT_CPU_FREQ in the generated BSP,
# and hence every HAL timing routine, is derived from the clock that actually
# reaches the CPU. A top-level PLL would leave the BSP believing 50 MHz and
# every usleep() would come out half as long as asked for.
#
# `locked` is exported. The top level holds the system in reset until the PLL
# has locked - without that, the CPU starts executing from an unstable clock.
# ---------------------------------------------------------------------------
add_instance clk clock_source
set_instance_parameter_value clk {clockFrequency} {50000000.0}
set_instance_parameter_value clk {resetSynchronousEdges} {DEASSERT}

# ALTPLL, not altera_pll: the latter is for 28 nm and newer families and
# refuses to generate for MAX 10 ("Component pll does not support selected
# device family MAX 10"). ALTPLL is the MAX 10 PLL.
#
# INCLK0_INPUT_FREQUENCY is a PERIOD in picoseconds, not a frequency:
# 20000 ps = 50 MHz. Multiply by 2, divide by 1, for a 100 MHz system clock.
add_instance pll altpll
set_instance_parameter_value pll {INCLK0_INPUT_FREQUENCY} {20000}
set_instance_parameter_value pll {OPERATION_MODE} {NORMAL}
set_instance_parameter_value pll {CLK0_MULTIPLY_BY} {2}
set_instance_parameter_value pll {CLK0_DIVIDE_BY} {1}
set_instance_parameter_value pll {CLK0_DUTY_CYCLE} {50}
set_instance_parameter_value pll {CLK0_PHASE_SHIFT} {0}
set_instance_parameter_value pll {PORT_locked} {PORT_USED}

add_connection clk.clk pll.inclk_interface

# The PLL's reference-clock reset comes through its OWN bridge, not from the
# system reset network.
#
# Wiring the system reset into the PLL's reset deadlocks the board: the top
# level holds the system in reset until the PLL locks, but the PLL cannot lock
# while that same signal holds it in reset. Qsys will not let the interface go
# unconnected either - it fails generation and tells you to use a reset bridge,
# which is exactly what this is. The bridge's input is exported and tied
# inactive at the top level; the PLL is actually reset through pll_areset,
# straight from the button, so the loop is broken.
add_instance rb_pll altera_reset_bridge
set_instance_parameter_value rb_pll {ACTIVE_LOW_RESET} {1}
set_instance_parameter_value rb_pll {SYNCHRONOUS_EDGES} {deassert}
set_instance_parameter_value rb_pll {NUM_RESET_OUTPUTS} {1}
set_instance_parameter_value rb_pll {USE_RESET_REQUEST} {0}
add_connection clk.clk           rb_pll.clk
add_connection rb_pll.out_reset  pll.inclk_interface_reset

# ---------------------------------------------------------------------------
# Nios II/f
#
# Nios II/f, not /e. One consequence is worth knowing:
#
#  CACHES. Nios II/f has a data cache; Nios II/e does not. Every access to the
#  firewall's registers and to the protected peripheral MUST bypass it, or
#  writes sit in the cache and the hardware never sees them. The driver uses
#  IORD_32DIRECT/IOWR_32DIRECT, which set address bit 31 to force an uncached
#  access - this is why it does not use plain volatile pointers. On Nios II/e
#  that choice is invisible; here it is the difference between working and not.
#
#  Set impl to Tiny below if you want Nios II/e instead.
# ---------------------------------------------------------------------------
add_instance cpu altera_nios2_gen2
set_instance_parameter_value cpu {impl} {Fast}
set_instance_parameter_value cpu {icache_size} {4096}
set_instance_parameter_value cpu {dcache_size} {2048}
set_instance_parameter_value cpu {mul_32_impl} {1}
set_instance_parameter_value cpu {resetSlave} {onchip_ram.s1}
set_instance_parameter_value cpu {resetOffset} {0}
set_instance_parameter_value cpu {exceptionSlave} {onchip_ram.s1}
set_instance_parameter_value cpu {exceptionOffset} {32}

# ---------------------------------------------------------------------------
# On-chip memory for code and data
# ---------------------------------------------------------------------------
add_instance onchip_ram altera_avalon_onchip_memory2
set_instance_parameter_value onchip_ram {memorySize} {131072}
set_instance_parameter_value onchip_ram {dataWidth} {32}
set_instance_parameter_value onchip_ram {initMemContent} {1}
set_instance_parameter_value onchip_ram {useNonDefaultInitFile} {0}
set_instance_parameter_value onchip_ram {enableDiffWidth} {0}
set_instance_parameter_value onchip_ram {singleClockOperation} {1}

# ---------------------------------------------------------------------------
# stdout, a system ID, and a timer for the HAL
# ---------------------------------------------------------------------------
add_instance jtag_uart altera_avalon_jtag_uart

add_instance sysid altera_avalon_sysid_qsys
set_instance_parameter_value sysid {id} {2863311530}

add_instance timer altera_avalon_timer
set_instance_parameter_value timer {alwaysRun} {0}
set_instance_parameter_value timer {period} {1}
set_instance_parameter_value timer {periodUnits} {MSEC}

# ---------------------------------------------------------------------------
# The IP core under demonstration
#
# ADDR_WIDTH is 12 rather than the default 32 on purpose. A 32-bit AXI slave
# advertises a 4 GB span, which would swallow the whole Nios address map. It
# also exercises the parameterised byte-merge path that only runs when
# ADDR_WIDTH < 32 - a path the RTL example, which uses 32, never touches.
# ---------------------------------------------------------------------------
add_instance fw altera_axi4_lite_firewall
set_instance_parameter_value fw {ADDR_WIDTH} {12}
set_instance_parameter_value fw {DATA_WIDTH} {32}
set_instance_parameter_value fw {CTRL_ADDR_WIDTH} {12}
set_instance_parameter_value fw {NUM_RULES} {8}
set_instance_parameter_value fw {TIMEOUT_WIDTH} {20}

# ---------------------------------------------------------------------------
# The peripheral being protected - 16 words, with injectable faults
# ---------------------------------------------------------------------------
add_instance tgt demo_axi4_lite_target_slave
set_instance_parameter_value tgt {ADDR_WIDTH} {6}
set_instance_parameter_value tgt {DATA_WIDTH} {32}
set_instance_parameter_value tgt {MEM_WORDS} {16}

# ---------------------------------------------------------------------------
# PIOs: fault injection into the peripheral, and the LEDs
#
# pio_fault is how software breaks the peripheral on purpose and, crucially,
# how it RESETS it during recovery. Version 2.0 of the core removed its
# peripheral-reset output, making that the integrator's job - this PIO is that
# job, done.
#   bit 0  hang         stop responding
#   bit 1  hang_late    0 = refuse the command, 1 = accept it then go silent
#   bit 2  soft_resetn  0 = hold the peripheral in reset
# ---------------------------------------------------------------------------
add_instance pio_fault altera_avalon_pio
set_instance_parameter_value pio_fault {direction} {Output}
set_instance_parameter_value pio_fault {width} {3}
set_instance_parameter_value pio_fault {resetValue} {4}

add_instance pio_led altera_avalon_pio
set_instance_parameter_value pio_led {direction} {Output}
set_instance_parameter_value pio_led {width} {10}
set_instance_parameter_value pio_led {resetValue} {0}

# ---------------------------------------------------------------------------
# Clocks
# ---------------------------------------------------------------------------
# Altera's own IP names its clock sink `clk` (and the on-chip memory `clk1`);
# the two components in this repository name theirs `clock`. Neither is wrong;
# they just have to be spelled correctly here.
# Everything except the PLL itself runs on the PLL's 100 MHz output.
foreach inst {cpu jtag_uart sysid timer pio_fault pio_led} {
    add_connection pll.c0 ${inst}.clk
}
add_connection pll.c0 onchip_ram.clk1
foreach inst {fw tgt} {
    add_connection pll.c0 ${inst}.clock
}

# ---------------------------------------------------------------------------
# Resets. Everything sits in one reset domain, plus the CPU's debug reset.
# The peripheral's SOFTWARE reset is separate and arrives on tgt's conduit.
# ---------------------------------------------------------------------------
foreach inst {cpu jtag_uart sysid timer pio_fault pio_led fw tgt} {
    add_connection clk.clk_reset ${inst}.reset
}
add_connection clk.clk_reset onchip_ram.reset1

# cpu.debug_reset_request is deliberately left unconnected. Routing it into
# clk.clk_in_reset would make that interface both connected and exported,
# which Qsys warns about, and the JTAG debug module resets the processor
# through its own path regardless. Nothing in this demo needs a debugger
# halt to reset the peripherals as well.

# ---------------------------------------------------------------------------
# Instruction and data masters
# ---------------------------------------------------------------------------
add_connection cpu.instruction_master onchip_ram.s1
add_connection cpu.data_master        onchip_ram.s1

# The JTAG debug module is a slave to BOTH masters. Connecting only the data
# master generates but then fails elaboration with "Debug port is enabled.
# Please connect the instruction_master and data_master to debug_mem_slave".
add_connection cpu.data_master        cpu.debug_mem_slave
add_connection cpu.instruction_master cpu.debug_mem_slave
foreach slave {jtag_uart.avalon_jtag_slave sysid.control_slave timer.s1
               pio_fault.s1 pio_led.s1 fw.s_axi_ctrl fw.s_axi pll.pll_slave} {
    add_connection cpu.data_master $slave
}

# The firewall's master drives the protected peripheral, and nothing else.
add_connection fw.m_axi tgt.s0

# ---------------------------------------------------------------------------
# Interrupts. The firewall's is the interesting one: a violation or a timeout
# raises it, and the ISR reads STATUS to find out which.
# ---------------------------------------------------------------------------
add_connection cpu.irq jtag_uart.irq
set_connection_parameter_value cpu.irq/jtag_uart.irq irqNumber {1}
add_connection cpu.irq timer.irq
set_connection_parameter_value cpu.irq/timer.irq irqNumber {2}
add_connection cpu.irq fw.irq
set_connection_parameter_value cpu.irq/fw.irq irqNumber {3}

# ---------------------------------------------------------------------------
# Base addresses, assigned rather than inferred - see the header.
# ---------------------------------------------------------------------------
set_connection_parameter_value cpu.data_master/onchip_ram.s1        baseAddress {0x00000000}
set_connection_parameter_value cpu.instruction_master/onchip_ram.s1 baseAddress {0x00000000}
set_connection_parameter_value cpu.data_master/cpu.debug_mem_slave        baseAddress {0x00030000}
set_connection_parameter_value cpu.instruction_master/cpu.debug_mem_slave baseAddress {0x00030000}
set_connection_parameter_value cpu.data_master/jtag_uart.avalon_jtag_slave baseAddress {0x00021000}
set_connection_parameter_value cpu.data_master/sysid.control_slave  baseAddress {0x00021010}
set_connection_parameter_value cpu.data_master/timer.s1             baseAddress {0x00021020}
set_connection_parameter_value cpu.data_master/pio_led.s1           baseAddress {0x00021040}
set_connection_parameter_value cpu.data_master/pio_fault.s1         baseAddress {0x00021050}
set_connection_parameter_value cpu.data_master/fw.s_axi_ctrl        baseAddress {0x00022000}
set_connection_parameter_value cpu.data_master/fw.s_axi             baseAddress {0x00023000}
set_connection_parameter_value cpu.data_master/pll.pll_slave        baseAddress {0x00021060}

# The one that matters: the peripheral sits at 0 in the firewall's own master
# address space, so a rule written for 0x010 protects peripheral word 4.
set_connection_parameter_value fw.m_axi/tgt.s0 baseAddress {0x00000000}

# ---------------------------------------------------------------------------
# Exports to the top level
# ---------------------------------------------------------------------------
set_interface_property clk         EXPORT_OF clk.clk_in
set_interface_property reset       EXPORT_OF clk.clk_in_reset
set_interface_property pll_locked  EXPORT_OF pll.locked_conduit
set_interface_property pll_areset  EXPORT_OF pll.areset_conduit
set_interface_property pll_ref_reset EXPORT_OF rb_pll.in_reset
set_interface_property led         EXPORT_OF pio_led.external_connection
set_interface_property fault_ctl   EXPORT_OF pio_fault.external_connection
set_interface_property target_fault EXPORT_OF tgt.fault

save_system firewall_sys.qsys
puts "=== system saved ==="
