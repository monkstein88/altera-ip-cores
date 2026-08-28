/* =============================================================================
 * altera_axi4_lite_firewall.c
 *
 * Nios II HAL driver for the AXI4-Lite Firewall IP core, v2.0.
 * See altera_axi4_lite_firewall.h for the recovery contract - the ordering in
 * alt_axi4_lite_firewall_recover() is load-bearing, not incidental.
 *
 * Everything except the interrupt is portable. The __nios2__ guards exist so
 * the DE10-Lite example's host test can compile this file on a workstation and
 * exercise it against a software model of the register file.
 * ===========================================================================*/

#include "altera_axi4_lite_firewall.h"

#ifdef __nios2__
# include "sys/alt_irq.h"
#endif

/* ------------------------------------------------------------------- ISR */
#ifdef __nios2__
/*
 * The core's irq is LEVEL sensitive and stays asserted until the STATUS bits
 * that caused it are cleared. So the sticky bits are acknowledged here, before
 * returning - an ISR that only recorded the status and returned would be
 * re-entered forever.
 *
 * Acknowledging does NOT reopen a downstream blocked by a timeout. That is
 * deliberate in the hardware, and it is why this ISR cannot be the whole fault
 * response: recovery needs the peripheral reset, which is not an interrupt-
 * context operation. The ISR records what happened and hands it to the
 * application through on_fault / fault_count.
 */
static void alt_axi4_lite_firewall_isr(void *context)
{
    alt_axi4_lite_firewall_dev *dev = (alt_axi4_lite_firewall_dev *)context;
    uint32_t st = FW_IORD32(dev->base, FW_STATUS);

    dev->last_status = st;
    dev->fault_count++;

    /* Clear the sticky causes so the level deasserts. */
    FW_IOWR32(dev->base, FW_STATUS, st & FW_ST_STICKY);

    if (dev->on_fault != 0) {
        dev->on_fault(dev, st);
    }
}
#endif /* __nios2__ */

/* ------------------------------------------------------------------ init */
int alt_axi4_lite_firewall_init(alt_axi4_lite_firewall_dev *dev)
{
    uint32_t info = FW_IORD32(dev->base, FW_CORE_INFO);

    dev->version   = FW_CORE_VERSION(info);
    dev->num_rules = FW_CORE_NUM_RULES(info);

    if (dev->version != FW_VERSION_2_0) {
        /* Refuse rather than drive a core whose recovery contract differs.
           Leaving num_rules populated is deliberate: a caller that wants to
           report the mismatch can still say what it found. */
        return FW_ERR_BAD_VERSION;
    }

#ifdef __nios2__
    /* system.h defines both as -1 when the interrupt sender is unconnected. */
    if (dev->irq >= 0 && dev->irq_controller_id >= 0) {
        alt_ic_isr_register((alt_u32)dev->irq_controller_id,
                            (alt_u32)dev->irq,
                            alt_axi4_lite_firewall_isr,
                            dev,
                            0);
    }
#endif

    return FW_OK;
}

void alt_axi4_lite_firewall_set_reset_handlers(
        alt_axi4_lite_firewall_dev *dev,
        alt_axi4_lite_firewall_reset_fn assert_reset,
        alt_axi4_lite_firewall_reset_fn release_reset,
        alt_axi4_lite_firewall_delay_fn delay_clocks,
        void *context)
{
    dev->assert_reset  = assert_reset;
    dev->release_reset = release_reset;
    dev->delay_clocks  = delay_clocks;
    dev->context       = context;
}

void alt_axi4_lite_firewall_set_fault_handler(
        alt_axi4_lite_firewall_dev *dev,
        void (*on_fault)(struct alt_axi4_lite_firewall_dev_s *dev,
                         uint32_t status))
{
    dev->on_fault = on_fault;
}

/* --------------------------------------------------------------- config */
void alt_axi4_lite_firewall_reset_config(alt_axi4_lite_firewall_dev *dev,
                                         uint32_t timeout_cycles)
{
    uint32_t i;

    /* Retire every rule first. Default-deny means an unconfigured core blocks
       everything, which is the safe direction to pass through. */
    for (i = 0; i < dev->num_rules; i++) {
        FW_IOWR32(dev->base, FW_RULE_PERM(i), 0u);
    }

    FW_IOWR32(dev->base, FW_TIMEOUT_VALUE, timeout_cycles);
    FW_IOWR32(dev->base, FW_IRQ_ENABLE,    FW_IRQ_ALL);
    FW_IOWR32(dev->base, FW_STATUS,        FW_ST_STICKY);  /* clear stale faults */
    FW_IOWR32(dev->base, FW_CTRL,
              FW_CTRL_GLOBAL_ENABLE | FW_CTRL_AUTO_ISOLATE);
}

void alt_axi4_lite_firewall_set_rule(alt_axi4_lite_firewall_dev *dev,
                                     uint32_t i, uint32_t base,
                                     uint32_t limit, uint32_t perms)
{
    /* Retire before editing. If this rule is currently valid, writing base
       then limit leaves a window in which the new base is paired with the old
       limit - a range that was never intended and may be wide open. Clearing
       VALID first costs one register write and removes the window entirely.
       At init this is a no-op: VALID is 0 out of reset. */
    FW_IOWR32(dev->base, FW_RULE_PERM(i),  0u);
    FW_IOWR32(dev->base, FW_RULE_BASE(i),  base);
    FW_IOWR32(dev->base, FW_RULE_LIMIT(i), limit);
    FW_IOWR32(dev->base, FW_RULE_PERM(i),  perms | FW_PERM_VALID);
}

void alt_axi4_lite_firewall_clear_rule(alt_axi4_lite_firewall_dev *dev,
                                       uint32_t i)
{
    FW_IOWR32(dev->base, FW_RULE_PERM(i), 0u);
}

int alt_axi4_lite_firewall_configure(alt_axi4_lite_firewall_dev *dev,
                                     const alt_axi4_lite_firewall_rule *rules,
                                     uint32_t count)
{
    uint32_t i;

    if (count > dev->num_rules) {
        return -1;
    }

    for (i = 0; i < count; i++) {
        alt_axi4_lite_firewall_set_rule(dev, i, rules[i].base,
                                        rules[i].limit, rules[i].perms);
    }
    /* Anything the caller did not describe is retired, so a shorter table
       cannot leave a stale window open from a previous configuration. */
    for (; i < dev->num_rules; i++) {
        alt_axi4_lite_firewall_clear_rule(dev, i);
    }
    return FW_OK;
}

void alt_axi4_lite_firewall_set_timeout(alt_axi4_lite_firewall_dev *dev,
                                        uint32_t cycles)
{
    FW_IOWR32(dev->base, FW_TIMEOUT_VALUE, cycles);
}

/* --------------------------------------------------------------- status */
uint32_t alt_axi4_lite_firewall_status(alt_axi4_lite_firewall_dev *dev)
{
    return FW_IORD32(dev->base, FW_STATUS);
}

int alt_axi4_lite_firewall_is_blocked(alt_axi4_lite_firewall_dev *dev)
{
    return (FW_IORD32(dev->base, FW_STATUS) & FW_ST_BLOCKED) != 0u;
}

void alt_axi4_lite_firewall_ack(alt_axi4_lite_firewall_dev *dev,
                                uint32_t sticky_bits)
{
    FW_IOWR32(dev->base, FW_STATUS, sticky_bits & FW_ST_STICKY);
}

void alt_axi4_lite_firewall_fault(alt_axi4_lite_firewall_dev *dev,
                                  uint32_t *addr, int *was_write,
                                  uint32_t *type)
{
    uint32_t info;

    if (addr != 0) {
        *addr = FW_IORD32(dev->base, FW_FAULT_ADDR);
    }

    info = FW_IORD32(dev->base, FW_FAULT_INFO);

    if (was_write != 0) {
        *was_write = (int)(info & FW_FAULT_WAS_WRITE);
    }
    if (type != 0) {
        *type = (info >> FW_FAULT_TYPE_SHIFT) & FW_FAULT_TYPE_MASK;
    }
}

const char *alt_axi4_lite_firewall_fault_name(uint32_t fault_info)
{
    switch ((fault_info >> FW_FAULT_TYPE_SHIFT) & FW_FAULT_TYPE_MASK) {
        case FW_FAULT_TYPE_ADDR: return "address violation";
        case FW_FAULT_TYPE_PERM: return "permission violation";
        case FW_FAULT_TYPE_TMO:  return "downstream timeout";
        default:                 return "none";
    }
}

/* ------------------------------------------------------------- recovery */
int alt_axi4_lite_firewall_recover(alt_axi4_lite_firewall_dev *dev,
                                   uint32_t poll_limit)
{
    uint32_t st;
    uint32_t spins;
    int      quiesced = 0;

    if (dev->assert_reset == 0 || dev->release_reset == 0 ||
        dev->delay_clocks == 0) {
        /* Without a way to reset the peripheral there is no safe recovery:
           UNBLOCK on its own would retract a VALID on a live bus. Refuse
           rather than do half of it. */
        return FW_ERR_NO_RESET_HOOK;
    }

    /* ---- step 2: acknowledge -------------------------------------------
       Clears the sticky bits and releases the auto-isolate latch. It does NOT
       reopen the downstream; that is deliberate, so acknowledging a fault
       cannot accidentally restart traffic toward a peripheral nobody has
       reset yet. */
    FW_IOWR32(dev->base, FW_STATUS, FW_ST_STICKY);

    /* ---- step 3: wait for the downstream to go quiet - BOUNDED ----------
       The busy bits mean "the peripheral owes us a response", and a peripheral
       that accepted a command and then died owes one forever, so an unbounded
       poll hangs exactly when recovery matters most.
       Clear means no late response can still be in flight and the reset is
       unambiguously safe. Stuck means reset anyway and let UNBLOCK discard
       what is owed - hence the FW_WARN_NOT_QUIESCED return rather than an
       error. (STATUS.WR_CMD_STUCK/RD_CMD_STUCK are the other case: a command
       the peripheral never even accepted, which only UNBLOCK can clear and
       which polling will never see go away.) */
    for (spins = 0; spins < poll_limit; spins++) {
        st = FW_IORD32(dev->base, FW_STATUS);
        if ((st & (FW_ST_WR_RESP_BUSY | FW_ST_RD_RESP_BUSY)) == 0u) {
            quiesced = 1;
            break;
        }
    }

    /* ---- step 4: reset the protected peripheral, and HOLD it ------------ */
    dev->assert_reset(dev->context);
    dev->delay_clocks(dev->context, FW_RESET_MIN_CLOCKS);

    /* ---- step 5: UNBLOCK, with the peripheral STILL IN RESET ------------
       This ordering is the whole reason this function exists rather than four
       inline register writes.

       A timed-out command left m_axi_AWVALID (or ARVALID) asserted, because
       AXI forbids withdrawing a VALID before its handshake. UNBLOCK is the
       single point at which the core retracts it. If the peripheral is out of
       reset when that happens - or worse, was released before UNBLOCK - it
       sees a perfectly valid command sitting on the bus and accepts it,
       committing a transaction the master was already told had FAILED.

       Holding reset across the write means there is nothing downstream able to
       latch the orphan at the moment it disappears. DE10-Lite demo scenario C
       releases the reset one step early and shows the stale write landing;
       scenario b uses this order and shows it not landing. */
    FW_IOWR32(dev->base, FW_RECOVERY, FW_RECOVERY_UNBLOCK);

    /* ---- step 6: release the peripheral -------------------------------- */
    dev->release_reset(dev->context);

    /* Anything attempted while blocked was answered SLVERR, not stalled, so
       the caller must retry whatever failed since the fault. There is no reset
       pulse to hide the outage behind - see the core's v2.0 notes. */

    st = FW_IORD32(dev->base, FW_STATUS);
    if ((st & FW_ST_BLOCKED) != 0u) {
        return FW_ERR_STILL_BLOCKED;
    }

    return quiesced ? FW_OK : FW_WARN_NOT_QUIESCED;
}
