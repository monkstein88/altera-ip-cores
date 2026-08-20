/* =============================================================================
 * altera_avalon_mm_firewall_regs.h
 *
 * Register map for the Avalon-MM Firewall IP core, v1.0.
 *
 * This header is the low level: offsets, accessors and bit masks, and nothing
 * else. It depends only on <io.h>, so it is usable from a bare-metal
 * application, from an interrupt handler, or from a BSP with no HAL driver at
 * all. The driver in HAL/ is built on top of it.
 *
 * ---------------------------------------------------------------------------
 * BYTE OFFSETS vs WORD ADDRESSES
 * ---------------------------------------------------------------------------
 * The csr port is WORD-addressed in hardware - Platform Designer's default
 * addressUnits for an Avalon-MM agent - so the RTL sees address 0,1,2,...
 * The interconnect converts, and software sees byte offsets 0x00,0x04,0x08,...
 *
 * Both are given below. The *_OFST macros are byte offsets, which is what the
 * IORD_32DIRECT/IOWR_32DIRECT accessors take and what the documentation quotes.
 * The *_REG macros are the word indices the RTL decodes, provided because they
 * are what you will see in a simulation waveform and because getting the
 * factor of four wrong is the easiest mistake to make with this core.
 *
 * The accessors use IORD_32DIRECT rather than IORD, deliberately: IORD scales
 * its argument by SYSTEM_BUS_WIDTH, so it would silently do the wrong thing on
 * a system whose native word is not 32 bits. Every register here is 32 bits
 * wide regardless.
 * ===========================================================================*/

#ifndef __ALTERA_AVALON_MM_FIREWALL_REGS_H__
#define __ALTERA_AVALON_MM_FIREWALL_REGS_H__

#include <io.h>

/* ------------------------------------------------------- register offsets */

#define ALTERA_AVALON_MM_FIREWALL_CTRL_REG              0
#define ALTERA_AVALON_MM_FIREWALL_STATUS_REG            1
#define ALTERA_AVALON_MM_FIREWALL_IRQ_ENABLE_REG        2
#define ALTERA_AVALON_MM_FIREWALL_TIMEOUT_REG           3
#define ALTERA_AVALON_MM_FIREWALL_FAULT_ADDR_REG        4
#define ALTERA_AVALON_MM_FIREWALL_FAULT_INFO_REG        5
#define ALTERA_AVALON_MM_FIREWALL_CORE_INFO_REG         6
#define ALTERA_AVALON_MM_FIREWALL_RECOVERY_REG          7

#define ALTERA_AVALON_MM_FIREWALL_CTRL_OFST             0x00
#define ALTERA_AVALON_MM_FIREWALL_STATUS_OFST           0x04
#define ALTERA_AVALON_MM_FIREWALL_IRQ_ENABLE_OFST       0x08
#define ALTERA_AVALON_MM_FIREWALL_TIMEOUT_OFST          0x0C
#define ALTERA_AVALON_MM_FIREWALL_FAULT_ADDR_OFST       0x10
#define ALTERA_AVALON_MM_FIREWALL_FAULT_INFO_OFST       0x14
#define ALTERA_AVALON_MM_FIREWALL_CORE_INFO_OFST        0x18
#define ALTERA_AVALON_MM_FIREWALL_RECOVERY_OFST         0x1C

/* Rule table. i runs 0 .. NUM_RULES-1; NUM_RULES is readable from CORE_INFO. */
#define ALTERA_AVALON_MM_FIREWALL_RULE_TABLE_OFST       0x40
#define ALTERA_AVALON_MM_FIREWALL_RULE_STRIDE           0x10

#define ALTERA_AVALON_MM_FIREWALL_RULE_BASE_OFST(i)  \
    (ALTERA_AVALON_MM_FIREWALL_RULE_TABLE_OFST + \
     (i) * ALTERA_AVALON_MM_FIREWALL_RULE_STRIDE + 0x0)
#define ALTERA_AVALON_MM_FIREWALL_RULE_LIMIT_OFST(i) \
    (ALTERA_AVALON_MM_FIREWALL_RULE_TABLE_OFST + \
     (i) * ALTERA_AVALON_MM_FIREWALL_RULE_STRIDE + 0x4)
#define ALTERA_AVALON_MM_FIREWALL_RULE_PERM_OFST(i)  \
    (ALTERA_AVALON_MM_FIREWALL_RULE_TABLE_OFST + \
     (i) * ALTERA_AVALON_MM_FIREWALL_RULE_STRIDE + 0x8)

/* ------------------------------------------------------------- accessors */

#define IORD_ALTERA_AVALON_MM_FIREWALL_CTRL(base) \
    IORD_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_CTRL_OFST)
#define IOWR_ALTERA_AVALON_MM_FIREWALL_CTRL(base, data) \
    IOWR_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_CTRL_OFST, (data))

#define IORD_ALTERA_AVALON_MM_FIREWALL_STATUS(base) \
    IORD_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_STATUS_OFST)
/* Write-1-to-clear on bits [3:0]. Bits [9:4] are read-only and ignore writes. */
#define IOWR_ALTERA_AVALON_MM_FIREWALL_STATUS(base, data) \
    IOWR_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_STATUS_OFST, (data))

#define IORD_ALTERA_AVALON_MM_FIREWALL_IRQ_ENABLE(base) \
    IORD_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_IRQ_ENABLE_OFST)
#define IOWR_ALTERA_AVALON_MM_FIREWALL_IRQ_ENABLE(base, data) \
    IOWR_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_IRQ_ENABLE_OFST, (data))

#define IORD_ALTERA_AVALON_MM_FIREWALL_TIMEOUT(base) \
    IORD_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_TIMEOUT_OFST)
#define IOWR_ALTERA_AVALON_MM_FIREWALL_TIMEOUT(base, data) \
    IOWR_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_TIMEOUT_OFST, (data))

#define IORD_ALTERA_AVALON_MM_FIREWALL_FAULT_ADDR(base) \
    IORD_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_FAULT_ADDR_OFST)
#define IORD_ALTERA_AVALON_MM_FIREWALL_FAULT_INFO(base) \
    IORD_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_FAULT_INFO_OFST)
#define IORD_ALTERA_AVALON_MM_FIREWALL_CORE_INFO(base) \
    IORD_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_CORE_INFO_OFST)

/* Write-only, self-clearing; reads as zero. */
#define IOWR_ALTERA_AVALON_MM_FIREWALL_RECOVERY(base, data) \
    IOWR_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_RECOVERY_OFST, (data))

#define IORD_ALTERA_AVALON_MM_FIREWALL_RULE_BASE(base, i) \
    IORD_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_RULE_BASE_OFST(i))
#define IOWR_ALTERA_AVALON_MM_FIREWALL_RULE_BASE(base, i, data) \
    IOWR_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_RULE_BASE_OFST(i), (data))

#define IORD_ALTERA_AVALON_MM_FIREWALL_RULE_LIMIT(base, i) \
    IORD_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_RULE_LIMIT_OFST(i))
#define IOWR_ALTERA_AVALON_MM_FIREWALL_RULE_LIMIT(base, i, data) \
    IOWR_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_RULE_LIMIT_OFST(i), (data))

#define IORD_ALTERA_AVALON_MM_FIREWALL_RULE_PERM(base, i) \
    IORD_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_RULE_PERM_OFST(i))
#define IOWR_ALTERA_AVALON_MM_FIREWALL_RULE_PERM(base, i, data) \
    IOWR_32DIRECT((base), ALTERA_AVALON_MM_FIREWALL_RULE_PERM_OFST(i), (data))

/* --------------------------------------------------------------- CTRL */

#define ALTERA_AVALON_MM_FIREWALL_CTRL_ENABLE_MSK          (0x1)
#define ALTERA_AVALON_MM_FIREWALL_CTRL_ENABLE_OFST         (0)
#define ALTERA_AVALON_MM_FIREWALL_CTRL_AUTO_ISOLATE_MSK    (0x2)
#define ALTERA_AVALON_MM_FIREWALL_CTRL_AUTO_ISOLATE_OFST   (1)
#define ALTERA_AVALON_MM_FIREWALL_CTRL_MANUAL_ISOLATE_MSK  (0x4)
#define ALTERA_AVALON_MM_FIREWALL_CTRL_MANUAL_ISOLATE_OFST (2)

/* CTRL resets to ENABLE | AUTO_ISOLATE. The core is secure by default; do not
   clear ENABLE during initialisation "to get going" and forget to set it. */
#define ALTERA_AVALON_MM_FIREWALL_CTRL_RESET_VALUE         (0x3)

/* -------------------------------------------------------------- STATUS */
/* Bits [3:0] are sticky, write 1 to clear. Bits [9:4] are live, read-only. */

#define ALTERA_AVALON_MM_FIREWALL_STATUS_ADDR_VIOL_MSK     (0x001)
#define ALTERA_AVALON_MM_FIREWALL_STATUS_PERM_VIOL_MSK     (0x002)
#define ALTERA_AVALON_MM_FIREWALL_STATUS_TIMEOUT_MSK       (0x004)
#define ALTERA_AVALON_MM_FIREWALL_STATUS_BURST_VIOL_MSK    (0x008)
#define ALTERA_AVALON_MM_FIREWALL_STATUS_ISOLATED_MSK      (0x010)
#define ALTERA_AVALON_MM_FIREWALL_STATUS_BLOCKED_MSK       (0x020)
#define ALTERA_AVALON_MM_FIREWALL_STATUS_WR_BUSY_MSK       (0x040)
#define ALTERA_AVALON_MM_FIREWALL_STATUS_RD_BUSY_MSK       (0x080)
#define ALTERA_AVALON_MM_FIREWALL_STATUS_WR_CMD_STUCK_MSK  (0x100)
#define ALTERA_AVALON_MM_FIREWALL_STATUS_RD_CMD_STUCK_MSK  (0x200)

/* The four write-1-to-clear bits, as one mask. */
#define ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK        (0x00F)

/* ---------------------------------------------------------- IRQ_ENABLE */
/* One bit per sticky STATUS source, in the same positions. Resets to all
   enabled. Masking affects only the irq output, not the latching. */

#define ALTERA_AVALON_MM_FIREWALL_IRQ_ADDR_MSK       (0x1)
#define ALTERA_AVALON_MM_FIREWALL_IRQ_PERM_MSK       (0x2)
#define ALTERA_AVALON_MM_FIREWALL_IRQ_TIMEOUT_MSK    (0x4)
#define ALTERA_AVALON_MM_FIREWALL_IRQ_BURST_MSK      (0x8)
#define ALTERA_AVALON_MM_FIREWALL_IRQ_ALL_MSK        (0xF)

/* ---------------------------------------------------------- FAULT_INFO */

#define ALTERA_AVALON_MM_FIREWALL_FAULT_WAS_WRITE_MSK  (0x1)
#define ALTERA_AVALON_MM_FIREWALL_FAULT_TYPE(v)        (((v) >> 1) & 0x7)
#define ALTERA_AVALON_MM_FIREWALL_FAULT_BURSTCOUNT(v)  (((v) >> 8) & 0xFF)

/* Fault type codes. BURST_RANGE and BURST_DENIED share STATUS.BURST_VIOLATION
   and are distinguishable only here, which is why the field exists. */
#define ALTERA_AVALON_MM_FIREWALL_FAULT_NONE          0
#define ALTERA_AVALON_MM_FIREWALL_FAULT_ADDR          1  /* unmapped          */
#define ALTERA_AVALON_MM_FIREWALL_FAULT_PERM          2  /* wrong direction   */
#define ALTERA_AVALON_MM_FIREWALL_FAULT_TIMEOUT       3  /* downstream quiet  */
#define ALTERA_AVALON_MM_FIREWALL_FAULT_BURST_RANGE   4  /* overran window    */
#define ALTERA_AVALON_MM_FIREWALL_FAULT_BURST_DENIED  5  /* bursts forbidden  */

/* ----------------------------------------------------------- CORE_INFO */

#define ALTERA_AVALON_MM_FIREWALL_INFO_NUM_RULES(v)   ((v) & 0xFF)
#define ALTERA_AVALON_MM_FIREWALL_INFO_BURST_WIDTH(v) (((v) >> 8) & 0x1F)
#define ALTERA_AVALON_MM_FIREWALL_INFO_BEAT_SHIFT(v)  (((v) >> 13) & 0x7)
#define ALTERA_AVALON_MM_FIREWALL_INFO_VERSION(v)     (((v) >> 16) & 0xFFFF)

/* Largest burst the hardware can express, in beats. */
#define ALTERA_AVALON_MM_FIREWALL_INFO_MAX_BEATS(v) \
    (1u << (ALTERA_AVALON_MM_FIREWALL_INFO_BURST_WIDTH(v) - 1u))

#define ALTERA_AVALON_MM_FIREWALL_VERSION_1_0         0x0100

/* ------------------------------------------------------------ RECOVERY */

/* Declares downstream state discarded: releases STATUS.BLOCKED and withdraws
   any frozen m0 command. Issue it only while the protected peripheral is held
   in reset - see the driver and the user guide. */
#define ALTERA_AVALON_MM_FIREWALL_RECOVERY_UNBLOCK_MSK (0x1)

/* ----------------------------------------------------------- RULE_PERM */

#define ALTERA_AVALON_MM_FIREWALL_PERM_READ_MSK   (0x1)
#define ALTERA_AVALON_MM_FIREWALL_PERM_WRITE_MSK  (0x2)
#define ALTERA_AVALON_MM_FIREWALL_PERM_VALID_MSK  (0x4)
#define ALTERA_AVALON_MM_FIREWALL_PERM_BURST_MSK  (0x8)

#endif /* __ALTERA_AVALON_MM_FIREWALL_REGS_H__ */
