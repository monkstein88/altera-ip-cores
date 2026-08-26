/* =============================================================================
 * main.c - Nios II application for the Avalon-MM Firewall example.
 *
 * Runs a sequence of checks against the firewall from C, on a real processor,
 * through generated Platform Designer interconnect, at 100 MHz. It reports on
 * the JTAG UART and mirrors the firewall's live STATUS onto LEDR.
 *
 * This example answers a different question from the RTL demo next door. That
 * one asks whether the CORE BEHAVES; this one asks whether it INTEGRATES -
 * whether the component packages, whether the BSP finds the driver, whether
 * the interrupt reaches the CPU through Qsys, and whether a data cache gets in
 * the way.
 *
 * ---------------------------------------------------------------------------
 * THREE THINGS THAT ARE EASY TO GET WRONG
 * ---------------------------------------------------------------------------
 * 1. RULES ARE IN FIREWALL-SIDE ADDRESSES, NOT CPU ADDRESSES. s0 declares
 *    bridgesToMaster m0, so Platform Designer folds the firewall out of the
 *    address map entirely: the protected peripheral appears to the CPU under
 *    its OWN name, TGT_BASE, and an access to TGT_BASE + 0x10 reaches the core
 *    as address 0x010 - because the peripheral sits at 0 in m0's space. The
 *    rule table therefore holds 0x000, 0x040, 0x080, not 0x23000. Getting this
 *    backwards fills the table with values no transaction can ever match, and
 *    every access returns DECODEERROR.
 *
 *    That the peripheral keeps its own address is the point of bridgesToMaster:
 *    dropping this firewall into an existing system moves nothing.
 *
 * 2. THE DATA CACHE MUST BE BYPASSED. Nios II/f has one. Every access to the
 *    firewall and to the protected peripheral goes through IORD_32DIRECT /
 *    IOWR_32DIRECT, which force an uncached access. A plain volatile pointer
 *    would leave writes sitting in the cache where the hardware never sees
 *    them, and reads returning a cached copy of a register that has since
 *    changed.
 *
 * 3. THE PERIPHERAL'S RESET IS THE INTEGRATOR'S JOB. The core does not drive
 *    it, and recovery from a timeout requires it. Here it is a PIO bit, and
 *    the two callbacks below are what the driver calls during recover().
 * ===========================================================================*/

#include <stdio.h>
#include <unistd.h>

#include "system.h"
#include "altera_avalon_pio_regs.h"
#include "altera_avalon_mm_firewall.h"

/* The BSP constructs and initialises this from alt_sys_init.c before main(),
   because the driver's _sw.tcl sets auto_initialize. `extern` because
   alt_sys_init.c owns the definition. */
extern alt_avalon_mm_firewall_dev fw;

/* ---------------------------------------------------------------------------
 * The address map, in FIREWALL-side addresses. See note 1.
 *
 * Rules 0 and 1 abut on purpose and both permit everything: a burst crossing
 * the boundary is still refused, because permissions are per-window. The CPU
 * cannot issue a burst, so that case is the RTL demo's to prove - but the
 * windows are laid out the same way so the two examples can be read together.
 * ------------------------------------------------------------------------ */
#define FW_RW0    0x000u        /* rule 0: 0x000-0x03F  read + write + burst */
#define FW_RW1    0x040u        /* rule 1: 0x040-0x07F  read + write + burst */
#define FW_RO     0x080u        /* rule 2: 0x080-0x0AF  read only            */
#define FW_WO     0x0B0u        /* rule 3: 0x0B0-0x0DF  write only           */
#define FW_NB     0x0E0u        /* rule 4: 0x0E0-0x0EF  no bursts            */
#define FW_NONE   0x0F0u        /* covered by no rule -> DECODEERROR         */

/* pio_fault bits, matching the peripheral's fault conduit. */
#define P_HANG        0x1u
#define P_HANG_LATE   0x2u
#define P_RESETN      0x4u
#define P_RUN         (P_RESETN)                        /* healthy           */
#define P_STARVE      (P_RESETN | P_HANG)               /* never accept      */
#define P_SILENT      (P_RESETN | P_HANG | P_HANG_LATE) /* accept, go silent */
#define P_IN_RESET    (0u)                              /* held in reset     */

static int passed, failed;

static void ok(const char *what, int cond)
{
    if (cond) { passed++; printf("  PASS  %s\n", what); }
    else      { failed++; printf("  FAIL: %s\n", what); }
}

static void ok_eq(const char *what, alt_u32 got, alt_u32 exp)
{
    if (got == exp) { passed++; printf("  PASS  %s (0x%08lx)\n", what, (unsigned long)got); }
    else            { failed++; printf("  FAIL: %s - got 0x%08lx, expected 0x%08lx\n",
                                       what, (unsigned long)got, (unsigned long)exp); }
}

/* --------------------------------------------------------------------------
 * Access to the protected path. Uncached, always. See note 2.
 * ------------------------------------------------------------------------ */
static void  p_write(alt_u32 off, alt_u32 v) { IOWR_32DIRECT(TGT_BASE, off, v); }
static alt_u32 p_read(alt_u32 off)           { return IORD_32DIRECT(TGT_BASE, off); }

static void fault_ctl(alt_u32 v) { IOWR_ALTERA_AVALON_PIO_DATA(PIO_FAULT_BASE, v); }

/* The two callbacks the driver invokes during recover(). Holding the reset for
   a few microseconds is well beyond the >= 16 clocks the core asks for, and
   this runs from a thread rather than the ISR - see the note by on_fault. */
static void periph_assert_reset(void *ctx)  { (void)ctx; fault_ctl(P_IN_RESET); usleep(10); }
static void periph_release_reset(void *ctx) { (void)ctx; fault_ctl(P_RUN); usleep(10); }

/* Called from the ISR. Deliberately does nothing but record: the ISR should
   stay short, and resetting a peripheral from interrupt context is exactly
   the thing the driver header warns about. */
static volatile alt_u32 last_status, last_addr, last_info;
static void on_fault(alt_avalon_mm_firewall_dev *d, alt_u32 status,
                     alt_u32 addr, alt_u32 info)
{
    (void)d;
    last_status = status;
    last_addr   = addr;
    last_info   = info;
}

static void show_status(void)
{
    IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE,
                                alt_avalon_mm_firewall_status(&fw) & 0x3FFu);
}

int main(void)
{
    static const alt_avalon_mm_firewall_rule map[] = {
        { FW_RW0, FW_RW0 + 0x3F, ALT_AVMM_FW_PERM_READ | ALT_AVMM_FW_PERM_WRITE
                                 | ALT_AVMM_FW_PERM_BURST },
        { FW_RW1, FW_RW1 + 0x3F, ALT_AVMM_FW_PERM_READ | ALT_AVMM_FW_PERM_WRITE
                                 | ALT_AVMM_FW_PERM_BURST },
        { FW_RO,  FW_RO  + 0x2F, ALT_AVMM_FW_PERM_READ  | ALT_AVMM_FW_PERM_BURST },
        { FW_WO,  FW_WO  + 0x2F, ALT_AVMM_FW_PERM_WRITE | ALT_AVMM_FW_PERM_BURST },
        { FW_NB,  FW_NB  + 0x0F, ALT_AVMM_FW_PERM_READ  | ALT_AVMM_FW_PERM_WRITE },
    };
    alt_u32 st, v;
    alt_u32 faults_before;

    printf("\n=========================================================\n");
    printf(" Avalon-MM Firewall - Nios II/f example, DE10-Lite\n");
    printf(" system clock %d Hz\n", (int)ALT_CPU_FREQ);
    printf("=========================================================\n");

    fault_ctl(P_RUN);

    /* ---- A. what alt_sys_init() left behind -------------------------- */
    printf("\n--- A. BSP auto-initialisation ---\n");
    ok_eq("CORE_INFO version is v1.0", fw.version,
          ALTERA_AVALON_MM_FIREWALL_VERSION_1_0);
    ok_eq("geometry: rules read back from the hardware", fw.num_rules, 5);
    ok_eq("geometry: bytes per beat", fw.bytes_per_beat, 4);
    /* 16, not the core's default 128: this system sets BURST_WIDTH = 5.
       A Nios II data master issues single accesses, and the narrower counters
       are what let the whole system close timing at 100 MHz - see
       qsys/build_system.tcl. The point of the check is that the driver reads
       the geometry out of CORE_INFO rather than being told it. */
    ok_eq("geometry: max burst beats, read from CORE_INFO", fw.max_burst_beats, 16);
    ok("the interrupt was connected in Qsys", fw.irq >= 0);
    /* The table resets empty and the hardware is default-deny, so everything
       is refused until configure() runs. That is the right state for a system
       that has not yet said what it wants to allow.
       
       Counted through fault_count, not by reading STATUS: the driver's ISR
       acknowledges the sticky bits as part of handling the fault, so by the
       time this thread got to read STATUS it would be clean again. The ISR
       having already run is the evidence, not a leftover bit. */
    /*
     * Retire every rule first, rather than trusting the table to be empty.
     *
     * It is empty after a fresh configuration, and that IS the property worth
     * having - the state after alt_sys_init() is "everything denied". But
     * nios2-download restarts the CPU without resetting the FPGA fabric, so
     * on a re-run the rule table still holds whatever the previous run
     * programmed, and the check would pass or fail depending on how the board
     * was last used. Clearing first tests default-deny deterministically.
     */
    {
        unsigned i;
        for (i = 0; i < fw.num_rules; i++)
            alt_avalon_mm_firewall_clear_rule(&fw, i);
    }
    faults_before = fw.fault_count;
    p_write(FW_RW0, 0x11112222);
    usleep(1000);
    ok("with no valid rule, a write is denied", fw.fault_count != faults_before);

    /* ---- B. configure ------------------------------------------------ */
    printf("\n--- B. Programming the rule table from C ---\n");
    alt_avalon_mm_firewall_set_reset_handlers(&fw, periph_assert_reset,
                                              periph_release_reset, NULL);
    fw.on_fault = on_fault;
    ok_eq("configure() accepts the map", (alt_u32)alt_avalon_mm_firewall_configure(&fw, map, 5), 0);
    alt_avalon_mm_firewall_set_timeout(&fw, 5000);      /* cycles without progress */
    IOWR_ALTERA_AVALON_MM_FIREWALL_STATUS(fw.base,
        ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK);
    ok_eq("STATUS is clean after acknowledging", alt_avalon_mm_firewall_status(&fw), 0);
    ok("configure() refuses more rules than the hardware has",
       alt_avalon_mm_firewall_configure(&fw, map, 99) != 0);

    /* ---- C. permitted traffic ---------------------------------------- */
    printf("\n--- C. Permitted access, through Qsys interconnect ---\n");
    p_write(FW_RW0, 0xA5A51234u);
    ok_eq("permitted write reads back byte for byte", p_read(FW_RW0), 0xA5A51234u);
    ok_eq("...and raised no fault", alt_avalon_mm_firewall_status(&fw), 0);
    p_write(FW_RW1 + 0x10, 0xCAFEBABEu);
    ok_eq("the adjacent window works too", p_read(FW_RW1 + 0x10), 0xCAFEBABEu);
    ok_eq("read-only window is readable", (p_read(FW_RO), alt_avalon_mm_firewall_status(&fw)), 0);
    show_status();

    /* ---- D. access control, and the interrupt ------------------------ */
    printf("\n--- D. Denied access raises the interrupt ---\n");
    faults_before = fw.fault_count;
    last_status = 0;
    p_write(FW_RO, 0xDEAD0000u);                 /* write to a read-only window */
    usleep(1000);                                 /* let the ISR run            */
    ok("the ISR ran", fw.fault_count == faults_before + 1);
    ok("STATUS.PERM_VIOLATION was latched",
       (last_status & ALTERA_AVALON_MM_FIREWALL_STATUS_PERM_VIOL_MSK) != 0);
    ok_eq("FAULT_ADDR names the offending access", last_addr, FW_RO);
    ok_eq("FAULT_INFO.WAS_WRITE is set", last_info & 1u, 1u);
    ok_eq("FAULT_INFO.TYPE is PERM",
          ALTERA_AVALON_MM_FIREWALL_FAULT_TYPE(last_info),
          ALTERA_AVALON_MM_FIREWALL_FAULT_PERM);
    printf("        driver decoded it as: \"%s\"\n",
           alt_avalon_mm_firewall_fault_name(last_info));
    ok_eq("the ISR acknowledged, so STATUS is clean again",
          alt_avalon_mm_firewall_status(&fw)
          & ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK, 0);

    printf("\n--- E. Read of a write-only window returns zeros ---\n");
    p_write(FW_WO, 0xFEEDFACEu);
    usleep(1000);
    IOWR_ALTERA_AVALON_MM_FIREWALL_STATUS(fw.base,
        ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK);
    v = p_read(FW_WO);
    usleep(1000);
    ok_eq("the stored value does not leave the peripheral", v, 0u);

    printf("\n--- F. Unmapped address ---\n");
    IOWR_ALTERA_AVALON_MM_FIREWALL_STATUS(fw.base,
        ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK);
    last_status = 0;
    (void)p_read(FW_NONE);
    usleep(1000);
    ok("STATUS.ADDR_VIOLATION was latched",
       (last_status & ALTERA_AVALON_MM_FIREWALL_STATUS_ADDR_VIOL_MSK) != 0);
    ok_eq("FAULT_INFO.TYPE is ADDR",
          ALTERA_AVALON_MM_FIREWALL_FAULT_TYPE(last_info),
          ALTERA_AVALON_MM_FIREWALL_FAULT_ADDR);
    show_status();

    /* ---- G. timeout, isolation and recovery -------------------------- */
    printf("\n--- G. Downstream timeout and the recovery sequence ---\n");
    /*
     * The interrupt is MASKED for this section, and that is the point of it.
     *
     * The driver's ISR acknowledges the sticky bits and, on a timeout, calls
     * recover() - which resets the peripheral and unblocks the core. Left
     * enabled, the fault is handled and cleared before this thread can read a
     * single bit of it, and every check below sees a healthy firewall.
     *
     * Masking and polling instead is the pattern the driver header recommends
     * for anything but the simplest peripheral: "leave on_fault to set a flag
     * and call recover() from a thread". Here the thread does the whole job.
     */
    IOWR_ALTERA_AVALON_MM_FIREWALL_IRQ_ENABLE(fw.base, 0);
    IOWR_ALTERA_AVALON_MM_FIREWALL_STATUS(fw.base,
        ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK);
    fault_ctl(P_STARVE);                          /* peripheral stops answering */
    p_write(FW_RW0, 0xCAFEF00Du);                 /* must return, not hang      */
    ok("the CPU was released rather than hung", 1);
    usleep(2000);
    st = alt_avalon_mm_firewall_status(&fw);
    show_status();
    ok("STATUS.BLOCKED is set", (st & ALTERA_AVALON_MM_FIREWALL_STATUS_BLOCKED_MSK) != 0);
    ok("STATUS.WR_CMD_STUCK is set - the command was never accepted",
       (st & ALTERA_AVALON_MM_FIREWALL_STATUS_WR_CMD_STUCK_MSK) != 0);
    ok("the driver reports it as blocked", alt_avalon_mm_firewall_is_blocked(&fw));
    ok("STATUS.TIMEOUT_ERROR is set",
       (st & ALTERA_AVALON_MM_FIREWALL_STATUS_TIMEOUT_MSK) != 0);

    /* While blocked, traffic is REJECTED, not stalled. There is no window in
       which the firewall quietly holds traffic, so a driver needs a retry
       path rather than a wait loop. */
    v = p_read(FW_RW0);
    ok("traffic while blocked is answered, not stalled", 1);
    ok("...and the core is still blocked", alt_avalon_mm_firewall_is_blocked(&fw));

    /* The recovery the core documents, run by the driver: acknowledge, hold
       the peripheral in reset, UNBLOCK while it is still in reset, release. */
    fault_ctl(P_STARVE);
    ok_eq("recover() succeeds", (alt_u32)alt_avalon_mm_firewall_recover(&fw), 0);
    fault_ctl(P_RUN);
    usleep(2000);
    ok("the core is no longer blocked", !alt_avalon_mm_firewall_is_blocked(&fw));
    ok_eq("STATUS is fully clean after recovery", alt_avalon_mm_firewall_status(&fw), 0);
    ok_eq("nothing stale landed in the peripheral", p_read(FW_RW0), 0u);
    p_write(FW_RW0, 0x600DF00Du);
    ok_eq("traffic works again", p_read(FW_RW0), 0x600DF00Du);
    ok("a recovery was counted", fw.recover_count > 0);
    IOWR_ALTERA_AVALON_MM_FIREWALL_IRQ_ENABLE(fw.base,
        ALTERA_AVALON_MM_FIREWALL_IRQ_ALL_MSK);   /* unmask again */

    /* ---- H. the other timeout shape ---------------------------------- */
    printf("\n--- H. Accepted-then-silent: the other timeout shape ---\n");
    IOWR_ALTERA_AVALON_MM_FIREWALL_IRQ_ENABLE(fw.base, 0);    /* as in G */
    IOWR_ALTERA_AVALON_MM_FIREWALL_STATUS(fw.base,
        ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK);
    fault_ctl(P_SILENT);
    (void)p_read(FW_RW0);
    usleep(2000);
    st = alt_avalon_mm_firewall_status(&fw);
    show_status();
    ok("STATUS.TIMEOUT_ERROR is set", (st & ALTERA_AVALON_MM_FIREWALL_STATUS_TIMEOUT_MSK) != 0);
    ok("STATUS.RD_CMD_STUCK is CLEAR - the command WAS accepted",
       (st & ALTERA_AVALON_MM_FIREWALL_STATUS_RD_CMD_STUCK_MSK) == 0);
    fault_ctl(P_SILENT);
    ok_eq("recover() succeeds again", (alt_u32)alt_avalon_mm_firewall_recover(&fw), 0);
    fault_ctl(P_RUN);
    usleep(2000);
    ok("recovered", !alt_avalon_mm_firewall_is_blocked(&fw));
    IOWR_ALTERA_AVALON_MM_FIREWALL_IRQ_ENABLE(fw.base,
        ALTERA_AVALON_MM_FIREWALL_IRQ_ALL_MSK);

    /* ---- I. bypass does not reopen a broken downstream --------------- */
    printf("\n--- I. Bypass mode turns off access control, not isolation ---\n");
    IOWR_ALTERA_AVALON_MM_FIREWALL_STATUS(fw.base,
        ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK);
    IOWR_ALTERA_AVALON_MM_FIREWALL_CTRL(fw.base,
        ALTERA_AVALON_MM_FIREWALL_CTRL_AUTO_ISOLATE_MSK);   /* GLOBAL_ENABLE off */
    v = p_read(FW_NONE);                                     /* unmapped, allowed now */
    usleep(1000);
    ok_eq("with access control off, an unmapped read raises no fault",
          alt_avalon_mm_firewall_status(&fw)
          & ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK, 0);
    IOWR_ALTERA_AVALON_MM_FIREWALL_CTRL(fw.base,
        ALTERA_AVALON_MM_FIREWALL_CTRL_ENABLE_MSK |
        ALTERA_AVALON_MM_FIREWALL_CTRL_AUTO_ISOLATE_MSK);
    /* Counted, not read back: the ISR acknowledges STATUS as it handles the
       fault, so a later read of it races the interrupt. */
    faults_before = fw.fault_count;
    (void)p_read(FW_NONE);
    usleep(1000);
    ok("with it back on, the same read faults", fw.fault_count > faults_before);
    IOWR_ALTERA_AVALON_MM_FIREWALL_STATUS(fw.base,
        ALTERA_AVALON_MM_FIREWALL_STATUS_STICKY_MSK);
    show_status();

    printf("\n=========================================================\n");
    printf(" passed : %d\n", passed);
    printf(" failed : %d\n", failed);
    if (failed == 0) printf(" *** ALL CHECKS PASSED ***\n");
    else             printf(" *** %d FAILURE(S) ***\n", failed);
    printf("=========================================================\n");

    while (1) { show_status(); usleep(100000); }
    return 0;
}
