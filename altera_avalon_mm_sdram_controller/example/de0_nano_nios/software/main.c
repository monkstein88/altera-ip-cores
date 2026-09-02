/* ===========================================================================
 * main.c - SDRAM memory test for the Avalon-MM SDRAM Controller.
 *
 * Runs on Nios II, reaching the controller through the Platform Designer
 * interconnect - including the 32-to-16 bit width adapter Qsys inserts,
 * because the CPU is a 32-bit master and this slave is 16 bits wide.
 *
 * WHAT THIS TESTS THAT THE RTL EXAMPLE DOES NOT
 * ---------------------------------------------
 * The RTL example drives the controller from a hardware sequencer with
 * nothing in between, one 16-bit word at a time. This one goes through a
 * cache, a width adapter and an interconnect, with byte, half-word and word
 * accesses. Those are the paths where a byte-enable or read-latency mistake
 * shows up as "memory works, but not from software".
 *
 * WHY THE CACHE IS FLUSHED, AND WHERE
 * -----------------------------------
 * The data cache sits between this program and the controller. A write
 * followed by a read of the same address can be answered entirely from the
 * cache, which proves nothing about the SDRAM. Every test below therefore
 * either flushes between the write pass and the read pass, or uses the
 * uncached alias of the region. Getting this wrong makes a broken controller
 * look perfect, so it is stated at each call site rather than assumed.
 *
 * The tests mirror the RTL example's scenarios so the two can be compared:
 * data bus, address bus, byte enables, one row, bank crossing, row thrash,
 * refresh retention, and a full march.
 * =========================================================================== */

#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "system.h"
#include "sys/alt_cache.h"
#include "altera_avalon_pio_regs.h"
#include "altera_avalon_timer_regs.h"
#include "sys/alt_alarm.h"

/* ---------------------------------------------------------------------------
 * The memory under test.
 *
 * SDRAM_BASE and SDRAM_SPAN come from system.h, which Platform Designer
 * generates from the .qsys - so they follow the preset rather than being
 * repeated here. A wrong constant in this file would be a test that passes
 * while addressing the wrong chip.
 * ------------------------------------------------------------------------- */
#define SDRAM_BASE_U   ((volatile uint16_t *)(SDRAM_BASE | 0x80000000u))
#define SDRAM_BASE_C   ((volatile uint16_t *)(SDRAM_BASE))
#define SDRAM_WORDS    (SDRAM_SPAN / 2)          /* 16-bit words */

/* The RTL example's geometry, from the same preset. COL_WORDS is one full row
 * of columns; BANK_STRIDE is the step that moves to the next bank under
 * ADDR_MAP 0. */
/* The DE0-Nano's IS42S16160B has a NINE-bit column where the DE10-Lite part
 * has ten, so a row is half as wide and the bank crossing is half as far. */
#define COL_BITS       9
#define COL_WORDS      (1u << COL_BITS)
#define BANK_STRIDE    (1u << (COL_BITS + 1))

static int checks_passed;
static int checks_failed;

static void check(const char *what, int ok)
{
    if (ok) { checks_passed++; printf("  PASS  %s\n", what); }
    else    { checks_failed++; printf("  FAIL  %s\n", what); }
}

/* The same address-derived pattern the RTL sequencer uses, so a word written
 * by one and read by the other would agree. Address-derived rather than an
 * LFSR: the read pass needs no state from the write pass, and a stuck or
 * swapped address line always changes the value. */
static inline uint16_t patt(uint32_t word_index)
{
    return (uint16_t)((word_index & 0xFFFFu) ^ ((word_index >> 9) & 0xFFFFu)
                      ^ 0xA5A5u);
}

/* --------------------------------------------------------------------------
 * A microsecond clock.
 *
 * The timer is the HAL's SYSTEM CLOCK, programmed with a 1 ms period, so its
 * countdown wraps every millisecond. Reading that countdown alone cannot
 * measure anything longer - and the refresh test below waits a whole second,
 * so with a snapshot-only clock it waited forever: the elapsed count could
 * never reach a second's worth, and the loop never exited. On the board that
 * looked exactly like a hung CPU.
 *
 * alt_nticks() counts the whole periods; the countdown fills in below one.
 * Together they measure microseconds over intervals of any length this
 * program cares about.
 *
 * The timer is NOT started or reprogrammed here. The HAL owns it, and writing
 * its control register to "start" it also clears the interrupt-enable that
 * alt_nticks() depends on - which stops the tick counter and breaks the very
 * thing this clock is built on.
 * ------------------------------------------------------------------------ */
static uint32_t timer_snapshot(void)
{
    IOWR_ALTERA_AVALON_TIMER_SNAPL(TIMER_BASE, 0);
    return ((uint32_t)IORD_ALTERA_AVALON_TIMER_SNAPH(TIMER_BASE) << 16)
         |  (uint32_t)IORD_ALTERA_AVALON_TIMER_SNAPL(TIMER_BASE);
}

static uint64_t now_us(void)
{
    alt_u32  t1, t2;
    uint32_t snap, within;

    do {
        t1   = alt_nticks();
        snap = timer_snapshot();
        t2   = alt_nticks();
    } while (t1 != t2);          /* a tick landed mid-read: take it again */

    within = (uint32_t)TIMER_LOAD_VALUE - snap;      /* counts into this tick */
    return (uint64_t)t1 * (1000000ull / (uint64_t)alt_ticks_per_second())
         + ((uint64_t)within * 1000000ull) / (uint64_t)TIMER_FREQ;
}

/* ===========================================================================
 * Test 1 - the data bus.
 *
 * Walking ones then walking zeros at a single address. Catches a DQ line that
 * is stuck, open, or shorted to its neighbour. Uncached throughout: this is
 * about the wires, and a cache hit would not touch them.
 * ========================================================================= */
static void test_data_bus(void)
{
    volatile uint16_t *p = SDRAM_BASE_U;
    int ok = 1;
    int i;

    for (i = 0; i < 16; i++) {
        uint16_t v = (uint16_t)(1u << i);
        *p = v;
        if (*p != v) { ok = 0; printf("        walking one, bit %d\n", i); }
    }
    for (i = 0; i < 16; i++) {
        uint16_t v = (uint16_t)~(1u << i);
        *p = v;
        if (*p != v) { ok = 0; printf("        walking zero, bit %d\n", i); }
    }
    *p = 0x0000; if (*p != 0x0000) ok = 0;
    *p = 0xFFFF; if (*p != 0xFFFF) ok = 0;

    check("data bus: walking ones and zeros", ok);
}

/* ===========================================================================
 * Test 2 - the address bus.
 *
 * A distinct value at address 0 and at every power-of-two word offset. If two
 * address lines are swapped or one is stuck, two of these addresses collide
 * and the readback finds the wrong value. Uncached, for the same reason as
 * above: an aliased address that the cache satisfies is exactly the fault
 * being looked for.
 * ========================================================================= */
static void test_address_bus(void)
{
    volatile uint16_t *base = SDRAM_BASE_U;
    uint32_t offs;
    int ok = 1;
    int n = 0;

    base[0] = 0xBEEF;
    for (offs = 1; offs < SDRAM_WORDS; offs <<= 1) {
        base[offs] = (uint16_t)(0x1000u + n);
        n++;
    }
    if (base[0] != 0xBEEF) {
        ok = 0;
        printf("        address 0 was overwritten - an address line is stuck\n");
    }
    n = 0;
    for (offs = 1; offs < SDRAM_WORDS; offs <<= 1) {
        uint16_t want = (uint16_t)(0x1000u + n);
        if (base[offs] != want) {
            ok = 0;
            printf("        word offset 0x%08lx read 0x%04x, expected 0x%04x\n",
                   (unsigned long)offs, base[offs], want);
        }
        n++;
    }
    printf("        %d power-of-two addresses checked\n", n + 1);
    check("address bus: no aliasing across the whole device", ok);
}

/* ===========================================================================
 * Test 3 - byte enables.
 *
 * The controller carries byte enables through to DQM. A byte write must leave
 * the other byte of the half-word alone. This is the test that fails when a
 * width adapter or a DQM connection is wrong, and it cannot be done from the
 * RTL sequencer's 16-bit-only interface - which is part of why this example
 * exists.
 * ========================================================================= */
static void test_byte_enables(void)
{
    volatile uint16_t *p16 = SDRAM_BASE_U + 64;
    volatile uint8_t  *p8  = (volatile uint8_t *)p16;
    int ok = 1;

    *p16 = 0xFFFF;
    p8[0] = 0x34;                       /* low byte only */
    if (*p16 != 0xFF34) {
        ok = 0; printf("        after low-byte write: 0x%04x, expected 0xFF34\n", *p16);
    }
    *p16 = 0xFFFF;
    p8[1] = 0x12;                       /* high byte only */
    if (*p16 != 0x12FF) {
        ok = 0; printf("        after high-byte write: 0x%04x, expected 0x12FF\n", *p16);
    }
    *p16 = 0x0000;
    p8[0] = 0xAB; p8[1] = 0xCD;
    if (*p16 != 0xCDAB) {
        ok = 0; printf("        after two byte writes: 0x%04x, expected 0xCDAB\n", *p16);
    }
    check("byte enables reach DQM: a byte write spares its neighbour", ok);
}

/* ===========================================================================
 * Test 4 - 32-bit access across the width adapter.
 *
 * The CPU is a 32-bit master and this slave is 16 bits wide, so every word
 * access becomes two half-word accesses in the interconnect. Word writes and
 * reads must still be coherent, and the halves must land in the right order.
 * ========================================================================= */
static void test_word_access(void)
{
    volatile uint32_t *p32 = (volatile uint32_t *)(SDRAM_BASE_U + 128);
    volatile uint16_t *p16 = (volatile uint16_t *)p32;
    int ok = 1;

    *p32 = 0xDEADBEEFu;
    if (*p32 != 0xDEADBEEFu) {
        ok = 0; printf("        word readback 0x%08lx\n", (unsigned long)*p32);
    }
    /* Little-endian: the low half-word holds the low 16 bits. */
    if (p16[0] != 0xBEEF || p16[1] != 0xDEAD) {
        ok = 0;
        printf("        halves are 0x%04x 0x%04x, expected 0xBEEF 0xDEAD\n",
               p16[0], p16[1]);
    }
    check("32-bit access through the width adapter is coherent", ok);
}

/* ===========================================================================
 * Test 5 - one row, one bank.
 *
 * COL_WORDS consecutive words from a row-aligned base: the column moves and
 * nothing else, so every access after the first is a row hit. The fastest
 * case the controller has, and the baseline the next test is compared against.
 *
 * Written cached and flushed before reading, so the read pass really reaches
 * the device.
 * ========================================================================= */
static uint32_t test_one_row(void)
{
    volatile uint16_t *p = SDRAM_BASE_C;
    uint32_t i, us;
    uint64_t t0;
    int ok = 1;

    t0 = now_us();
    for (i = 0; i < COL_WORDS; i++) p[i] = patt(i);
    alt_dcache_flush_all();
    us = (uint32_t)(now_us() - t0);

    for (i = 0; i < COL_WORDS; i++) {
        if (p[i] != patt(i)) {
            ok = 0;
            printf("        word %lu read 0x%04x, expected 0x%04x\n",
                   (unsigned long)i, p[i], patt(i));
            break;
        }
    }
    check("one row: write and read back a full row of columns", ok);
    printf("        %lu words written in %lu us\n",
           (unsigned long)COL_WORDS, (unsigned long)us);
    return us;
}

/* ===========================================================================
 * Test 6 - row thrash, and the comparison that gives it meaning.
 *
 * Stride BANK_STRIDE clears the column and advances the row, so every single
 * access is a row miss in the same bank: PRECHARGE, ACTIVATE, one word. The
 * worst case the controller has.
 *
 * The number on its own says nothing - it is the RATIO against the one-row
 * case that shows the controller is doing what it claims. On this part a row
 * miss should cost several times a row hit.
 * ========================================================================= */
static void test_row_thrash(uint32_t one_row_us)
{
    volatile uint16_t *p = SDRAM_BASE_C;
    const uint32_t n = 256;
    uint32_t i, us;
    uint64_t t0;
    int ok = 1;

    t0 = now_us();
    for (i = 0; i < n; i++) p[i * BANK_STRIDE] = patt(i * BANK_STRIDE);
    alt_dcache_flush_all();
    us = (uint32_t)(now_us() - t0);

    for (i = 0; i < n; i++) {
        if (p[i * BANK_STRIDE] != patt(i * BANK_STRIDE)) {
            ok = 0;
            printf("        stride word %lu mismatched\n", (unsigned long)i);
            break;
        }
    }
    check("row thrash: every access a row miss, data still correct", ok);

    /* Per-word cost, scaled to keep integer arithmetic meaningful. */
    if (one_row_us > 0) {
        uint32_t hit_ns_x1000  = (one_row_us * 1000000u) / COL_WORDS;
        uint32_t miss_ns_x1000 = (us * 1000000u) / n;
        printf("        row hit ~%lu ns/word, row miss ~%lu ns/word\n",
               (unsigned long)(hit_ns_x1000 / 1000u),
               (unsigned long)(miss_ns_x1000 / 1000u));
        check("a row miss costs more per word than a row hit",
              miss_ns_x1000 > hit_ns_x1000);
    }
}

/* ===========================================================================
 * Test 7 - four banks, one row each.
 *
 * Rotate through the four banks at the same row, advancing the column only
 * once all four have been visited. A controller that keeps one row open per
 * bank absorbs this at nearly full rate; one that keeps a single open row
 * pays a full row cycle on every access. This is the access this core exists
 * for, so it is worth its own test rather than being folded into the march.
 * ========================================================================= */
static void test_four_banks(void)
{
    volatile uint16_t *p = SDRAM_BASE_C;
    const uint32_t n = 1024;
    uint32_t i, us;
    uint64_t t0;
    int ok = 1;

    /* addr = col | (bank0 << COL_BITS) | (row << (COL_BITS+1))
     *            | (bank1 << (COL_BITS+1+13))
     *
     * The row is STAGGERED so the four banks are never all on the same row.
     * A rotation that leaves every bank on row 0 - which this used to do -
     * does not test per-bank row tracking at all: a controller with one
     * shared open-row register holds the right row by coincidence and passes.
     * That was measured, not guessed; the fault was injected into the real
     * design on a DE0-Nano and this test missed it.
     *
     * With the stagger, access 4 asks for bank 0 at the row banks 1-3 have
     * just activated, while bank 0 still has its own older row open. A shared
     * register calls that a hit and reads the wrong row; per-bank state calls
     * it a miss and re-activates. */
    #define BANK_ROT_ROW(i)  (((i) >> 2) + (((i) & 3u) ? 1u : 0u))
    #define BANK_ROT_ADDR(i) \
        (((i) >> 2) \
         | ((((i) >> 0) & 1u) << COL_BITS) \
         | (BANK_ROT_ROW(i) << (COL_BITS + 1)) \
         | ((((i) >> 1) & 1u) << (COL_BITS + 1 + 13)))

    t0 = now_us();
    for (i = 0; i < n; i++) p[BANK_ROT_ADDR(i)] = patt(BANK_ROT_ADDR(i));
    alt_dcache_flush_all();
    us = (uint32_t)(now_us() - t0);

    for (i = 0; i < n; i++) {
        uint32_t a = BANK_ROT_ADDR(i);
        if (p[a] != patt(a)) {
            ok = 0;
            printf("        bank-rotation word %lu mismatched\n", (unsigned long)i);
            break;
        }
    }
    check("four banks at staggered rows: per-bank row tracking", ok);
    printf("        %lu words in %lu us\n", (unsigned long)n, (unsigned long)us);
    #undef BANK_ROT_ADDR
    #undef BANK_ROT_ROW
}

/* ===========================================================================
 * Test 8 - refresh retention.
 *
 * Write a block, sit idle far longer than the refresh interval, then read it
 * back. tREFI is 7.8125 us and the whole device must be refreshed every 64 ms,
 * so a second of idling is more than 120 full refresh cycles. If auto-refresh
 * were not happening, the data would be long gone.
 *
 * This is the one test here that a simulation cannot do: no functional model
 * forgets. It is the reason to run this on hardware.
 * ========================================================================= */
static void test_refresh(void)
{
    volatile uint16_t *p = SDRAM_BASE_C + 0x10000;
    const uint32_t n = 4096;
    uint32_t i;
    uint64_t t0;
    int ok = 1;

    for (i = 0; i < n; i++) p[i] = patt(0x10000u + i);
    alt_dcache_flush_all();

    printf("        idling ~1 s (over 120 full refresh periods)...\n");
    t0 = now_us();
    while ((now_us() - t0) < 1000000ull) {
        /* nothing: the controller must refresh on its own */
    }

    alt_dcache_flush_all();
    for (i = 0; i < n; i++) {
        if (p[i] != patt(0x10000u + i)) {
            ok = 0;
            printf("        word %lu lost after idle: 0x%04x, expected 0x%04x\n",
                   (unsigned long)i, p[i], patt(0x10000u + i));
            break;
        }
    }
    check("refresh retention: data survives a second of idle", ok);
}

/* ===========================================================================
 * Test 9 - the whole device.
 *
 * Every word written, then every word verified. This is the test that catches
 * a row or bank bit that is wrong only in part of the map, and the only one
 * that touches all SDRAM_WORDS of it. It is also the throughput figure worth
 * quoting, because it is long enough that startup costs vanish.
 * ========================================================================= */
static void test_full_march(void)
{
    volatile uint16_t *p = SDRAM_BASE_C;
    uint32_t i, wr_us, rd_us;
    uint64_t t0;
    int ok = 1;

    printf("        marching %lu words (%lu MByte)...\n",
           (unsigned long)SDRAM_WORDS, (unsigned long)(SDRAM_SPAN >> 20));

    t0 = now_us();
    for (i = 0; i < SDRAM_WORDS; i++) p[i] = patt(i);
    alt_dcache_flush_all();
    wr_us = (uint32_t)(now_us() - t0);

    t0 = now_us();
    for (i = 0; i < SDRAM_WORDS; i++) {
        if (p[i] != patt(i)) {
            ok = 0;
            printf("        word %lu read 0x%04x, expected 0x%04x\n",
                   (unsigned long)i, p[i], patt(i));
            break;
        }
    }
    rd_us = (uint32_t)(now_us() - t0);

    check("full march: every word in the device written and verified", ok);
    if (wr_us && rd_us) {
        printf("        write %lu MB/s, read %lu MB/s\n",
               (unsigned long)((uint64_t)SDRAM_SPAN / wr_us),
               (unsigned long)((uint64_t)SDRAM_SPAN / rd_us));
        printf("        (CPU-bound, not the controller's limit - see README)\n");
    }
}

int main(void)
{
    uint32_t one_row_us;

    /* Unbuffered stdout.
     *
     * The JTAG UART is a pipe to a host that may not be attached yet, and
     * this program never returns - it ends in an idle loop - so anything
     * left in a stdio buffer is never flushed. Buffered, the whole run
     * produces no output at all and looks exactly like a CPU that is not
     * running. Unbuffered, each line appears as it happens, which also makes
     * a hang report itself: the last line printed is the test that hung.
     *
     * SMALL_C_LIB has no setvbuf - the reduced printf writes straight through,
     * so there is nothing to unbuffer. The guard is what lets one source file
     * serve both BSPs. */
#ifndef SMALL_C_LIB
    setvbuf(stdout, NULL, _IONBF, 0);
#endif

    printf("\n");
    printf("=============================================================\n");
    printf(" Avalon-MM SDRAM Controller - Nios II memory test\n");
    printf(" %lu MByte at 0x%08lx, %lu 16-bit words\n",
           (unsigned long)(SDRAM_SPAN >> 20), (unsigned long)SDRAM_BASE,
           (unsigned long)SDRAM_WORDS);
    printf("=============================================================\n\n");

    IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE, 0x001);
    test_data_bus();
    IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE, 0x003);
    test_address_bus();
    IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE, 0x007);
    test_byte_enables();
    IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE, 0x00F);
    test_word_access();
    IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE, 0x01F);
    one_row_us = test_one_row();
    IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE, 0x03F);
    test_row_thrash(one_row_us);
    IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE, 0x07F);
    test_four_banks();
    IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE, 0x0FF);
    test_refresh();
    IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE, 0x7F);
    test_full_march();

    printf("\n-------------------------------------------------------------\n");
    printf("  checks passed : %d\n", checks_passed);
    printf("  checks failed : %d\n", checks_failed);
    if (checks_failed == 0) {
        printf("  *** ALL TESTS PASSED ***\n");
        IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE, 0xFF);    /* all lit */
    } else {
        printf("  *** THERE ARE FAILURES ***\n");
        IOWR_ALTERA_AVALON_PIO_DATA(PIO_LED_BASE, 0x81);    /* ends lit */
    }
    printf("=============================================================\n");

    while (1) { }
    return 0;
}
