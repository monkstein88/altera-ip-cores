# =============================================================================
# build_system.tcl - Nios II system for the Avalon-MM SDRAM Controller,
#                    DE10-Lite.
#
#   ../build.sh qsys
#
# WHAT THIS DEMONSTRATES THAT THE RTL EXAMPLE DOES NOT
# ----------------------------------------------------
# The RTL example drives the controller's Avalon-MM slave from a hardware
# sequencer: no CPU, no interconnect, nothing between the master and the
# controller. That is the right shape for measuring the controller.
#
# This one is the shape most people will actually use it in: a Nios II with a
# data cache, reaching the controller through Platform Designer's interconnect,
# including the 32-to-16 bit width adapter Qsys inserts because the CPU is a
# 32-bit master and this slave is 16 bits wide. Software sees ordinary memory.
#
# So the two examples answer different questions. The RTL one asks "does the
# controller work, and how fast is it". This one asks "does it behave as
# memory when a CPU and an interconnect are in the way" - which is where
# read-latency and byte-enable mistakes surface.
#
# CODE DOES NOT RUN FROM THE SDRAM
# --------------------------------
# The CPU's reset and exception vectors, its code and its stack are all in
# on-chip RAM. That is deliberate: this program is a memory test, and a memory
# test that is executing out of the memory it is testing cannot report a
# failure it has just caused. The SDRAM is data only.
#
# THE PLL IS AT THE TOP LEVEL
# ---------------------------
# The SDRAM needs a second clock, phase-shifted, for DRAM_CLK. ALTPLL's second
# output cannot be enabled from a qsys-script - writing PORT_clk1 = PORT_USED
# is silently reverted by the megafunction's own validation - so the PLL lives
# in rtl/sdram_pll.sv and this system takes a ready-made 100 MHz clock. The
# RTL example hit the same wall; see its build_system.tcl.
# =============================================================================

package require -exact qsys 14.0

create_system sdram_nios_sys
set_project_property DEVICE_FAMILY {MAX 10}
set_project_property DEVICE {10M50DAF484C7G}
set_project_property HIDE_FROM_IP_CATALOG {false}

# ---------------------------------------------------------------------------
# Clock and reset in - 100 MHz, from the top-level PLL.
# ---------------------------------------------------------------------------
add_instance clk clock_source
set_instance_parameter_value clk {clockFrequency} {100000000.0}
set_instance_parameter_value clk {resetSynchronousEdges} {DEASSERT}

# ---------------------------------------------------------------------------
# The CPU.
#
# Nios II/f: the caches are the point. A data cache in front of the controller
# changes the access pattern it sees from single words to bursts of a cache
# line, which is a different and more realistic exercise than the RTL example's
# one-word-at-a-time sequencer. The memory test flushes explicitly where it
# needs to see the device rather than the cache.
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
# On-chip RAM: code, stack and heap. NOT the memory under test.
# ---------------------------------------------------------------------------
add_instance onchip_ram altera_avalon_onchip_memory2
set_instance_parameter_value onchip_ram {memorySize} {131072}
set_instance_parameter_value onchip_ram {dataWidth} {32}
set_instance_parameter_value onchip_ram {initMemContent} {1}
set_instance_parameter_value onchip_ram {useNonDefaultInitFile} {0}
set_instance_parameter_value onchip_ram {enableDiffWidth} {0}
set_instance_parameter_value onchip_ram {singleClockOperation} {1}

# ---------------------------------------------------------------------------
# Housekeeping peripherals.
#
# The timer is not decoration: it is what turns "the test passed" into a
# throughput figure that can be compared against the benchmark's.
# ---------------------------------------------------------------------------
add_instance jtag_uart altera_avalon_jtag_uart

add_instance sysid altera_avalon_sysid_qsys
set_instance_parameter_value sysid {id} {3735928559}

add_instance timer altera_avalon_timer
set_instance_parameter_value timer {alwaysRun} {0}
set_instance_parameter_value timer {period} {1}
set_instance_parameter_value timer {periodUnits} {MSEC}

add_instance pio_led altera_avalon_pio
set_instance_parameter_value pio_led {direction} {Output}
set_instance_parameter_value pio_led {width} {10}

# ---------------------------------------------------------------------------
# The component under demonstration.
#
# The preset carries the geometry and the timings for the part fitted to this
# board, so nothing here is typed from memory. The clock is NOT a parameter -
# the controller takes it from the clock source connected below.
# ---------------------------------------------------------------------------
add_instance sdram altera_avalon_mm_sdram_controller
apply_preset sdram "ISSI IS42S16320D-7 - DE10-Lite 64 MByte"

# ---------------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------------
add_connection clk.clk       cpu.clk
add_connection clk.clk       onchip_ram.clk1
add_connection clk.clk       jtag_uart.clk
add_connection clk.clk       sysid.clk
add_connection clk.clk       timer.clk
add_connection clk.clk       pio_led.clk
add_connection clk.clk       sdram.clk

add_connection clk.clk_reset cpu.reset
add_connection clk.clk_reset onchip_ram.reset1
add_connection clk.clk_reset jtag_uart.reset
add_connection clk.clk_reset sysid.reset
add_connection clk.clk_reset timer.reset
add_connection clk.clk_reset pio_led.reset
add_connection clk.clk_reset sdram.reset

# Instruction fetch: on-chip RAM and the debug slave only. The CPU never
# fetches from the SDRAM - see the note at the top.
add_connection cpu.instruction_master onchip_ram.s1
add_connection cpu.instruction_master cpu.debug_mem_slave

# Data: everything, including the memory under test.
add_connection cpu.data_master onchip_ram.s1
add_connection cpu.data_master jtag_uart.avalon_jtag_slave
add_connection cpu.data_master sysid.control_slave
add_connection cpu.data_master timer.s1
add_connection cpu.data_master pio_led.s1
add_connection cpu.data_master sdram.s1
add_connection cpu.data_master cpu.debug_mem_slave

# The SDRAM is the one slave that must NOT be cached blindly: the test needs
# to choose when it is looking at the device and when at the cache. Leaving it
# cacheable and flushing explicitly is the realistic arrangement, and it is
# what the software does.

add_connection cpu.irq jtag_uart.irq
set_connection_parameter_value cpu.irq/jtag_uart.irq irqNumber {1}
add_connection cpu.irq timer.irq
set_connection_parameter_value cpu.irq/timer.irq irqNumber {0}

# ---------------------------------------------------------------------------
# Address map. Fixed rather than auto-assigned, so the numbers in the
# software's header and in README.md stay true.
# ---------------------------------------------------------------------------
set_connection_parameter_value cpu.data_master/onchip_ram.s1        baseAddress {0x00000000}
set_connection_parameter_value cpu.instruction_master/onchip_ram.s1 baseAddress {0x00000000}
set_connection_parameter_value cpu.data_master/cpu.debug_mem_slave         baseAddress {0x00040000}
set_connection_parameter_value cpu.instruction_master/cpu.debug_mem_slave  baseAddress {0x00040000}
set_connection_parameter_value cpu.data_master/sdram.s1              baseAddress {0x08000000}
set_connection_parameter_value cpu.data_master/jtag_uart.avalon_jtag_slave baseAddress {0x00041000}
set_connection_parameter_value cpu.data_master/sysid.control_slave   baseAddress {0x00041010}
set_connection_parameter_value cpu.data_master/timer.s1              baseAddress {0x00041020}
set_connection_parameter_value cpu.data_master/pio_led.s1            baseAddress {0x00041040}

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------
set_interface_property clk        EXPORT_OF clk.clk_in
set_interface_property reset      EXPORT_OF clk.clk_in_reset
set_interface_property sdram_wire EXPORT_OF sdram.wire
set_interface_property led        EXPORT_OF pio_led.external_connection

save_system sdram_nios_sys.qsys
puts "=== system saved ==="
