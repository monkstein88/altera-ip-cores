# =============================================================================
# altera_avalon_mm_sdcard_controller_sw.tcl
#
# Nios II BSP driver description for the Avalon-MM SD Card Controller (SPI).
#
# This is the file that makes the driver real. Without it,
# nios2-bsp-generate-files has no idea the component ships software: the .c and
# .h would have to be copied into every application by hand, and would then
# drift from the hardware they describe. With it, adding the component to a
# Platform Designer system is enough - the BSP picks up the driver, compiles it,
# and puts the headers on the include path.
#
# HOW IT IS FOUND
# ---------------
# The BSP tools scan the IP search path for *_sw.tcl and match `hw_class_name`
# against the `set_module_property NAME` in the component's _hw.tcl. The file
# name itself is not matched.
#
# Regenerate the BSP after changing anything here:
#     nios2-bsp-generate-files --settings settings.bsp --bsp-dir .
# =============================================================================

create_driver altera_avalon_mm_sdcard_controller_driver

# Must equal `set_module_property NAME` in
# altera_avalon_mm_sdcard_controller_hw.tcl. This is the only link between the
# hardware component and this driver; get it wrong and the BSP silently
# generates nothing, which looks exactly like the driver having no effect.
set_sw_property hw_class_name altera_avalon_mm_sdcard_controller

set_sw_property version 1.0

# Refuse to build against hardware older than this. The register map is not
# self-describing beyond CORE_INFO, and the driver additionally checks the
# major version at run time - belt and braces, because a BSP can be copied
# between projects far more easily than it can be kept in step with them.
set_sw_property min_compatible_hw_version 1.0

# Emit ALTERA_AVALON_MM_SDCARD_CONTROLLER_INSTANCE / _INIT into alt_sys_init.c,
# so every instance is constructed from system.h and its interrupt registered
# before main() runs.
#
# What auto-initialisation deliberately does NOT do is identify the card.
# Identification takes hundreds of milliseconds - the specification allows a
# full second for ACMD41 alone - it can fail for reasons the application needs
# to know about, and there may be no card in the socket. Doing it before main()
# would produce an application that cannot boot without a card present. The
# division is the safe one: after alt_sys_init() the core is bound, version
# checked and its ISR registered, and the card is untouched until the
# application calls alt_sdcard_probe().
set_sw_property auto_initialize true

set_sw_property bsp_subdirectory drivers

set_sw_property display_name "Avalon-MM SD Card Controller driver"

# The driver registers its ISR with alt_ic_isr_register(), which is the
# ENHANCED interrupt API. Declaring that is not optional bookkeeping: the SBT
# assumes legacy-only when the property is absent, and it analyses this
# property across every driver in the system to decide which API the BSP is
# built against. A driver that silently claims legacy while calling the
# enhanced entry point is how a system ends up with a BSP that does not define
# ALT_ENHANCED_INTERRUPT_API_PRESENT and a driver that will not link.
set_sw_property supported_interrupt_apis "enhanced_interrupt_api"

# The ISR reads and acknowledges IRQ_STATUS and touches no state outside its
# own device structure, so a higher-priority ISR may preempt it safely.
set_sw_property isr_preemption_supported true

# -----------------------------------------------------------------------
# Source files
#
# Paths are relative to this file. inc/ carries the register map on its own,
# with no dependency beyond <io.h>, so an application that wants nothing but
# the offsets - or that drives the core from an ISR without the HAL layer - can
# include it without pulling in the driver.
# -----------------------------------------------------------------------
add_sw_property c_source       HAL/src/altera_avalon_mm_sdcard_controller.c
add_sw_property include_source HAL/inc/altera_avalon_mm_sdcard_controller.h
add_sw_property include_source inc/altera_avalon_mm_sdcard_controller_regs.h

# -----------------------------------------------------------------------
# Supported BSP types
#
# Plain C with no OS dependency: no allocation, no blocking primitives, no
# critical sections beyond what alt_ic_isr_register provides. It builds under
# both.
#
# Note that the block API BUSY-WAITS rather than sleeping. Under UCOSII that
# holds the calling task for the duration of a transfer - about 170 us per
# block at 25 MHz - which is fine for a filesystem task and wrong for an
# interrupt handler. Use the event callback if you need completion
# asynchronously.
# -----------------------------------------------------------------------
add_sw_property supported_bsp_type HAL
add_sw_property supported_bsp_type UCOSII
