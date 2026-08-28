/* ===========================================================================
 * test_axi4_lite_firewall_host.c - host-runnable tests for the firewall driver.
 *
 *     make            (from this directory)
 *
 * The driver is the one piece of this example that ships to other people's
 * systems, and its correctness is mostly about ORDERING - which register is
 * written while which other thing is true. That is invisible to a compiler
 * and awkward to see on hardware, so it is checked here against a model of
 * the core's register file that also models the hazard.
 *
 * The model implements the part of the core that makes the ordering matter:
 * a timed-out command leaves an orphan on m_axi, only RECOVERY.UNBLOCK
 * retracts it, and if the peripheral is out of reset at that instant it
 * latches the orphan. That is DE10-Lite demo scenario C. A driver that does
 * it right never trips it - which is what stale_write_landed asserts.
 *
 * This test includes the .c directly so it can substitute the register
 * accessors; there is no separate build of the driver to keep in step.
 * ===========================================================================
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

static uint32_t model_read(uintptr_t base, uint32_t off);
static void     model_write(uintptr_t base, uint32_t off, uint32_t val);

#define FW_IORD32(base, off)       model_read((uintptr_t)(base), (uint32_t)(off))
#define FW_IOWR32(base, off, val)  model_write((uintptr_t)(base), (uint32_t)(off), (uint32_t)(val))

/* The driver source is compiled straight into the test so the register
   accessors above can be substituted. Found via -I in the Makefile, which
   points at the component rather than at a copy in this directory. */
#include "altera_axi4_lite_firewall.c"

/* ------------------------------------------------------------------ */
/* Model of the core                                                   */
/* ------------------------------------------------------------------ */
#define MODEL_BASE 0x1000u
#define NREG       32

typedef struct {
    uint32_t reg[NREG];         /* indexed by offset/4, low registers only */
    uint32_t rule_perm[8];
    uint32_t rule_base[8];
    uint32_t rule_limit[8];

    uint32_t sticky;            /* STATUS[2:0] */
    int      blocked;           /* STATUS.BLOCKED    */
    int      isolated;          /* STATUS.ISOLATED   */
    int      wr_resp_busy;
    int      rd_resp_busy;
    int      wr_cmd_stuck;

    int      orphan_pending;    /* a VALID the peripheral never took */
    int      periph_in_reset;

    /* what the test is really asking about */
    int      stale_write_landed;
    int      unblock_while_running;
    int      busy_polls;
    uint32_t core_info;
} model_t;

static model_t m;

/* Sequence log, so tests can assert on ordering rather than end state. */
typedef enum { EV_WRITE, EV_READ, EV_RESET_ASSERT, EV_RESET_RELEASE, EV_DELAY } ev_kind;
typedef struct { ev_kind kind; uint32_t off; uint32_t val; } event_t;

#define MAXEV 256
static event_t evlog[MAXEV];
static int     nev;

static void ev(ev_kind k, uint32_t off, uint32_t val)
{
    if (nev < MAXEV) {
        evlog[nev].kind = k;
        evlog[nev].off  = off;
        evlog[nev].val  = val;
        nev++;
    }
}

static uint32_t model_status(void)
{
    uint32_t s = m.sticky;
    if (m.isolated)     s |= FW_ST_ISOLATED;
    if (m.blocked)      s |= FW_ST_BLOCKED;
    if (m.wr_resp_busy) s |= FW_ST_WR_RESP_BUSY;
    if (m.rd_resp_busy) s |= FW_ST_RD_RESP_BUSY;
    if (m.wr_cmd_stuck) s |= FW_ST_WR_CMD_STUCK;
    return s;
}

static uint32_t model_read(uintptr_t base, uint32_t off)
{
    (void)base;
    ev(EV_READ, off, 0);

    switch (off) {
    case FW_STATUS:
        if (m.wr_resp_busy || m.rd_resp_busy) m.busy_polls++;
        return model_status();
    case FW_CORE_INFO:
        return m.core_info;
    default:
        return (off / 4u < NREG) ? m.reg[off / 4u] : 0u;
    }
}

static void model_write(uintptr_t base, uint32_t off, uint32_t val)
{
    (void)base;
    ev(EV_WRITE, off, val);

    if (off == FW_STATUS) {
        m.sticky &= ~(val & FW_ST_STICKY);          /* write 1 to clear */
        /* Clearing TIMEOUT_ERROR releases auto-isolate but NOT the block. */
        if (val & FW_ST_TIMEOUT_ERROR) m.isolated = 0;
        return;
    }

    if (off == FW_RECOVERY) {
        if (val & FW_RECOVERY_UNBLOCK) {
            /* The orphaned VALID is retracted here and nowhere else. If the
               peripheral is running at this instant, it takes the command
               first - the transaction the master was told had failed. */
            if (m.orphan_pending && !m.periph_in_reset) {
                m.stale_write_landed = 1;
            }
            if (!m.periph_in_reset) m.unblock_while_running = 1;
            m.orphan_pending = 0;
            m.blocked        = 0;
            m.wr_cmd_stuck   = 0;
            /* UNBLOCK also clears the response trackers - see
               rtl/axi4_lite_firewall_top.sv, where `unblock` resets wr_aw_taken /
               wr_w_taken / rd_ar_taken alongside the block latch. Modelling
               this matters: it is why the busy bits a driver could never
               poll to zero do reach zero once recovery completes. */
            m.wr_resp_busy   = 0;
            m.rd_resp_busy   = 0;
        }
        return;
    }

    if (off >= 0x40u && off < 0x40u + 8u * 0x10u) {
        unsigned i   = (off - 0x40u) / 0x10u;
        unsigned sub = (off - 0x40u) % 0x10u;
        if      (sub == 0x0u) m.rule_base[i]  = val;
        else if (sub == 0x4u) m.rule_limit[i] = val;
        else                  m.rule_perm[i]  = val;
        return;
    }

    if (off / 4u < NREG) m.reg[off / 4u] = val;
}

/* ------------------------------------------------------------------ */
/* Peripheral reset hooks                                              */
/* ------------------------------------------------------------------ */
static void hook_assert(void *c)  { (void)c; m.periph_in_reset = 1; ev(EV_RESET_ASSERT, 0, 0); }
static void hook_release(void *c) { (void)c; m.periph_in_reset = 0; ev(EV_RESET_RELEASE, 0, 0); }
static void hook_delay(void *c, uint32_t n) { (void)c; ev(EV_DELAY, 0, n); }

/* Not const: the driver fills in version and num_rules from CORE_INFO. */
static alt_axi4_lite_firewall_dev fw_full = {
    .base = MODEL_BASE,
    .irq_controller_id = -1, .irq = -1,          /* no interrupt off-target */
    .assert_reset = hook_assert,
    .release_reset = hook_release,
    .delay_clocks = hook_delay
};
static alt_axi4_lite_firewall_dev fw_nohooks = {
    .base = MODEL_BASE, .irq_controller_id = -1, .irq = -1
};

/* ------------------------------------------------------------------ */
/* Test harness                                                        */
/* ------------------------------------------------------------------ */
static int passed, failed;

static void check(const char *what, int ok)
{
    if (ok) { passed++; printf("  PASS  %s\n", what); }
    else    { failed++; printf("  FAIL: %s\n", what); }
}

static void reset_model(void)
{
    memset(&m, 0, sizeof m);
    nev = 0;
    m.core_info = ((uint32_t)FW_VERSION_2_0 << 16) | 8u;
}

/* Put the model into the state a downstream write timeout leaves behind:
   SLVERR already reported, sticky TIMEOUT set, auto-isolated, blocked, and
   an orphaned command the peripheral never accepted. */
static void inject_write_timeout(void)
{
    m.sticky        |= FW_ST_TIMEOUT_ERROR;
    m.isolated       = 1;
    m.blocked        = 1;
    m.wr_cmd_stuck   = 1;
    m.orphan_pending = 1;
}

static int index_of_write(uint32_t off, uint32_t val)
{
    for (int i = 0; i < nev; i++)
        if (evlog[i].kind == EV_WRITE && evlog[i].off == off && evlog[i].val == val)
            return i;
    return -1;
}

static int index_of(ev_kind k)
{
    for (int i = 0; i < nev; i++) if (evlog[i].kind == k) return i;
    return -1;
}

int main(void)
{
    int rc;

    printf("=== AXI4-Lite Firewall driver - host tests ===\n\n");

    /* ---- probe ---------------------------------------------------- */
    printf("-- version probe --\n");
    reset_model();
    check("init accepts a v2.0 core",
          alt_axi4_lite_firewall_init(&fw_full) == FW_OK);
    check("init reads the rule count out of CORE_INFO", fw_full.num_rules == 8);

    reset_model();
    m.core_info = (0x0102u << 16) | 8u;          /* a v1.2 core */
    check("init rejects a v1.x core rather than mis-driving it",
          alt_axi4_lite_firewall_init(&fw_full) == FW_ERR_BAD_VERSION);
    /* Put the device back in a usable state for the tests that follow. */
    reset_model();
    (void)alt_axi4_lite_firewall_init(&fw_full);

    /* ---- rule programming ordering -------------------------------- */
    printf("\n-- rule programming --\n");
    reset_model();
    m.rule_perm[2] = FW_PERM_RW;                  /* rule 2 is LIVE */
    alt_axi4_lite_firewall_set_rule(&fw_full, 2, 0x2000, 0x2FFF, FW_PERM_READ);
    {
        int i_retire = index_of_write(FW_RULE_PERM(2), 0u);
        int i_base   = index_of_write(FW_RULE_BASE(2), 0x2000u);
        int i_limit  = index_of_write(FW_RULE_LIMIT(2), 0x2FFFu);
        int i_arm    = index_of_write(FW_RULE_PERM(2), FW_PERM_RO);
        check("a live rule is retired before its base/limit change",
              i_retire >= 0 && i_base > i_retire && i_limit > i_retire);
        check("and re-armed with VALID only after both are in place",
              i_arm > i_base && i_arm > i_limit);
        check("final permissions are read-only + valid", m.rule_perm[2] == FW_PERM_RO);
    }

    reset_model();
    fw_full.num_rules = 8;
    alt_axi4_lite_firewall_reset_config(&fw_full, 50000);
    check("reset_config retires every rule (default-deny)",
          m.rule_perm[0] == 0 && m.rule_perm[7] == 0);
    check("reset_config enables enforcement and auto-isolate",
          m.reg[FW_CTRL / 4] == (FW_CTRL_GLOBAL_ENABLE | FW_CTRL_AUTO_ISOLATE));
    check("reset_config programs the timeout", m.reg[FW_TIMEOUT_VALUE / 4] == 50000u);

    /* ---- ack only touches the sticky bits ------------------------- */
    printf("\n-- fault acknowledge --\n");
    reset_model();
    inject_write_timeout();
    alt_axi4_lite_firewall_ack(&fw_full, 0xFFFFFFFFu);
    check("ack clears the sticky bits", m.sticky == 0);
    check("ack does NOT reopen the downstream - that needs UNBLOCK", m.blocked == 1);

    /* ---- the ordering that matters -------------------------------- */
    printf("\n-- recovery ordering (the point of this file) --\n");
    reset_model();
    inject_write_timeout();
    rc = alt_axi4_lite_firewall_recover(&fw_full, 1000);
    {
        int i_assert  = index_of(EV_RESET_ASSERT);
        int i_unblock = index_of_write(FW_RECOVERY, FW_RECOVERY_UNBLOCK);
        int i_release = index_of(EV_RESET_RELEASE);
        int i_delay   = index_of(EV_DELAY);

        check("recovery succeeds", rc == FW_OK);
        check("peripheral reset is asserted before UNBLOCK",
              i_assert >= 0 && i_unblock > i_assert);
        check("reset is held for the minimum duration before UNBLOCK",
              i_delay > i_assert && i_unblock > i_delay);
        check("reset is released only AFTER UNBLOCK",
              i_release > i_unblock);
        check("no stale write landed on the protected peripheral",
              m.stale_write_landed == 0);
        check("UNBLOCK never retracts a VALID onto a live peripheral",
              m.unblock_while_running == 0);
        check("downstream is open again", m.blocked == 0);
        check("the orphaned command was discarded", m.orphan_pending == 0);
    }

    /* ---- the bounded poll ----------------------------------------- */
    printf("\n-- bounded poll --\n");
    reset_model();
    inject_write_timeout();
    m.wr_resp_busy = 1;                 /* a peripheral that owes a response forever */
    rc = alt_axi4_lite_firewall_recover(&fw_full, 50);
    check("a never-clearing busy bit does not hang the driver",
          rc == FW_WARN_NOT_QUIESCED);
    check("the poll stopped at the caller's bound, and nowhere later",
          m.busy_polls == 50);
    check("recovery still completed despite the warning", m.blocked == 0);
    check("and still landed no stale write", m.stale_write_landed == 0);

    /* ---- refuse to half-do it ------------------------------------- */
    printf("\n-- misuse --\n");
    reset_model();
    inject_write_timeout();
    rc = alt_axi4_lite_firewall_recover(&fw_nohooks, 1000);
    check("recovery without reset hooks is refused, not attempted",
          rc == FW_ERR_NO_RESET_HOOK);
    check("and nothing was written - the downstream is untouched",
          m.blocked == 1 && m.orphan_pending == 1);

    /* ---- fault decode --------------------------------------------- */
    printf("\n-- fault decode --\n");
    reset_model();
    m.reg[FW_FAULT_ADDR / 4] = 0x00001030u;
    m.reg[FW_FAULT_INFO / 4] = (FW_FAULT_TYPE_ADDR << FW_FAULT_TYPE_SHIFT); /* read */
    {
        uint32_t addr; int was_write; uint32_t type;
        alt_axi4_lite_firewall_fault(&fw_full, &addr, &was_write, &type);
        check("fault address decoded", addr == 0x00001030u);
        check("fault direction decoded (a read)", was_write == 0);
        check("fault type decoded (unmapped address)", type == FW_FAULT_TYPE_ADDR);
    }
    reset_model();
    m.reg[FW_FAULT_INFO / 4] = (FW_FAULT_TYPE_TMO << FW_FAULT_TYPE_SHIFT) | FW_FAULT_WAS_WRITE;
    {
        int was_write; uint32_t type;
        alt_axi4_lite_firewall_fault(&fw_full, 0, &was_write, &type);   /* NULL addr is allowed */
        check("a NULL output pointer is tolerated", 1);
        check("timeout-on-write decoded",
              was_write == 1 && type == FW_FAULT_TYPE_TMO);
    }

    printf("\n=========================================\n");
    printf(" passed : %d\n failed : %d\n", passed, failed);
    printf(failed == 0 ? " *** ALL DRIVER TESTS PASSED ***\n"
                       : " *** DRIVER TESTS FAILED ***\n");
    printf("=========================================\n");
    return failed == 0 ? 0 : 1;
}
