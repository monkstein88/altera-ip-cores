# =============================================================================
# axi4_lite_firewall_sw.tcl
#
# Nios II BSP driver description for the AXI4-Lite Firewall IP core.
#
# This is the file that makes the driver real. Without it, nios2-bsp-generate-
# files has no idea the component ships software: the .c and .h would have to
# be copied into every application by hand, and would then drift from the
# hardware they describe. That is exactly what this example used to do. With
# it, adding the component to a Platform Designer system is enough - the BSP
# picks up the driver, compiles it, and puts the headers on the include path.
#
# HOW IT IS FOUND
# ---------------
# The BSP tools scan the IP search path for *_sw.tcl and match `hw_class_name`
# against the `set_module_property NAME` in the component's _hw.tcl. The file
# name itself is not matched, which is why this one can follow the
# axi4_lite_firewall_* convention used by the _hw.tcl while everything the
# compiler sees keeps the altera_axi4_lite_firewall_* prefix that
# `hw_class_name` requires.
#
# Regenerate the BSP after changing anything here:
#     nios2-bsp-generate-files --settings settings.bsp --bsp-dir .
# =============================================================================

create_driver altera_axi4_lite_firewall_driver

# Must equal `set_module_property NAME` in axi_firewall_hw.tcl. This is the
# only link between the hardware component and this driver; get it wrong and
# the BSP silently generates nothing, which looks exactly like the driver
# having no effect.
set_sw_property hw_class_name altera_axi4_lite_firewall

set_sw_property version 2.0

# Refuse to build against hardware older than this, and note that the boundary
# is a real one rather than a formality: a v1.x core acknowledges a fault and
# reopens the downstream by itself, so this driver's RECOVERY.UNBLOCK write
# would be meaningless there. The driver additionally checks CORE_INFO at run
# time - belt and braces, because a BSP can be copied between projects far more
# easily than it can be kept in step with them.
set_sw_property min_compatible_hw_version 2.0

# Emit ALTERA_AXI4_LITE_FIREWALL_INSTANCE / _INIT into alt_sys_init.c, so every
# instance is constructed from system.h and its interrupt is registered before
# main() runs.
#
# What auto-initialisation deliberately does NOT do is program the rule table
# or install the peripheral-reset callbacks - neither can be derived from the
# hardware. That division is the safe one: the table resets empty and the
# hardware is default-deny, so the state after alt_sys_init() is "everything
# denied", which is exactly what should be true while an application is still
# starting up.
set_sw_property auto_initialize true

set_sw_property bsp_subdirectory drivers

set_sw_property display_name "AXI4-Lite Firewall driver"

# The driver registers its ISR with alt_ic_isr_register(), which is the
# ENHANCED interrupt API. Declaring that is not optional bookkeeping: the SBT
# assumes legacy-only when the property is absent, and it analyses this
# property across every driver in the system to decide which API the BSP is
# built against. A driver that silently claims legacy while calling the
# enhanced entry point is how a system ends up with a BSP that does not define
# ALT_ENHANCED_INTERRUPT_API_PRESENT and a driver that will not link.
set_sw_property supported_interrupt_apis "enhanced_interrupt_api"

# The ISR takes no locks and touches no state outside its own device
# structure, so a higher-priority ISR may preempt it safely.
set_sw_property isr_preemption_supported true

# -----------------------------------------------------------------------
# Source files
#
# Paths are relative to this file. inc/ carries the register map on its own,
# with no dependency beyond <stdint.h>, so an application that wants nothing
# but the offsets can include it without pulling in the driver - and so the
# example's host test can compile the driver logic on a workstation.
# -----------------------------------------------------------------------
add_sw_property c_source       HAL/src/altera_axi4_lite_firewall.c
add_sw_property include_source HAL/inc/altera_axi4_lite_firewall.h
add_sw_property include_source inc/altera_axi4_lite_firewall_regs.h

# -----------------------------------------------------------------------
# Supported BSP types
#
# The driver is plain C with no OS dependency: no allocation, no blocking, no
# critical sections beyond what alt_ic_isr_register provides. It builds under
# both.
# -----------------------------------------------------------------------
add_sw_property supported_bsp_type HAL
add_sw_property supported_bsp_type UCOSII
