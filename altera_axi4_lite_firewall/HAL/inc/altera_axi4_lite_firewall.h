/* =============================================================================
 * altera_axi4_lite_firewall.h
 *
 * Nios II HAL driver for the AXI4-Lite Firewall IP core, v2.0.
 *
 * The register map lives in inc/altera_axi4_lite_firewall_regs.h, which has no
 * dependency beyond <stdint.h> and can be used on its own. This header adds
 * the device structure, the rule-programming helpers, the recovery sequence
 * and the interrupt.
 *
 * ---------------------------------------------------------------------------
 * THE ONE THING TO READ BEFORE USING THIS
 * ---------------------------------------------------------------------------
 * alt_axi4_lite_firewall_recover() holds the protected peripheral in reset
 * ACROSS the RECOVERY.UNBLOCK write, and releases it only afterwards. The
 * core's own documentation presents reset (step 4) and UNBLOCK (step 5) as
 * separate steps, which reads as though the reset may be a pulse that ends
 * before the UNBLOCK. It must not be.
 *
 * A timed-out command leaves m_axi_AWVALID (or ARVALID) asserted - AXI forbids
 * withdrawing it - and only UNBLOCK retracts it. If the peripheral is out of
 * reset during that window it will accept the orphaned command and commit a
 * transaction the master was already told had FAILED. This is not theoretical:
 * it is scenario C of the DE10-Lite demo, which reproduces it deliberately and
 * on hardware. Scenario b is this ordering, and shows the stale write not
 * landing.
 *
 * The core does NOT own a reset output - that was removed in v2.0 - so
 * resetting the protected peripheral is the driver's job, via a reset bridge,
 * a PIO bit, or whatever the system provides. Supply the three callbacks or
 * recovery refuses to run.
 *
 * Transactions attempted while blocked are ANSWERED WITH SLVERR, not stalled.
 * Anything issued between the fault and the recovery has failed and needs
 * retrying; drivers for peripherals behind this core need a retry path.
 *
 * ---------------------------------------------------------------------------
 * AUTOMATIC INITIALISATION
 * ---------------------------------------------------------------------------
 * axi4_lite_firewall_sw.tcl sets auto_initialize, so the BSP emits
 * ALTERA_AXI4_LITE_FIREWALL_INSTANCE / _INIT into alt_sys_init.c for every
 * instance in the system, and alt_sys_init() runs before main().
 *
 * What that gets you is deliberately limited: the base address and interrupt
 * numbers from system.h, a version check, the rule count read from CORE_INFO,
 * and the interrupt registered. It does NOT program the rule table and does
 * NOT install the reset callbacks, because neither can be derived from the
 * hardware. That is the safe division: the rule table resets empty and the
 * hardware is default-deny, so the state after alt_sys_init() is "everything
 * denied", which is the right thing to be true while the application is still
 * starting up.
 *
 * The application then calls alt_axi4_lite_firewall_set_reset_handlers() and
 * programs its rules.
 *
 * ---------------------------------------------------------------------------
 * OFF-TARGET USE
 * ---------------------------------------------------------------------------
 * Everything except the interrupt is portable: define FW_IORD32/FW_IOWR32
 * before including this header and the driver runs against a software model of
 * the register file. The DE10-Lite example's host test does exactly that. The
 * interrupt plumbing is guarded by __nios2__ and simply is not compiled
 * elsewhere.
 * ===========================================================================*/

#ifndef __ALTERA_AXI4_LITE_FIREWALL_H__
#define __ALTERA_AXI4_LITE_FIREWALL_H__

#include "altera_axi4_lite_firewall_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

struct alt_axi4_lite_firewall_dev_s;

/* Peripheral reset hooks. `context` is the dev's own `context` field. */
typedef void (*alt_axi4_lite_firewall_reset_fn)(void *context);
typedef void (*alt_axi4_lite_firewall_delay_fn)(void *context, uint32_t clocks);

typedef struct alt_axi4_lite_firewall_dev_s
{
    uintptr_t base;              /* s_axi_ctrl base address                  */
    int32_t   irq_controller_id; /* -1 when the irq is left unconnected      */
    int32_t   irq;               /* -1 when the irq is left unconnected      */

    uint32_t  version;           /* from CORE_INFO, filled by init()         */
    uint32_t  num_rules;         /* from CORE_INFO, filled by init()         */

    /* Mandatory for recover(). Install with set_reset_handlers(). */
    alt_axi4_lite_firewall_reset_fn assert_reset;
    alt_axi4_lite_firewall_reset_fn release_reset;
    alt_axi4_lite_firewall_delay_fn delay_clocks;
    void                           *context;

    /* Optional. Called from the ISR with STATUS already read, and with the
       sticky bits already acknowledged so the level-sensitive irq deasserts.
       Keep it short: it runs in interrupt context. */
    void (*on_fault)(struct alt_axi4_lite_firewall_dev_s *dev, uint32_t status);

    uint32_t  fault_count;       /* incremented by the ISR                    */
    uint32_t  last_status;       /* STATUS as the ISR saw it                  */
} alt_axi4_lite_firewall_dev;

/* One address window, for alt_axi4_lite_firewall_configure(). */
typedef struct
{
    uint32_t base;
    uint32_t limit;
    uint32_t perms;              /* FW_PERM_RW / _RO / _WO                    */
} alt_axi4_lite_firewall_rule;

/* Return codes */
#define FW_OK                  0
#define FW_ERR_BAD_VERSION    -1
#define FW_ERR_STILL_BLOCKED  -2
#define FW_ERR_NO_RESET_HOOK  -3
#define FW_WARN_NOT_QUIESCED   1   /* recovered, but the poll timed out */

/* ---------------------------------------------------------------------------
 * WHICH system.h NAMES THE INSTANCE MACRO USES - read this if it will not
 * compile.
 *
 * This core has TWO slaves, s_axi (the protected path) and s_axi_ctrl (the
 * register file), and Qsys names its system.h macros according to how many of
 * them the CPU can see:
 *
 *   CPU sees BOTH slaves      ->  FW_S_AXI_BASE, FW_S_AXI_CTRL_BASE
 *   CPU sees only s_axi_ctrl  ->  FW_BASE
 *
 * The BSP generator passes the MODULE name (FW) to the macro either way, so a
 * driver cannot satisfy both spellings at once. The default below is the
 * two-slave form, because that is the configuration in which the CPU is also
 * the master being policed - the common one, and the one this repository's
 * DE10-Lite example uses.
 *
 * If your system connects only the control port to the CPU, system.h collapses
 * to FW_BASE and you must say so, by adding this to your application's
 * CFLAGS (or to the BSP's public defines):
 *
 *   -DALTERA_AXI4_LITE_FIREWALL_BASE_OF(n)=n##_BASE
 *   -DALTERA_AXI4_LITE_FIREWALL_IRQ_OF(n)=n##_IRQ
 *   -DALTERA_AXI4_LITE_FIREWALL_IC_OF(n)=n##_IRQ_INTERRUPT_CONTROLLER_ID
 *
 * Getting it wrong produces an "FW_BASE undeclared" (or "FW_S_AXI_CTRL_BASE
 * undeclared") error from alt_sys_init.c, which is at least a legible symptom
 * once you know what it means.
 * ------------------------------------------------------------------------ */
#ifndef ALTERA_AXI4_LITE_FIREWALL_BASE_OF
# define ALTERA_AXI4_LITE_FIREWALL_BASE_OF(n)  n##_S_AXI_CTRL_BASE
#endif
#ifndef ALTERA_AXI4_LITE_FIREWALL_IRQ_OF
# define ALTERA_AXI4_LITE_FIREWALL_IRQ_OF(n)   n##_S_AXI_CTRL_IRQ
#endif
#ifndef ALTERA_AXI4_LITE_FIREWALL_IC_OF
# define ALTERA_AXI4_LITE_FIREWALL_IC_OF(n) \
             n##_S_AXI_CTRL_IRQ_INTERRUPT_CONTROLLER_ID
#endif

/*
 * Emitted into alt_sys_init.c by the BSP generator, once per instance.
 *
 * The _IRQ and _IRQ_INTERRUPT_CONTROLLER_ID names are defined by system.h as
 * -1 when the interrupt sender is left unconnected, which init() checks before
 * trying to register a handler.
 *
 * DELIBERATE DEVIATION: the storage is NOT declared static, matching this
 * repository's Avalon-MM Firewall driver and for the same reason. Most Altera
 * drivers hand the application a device through the HAL device list
 * (alt_dev_reg / alt_open), which only suits character and file devices; this
 * is neither. The application must nevertheless reach the structure, because
 * the peripheral-reset callbacks cannot be derived from hardware and have to
 * be installed after alt_sys_init() has run:
 *
 *     extern alt_axi4_lite_firewall_dev firewall_0;   // named as in system.h
 *
 * The cost is a global symbol per instance, named after the Platform Designer
 * instance name. Keep that in mind before naming an application variable the
 * same thing.
 */
#define ALTERA_AXI4_LITE_FIREWALL_INSTANCE(name, dev)                         \
    alt_axi4_lite_firewall_dev dev = {                                        \
        ALTERA_AXI4_LITE_FIREWALL_BASE_OF(name),                              \
        ALTERA_AXI4_LITE_FIREWALL_IC_OF(name),                                \
        ALTERA_AXI4_LITE_FIREWALL_IRQ_OF(name),                               \
        0, 0,                                                                 \
        (alt_axi4_lite_firewall_reset_fn)0,                                   \
        (alt_axi4_lite_firewall_reset_fn)0,                                   \
        (alt_axi4_lite_firewall_delay_fn)0,                                   \
        (void *)0,                                                            \
        (void (*)(struct alt_axi4_lite_firewall_dev_s *, uint32_t))0,         \
        0, 0                                                                  \
    }

#define ALTERA_AXI4_LITE_FIREWALL_INIT(name, dev)                             \
    alt_axi4_lite_firewall_init(&dev)

/* --------------------------------------------------------------------- API */

/*
 * Read CORE_INFO, populate version and num_rules, and register the interrupt
 * if one is connected. Returns FW_OK, or FW_ERR_BAD_VERSION if CORE_INFO
 * reports a version this driver does not speak.
 *
 * dev->base must already be set - ALTERA_AXI4_LITE_FIREWALL_INSTANCE does it.
 *
 * Worth checking the return: a v1.x core acknowledges a fault and reopens the
 * downstream by itself, so a v2.0 driver's UNBLOCK is redundant there - and
 * conversely a v1.x driver on a v2.0 core sees every transaction return SLVERR
 * after the first timeout, forever.
 */
int alt_axi4_lite_firewall_init(alt_axi4_lite_firewall_dev *dev);

/* Mandatory before recover(). Without all three, recover() refuses and
   returns FW_ERR_NO_RESET_HOOK. */
void alt_axi4_lite_firewall_set_reset_handlers(
        alt_axi4_lite_firewall_dev *dev,
        alt_axi4_lite_firewall_reset_fn assert_reset,
        alt_axi4_lite_firewall_reset_fn release_reset,
        alt_axi4_lite_firewall_delay_fn delay_clocks,
        void *context);

/* Optional fault callback, invoked from the ISR. */
void alt_axi4_lite_firewall_set_fault_handler(
        alt_axi4_lite_firewall_dev *dev,
        void (*on_fault)(struct alt_axi4_lite_firewall_dev_s *dev,
                         uint32_t status));

/* Clear every rule, set the timeout, enable interrupts and enforcement, and
   acknowledge any stale faults. Leaves the core default-deny. */
void alt_axi4_lite_firewall_reset_config(alt_axi4_lite_firewall_dev *dev,
                                         uint32_t timeout_cycles);

/* Program `count` rules from `rules`, then clear the remaining slots. */
int alt_axi4_lite_firewall_configure(alt_axi4_lite_firewall_dev *dev,
                                     const alt_axi4_lite_firewall_rule *rules,
                                     uint32_t count);

void alt_axi4_lite_firewall_set_rule(alt_axi4_lite_firewall_dev *dev,
                                     uint32_t i, uint32_t base,
                                     uint32_t limit, uint32_t perms);

void alt_axi4_lite_firewall_clear_rule(alt_axi4_lite_firewall_dev *dev,
                                       uint32_t i);

void alt_axi4_lite_firewall_set_timeout(alt_axi4_lite_firewall_dev *dev,
                                        uint32_t cycles);

uint32_t alt_axi4_lite_firewall_status(alt_axi4_lite_firewall_dev *dev);
int      alt_axi4_lite_firewall_is_blocked(alt_axi4_lite_firewall_dev *dev);

/* Acknowledge sticky faults. Does NOT reopen a downstream blocked by a
   timeout - that needs recover(). */
void alt_axi4_lite_firewall_ack(alt_axi4_lite_firewall_dev *dev,
                                uint32_t sticky_bits);

/* Decode the latched fault. Any output pointer may be NULL. */
void alt_axi4_lite_firewall_fault(alt_axi4_lite_firewall_dev *dev,
                                  uint32_t *addr, int *was_write,
                                  uint32_t *type);

const char *alt_axi4_lite_firewall_fault_name(uint32_t fault_info);

/* Full v2.0 recovery from a downstream timeout. See the header comment: the
   peripheral is held in reset across the UNBLOCK write.
   `poll_limit` bounds the wait for the busy bits - pass something finite. */
int alt_axi4_lite_firewall_recover(alt_axi4_lite_firewall_dev *dev,
                                   uint32_t poll_limit);

#ifdef __cplusplus
}
#endif

#endif /* __ALTERA_AXI4_LITE_FIREWALL_H__ */
