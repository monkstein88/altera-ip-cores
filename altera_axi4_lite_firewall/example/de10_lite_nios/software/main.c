/* ===========================================================================
 * main.c - Nios II/f application for the AXI4-Lite Firewall example.
 *
 * Runs the same scenarios as the RTL-only example in ../../de10_lite_rtl/,
 * but driven by software on a real processor through a Platform Designer
 * interconnect, rather than by a hardware sequencer wired point to point.
 * That difference is the reason this example exists: it is the only place the
 * core is exercised through generated Qsys interconnect and an Avalon-to-AXI
 * bridge, which is a thing the testbenches structurally cannot cover.
 *
 * Output goes to the JTAG UART:  nios2-terminal
 *
 * ---------------------------------------------------------------------------
 * TWO ADDRESS SPACES, AND WHY THE RULES LOOK "WRONG"
 * ---------------------------------------------------------------------------
 * Platform Designer hands an AXI slave the offset within its own span, not the
 * full system address. So a CPU access to FW_S_AXI_BASE + 0x10 arrives at the
 * firewall as address 0x010, and the firewall forwards 0x010 to m_axi.
 *
 * Rules are therefore programmed in FIREWALL-side addresses (0x000, 0x010,
 * ...), while the CPU dereferences SYSTEM addresses (FW_S_AXI_BASE + ...).
 * Getting this backwards is the single easiest mistake to make here: the rule
 * table would be full of 0x23xxx values that no transaction ever matches, and
 * every access would come back DECERR with STATUS.ADDR_VIOLATION set.
 *
 * ---------------------------------------------------------------------------
 * NIOS II/f AND THE DATA CACHE
 * ---------------------------------------------------------------------------
 * This CPU has a 2 KB data cache. Every access below goes through
 * IORD_32DIRECT / IOWR_32DIRECT, which force an uncached access. Plain
 * pointer dereferences would let register writes sit in the cache and never
 * reach the firewall - and reads would return stale copies of STATUS, so the
 * fault bits would appear never to set. On Nios II/e, which has no data
 * cache, the same code works either way; here it does not.
 * ===========================================================================
 */

#include <stdio.h>
#include <unistd.h>
#include "system.h"
#include "sys/alt_irq.h"
#include "altera_avalon_pio_regs.h"
#include "altera_axi4_lite_firewall.h"

/* ------------------------------------------------------------------ */
/* Peripheral fault injection, via pio_fault                           */
/*   bit 0 hang   bit 1 hang_late   bit 2 soft_resetn                  */
/* ------------------------------------------------------------------ */
#define FAULT_HANG        0x1u
#define FAULT_HANG_LATE   0x2u
#define FAULT_RESETN      0x4u

static alt_u32 fault_shadow = FAULT_RESETN;     /* peripheral running, healthy */

static void fault_write(alt_u32 v)
{
    fault_shadow = v;
    IOWR_ALTERA_AVALON_PIO_DATA(PIO_FAULT_BASE, v);
}

static void periph_reset_assert(void *ctx)
{
    (void)ctx;
    fault_write(fault_shadow & ~FAULT_RESETN);
}

static void periph_reset_release(void *ctx)
{
    (void)ctx;
    fault_write(fault_shadow | FAULT_RESETN);
}

static void periph_delay_clocks(void *ctx, uint32_t clocks)
{
    (void)ctx; (void)clocks;
    /* One microsecond is 50 clocks at 50 MHz, comfortably above the 16 the
       core's recovery sequence requires. */
    usleep(1);
}

/* The BSP constructs and initialises this from alt_sys_init.c before main(),
   because axi4_lite_firewall_sw.tcl sets auto_initialize. alt_sys_init.c owns
   the definition; `fw` is the Platform Designer instance name.

   What alt_sys_init() has already done: read CORE_INFO, filled in version and
   num_rules, and registered the driver's ISR. What it has NOT done, because
   neither can be derived from hardware, is program the rule table or install
   the peripheral-reset callbacks - both happen in main(). */
extern alt_axi4_lite_firewall_dev fw;

/* ------------------------------------------------------------------ */
/* The demo address map.                                               */
/* FW_* are what the rules are written in; CPU_* are what we dereference*/
/* ------------------------------------------------------------------ */
#define FW_RW     0x000u        /* rule 0: read + write */
#define FW_RO     0x010u        /* rule 1: read only    */
#define FW_WO     0x020u        /* rule 2: write only   */
#define FW_NONE   0x030u        /* covered by no rule   */

#define CPU_ADDR(fwaddr)  (FW_S_AXI_BASE + (fwaddr))

/* ------------------------------------------------------------------ */
static int passed, failed;

static void check(const char *what, int ok)
{
    if (ok) { passed++; printf("  PASS  %s\n", what); }
    else    { failed++; printf("  FAIL  %s\n", what); }
}

static volatile int     irq_count;
static volatile alt_u32 irq_status;

/* The ISR MASKS the interrupt; it does not acknowledge it.
 *
 * The obvious ISR calls firewall_ack() to make the level-sensitive irq
 * deassert. That destroys the evidence: acknowledging clears the sticky
 * STATUS bits, and on real hardware the ISR wins the race against the
 * checking code below - so a violation that genuinely happened reads back as
 * STATUS = 0 and the check fails. Every sticky-bit check in this program
 * failed exactly that way on the first hardware run, while every live-bit
 * check passed, which is what pointed at the ISR.
 *
 * Writing IRQ_ENABLE = 0 stops the interrupt re-entering without touching
 * STATUS, so the fault is still there to be read. The probe helpers re-arm
 * it. What the ISR did observe is kept in irq_status and OR-ed into the
 * result, so a fault is reported whether the main path or the ISR saw it
 * first - the check no longer depends on winning a race.
 */
static void firewall_isr(void *context)
{
    (void)context;
    irq_count++;
    irq_status |= alt_axi4_lite_firewall_status(&fw);
    IOWR_32DIRECT(FW_S_AXI_CTRL_BASE, FW_IRQ_ENABLE, 0u);
}

/* A guarded access: perform it, then ask STATUS what the firewall thought.
   A Nios II load or store gives C no way to see the AXI response code, so
   STATUS is how software finds out an access was denied. */
static void probe_begin(void)
{
    alt_axi4_lite_firewall_ack(&fw, FW_ST_STICKY);
    IOWR_32DIRECT(FW_S_AXI_CTRL_BASE, FW_IRQ_ENABLE, FW_IRQ_ALL);   /* re-arm */
    irq_count  = 0;
    irq_status = 0;
}

/* A store on Nios II/f is POSTED: the processor carries on without waiting for
 * the transaction to reach the firewall, so reading STATUS immediately
 * afterwards can look at the core before the offending write has been
 * evaluated. Reading back from the same slave forces the write to complete
 * first - Avalon keeps one master's accesses to one slave in order - and
 * FW_RW is used for the flush because it is permitted, so it cannot itself
 * add a fault. A read needs no flush: the processor stalls until the data
 * comes back, so the access is complete by definition. */
static alt_u32 probe_write(alt_u32 fwaddr, alt_u32 value)
{
    probe_begin();
    IOWR_32DIRECT(CPU_ADDR(fwaddr), 0, value);
    (void)IORD_32DIRECT(CPU_ADDR(FW_RW), 0);
    return alt_axi4_lite_firewall_status(&fw) | irq_status;
}

static alt_u32 probe_read(alt_u32 fwaddr, alt_u32 *out)
{
    probe_begin();
    *out = IORD_32DIRECT(CPU_ADDR(fwaddr), 0);
    return alt_axi4_lite_firewall_status(&fw) | irq_status;
}

static void show_leds(void)
{
    IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE, alt_axi4_lite_firewall_status(&fw) & 0x3FFu);
}

int main(void)
{
    int      num_rules, rc;
    alt_u32  st, v;

    printf("\n===========================================================\n");
    printf(" AXI4-Lite Firewall - Nios II/f example (DE10-Lite)\n");
    printf("===========================================================\n\n");

    /* alt_sys_init() already probed CORE_INFO and filled these in. Reading
       them back is how this program confirms auto-initialisation ran at all:
       a num_rules of 0 means the BSP did not construct the device, which is
       the symptom of a missing or misnamed _sw.tcl. */
    num_rules = (int)fw.num_rules;
    if (fw.version != FW_VERSION_2_0 || num_rules <= 0) {
        printf("ERROR: no v2.0 firewall at 0x%08x (version=0x%04x, rules=%d)\n",
               (unsigned)fw.base, (unsigned)fw.version, num_rules);
        return 1;
    }
    printf("Core found: v2.0, %d rules, control port at 0x%08x\n",
           num_rules, (unsigned)fw.base);
    printf("Protected path at 0x%08x (firewall sees offsets 0x000..0xFFF)\n\n",
           (unsigned)FW_S_AXI_BASE);

    /* Override the driver's ISR with this program's own.
     *
     * The driver's default ISR acknowledges the sticky bits, which is the
     * right default for an application: the irq is level sensitive and would
     * otherwise re-enter forever. It is the WRONG thing here, for the reason
     * documented above firewall_isr() - acknowledging destroys the very
     * evidence these checks read back. Registering a second handler on the
     * same irq replaces the first, so this line is all it takes.
     */
    alt_ic_isr_register(FW_S_AXI_CTRL_IRQ_INTERRUPT_CONTROLLER_ID,
                        FW_S_AXI_CTRL_IRQ, firewall_isr, NULL, NULL);

    /* ---- configure ------------------------------------------------- */
    fault_write(FAULT_RESETN);
    alt_axi4_lite_firewall_set_reset_handlers(&fw, periph_reset_assert,
                                              periph_reset_release,
                                              periph_delay_clocks, NULL);
    alt_axi4_lite_firewall_reset_config(&fw, 50000u);
    alt_axi4_lite_firewall_set_rule(&fw, 0, FW_RW, FW_RW + 0xFu, FW_PERM_READ | FW_PERM_WRITE);
    alt_axi4_lite_firewall_set_rule(&fw, 1, FW_RO, FW_RO + 0xFu, FW_PERM_READ);
    alt_axi4_lite_firewall_set_rule(&fw, 2, FW_WO, FW_WO + 0xFu, FW_PERM_WRITE);

    printf("--- access control ---\n");

    st = probe_write(FW_RW, 0xA5A51234u);
    check("permitted write is allowed", (st & FW_ST_STICKY) == 0);

    st = probe_read(FW_RW, &v);
    check("permitted read is allowed", (st & FW_ST_STICKY) == 0);
    check("and the data survived the round trip", v == 0xA5A51234u);

    st = probe_read(FW_RO, &v);
    check("read-only region: read allowed", (st & FW_ST_STICKY) == 0);

    irq_count = 0;
    st = probe_write(FW_RO, 0xDEAD0000u);
    check("read-only region: write denied", (st & FW_ST_PERM_VIOLATION) != 0);
    check("and it raised an interrupt", irq_count > 0);

    st = probe_write(FW_WO, 0x5555AAAAu);
    check("write-only region: write allowed", (st & FW_ST_STICKY) == 0);

    st = probe_read(FW_WO, &v);
    check("write-only region: read denied", (st & FW_ST_PERM_VIOLATION) != 0);
    check("and the denied read returned zeros, not the stored data", v == 0);

    st = probe_write(FW_NONE, 0x12345678u);
    check("unmapped address: write denied (default-deny)",
          (st & FW_ST_ADDR_VIOLATION) != 0);

    st = probe_read(FW_NONE, &v);
    check("unmapped address: read denied", (st & FW_ST_ADDR_VIOLATION) != 0);

    {
        uint32_t faddr; int was_write; uint32_t type;
        alt_axi4_lite_firewall_fault(&fw, &faddr, &was_write, &type);
        check("fault registers captured the offending address", faddr == FW_NONE);
        check("fault registers captured the direction", was_write == 0);
        check("fault registers captured the type", type == FW_FAULT_TYPE_ADDR);
    }
    alt_axi4_lite_firewall_ack(&fw, FW_ST_STICKY);
    show_leds();

    /* ---- timeout, isolation, recovery ------------------------------ */
    printf("\n--- fault isolation ---\n");

    printf("  breaking the peripheral (it will refuse the command)...\n");
    fault_write(FAULT_RESETN | FAULT_HANG);

    st = probe_write(FW_RW, 0xBAD0BAD0u);
    check("a hung peripheral produces a timeout, not a lockup",
          (st & FW_ST_TIMEOUT_ERROR) != 0);
    check("the core isolated itself", (st & FW_ST_ISOLATED) != 0);
    check("and blocked the downstream", (st & FW_ST_BLOCKED) != 0);
    check("WR_CMD_STUCK: the command was never accepted",
          (st & FW_ST_WR_CMD_STUCK) != 0);
    show_leds();

    printf("  the CPU is still running - that is the whole point.\n");

    st = probe_write(FW_RW, 0x11112222u);
    check("while blocked, further traffic is rejected, not stalled",
          (st & FW_ST_BLOCKED) != 0);

    alt_axi4_lite_firewall_ack(&fw, FW_ST_STICKY);
    st = alt_axi4_lite_firewall_status(&fw);
    check("acknowledging alone does NOT reopen the downstream",
          (st & FW_ST_BLOCKED) != 0);

    printf("  recovering (reset the peripheral, held across UNBLOCK)...\n");
    fault_write(FAULT_RESETN);              /* stop hanging */
    rc = alt_axi4_lite_firewall_recover(&fw, 1000);
    check("recovery reported success", rc == FW_OK || rc == FW_WARN_NOT_QUIESCED);

    st = alt_axi4_lite_firewall_status(&fw);
    check("downstream is open again", (st & FW_ST_BLOCKED) == 0);
    check("and the core is no longer isolated", (st & FW_ST_ISOLATED) == 0);

    st = probe_read(FW_RW, &v);
    check("the peripheral is fresh after its reset", v == 0);
    check("and no stale write landed on it", v != 0xBAD0BAD0u);

    st = probe_write(FW_RW, 0x600D600Du);
    check("traffic works again after recovery", (st & FW_ST_STICKY) == 0);
    st = probe_read(FW_RW, &v);
    check("and reads back correctly", v == 0x600D600Du);
    show_leds();

    /* ---- the other timeout shape ----------------------------------- */
    printf("\n--- the second failure shape ---\n");
    printf("  peripheral now ACCEPTS the command, then goes silent...\n");
    fault_write(FAULT_RESETN | FAULT_HANG | FAULT_HANG_LATE);

    st = probe_read(FW_RW, &v);
    check("accept-then-silent also times out", (st & FW_ST_TIMEOUT_ERROR) != 0);
    check("RD_RESP_BUSY: the peripheral owes a response forever",
          (st & FW_ST_RD_RESP_BUSY) != 0);
    check("and RD_CMD_STUCK is clear - the command WAS accepted",
          (st & FW_ST_RD_CMD_STUCK) == 0);
    printf("  (this is the case where an unbounded poll of the busy bits\n"
           "   would hang; the driver bounds it)\n");

    fault_write(FAULT_RESETN);
    rc = alt_axi4_lite_firewall_recover(&fw, 1000);
    check("bounded recovery completes even so",
          rc == FW_OK || rc == FW_WARN_NOT_QUIESCED);
    show_leds();

    /* ---- bypass ---------------------------------------------------- */
    printf("\n--- global bypass ---\n");
    IOWR_32DIRECT(FW_S_AXI_CTRL_BASE, FW_CTRL, FW_CTRL_AUTO_ISOLATE);
    st = probe_write(FW_NONE, 0x0BAD0BADu);
    check("with GLOBAL_ENABLE clear, an unmapped write is forwarded",
          (st & FW_ST_STICKY) == 0);
    IOWR_32DIRECT(FW_S_AXI_CTRL_BASE, FW_CTRL,
                  FW_CTRL_GLOBAL_ENABLE | FW_CTRL_AUTO_ISOLATE);
    st = probe_write(FW_NONE, 0u);
    check("and denied again once enforcement is restored",
          (st & FW_ST_ADDR_VIOLATION) != 0);
    alt_axi4_lite_firewall_ack(&fw, FW_ST_STICKY);

    /* ---- done ------------------------------------------------------ */
    show_leds();
    printf("\n===========================================================\n");
    printf(" passed : %d\n failed : %d\n", passed, failed);
    printf(failed == 0 ? " *** ALL CHECKS PASSED ***\n"
                       : " *** FAILURES ***\n");
    printf("===========================================================\n");
    printf("\nLEDR now shows the firewall's live STATUS[9:0].\n");

    /* A terminator the host can wait for. run_on_board.sh reads the JTAG UART
       until it sees this line, then stops - without it the capture can only
       be ended by a timeout, and a run that died early would be
       indistinguishable from one that is merely slow. */
    printf("\n=== DEMO COMPLETE ===\n");

    while (1) {
        show_leds();
        usleep(100000);
    }
    return 0;
}
