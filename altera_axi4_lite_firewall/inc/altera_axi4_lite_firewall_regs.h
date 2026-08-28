/* =============================================================================
 * altera_axi4_lite_firewall_regs.h
 *
 * Register map for the AXI4-Lite Firewall IP core, v2.0.
 *
 * This header stands alone. It has no dependency beyond <stdint.h> and, on
 * Nios II, <io.h>, so an application that wants nothing but the offsets and
 * bit names can include it without pulling in the driver.
 *
 * All registers are 32 bits and word aligned, on the s_axi_ctrl port.
 * ===========================================================================*/

#ifndef __ALTERA_AXI4_LITE_FIREWALL_REGS_H__
#define __ALTERA_AXI4_LITE_FIREWALL_REGS_H__

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------- registers */
#define FW_CTRL              0x00u
#define FW_STATUS            0x04u
#define FW_IRQ_ENABLE        0x08u
#define FW_TIMEOUT_VALUE     0x0Cu
#define FW_FAULT_ADDR        0x10u
#define FW_FAULT_INFO        0x14u
#define FW_CORE_INFO         0x18u
#define FW_RECOVERY          0x1Cu

/* Rule i: base / limit / permissions */
#define FW_RULE_BASE(i)      (0x40u + (i) * 0x10u + 0x0u)
#define FW_RULE_LIMIT(i)     (0x40u + (i) * 0x10u + 0x4u)
#define FW_RULE_PERM(i)      (0x40u + (i) * 0x10u + 0x8u)

/* CTRL */
#define FW_CTRL_GLOBAL_ENABLE   0x1u   /* 1 = enforce rules (reset default)   */
#define FW_CTRL_AUTO_ISOLATE    0x2u   /* 1 = a timeout latches ISOLATED      */
#define FW_CTRL_MANUAL_ISOLATE  0x4u

/* STATUS - bits 0..2 are sticky and write-1-to-clear; 3..8 are live, read-only */
#define FW_ST_ADDR_VIOLATION 0x001u
#define FW_ST_PERM_VIOLATION 0x002u
#define FW_ST_TIMEOUT_ERROR  0x004u
#define FW_ST_ISOLATED       0x008u
#define FW_ST_BLOCKED        0x010u   /* downstream shut; only UNBLOCK clears */
#define FW_ST_WR_RESP_BUSY   0x020u   /* peripheral owes a write response     */
#define FW_ST_RD_RESP_BUSY   0x040u   /* peripheral owes a read response      */
#define FW_ST_WR_CMD_STUCK   0x080u   /* AWVALID/WVALID never accepted        */
#define FW_ST_RD_CMD_STUCK   0x100u   /* ARVALID never accepted               */
#define FW_ST_STICKY         (FW_ST_ADDR_VIOLATION | \
                              FW_ST_PERM_VIOLATION | \
                              FW_ST_TIMEOUT_ERROR)

/* IRQ_ENABLE - one bit per sticky source, same positions */
#define FW_IRQ_ADDR          0x1u
#define FW_IRQ_PERM          0x2u
#define FW_IRQ_TIMEOUT       0x4u
#define FW_IRQ_ALL           0x7u

/* RULE_PERM */
#define FW_PERM_READ         0x1u
#define FW_PERM_WRITE        0x2u
#define FW_PERM_VALID        0x4u
#define FW_PERM_RW           (FW_PERM_VALID | FW_PERM_READ | FW_PERM_WRITE)
#define FW_PERM_RO           (FW_PERM_VALID | FW_PERM_READ)
#define FW_PERM_WO           (FW_PERM_VALID | FW_PERM_WRITE)

/* RECOVERY - self-clearing, reads back 0 */
#define FW_RECOVERY_UNBLOCK  0x1u

/* FAULT_INFO */
#define FW_FAULT_WAS_WRITE   0x1u
#define FW_FAULT_TYPE_SHIFT  1
#define FW_FAULT_TYPE_MASK   0x7u
#define FW_FAULT_TYPE_ADDR   1u
#define FW_FAULT_TYPE_PERM   2u
#define FW_FAULT_TYPE_TMO    3u

/* CORE_INFO */
#define FW_CORE_VERSION(ci)   (((ci) >> 16) & 0xFFFFu)
#define FW_CORE_NUM_RULES(ci) ((ci) & 0xFFu)
#define FW_VERSION_2_0        0x0200u

/* The core's documentation specifies a minimum peripheral reset duration.
   AMD specify the same figure for their AXI Firewall's equivalent step. */
#define FW_RESET_MIN_CLOCKS   16u

/* --------------------------------------------------------------------------
 * Register access.
 *
 * Define FW_IORD32 / FW_IOWR32 before including this header to redirect them.
 * The host test in the DE10-Lite example does exactly that, which is what
 * lets the driver logic be exercised against a software model of the register
 * file on a workstation.
 *
 * On Nios II these are the DIRECT variants on purpose: they bypass the data
 * cache. A cached read of a status register returns whatever was there when
 * the line was filled, which for a fault register is exactly the wrong answer.
 * -------------------------------------------------------------------------- */
#ifndef FW_IORD32
# ifdef __nios2__
#  include "io.h"
#  define FW_IORD32(base, off)       IORD_32DIRECT((base), (off))
#  define FW_IOWR32(base, off, val)  IOWR_32DIRECT((base), (off), (val))
# else
#  define FW_IORD32(base, off) \
       (*(volatile uint32_t *)((uintptr_t)(base) + (uintptr_t)(off)))
#  define FW_IOWR32(base, off, val) \
       (*(volatile uint32_t *)((uintptr_t)(base) + (uintptr_t)(off)) = (uint32_t)(val))
# endif
#endif

#ifdef __cplusplus
}
#endif

#endif /* __ALTERA_AXI4_LITE_FIREWALL_REGS_H__ */
