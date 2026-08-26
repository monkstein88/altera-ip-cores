/* =============================================================================
 * altera_avalon_mm_firewall.c
 *
 * Nios II HAL driver for the Avalon-MM Firewall IP core, v1.0.
 * See HAL/inc/altera_avalon_mm_firewall.h for the API and
 * inc/altera_avalon_mm_firewall_regs.h for the register map.
 * ===========================================================================*/

#include "altera_avalon_mm_firewall.h"
#include "sys/alt_irq.h"

#define DEFAULT_BUSY_POLL_LIMIT 1000u

static void alt_avalon_mm_firewall_isr(void *context);

/* -------------------------------------------------------------------------- */

int alt_avalon_mm_firewall_init(alt_avalon_mm_firewall_dev *dev)
{
    alt_u32 info;

    dev->fault_count   = 0;
    dev->timeout_count = 0;
    dev->recover_count = 0;
    if (dev->busy_poll_limit == 0)
        dev->busy_poll_limit = DEFAULT_BUSY_POLL_LIMIT;

    /*
     * Check the version before trusting anything else in this file. The
     * register map is not self-describing beyond this word, and a driver
     * writing v1.0 offsets into a future core would fail silently rather than
     * loudly - which for a security peripheral is the wrong direction to fail.
     */
    info = IORD_ALTERA_AVALON_MM_FIREWALL_CORE_INFO(dev->base);
    dev->version = ALTERA_AVALON_MM_FIREWALL_INFO_VERSION(info);
    if (dev->version != ALTERA_AVALON_MM_FIREWALL_VERSION_1_0)
        return -1;

    /* Let the hardware describe its own geometry, so nothing has to be
       duplicated from system.h and kept in step by hand. */
    dev->num_rules       = ALTERA_AVALON_MM_FIREWALL_INFO_NUM_RULES(info);
    dev->max_burst_beats = ALTERA_AVALON_MM_FIREWALL_INFO_MAX_BEATS(info);
    dev->bytes_per_beat  =
        1u << ALTERA_AVALON_MM_FIREWALL_INFO_BEAT_SHIFT(info);

    /*
     * Do NOT touch CTRL here. It resets to ENABLE | AUTO_ISOLATE - secure by
     * default - and the window between reset and the application's first
     * configure() call is exactly when default-deny should be in force, not a
     * firewall someone helpfully switched off during init.
     *
     * Do NOT program any rule here either. The table resets empty, which means
     * "deny everything", and that is the correct state for a system that has
     * not yet said what it wants to allow.
     */

    /* Registering the interrupt now, before the application has installed
       reset callbacks, is deliberate: a fault arriving early is then
       acknowledged rather than left asserting a level interrupt forever.
       recover() will decline safely until the callbacks exist. */
    if (dev->irq >= 0 && dev->irq_controller_id >= 0) {
        IOWR_ALTERA_AVALON_MM_FIREWALL_IRQ_ENABLE(
            dev->base, ALTERA_AVALON_MM_FIREWALL_IRQ_ALL_MSK);
        return alt_ic_isr_register((alt_u32)dev->irq_controller_id,
                                   (alt_u32)dev->irq,
                                   alt_avalon_mm_firewall_isr, dev, 0);
    }
    return 0;
}

void alt_avalon_mm_firewall_set_reset_handlers(
        alt_avalon_mm_firewall_dev *dev,
        alt_avalon_mm_firewall_reset_fn assert_reset,
        alt_avalon_mm_firewall_reset_fn release_reset,
        void *context)
{
    dev->assert_reset  = assert_reset;
    dev->release_reset = release_reset;
    dev->reset_context = context;
}

/* -------------------------------------------------------------------------- */

void alt_avalon_mm_firewall_clear_rule(alt_avalon_mm_firewall_dev *dev,
                                       unsigned index)
{
    IOWR_ALTERA_AVALON_MM_FIREWALL_RULE_PERM(dev->base, index, 0);
}

void alt_avalon_mm_firewall_set_rule(alt_avalon_mm_firewall_dev *dev,
                                     unsigned index, alt_u32 base,
                                     alt_u32 limit, alt_u32 perm)
{
    /*
     * Retire the window before moving it.
     *
     * BASE, LIMIT and PERM are three separate registers, so writing them in
     * any order leaves an interval in which the base is new and the limit is
     * still old - a window describing a range nobody intended, live on the
     * bus, for a few cycles. Clearing VALID first makes the window invisible
     * for the duration, and default-deny covers the gap.
     *
     * At initialisation this costs one extra write and nothing else: VALID is
     * 0 out of reset anyway.
     */
    IOWR_ALTERA_AVALON_MM_FIREWALL_RULE_PERM(dev->base, index, 0);
    IOWR_ALTERA_AVALON_MM_FIREWALL_RULE_BASE(dev->base, index, base);
    IOWR_ALTERA_AVALON_MM_FIREWALL_RULE_LIMIT(dev->base, index, limit);
    IOWR_ALTERA_AVALON_MM_FIREWALL_RULE_PERM(
        dev->base, index, perm | ALTERA_AVALON_MM_FIREWALL_PERM_VALID_MSK);
}

int alt_avalon_mm_firewall_configure(alt_avalon_mm_firewall_dev *dev,
                                     const alt_avalon_mm_firewall_rule *rules,
                                     unsigned n)
{
    unsigned i;

    if (n > dev->num_rules)
        return -1;

    for (i = 0; i < n; i++)
        alt_avalon_mm_firewall_set_rule(dev, i, rules[i].base, rules[i].limit,
                                        rules[i].perm);

    /* Everything not described is denied. Retiring the unused slots matters
       when reconfiguring a running system - a stale window left valid is an
       open door nobody remembers opening. */
    for (; i < dev->num_rules; i++)
        alt_avalon_mm_firewall_clear_rule(dev, i);

    return 0;
}

void alt_avalon_mm_firewall_set_timeout(alt_avalon_mm_firewall_dev *dev,
                                        alt_u32 cycles)
{
    IOWR_ALTERA_AVALON_MM_FIREWALL_TIMEOUT(dev->base, cycles);
}

/* -------------------------------------------------------------------------- */

alt_u32 alt_avalon_mm_firewall_status(alt_avalon_mm_firewall_dev *dev)
{
    return IORD_ALTERA_AVALON_MM_FIREWALL_STATUS(dev->base);
}

int alt_avalon_mm_firewall_is_blocked(alt_avalon_mm_firewall_dev *dev)
{
    return (IORD_ALTERA_AVALON_MM_FIREWALL_STATUS(dev->base)
            & ALTERA_AVALON_MM_FIREWALL_STATUS_BLOCKED_MSK) ? 1 : 0;
}

const char *alt_avalon_mm_firewall_fault_name(alt_u32 fault_info)
{
    switch (ALTERA_AVALON_MM_FIREWALL_FAULT_TYPE(fault_info)) {
    case ALTERA_AVALON_MM_FIREWALL_FAULT_ADDR:
        return "unmapped address";
    case ALTERA_AVALON_MM_FIREWALL_FAULT_PERM:
        return "direction not permitted";
    case ALTERA_AVALON_MM_FIREWALL_FAULT_TIMEOUT:
        return "downstream timeout";
    case ALTERA_AVALON_MM_FIREWALL_FAULT_BURST_RANGE:
        return "burst overran its window";
    case ALTERA_AVALON_MM_FIREWALL_FAULT_BURST_DENIED:
        return "bursts not permitted here";
    default:
        return "none";
    }
}

/* -------------------------------------------------------------------------- */

static void alt_avalon_mm_firewall_isr(void *context)
{
    alt_avalon_mm_firewall_dev *dev = (alt_avalon_mm_firewall_dev *)context;
    alt_u32 status = IORD_ALTERA_AVALON_MM_FIREWALL_STATUS(dev->base);
    alt_u32 addr, info;

    if ((status & ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK) == 0)
        return;

    addr = IORD_ALTERA_AVALON_MM_FIREWALL_FAULT_ADDR(dev->base);
    info = IORD_ALTERA_AVALON_MM_FIREWALL_FAULT_INFO(dev->base);

    dev->fault_count++;
    if (status & ALTERA_AVALON_MM_FIREWALL_STATUS_TIMEOUT_MSK)
        dev->timeout_count++;

    if (dev->on_fault)
        dev->on_fault(dev, status, addr, info);

    /*
     * Acknowledge. Write-1-to-clear on the sticky bits; this also releases the
     * auto-isolate latch.
     *
     * Read FAULT_ADDR and FAULT_INFO BEFORE this, not after: they are a single
     * shared latch, and acknowledging reopens the core to traffic that can
     * fault again immediately and overwrite them.
     */
    IOWR_ALTERA_AVALON_MM_FIREWALL_STATUS(
        dev->base, status & ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK);

    /*
     * A timeout additionally leaves the downstream BLOCKED. Acknowledging does
     * not reopen it - deliberately, so that clearing a fault cannot restart
     * traffic toward a peripheral nobody has reset.
     *
     * Recovery resets a peripheral, so in most systems it does not belong in
     * an ISR. This is fine for a simple polled peripheral; if yours needs a
     * longer reset or must coordinate with a driver, leave on_fault to set a
     * flag and call recover() from a thread instead.
     */
    if (status & ALTERA_AVALON_MM_FIREWALL_STATUS_TIMEOUT_MSK)
        alt_avalon_mm_firewall_recover(dev);
}

/* -------------------------------------------------------------------------- */

int alt_avalon_mm_firewall_recover(alt_avalon_mm_firewall_dev *dev)
{
    alt_u32 status;
    alt_u32 spins;

    if (!dev->assert_reset || !dev->release_reset)
        return -1;

    /* 1. The caller has stopped issuing transactions to the protected path. */

    /* 2. Acknowledge, in case we were not called from the ISR. */
    IOWR_ALTERA_AVALON_MM_FIREWALL_STATUS(
        dev->base, ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK);

    /*
     * 3. Wait for the downstream to go quiet - WITH A BOUND.
     *
     * WR_BUSY/RD_BUSY mean "the peripheral owes us something". A peripheral
     * that accepted a command and then died owes it forever, so an unbounded
     * poll hangs precisely when recovery matters most. Treat them as advisory:
     * clear means no late response can still be in flight and the reset is
     * unambiguously safe; still set means reset anyway and let UNBLOCK discard
     * what is owed.
     *
     * WR_CMD_STUCK / RD_CMD_STUCK are the other case - a command the
     * peripheral never even accepted. Those can only be cleared by UNBLOCK, so
     * polling the busy bits alone would never have been enough.
     */
    for (spins = 0; spins < dev->busy_poll_limit; spins++) {
        status = IORD_ALTERA_AVALON_MM_FIREWALL_STATUS(dev->base);
        if ((status & (ALTERA_AVALON_MM_FIREWALL_STATUS_WR_BUSY_MSK |
                       ALTERA_AVALON_MM_FIREWALL_STATUS_RD_BUSY_MSK)) == 0)
            break;
    }

    /* 4. Put the peripheral into reset and HOLD it there. */
    dev->assert_reset(dev->reset_context);

    /*
     * 5. Declare the downstream state discarded, WHILE THE PERIPHERAL IS STILL
     *    IN RESET.
     *
     * This ordering is the one thing to preserve if you rewrite this function.
     * UNBLOCK is what withdraws a command the core froze because waitrequest
     * never fell. If the peripheral is already out of reset when that write
     * lands, it can complete the frozen command's handshake first - and latch
     * a transaction the firewall already reported to the master as failed.
     * Withdrawing it while the peripheral cannot see the bus removes that
     * window entirely and costs nothing.
     */
    IOWR_ALTERA_AVALON_MM_FIREWALL_RECOVERY(
        dev->base, ALTERA_AVALON_MM_FIREWALL_RECOVERY_UNBLOCK_MSK);

    /* 6. Release the peripheral. */
    dev->release_reset(dev->reset_context);

    /*
     * Acknowledge AGAIN, and this is not redundant.
     *
     * Step 2's acknowledge can be overwritten before the sequence finishes. A
     * command the peripheral never accepted keeps m0_read/m0_write asserted
     * with waitrequest high, so the core's no-progress timer keeps expiring
     * and re-latching TIMEOUT_ERROR - and re-arming auto-isolate with it - for
     * as long as the command is frozen. Only UNBLOCK at step 5 retires it.
     *
     * Without this second acknowledge, a recovery that has genuinely succeeded
     * leaves STATUS reading TIMEOUT_ERROR | ISOLATED, and ISOLATED still gates
     * the data path: the next transaction is refused and the caller sees a
     * "recovered" core that answers nothing. Found on hardware, where the
     * symptom was a post-recovery write that silently did not land.
     *
     * It is safe here and nowhere earlier: the frozen command is gone, the
     * peripheral is out of reset and healthy, so nothing is left to re-fire.
     */
    IOWR_ALTERA_AVALON_MM_FIREWALL_STATUS(
        dev->base, ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK);

    dev->recover_count++;

    /*
     * 7. The caller resumes.
     *
     * Anything attempted between the fault and now was ANSWERED WITH AN ERROR,
     * not stalled. There is no window in which the firewall quietly held
     * traffic, so every transaction issued in that interval failed and must be
     * retried by whoever issued it.
     */
    return 0;
}
