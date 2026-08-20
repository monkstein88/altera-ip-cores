/* ===========================================================================
 * axi4_lite_firewall.c - driver for the AXI4-Lite Firewall IP core, v2.0
 * See axi4_lite_firewall.h for the register map and the recovery contract.
 * ===========================================================================
 */

#include "axi4_lite_firewall.h"

int firewall_probe(const firewall_t *fw)
{
    uint32_t info = FW_IORD32(fw->base, FW_CORE_INFO);

    if (FW_CORE_VERSION(info) != FW_VERSION_2_0) {
        return FW_ERR_BAD_VERSION;
    }
    return (int)FW_CORE_NUM_RULES(info);
}

void firewall_init(const firewall_t *fw, unsigned num_rules, uint32_t timeout_cycles)
{
    unsigned i;

    /* Retire every rule first. Default-deny means an unconfigured core blocks
       everything, which is the safe direction to pass through. */
    for (i = 0; i < num_rules; i++) {
        FW_IOWR32(fw->base, FW_RULE_PERM(i), 0u);
    }

    FW_IOWR32(fw->base, FW_TIMEOUT_VALUE, timeout_cycles);
    FW_IOWR32(fw->base, FW_IRQ_ENABLE,    FW_IRQ_ALL);
    FW_IOWR32(fw->base, FW_STATUS,        FW_ST_STICKY);   /* clear stale faults */
    FW_IOWR32(fw->base, FW_CTRL,          FW_CTRL_GLOBAL_ENABLE | FW_CTRL_AUTO_ISOLATE);
}

void firewall_set_rule(const firewall_t *fw, unsigned i,
                       uint32_t base, uint32_t limit, uint32_t perms)
{
    /* Retire before editing. If this rule is currently valid, writing base
       then limit leaves a window in which the new base is paired with the old
       limit - a range that was never intended and may be wide open. Clearing
       VALID first costs one register write and removes the window entirely.
       At init this is a no-op: VALID is 0 out of reset. */
    FW_IOWR32(fw->base, FW_RULE_PERM(i),  0u);
    FW_IOWR32(fw->base, FW_RULE_BASE(i),  base);
    FW_IOWR32(fw->base, FW_RULE_LIMIT(i), limit);
    FW_IOWR32(fw->base, FW_RULE_PERM(i),  perms | FW_PERM_VALID);
}

void firewall_clear_rule(const firewall_t *fw, unsigned i)
{
    FW_IOWR32(fw->base, FW_RULE_PERM(i), 0u);
}

uint32_t firewall_status(const firewall_t *fw)
{
    return FW_IORD32(fw->base, FW_STATUS);
}

void firewall_ack(const firewall_t *fw, uint32_t sticky_bits)
{
    FW_IOWR32(fw->base, FW_STATUS, sticky_bits & FW_ST_STICKY);
}

void firewall_fault(const firewall_t *fw, uint32_t *addr,
                    int *was_write, unsigned *type)
{
    uint32_t info;

    if (addr != 0) {
        *addr = FW_IORD32(fw->base, FW_FAULT_ADDR);
    }

    info = FW_IORD32(fw->base, FW_FAULT_INFO);

    if (was_write != 0) {
        *was_write = (int)(info & FW_FAULT_WAS_WRITE);
    }
    if (type != 0) {
        *type = (unsigned)((info >> FW_FAULT_TYPE_SHIFT) & FW_FAULT_TYPE_MASK);
    }
}

int firewall_recover(const firewall_t *fw, unsigned poll_limit)
{
    uint32_t st;
    unsigned spins;
    int      quiesced = 0;

    if (fw->reset_assert == 0 || fw->reset_release == 0 || fw->delay_clocks == 0) {
        /* Without a way to reset the peripheral there is no safe recovery:
           UNBLOCK on its own would retract a VALID on a live bus. Refuse
           rather than do half of it. */
        return FW_ERR_NO_RESET_HOOK;
    }

    /* ---- step 2: acknowledge -------------------------------------------
       Clears the sticky bits and releases the auto-isolate latch. It does
       NOT reopen the downstream; that is deliberate, so acknowledging a
       fault cannot accidentally restart traffic toward a peripheral nobody
       has reset yet. */
    FW_IOWR32(fw->base, FW_STATUS, FW_ST_STICKY);

    /* ---- step 3: wait for the downstream to go quiet - BOUNDED ----------
       The busy bits mean "the peripheral owes us a response", and a
       peripheral that accepted a command and then died owes one forever, so
       an unbounded poll hangs exactly when recovery matters most.
       Clear means no late response can still be in flight and the reset is
       unambiguously safe. Stuck means reset anyway and let UNBLOCK discard
       what is owed - hence the FW_WARN_NOT_QUIESCED return rather than an
       error. (STATUS.WR_CMD_STUCK/RD_CMD_STUCK are the other case: a command
       the peripheral never even accepted, which only UNBLOCK can clear and
       which polling will never see go away.) */
    for (spins = 0; spins < poll_limit; spins++) {
        st = FW_IORD32(fw->base, FW_STATUS);
        if ((st & (FW_ST_WR_RESP_BUSY | FW_ST_RD_RESP_BUSY)) == 0u) {
            quiesced = 1;
            break;
        }
    }

    /* ---- step 4: reset the protected peripheral, and HOLD it ------------ */
    fw->reset_assert(fw->ctx);
    fw->delay_clocks(fw->ctx, FW_RESET_MIN_CLOCKS);

    /* ---- step 5: UNBLOCK, with the peripheral STILL IN RESET ------------
       This ordering is the whole reason this function exists rather than
       four inline register writes.

       A timed-out command left m_axi_AWVALID (or ARVALID) asserted, because
       AXI forbids withdrawing a VALID before its handshake. UNBLOCK is the
       single point at which the core retracts it. If the peripheral is out
       of reset when that happens - or worse, was released before UNBLOCK -
       it sees a perfectly valid command sitting on the bus and accepts it,
       committing a transaction the master was already told had FAILED.

       Holding reset across the write means there is nothing downstream able
       to latch the orphan at the moment it disappears. DE10-Lite demo
       scenario C releases the reset one step early and shows the stale write
       landing; scenario b uses this order and shows it not landing. */
    FW_IOWR32(fw->base, FW_RECOVERY, FW_RECOVERY_UNBLOCK);

    /* ---- step 6: release the peripheral -------------------------------- */
    fw->reset_release(fw->ctx);

    /* Anything attempted while blocked was answered SLVERR, not stalled, so
       the caller must retry whatever failed since the fault. There is no
       reset pulse to hide the outage behind - see the core's v2.0 notes. */

    st = FW_IORD32(fw->base, FW_STATUS);
    if ((st & FW_ST_BLOCKED) != 0u) {
        return FW_ERR_STILL_BLOCKED;
    }

    return quiesced ? FW_OK : FW_WARN_NOT_QUIESCED;
}
