# =============================================================================
# build_system.tcl - constructs the Platform Designer system for the Nios II
# Avalon-MM Firewall example, and generates its HDL.
#
#   ../build.sh qsys      (or see the command in build.sh)
#
# The system is built by script rather than committed as a hand-edited .qsys
# file because a .qsys is generated XML: you cannot review a diff of it, and it
# pins the Quartus version that wrote it. This script is the source of truth;
# firewall_sys/ and everything under it are build artifacts.
#
# ---------------------------------------------------------------------------
# ADDRESSES, AND WHY THEY ARE ASSIGNED BY HAND
# ---------------------------------------------------------------------------
# s0 declares `bridgesToMaster m0`, so Platform Designer treats s0's address
# space AS m0's: a CPU access to FW_S0_BASE + 0x10 reaches the core as address
# 0x010, and the core forwards 0x010 to m0 unchanged. For the protected
# peripheral to answer, its base in m0's space must be 0 - which is what the
# explicit assignment below does. Letting Qsys auto-assign happens to work too,
# but only by luck, and a later regeneration can move it.
#
# The firewall's RULES are therefore written in firewall-side addresses - the
# offset within s0's span - not CPU addresses. Getting that backwards fills the
# table with values no transaction can ever match, and every access returns
# DECODEERROR. It is the single easiest thing to get wrong here.
#
# ---------------------------------------------------------------------------
# 100 MHz, AND WHAT MAKES IT POSSIBLE
# ---------------------------------------------------------------------------
# The system runs at 100 MHz from the PLL. The core cannot do that with its
# combinational rule lookup - measured at 73.4 MHz in this configuration on
# this part - so REGISTER_LOOKUP is on. It costs one cycle per transaction and
# is the reason this example closes timing at all. See the core's README,
# "Performance".
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
# refuses to generate for MAX 10. INCLK0_INPUT_FREQUENCY is a PERIOD in
# picoseconds, not a frequency: 20000 ps = 50 MHz. Multiply by 2, divide by 1.
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
# system reset network. Wiring the system reset into the PLL's reset deadlocks
# the board: the top level holds the system in reset until the PLL locks, but
# the PLL cannot lock while that same signal holds it in reset. Qsys will not
# let the interface go unconnected either, so a bridge it is; its input is
# exported and tied inactive at the top level, and the PLL is actually reset
# through pll_areset straight from the button.
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
# CACHES are the thing to know. Nios II/f has a data cache; Nios II/e does not.
# Every access to the firewall's registers and to the protected peripheral MUST
# bypass it, or writes sit in the cache and the hardware never sees them. The
# HAL driver uses IORD_32DIRECT/IOWR_32DIRECT, which set address bit 31 to
# force an uncached access - which is why it does not use plain volatile
# pointers. On Nios II/e that choice is invisible; here it is the difference
# between working and not.
#
# Set impl to Tiny for Nios II/e instead.
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
set_instance_parameter_value sysid {id} {2863311531}

add_instance timer altera_avalon_timer
set_instance_parameter_value timer {alwaysRun} {0}
set_instance_parameter_value timer {period} {1}
set_instance_parameter_value timer {periodUnits} {MSEC}

# ---------------------------------------------------------------------------
# The IP core under demonstration
#
# NUM_RULES 5 and ADDR_WIDTH 12: the demo's map needs five windows, and a
# 12-bit span is plenty for a 256-byte peripheral. Both keep the rule lookup
# short - see the core's README, "Performance".
#
# REGISTER_LOOKUP is what makes 100 MHz reachable.
# ---------------------------------------------------------------------------
add_instance fw altera_avalon_mm_firewall
set_instance_parameter_value fw {ADDR_WIDTH} {12}
set_instance_parameter_value fw {DATA_WIDTH} {32}
# BURST_WIDTH 5 and MAX_PENDING_READS 1, not the defaults, and this is a
# timing decision with a number behind it.
#
# The core sizes its outstanding-beat counters from MAX_PENDING_READS x
# 2^(BURST_WIDTH-1): at the defaults that is 512 beats and an 11-bit counter,
# and the adder-plus-compare that checks read headroom sits directly in the
# waitrequest path. It was the critical path of this system at 95.7 MHz:
#
#   fw|rd_fwd_beats -> rd_beats_after (add) -> rd_gate_allow -> waitrequest
#     -> rd_accept -> fw|rd_deny_beats
#
# A Nios II data master issues single accesses; 512 beats of read capacity is
# capacity this system cannot use. 16 beats with one burst outstanding is
# still more than the CPU will ever ask for, and it halves those counters.
set_instance_parameter_value fw {BURST_WIDTH} {5}
set_instance_parameter_value fw {MAX_PENDING_READS} {1}
set_instance_parameter_value fw {NUM_RULES} {5}
set_instance_parameter_value fw {TIMEOUT_WIDTH} {20}
set_instance_parameter_value fw {CSR_ADDR_WIDTH} {8}
set_instance_parameter_value fw {USE_RESPONSE} {1}
set_instance_parameter_value fw {USE_WRITE_RESPONSE} {1}
set_instance_parameter_value fw {REGISTER_LOOKUP} {1}

# ---------------------------------------------------------------------------
# Pipeline bridge in front of the firewall's data port.
#
# Without it this system misses 100 MHz by 0.56 ns, and the failing path is
#
#   cpu|d_address_tag_field -> (generated interconnect) -> fw|rd_deny_beats
#
# the CPU's data-master address, through Qsys's decode and arbitration, into
# the firewall's accept logic. That is interconnect depth, not the rule lookup
# - REGISTER_LOOKUP has already taken care of the lookup - so the fix is the
# standard one for a long master-to-slave path: register the command and the
# response at the boundary.
#
# It costs a cycle each way on every access to the protected path. The CPU
# issues single accesses, so that is a real per-access cost here; it is also
# the price of running the whole system at twice the RTL demo's clock.
# ---------------------------------------------------------------------------
add_instance br altera_avalon_mm_bridge
set_instance_parameter_value br {DATA_WIDTH} {32}
set_instance_parameter_value br {SYMBOL_WIDTH} {8}
set_instance_parameter_value br {USE_AUTO_ADDRESS_WIDTH} {1}
set_instance_parameter_value br {MAX_BURST_SIZE} {16}
set_instance_parameter_value br {MAX_PENDING_RESPONSES} {4}
set_instance_parameter_value br {PIPELINE_COMMAND} {1}
set_instance_parameter_value br {PIPELINE_RESPONSE} {1}
set_instance_parameter_value br {USE_RESPONSE} {1}

# ---------------------------------------------------------------------------
# The peripheral being protected - 64 words, with injectable faults
# ---------------------------------------------------------------------------
add_instance tgt demo_avl_mm_target_slave
set_instance_parameter_value tgt {ADDR_WIDTH} {8}
set_instance_parameter_value tgt {DATA_WIDTH} {32}
set_instance_parameter_value tgt {BURST_WIDTH} {5}
set_instance_parameter_value tgt {MEM_WORDS} {64}
set_instance_parameter_value tgt {USE_WRITE_RESPONSE} {1}

# ---------------------------------------------------------------------------
# PIOs: fault injection into the peripheral, and the LEDs
#
# pio_fault is how software breaks the peripheral on purpose and, crucially,
# how it RESETS it during recovery. The core deliberately does not drive the
# peripheral's reset - that is the integrator's job, and this PIO is that job,
# done.
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
# Clocks. Everything except the PLL itself runs on the PLL's 100 MHz output.
# ---------------------------------------------------------------------------
foreach inst {cpu jtag_uart sysid timer pio_fault pio_led br} {
    add_connection pll.c0 ${inst}.clk
}
add_connection pll.c0 onchip_ram.clk1
foreach inst {fw tgt} {
    add_connection pll.c0 ${inst}.clock
}

# ---------------------------------------------------------------------------
# Resets. One domain. The peripheral's SOFTWARE reset is separate and arrives
# on tgt's fault conduit from pio_fault.
# ---------------------------------------------------------------------------
foreach inst {cpu jtag_uart sysid timer pio_fault pio_led br fw tgt} {
    add_connection clk.clk_reset ${inst}.reset
}
add_connection clk.clk_reset onchip_ram.reset1

# ---------------------------------------------------------------------------
# Instruction and data masters
# ---------------------------------------------------------------------------
add_connection cpu.instruction_master onchip_ram.s1
add_connection cpu.data_master        onchip_ram.s1

# The JTAG debug module is a slave to BOTH masters, or elaboration fails with
# "Debug port is enabled. Please connect the instruction_master and
# data_master to debug_mem_slave".
add_connection cpu.data_master        cpu.debug_mem_slave
add_connection cpu.instruction_master cpu.debug_mem_slave
foreach slave {jtag_uart.avalon_jtag_slave sysid.control_slave timer.s1
               pio_fault.s1 pio_led.s1 fw.csr br.s0 pll.pll_slave} {
    add_connection cpu.data_master $slave
}

# The protected path: CPU -> pipeline bridge -> firewall -> peripheral.
add_connection br.m0 fw.s0
add_connection fw.m0 tgt.s0

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
set_connection_parameter_value cpu.data_master/pll.pll_slave        baseAddress {0x00021060}
set_connection_parameter_value cpu.data_master/fw.csr               baseAddress {0x00022000}
set_connection_parameter_value cpu.data_master/br.s0                baseAddress {0x00023000}

# The two that matter: the firewall sits at 0 behind the bridge, and the
# peripheral sits at 0 in the firewall's own master address space. Both spans
# therefore start at 0, so a rule written for 0x010 protects peripheral word 4
# whatever Qsys does with the CPU-side base.
set_connection_parameter_value br.m0/fw.s0  baseAddress {0x00000000}
set_connection_parameter_value fw.m0/tgt.s0 baseAddress {0x00000000}

# ---------------------------------------------------------------------------
# Exports to the top level
# ---------------------------------------------------------------------------
set_interface_property clk           EXPORT_OF clk.clk_in
set_interface_property reset         EXPORT_OF clk.clk_in_reset
set_interface_property pll_locked    EXPORT_OF pll.locked_conduit
set_interface_property pll_areset    EXPORT_OF pll.areset_conduit
set_interface_property pll_ref_reset EXPORT_OF rb_pll.in_reset
set_interface_property led           EXPORT_OF pio_led.external_connection
set_interface_property fault_ctl     EXPORT_OF pio_fault.external_connection
set_interface_property target_fault  EXPORT_OF tgt.fault

save_system firewall_sys.qsys
puts "=== system saved ==="
