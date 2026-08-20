/* =============================================================================
 * altera_avalon_mm_firewall.h
 *
 * Nios II HAL driver for the Avalon-MM Firewall IP core, v1.0.
 *
 * The register map itself lives in inc/altera_avalon_mm_firewall_regs.h, which
 * has no dependency beyond <io.h> and can be used on its own. This header adds
 * the device structure, the rule-programming helpers, the ISR and the recovery
 * sequence.
 *
 * ---------------------------------------------------------------------------
 * THE ONE THING TO READ BEFORE USING THIS
 * ---------------------------------------------------------------------------
 * A firewall that has isolated a wedged peripheral answers every subsequent
 * transaction with an error until software runs the recovery sequence - and
 * that sequence must reset the protected peripheral, which this core cannot do
 * for you. Supply the two reset callbacks, or a single timeout takes the
 * peripheral out of service permanently.
 *
 * Transactions attempted while blocked are ANSWERED WITH AN ERROR, not
 * stalled. There is no window in which the firewall quietly holds traffic, so
 * anything issued between the fault and the recovery has failed and needs
 * retrying. Drivers for peripherals behind this core need a retry path.
 *
 * ---------------------------------------------------------------------------
 * AUTOMATIC INITIALISATION
 * ---------------------------------------------------------------------------
 * altera_avalon_mm_firewall_sw.tcl sets auto_initialize, so the BSP emits
 * ALTERA_AVALON_MM_FIREWALL_INSTANCE / _INIT into alt_sys_init.c for every
 * instance in the system, and alt_sys_init() runs before main().
 *
 * What that gets you is deliberately limited: the base address and interrupt
 * numbers from system.h, a version check, and the interrupt registered. It
 * does NOT program the rule table and does NOT install reset callbacks,
 * because neither can be derived from the hardware. That is the safe division:
 * the rule table resets empty and the hardware is default-deny, so the state
 * after alt_sys_init() is "everything denied", which is the right thing to be
 * true while the application is still starting up.
 *
 * The application then calls alt_avalon_mm_firewall_set_reset_handlers() and
 * alt_avalon_mm_firewall_configure().
 * ===========================================================================*/

#ifndef __ALTERA_AVALON_MM_FIREWALL_H__
#define __ALTERA_AVALON_MM_FIREWALL_H__

#include "altera_avalon_mm_firewall_regs.h"
#include "alt_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Short aliases for the register-header masks, for readability at call sites.
   The register header remains the single definition. */
#define ALT_AVMM_FW_PERM_READ    ALTERA_AVALON_MM_FIREWALL_PERM_READ_MSK
#define ALT_AVMM_FW_PERM_WRITE   ALTERA_AVALON_MM_FIREWALL_PERM_WRITE_MSK
#define ALT_AVMM_FW_PERM_VALID   ALTERA_AVALON_MM_FIREWALL_PERM_VALID_MSK
#define ALT_AVMM_FW_PERM_BURST   ALTERA_AVALON_MM_FIREWALL_PERM_BURST_MSK

/* ------------------------------------------------------------------ device */

struct alt_avalon_mm_firewall_dev_s;

/*
 * The reset callbacks are not optional in any system that can time out.
 *
 * The core deliberately does not own the protected peripheral's reset: owning
 * it would demand a dedicated reset net per peripheral, which shared reset
 * domains and hard IP often cannot provide. So recovery needs software to
 * drive it - typically a PIO bit or a Platform Designer reset bridge.
 *
 * assert_reset() must leave the peripheral in reset when it returns, and must
 * hold it for at least 16 clocks. release_reset() takes it out. The firewall's
 * UNBLOCK is issued BETWEEN the two, which is what stops a freshly-reset
 * peripheral from latching a transaction the core already reported as failed.
 */
typedef void (*alt_avalon_mm_firewall_reset_fn)(void *context);

typedef struct alt_avalon_mm_firewall_dev_s
{
    alt_u32     base;              /* csr slave base address                 */
    alt_32      irq_controller_id; /* -1 if the interrupt is not connected   */
    alt_32      irq;               /* -1 if the interrupt is not connected   */

    /* Filled in by init() from CORE_INFO, so callers need not consult
       system.h for values the hardware can report about itself. */
    alt_u32     num_rules;
    alt_u32     max_burst_beats;
    alt_u32     bytes_per_beat;
    alt_u32     version;

    alt_avalon_mm_firewall_reset_fn assert_reset;
    alt_avalon_mm_firewall_reset_fn release_reset;
    void       *reset_context;

    alt_u32     busy_poll_limit;   /* 0 selects a sane default               */

    /* Optional. Called from the ISR with the decoded fault. Keep it short. */
    void      (*on_fault)(struct alt_avalon_mm_firewall_dev_s *dev,
                          alt_u32 status, alt_u32 fault_addr,
                          alt_u32 fault_info);

    /* Statistics, maintained by the ISR. */
    alt_u32     fault_count;
    alt_u32     timeout_count;
    alt_u32     recover_count;
} alt_avalon_mm_firewall_dev;

/* One address window, for alt_avalon_mm_firewall_configure(). */
typedef struct
{
    alt_u32 base;    /* first byte, inclusive                                */
    alt_u32 limit;   /* last byte,  inclusive                                */
    alt_u32 perm;    /* ALT_AVMM_FW_PERM_* - VALID is added for you          */
} alt_avalon_mm_firewall_rule;

/* --------------------------------------------------- auto-init from the BSP */

/*
 * Emitted into alt_sys_init.c by the BSP generator, once per instance.
 *
 * <name>_IRQ and <name>_IRQ_INTERRUPT_CONTROLLER_ID are defined by system.h
 * as -1 when the interrupt sender is left unconnected, which init() checks
 * before trying to register a handler.
 */
#define ALTERA_AVALON_MM_FIREWALL_INSTANCE(name, dev)                        \
    alt_avalon_mm_firewall_dev dev = {                                       \
        name##_BASE,                                                         \
        name##_IRQ_INTERRUPT_CONTROLLER_ID,                                  \
        name##_IRQ,                                                          \
        0, 0, 0, 0,                                                          \
        (alt_avalon_mm_firewall_reset_fn)0,                                  \
        (alt_avalon_mm_firewall_reset_fn)0,                                  \
        (void *)0,                                                           \
        0,                                                                   \
        (void (*)(struct alt_avalon_mm_firewall_dev_s *, alt_u32, alt_u32,   \
                  alt_u32))0,                                                \
        0, 0, 0                                                              \
    }

#define ALTERA_AVALON_MM_FIREWALL_INIT(name, dev)                            \
    alt_avalon_mm_firewall_init(&dev)

/* --------------------------------------------------------------------- API */

/*
 * Read CORE_INFO, populate the geometry fields and register the interrupt.
 * Returns 0, or -1 if CORE_INFO reports a version this driver does not know.
 *
 * dev->base must already be set - ALTERA_AVALON_MM_FIREWALL_INSTANCE does it
 * from system.h. For a hand-built device, set base, irq and
 * irq_controller_id (the latter two to -1 if unused) before calling.
 *
 * Does not touch CTRL and does not program any rule. See the header note.
 */
int alt_avalon_mm_firewall_init(alt_avalon_mm_firewall_dev *dev);

/* Install the peripheral-reset callbacks. Until this is called, recovery
   cannot complete and alt_avalon_mm_firewall_recover() returns -1. */
void alt_avalon_mm_firewall_set_reset_handlers(
        alt_avalon_mm_firewall_dev *dev,
        alt_avalon_mm_firewall_reset_fn assert_reset,
        alt_avalon_mm_firewall_reset_fn release_reset,
        void *context);

/*
 * Program n windows into rules 0..n-1 and retire the rest. Rules are matched
 * lowest-index-first, so order them most-specific first if they overlap.
 * Returns 0, or -1 if n exceeds the rule count the hardware was generated with.
 */
int alt_avalon_mm_firewall_configure(alt_avalon_mm_firewall_dev *dev,
                                     const alt_avalon_mm_firewall_rule *rules,
                                     unsigned n);

/* Update one window safely - see the .c for why this is not three writes. */
void alt_avalon_mm_firewall_set_rule(alt_avalon_mm_firewall_dev *dev,
                                     unsigned index, alt_u32 base,
                                     alt_u32 limit, alt_u32 perm);
void alt_avalon_mm_firewall_clear_rule(alt_avalon_mm_firewall_dev *dev,
                                       unsigned index);

/* Stall budget in clk cycles. Counts cycles WITHOUT PROGRESS, not total
   transaction length, so it does not need scaling by burst length. */
void alt_avalon_mm_firewall_set_timeout(alt_avalon_mm_firewall_dev *dev,
                                        alt_u32 cycles);

/* The full recovery sequence, including the peripheral reset. Safe to call
   when nothing is wrong. Returns 0, or -1 if no reset callbacks are set. */
int alt_avalon_mm_firewall_recover(alt_avalon_mm_firewall_dev *dev);

/* Convenience. */
alt_u32 alt_avalon_mm_firewall_status(alt_avalon_mm_firewall_dev *dev);
int     alt_avalon_mm_firewall_is_blocked(alt_avalon_mm_firewall_dev *dev);

/* Human-readable fault type, for logging. Never returns NULL. */
const char *alt_avalon_mm_firewall_fault_name(alt_u32 fault_info);

#ifdef __cplusplus
}
#endif

#endif /* __ALTERA_AVALON_MM_FIREWALL_H__ */
