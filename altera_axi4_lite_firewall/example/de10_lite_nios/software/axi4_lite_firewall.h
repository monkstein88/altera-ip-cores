/* ===========================================================================
 * axi4_lite_firewall.h - driver for the AXI4-Lite Firewall IP core, v2.0
 *
 * Targets the Nios II HAL but does not require it: the register accessors
 * fall back to plain volatile pointer access off-target, which is what lets
 * test_firewall_host.c exercise this code against a software model of the
 * register file.
 *
 * THE ONE THING TO READ BEFORE USING THIS
 * ---------------------------------------
 * firewall_recover() holds the protected peripheral in reset ACROSS the
 * RECOVERY.UNBLOCK write, and releases it only afterwards. The core's own
 * documentation presents reset (step 4) and UNBLOCK (step 5) as separate
 * steps, which reads as though the reset may be a pulse that ends before the
 * UNBLOCK. It must not be.
 *
 * A timed-out command leaves m_axi_AWVALID (or ARVALID) asserted - AXI
 * forbids withdrawing it - and only UNBLOCK retracts it. If the peripheral is
 * out of reset during that window it will accept the orphaned command and
 * commit a transaction the master was already told had FAILED. This is not
 * theoretical: it is scenario C of the DE10-Lite demo, which reproduces it
 * deliberately and on hardware. Scenario b is this ordering, and shows the
 * stale write not landing.
 * ===========================================================================
 */

#ifndef AXI4_LITE_FIREWALL_H
#define AXI4_LITE_FIREWALL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --------------------------------------------------------------------------
 * Register map (s_axi_ctrl, 32-bit registers, word aligned)
 * -------------------------------------------------------------------------- */
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
 * Register access. Override FW_IORD32/FW_IOWR32 before including this header
 * to redirect them - the host test does exactly that.
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

/* --------------------------------------------------------------------------
 * Instance
 *
 * The peripheral reset hooks are mandatory for firewall_recover(). The core
 * no longer owns a reset output (that was removed in v2.0), so resetting the
 * protected peripheral is the driver's job - via a reset bridge, a PIO bit,
 * or whatever your system provides.
 * -------------------------------------------------------------------------- */
typedef struct {
    uintptr_t base;                                    /* s_axi_ctrl base    */
    void (*reset_assert)(void *ctx);                   /* drive reset active */
    void (*reset_release)(void *ctx);                  /* release it         */
    void (*delay_clocks)(void *ctx, uint32_t clocks);  /* busy-wait          */
    void  *ctx;
} firewall_t;

/* Return codes */
#define FW_OK                  0
#define FW_ERR_BAD_VERSION    -1
#define FW_ERR_STILL_BLOCKED  -2
#define FW_ERR_NO_RESET_HOOK  -3
#define FW_WARN_NOT_QUIESCED   1   /* recovered, but the poll timed out */

/* --------------------------------------------------------------------------
 * API
 * -------------------------------------------------------------------------- */

/* Check the core is the version this driver speaks. Returns the rule count,
   or FW_ERR_BAD_VERSION. Worth calling: a v1.x core acknowledges a fault and
   reopens the downstream by itself, so a v2.0 driver's UNBLOCK is redundant -
   and conversely a v1.x driver on a v2.0 core sees every transaction return
   SLVERR after the first timeout, forever. */
int firewall_probe(const firewall_t *fw);

/* Reset the core to a known state: rules all cleared, faults acknowledged,
   downstream open, interrupts enabled, enforcement on. */
void firewall_init(const firewall_t *fw, unsigned num_rules, uint32_t timeout_cycles);

/* Program rule `i`. Retires the rule before editing it: base, limit and
   permissions are three separate registers, so changing a LIVE rule in place
   leaves a window where the new base is paired with the old limit. */
void firewall_set_rule(const firewall_t *fw, unsigned i,
                       uint32_t base, uint32_t limit, uint32_t perms);

void firewall_clear_rule(const firewall_t *fw, unsigned i);

uint32_t firewall_status(const firewall_t *fw);

/* Acknowledge sticky faults. Also releases the auto-isolate latch. Does NOT
   reopen a downstream blocked by a timeout - that needs firewall_recover(). */
void firewall_ack(const firewall_t *fw, uint32_t sticky_bits);

/* Decode the latched fault. Any output pointer may be NULL. */
void firewall_fault(const firewall_t *fw, uint32_t *addr,
                    int *was_write, unsigned *type);

/* Full v2.0 recovery from a downstream timeout. See the header comment: the
   peripheral is held in reset across the UNBLOCK write.
   `poll_limit` bounds the wait for the busy bits - pass something finite. */
int firewall_recover(const firewall_t *fw, unsigned poll_limit);

#ifdef __cplusplus
}
#endif

#endif /* AXI4_LITE_FIREWALL_H */
