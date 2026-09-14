/* =============================================================================
 * driver_tests.c - the HAL driver, run against the RTL.
 *
 * Every other suite in this core drives the registers from SystemVerilog,
 * written to do what the driver does. This one runs the driver. What it can
 * find that they cannot is the difference between the two: a register written
 * in the wrong order, a wait timed by a CPU loop rather than by the hardware,
 * a status bit cleared before it was read. The first run of this file found
 * the second of those - see run_clocks() in the driver.
 *
 * The device is constructed with the BSP's own _INSTANCE macro, so a field
 * added to alt_sdcard_dev without its initialiser fails to compile here.
 *
 * -----------------------------------------------------------------------------
 * ONE SOURCE, EVERY BUILD
 * -----------------------------------------------------------------------------
 * The harness is built with and without the DMA and with and without a
 * card-detect switch. Every check() below runs exactly once in every one of
 * them: where the builds must behave differently, the EXPECTED VALUE depends on
 * the build, never whether the check runs.
 *
 * And no check() is reached twice. Helpers that run the same steps for several
 * cards or sizes - probe_card() and round_trip() - RETURN what went wrong, and
 * the checks are made once each at the call site. So the number of call sites
 * is the number of checks, which the runner compares against the run, and which
 * the documentation's count is derived from.
 * ===========================================================================*/

#include <stdio.h>
#include <string.h>

#include "sim.h"
#include "altera_avalon_mm_sdcard_controller.h"

/* The FatFs glue in software/fatfs is linked into every build, against the
 * stand-in headers in tb/driver/fatfs_stub. */
#include "diskio.h"

/* What system.h would say. */
#define SDCARD_BASE                         0x00010000u
#define SDCARD_IRQ_INTERRUPT_CONTROLLER_ID  0
#define SDCARD_IRQ                          0

ALTERA_AVALON_MM_SDCARD_CONTROLLER_INSTANCE(SDCARD, sdcard);

/* The driver's transfer split, as this build compiled it. */
#ifndef ALT_SDCARD_MAX_BLOCKS_PER_TRANSFER
#define ALT_SDCARD_MAX_BLOCKS_PER_TRANSFER  0xFFFFu
#endif

#define BLOCK       512u
#define MAX_BLOCKS  8u

#define HC_BLOCKS   7864320u
#define SC_BLOCKS   2097152u

static int checks_run, checks_fail;

static void check(const char *what, int cond)
{
    checks_run++;
    if (!cond) {
        checks_fail++;
        printf("  FAIL  %s\n", what);
    }
}

/* Word-aligned, and static so the DMA can reach them (see sim_main.cpp). */
static alt_u32 wbuf[MAX_BLOCKS * BLOCK / 4];
static alt_u32 rbuf[MAX_BLOCKS * BLOCK / 4];

static void fill(alt_u32 *buf, alt_u32 blocks, alt_u8 seed)
{
    alt_u8 *p = (alt_u8 *)buf;
    alt_u32 i;
    for (i = 0; i < blocks * BLOCK; i++)
        p[i] = (alt_u8)(seed + i * 7u + (i >> 9));
}

/* The card's flash, byte addressed on both cards whatever their command
 * addressing - so where a block landed is stated independently of the
 * block-to-address conversion under test. */
static int on_card(int which, alt_u32 block, const alt_u8 *p, alt_u32 blocks)
{
    alt_u32 i;
    for (i = 0; i < blocks * BLOCK; i++)
        if (sim_card_peek(which, block * BLOCK + i) != p[i]) return 0;
    return 1;
}

static alt_u32 cid_serial(void)
{
    return ((alt_u32)sdcard.cid[9] << 24) | ((alt_u32)sdcard.cid[10] << 16)
         | ((alt_u32)sdcard.cid[11] << 8) | (alt_u32)sdcard.cid[12];
}

static int cd(void) { return sim_cfg_card_detect(); }

/* A card identified and ready, whatever happened before. */
static void fresh_card(int which)
{
    sim_card_select(SIM_CARD_NONE);
    sim_card_select(which);
    (void)alt_sdcard_probe(&sdcard);
}

/* Out and back in - or out and a different one in - between two calls, with
 * the socket switch reading "present" on both sides of the gap. */
static void swap_to(int which)
{
    sim_card_select(SIM_CARD_NONE);
    sim_card_select(which);
}

/* -------------------------------------------------------------------------- */

static void test_init(void)
{
    int r;

    printf("  -- init --\n");
    sim_budget("init", 10000);

    /* Short enough that a data-phase timeout, if a test provokes one, does not
     * dominate the run; long enough for anything the cards legitimately do. */
    sdcard.timeout_cycles = 2000000u;

    r = alt_sdcard_init(&sdcard);
    check("alt_sdcard_init returns OK", r == ALT_SDCARD_OK);
    check("CORE_INFO: major version 1",
          ((sdcard.version & ALT_SDCARD_INFO_VER_MAJOR_MSK)
               >> ALT_SDCARD_INFO_VER_MAJOR_OFST_B) == 1u);
    check("CORE_INFO: DMA matches the build", sdcard.has_dma == sim_cfg_dma());
    check("CORE_INFO: card detect matches the build",
          sdcard.has_card_detect == cd());
    check("init leaves the card unidentified",
          sdcard.type == ALT_SDCARD_TYPE_NONE && sdcard.blocks == 0u);
    check("init registers the instance for code that is not handed a device",
          alt_sdcard_instance(0) == &sdcard && alt_sdcard_instance(1) == 0);
}

/* The borrowed convenience: no probe, just use the card. */
static void test_lazy_identification(void)
{
    int r;

    printf("  -- a block call identifies the card itself --\n");
    sim_card_select(SIM_CARD_HC);
    sim_budget("lazy identification", 20000000);

    fill(wbuf, 1, 0x5A);
    r = alt_sdcard_write_blocks(&sdcard, 10u, wbuf, 1);
    check("the first call, with no probe before it, succeeds", r == ALT_SDCARD_OK);
    check("...having identified the card",
          sdcard.type == ALT_SDCARD_TYPE_SDHC && sdcard.blocks == HC_BLOCKS);
    check("...once", alt_sdcard_generation(&sdcard) == 1u);
    check("...and the block is where it was sent",
          on_card(SIM_CARD_HC, 10u, (alt_u8 *)wbuf, 1));
}

/* What went wrong in an identification, or in a write-and-read-back. */
#define PROBE_RETURN   0x01u
#define PROBE_CLASS    0x02u
#define PROBE_CAPACITY 0x04u
#define PROBE_CID      0x08u
#define PROBE_GEN      0x10u

#define RT_WRITE_RET   0x01u
#define RT_ON_CARD     0x02u
#define RT_READ_RET    0x04u
#define RT_READ_BACK   0x08u
#define RT_DATA_PATH   0x10u

static unsigned probe_card(int which)
{
    int      r;
    int      hc = (which == SIM_CARD_HC);
    alt_u32  gen;
    unsigned bad = 0;

    printf("  -- explicit identification, %s card --\n", hc ? "SDHC" : "SDSC");
    sim_card_select(SIM_CARD_NONE);
    sim_card_select(which);
    sim_budget(hc ? "probe SDHC" : "probe SDSC", 20000000);

    gen = alt_sdcard_generation(&sdcard);
    r = alt_sdcard_probe(&sdcard);
    if (r != ALT_SDCARD_OK) {
        printf("        probe returned %d\n", r);
        bad |= PROBE_RETURN;
    }
    if (sdcard.type != (hc ? ALT_SDCARD_TYPE_SDHC : ALT_SDCARD_TYPE_SDSC))
        bad |= PROBE_CLASS;
    if (sdcard.blocks != (hc ? HC_BLOCKS : SC_BLOCKS))
        bad |= PROBE_CAPACITY;
    if (cid_serial() != (hc ? 0x48430001u : 0x53430002u))
        bad |= PROBE_CID;
    if (alt_sdcard_generation(&sdcard) != gen + 1u)
        bad |= PROBE_GEN;
    return bad;
}

static unsigned round_trip(int which, alt_u32 block, alt_u32 count, alt_u8 seed)
{
    int      r;
    unsigned beats, bad = 0;
    char     what[96];

    snprintf(what, sizeof what, "%s: %u-block write then read at block %u",
             which == SIM_CARD_HC ? "SDHC" : "SDSC", (unsigned)count,
             (unsigned)block);
    printf("  -- %s --\n", what);
    sim_budget(what, 20000000);

    fill(wbuf, count, seed);
    beats = sim_dma_beats();
    r = alt_sdcard_write_blocks(&sdcard, block, wbuf, count);
    if (r != ALT_SDCARD_OK) {
        printf("        write returned %d\n", r);
        bad |= RT_WRITE_RET;
    }
    if (!on_card(which, block, (alt_u8 *)wbuf, count))
        bad |= RT_ON_CARD;

    memset(rbuf, 0, sizeof rbuf);
    r = alt_sdcard_read_blocks(&sdcard, block, rbuf, count);
    if (r != ALT_SDCARD_OK) {
        printf("        read returned %d\n", r);
        bad |= RT_READ_RET;
    }
    if (memcmp(rbuf, wbuf, count * BLOCK) != 0)
        bad |= RT_READ_BACK;
    if ((sim_dma_beats() != beats) != sim_cfg_dma())
        bad |= RT_DATA_PATH;
    return bad;
}

/* ALT_SDCARD_RESP_AUTO: the response format from the index. */
static void test_resp_auto(void)
{
    alt_u32 r0 = 0, r1 = 0, again = 0;
    int     r13, r58, r58b;

    printf("  -- raw commands with the response format left to the driver --\n");
    fresh_card(SIM_CARD_HC);
    sim_budget("RESP_AUTO", 2000000);

    r58  = alt_sdcard_command(&sdcard, 58, 0, ALT_SDCARD_RESP_AUTO, 0, &r0, &r1);
    r13  = alt_sdcard_command(&sdcard, 13, 0, ALT_SDCARD_RESP_AUTO, 0, &r0, 0);
    r58b = alt_sdcard_command(&sdcard, 58, 0, ALT_SDCARD_RESP_AUTO, 0, 0, &again);

    /* The table entry whose error would show. RESP1 is cleared when a command
     * starts, so CMD58 read as R1 would return zero here rather than the OCR the
     * identification left behind. An R2 or R1b read as R1 would not show at
     * all in this core: the byte left over is clocked out under the next
     * frame, and busy is waited out before the next command regardless. */
    check("CMD58 as AUTO returns the OCR (R3)",
          r58 == ALT_SDCARD_OK && (r1 >> 24) == 0xC0u);
    check("CMD13 as AUTO succeeds", r13 == ALT_SDCARD_OK);
    /* If CMD13 had been read as R1, its second byte would still be on the bus
     * and would have been taken as this command's response. */
    check("...and the bus is still in step afterwards",
          r58b == ALT_SDCARD_OK && again == r1);
    check("a response format or a command index that does not exist is refused",
          alt_sdcard_command(&sdcard, 13, 0, 7u, 0, 0, 0) == ALT_SDCARD_ERR_PARAM &&
          alt_sdcard_command(&sdcard, 64, 0, ALT_SDCARD_RESP_AUTO, 0, 0, 0)
              == ALT_SDCARD_ERR_PARAM);
}

/* CRC errors: retried where it is safe, reported where it is not. */
static void test_retries(void)
{
    alt_u32 retries, crcs;
    unsigned faults;
    int     r;

    printf("  -- CRC errors are retried, other errors are not --\n");
    fresh_card(SIM_CARD_HC);
    sim_budget("retries", 40000000);

    /* A command CRC error on a read. */
    fill(wbuf, 1, 0x61);
    (void)alt_sdcard_write_blocks(&sdcard, 300u, wbuf, 1);
    retries = sdcard.retry_count;
    crcs    = sdcard.crc_error_count;
    faults  = sim_faults_applied(SIM_CARD_HC);
    sim_fault_once(SIM_INJ_R1_CRC);
    r = alt_sdcard_read_blocks(&sdcard, 300u, rbuf, 1);
    check("command CRC error on a read: the call still succeeds",
          r == ALT_SDCARD_OK && memcmp(rbuf, wbuf, BLOCK) == 0);
    check("...because the card rejected it once and the retry went through",
          sim_faults_applied(SIM_CARD_HC) == faults + 1u &&
          sdcard.retry_count == retries + 1u &&
          sdcard.crc_error_count == crcs + 1u);

    /* A corrupt block. */
    retries = sdcard.retry_count;
    sim_fault_once(SIM_INJ_BAD_DATA_CRC);
    r = alt_sdcard_read_blocks(&sdcard, 300u, rbuf, 1);
    check("data CRC error on a read: retried, and the data is right",
          r == ALT_SDCARD_OK && memcmp(rbuf, wbuf, BLOCK) == 0 &&
          sdcard.retry_count == retries + 1u);

    /* A corrupt block in a MULTI-block read. The card goes on sending until
     * CMD12, whatever the host made of the block, so a retry issued without one
     * found it still sending: the read came back as a timeout, and the card as
     * unusable for the call after it. */
    {
        int r2, ok;

        fill(wbuf, 2, 0x64);
        (void)alt_sdcard_write_blocks(&sdcard, 330u, wbuf, 2);
        retries = sdcard.retry_count;
        memset(rbuf, 0, sizeof rbuf);
        sim_fault_once(SIM_INJ_BAD_DATA_CRC);
        r  = alt_sdcard_read_blocks(&sdcard, 330u, rbuf, 2);
        ok = (memcmp(rbuf, wbuf, 2u * BLOCK) == 0);
        r2 = alt_sdcard_read_blocks(&sdcard, 330u, rbuf, 1);
        check("a corrupt block in a multi-block read: stopped, retried, and the card still answers",
              r == ALT_SDCARD_OK && ok && sdcard.retry_count == retries + 1u &&
              r2 == ALT_SDCARD_OK);
    }

    /* A written block the card refused on CRC - once, mid-stream. */
    fill(wbuf, 4, 0x62);
    retries = sdcard.retry_count;
    sim_fault_once(SIM_INJ_WRITE_CRC);
    r = alt_sdcard_write_blocks(&sdcard, 310u, wbuf, 4);
    check("a block rejected on CRC in a multi-block write: retried, all landed",
          r == ALT_SDCARD_OK && on_card(SIM_CARD_HC, 310u, (alt_u8 *)wbuf, 4) &&
          sdcard.retry_count == retries + 1u);

    /* A genuine write error: the card said no. */
    fill(wbuf, 1, 0x63);
    retries = sdcard.retry_count;
    faults  = sim_faults_applied(SIM_CARD_HC);
    sim_fault_once(SIM_INJ_WRITE_ERR);
    r = alt_sdcard_write_blocks(&sdcard, 320u, wbuf, 1);
    check("a write error is reported, not retried",
          r == ALT_SDCARD_ERR_WRITE && sdcard.retry_count == retries &&
          sim_faults_applied(SIM_CARD_HC) == faults + 1u);
    r = alt_sdcard_write_blocks(&sdcard, 320u, wbuf, 1);
    check("...and the card is usable straight afterwards",
          r == ALT_SDCARD_OK && on_card(SIM_CARD_HC, 320u, (alt_u8 *)wbuf, 1));

    /* A link that never recovers: bounded. */
    faults = sim_faults_applied(SIM_CARD_HC);
    sim_fault(SIM_INJ_BAD_DATA_CRC);
    r = alt_sdcard_read_blocks(&sdcard, 300u, rbuf, 1);
    sim_fault(0);
    check("a CRC error on every attempt gives up after 1 + retries of them",
          r == ALT_SDCARD_ERR_CRC &&
          sim_faults_applied(SIM_CARD_HC) == faults + 1u + sdcard.retries);
    check("...without forgetting a card that is still answering",
          sdcard.type == ALT_SDCARD_TYPE_SDHC);

    /* The knob. */
    sdcard.retries = 0;
    sim_fault_once(SIM_INJ_BAD_DATA_CRC);
    r = alt_sdcard_read_blocks(&sdcard, 300u, rbuf, 1);
    sdcard.retries = 2;
    check("retries = 0 reports the first CRC error", r == ALT_SDCARD_ERR_CRC);

    /* During identification. CMD0 cannot carry it - the card is still in SD
     * mode - so the first command to see it is CMD8, which the driver used to
     * return as a failure of the whole identification. */
    sim_card_select(SIM_CARD_NONE);
    sim_card_select(SIM_CARD_HC);
    faults = sim_faults_applied(SIM_CARD_HC);
    sim_fault_once(SIM_INJ_R1_CRC);
    r = alt_sdcard_probe(&sdcard);
    check("a command CRC error during identification is retried, not fatal",
          r == ALT_SDCARD_OK && sim_faults_applied(SIM_CARD_HC) == faults + 1u);

    /* The CSD comes through the data path, CRC16 and all. Reading it twice has
     * no side effect, so a corrupt copy is read again. */
    sim_card_select(SIM_CARD_NONE);
    sim_card_select(SIM_CARD_HC);
    faults  = sim_faults_applied(SIM_CARD_HC);
    retries = sdcard.retry_count;
    sim_fault_once(SIM_INJ_BAD_DATA_CRC);
    r = alt_sdcard_probe(&sdcard);
    check("a corrupt CSD during identification is read again, not taken or fatal",
          r == ALT_SDCARD_OK && sdcard.blocks == HC_BLOCKS &&
          sim_faults_applied(SIM_CARD_HC) == faults + 1u &&
          sdcard.retry_count > retries);
}

static void test_range(void)
{
    int r_end, r_over, r_last;

    printf("  -- addresses past the end of the card --\n");
    fresh_card(SIM_CARD_SC);
    sim_budget("range", 20000000);

    r_end  = alt_sdcard_read_blocks(&sdcard, SC_BLOCKS, rbuf, 1);
    r_over = alt_sdcard_read_blocks(&sdcard, SC_BLOCKS - 1u, rbuf, 2);
    r_last = alt_sdcard_read_blocks(&sdcard, SC_BLOCKS - 1u, rbuf, 1);

    check("a block number at the capacity is refused", r_end == ALT_SDCARD_ERR_PARAM);
    check("a count running past it is refused", r_over == ALT_SDCARD_ERR_PARAM);
    check("the last block itself is readable", r_last == ALT_SDCARD_OK);
}

/* Buffers the DMA cannot address. */
static void test_misaligned(void)
{
    /* One guard byte either side of the three blocks. */
    static alt_u8 raw[3 * BLOCK + 2];
    static alt_u8 back[3 * BLOCK + 2];
    alt_u32 i;
    int     r;

    printf("  -- a buffer that is not word aligned --\n");
    fresh_card(SIM_CARD_HC);
    sim_budget("misaligned", 20000000);

    for (i = 0; i < 3 * BLOCK; i++) raw[1 + i] = (alt_u8)(0x80u + i * 13u);

    r = alt_sdcard_write_blocks(&sdcard, 400u, raw + 1, 3);
    check("a misaligned write succeeds", r == ALT_SDCARD_OK);
    check("...and puts exactly the caller's bytes on the card",
          on_card(SIM_CARD_HC, 400u, raw + 1, 3));

    memset(back, 0, sizeof back);
    r = alt_sdcard_read_blocks(&sdcard, 400u, back + 1, 3);
    check("a misaligned read returns them, and nothing outside its buffer moved",
          r == ALT_SDCARD_OK && memcmp(back + 1, raw + 1, 3 * BLOCK) == 0 &&
          back[0] == 0u && back[3 * BLOCK + 1] == 0u);
}

/* BLK_COUNT is 16 bits, so long transfers go in pieces. */
static void test_split(void)
{
    alt_u32 cmds, want;
    int     r;

    printf("  -- a transfer longer than one BLK_COUNT --\n");
    fresh_card(SIM_CARD_HC);
    sim_budget("split", 20000000);

    want = (MAX_BLOCKS + ALT_SDCARD_MAX_BLOCKS_PER_TRANSFER - 1u)
         / ALT_SDCARD_MAX_BLOCKS_PER_TRANSFER;

    fill(wbuf, MAX_BLOCKS, 0x71);
    cmds = sdcard.cmd_count;
    r = alt_sdcard_write_blocks(&sdcard, 500u, wbuf, MAX_BLOCKS);
    check("a long write is issued in as many transfers as BLK_COUNT needs",
          r == ALT_SDCARD_OK && sdcard.cmd_count - cmds == want);
    check("...and every block lands",
          on_card(SIM_CARD_HC, 500u, (alt_u8 *)wbuf, MAX_BLOCKS));

    memset(rbuf, 0, sizeof rbuf);
    r = alt_sdcard_read_blocks(&sdcard, 500u, rbuf, MAX_BLOCKS);
    check("a long read comes back whole",
          r == ALT_SDCARD_OK && memcmp(rbuf, wbuf, MAX_BLOCKS * BLOCK) == 0);
}

/* The card goes, and nothing comes back. */
static void test_removal(void)
{
    alt_u32 retries, type_after;
    int     r1, r2, retried;

    printf("  -- the card is pulled --\n");
    fresh_card(SIM_CARD_HC);
    sim_budget("removal", 20000000);

    sim_card_select(SIM_CARD_NONE);
    retries = sdcard.retry_count;
    r1 = alt_sdcard_read_blocks(&sdcard, 0u, rbuf, 1);
    /* Taken before the second call, whose identification attempt counts its
     * own CMD0 retries - which are right, and not what is being checked. */
    type_after = (alt_u32)sdcard.type | sdcard.blocks;
    retried    = (sdcard.retry_count != retries);
    r2 = alt_sdcard_read_blocks(&sdcard, 0u, rbuf, 1);

    /* With the switch the driver knows before it sends anything. Without, the
     * read goes out and times out - which is exactly how a card that has gone
     * looks - and the retry of identification finds nothing. */
    check("the first call after removal fails as the socket can tell it",
          r1 == (cd() ? ALT_SDCARD_ERR_NO_CARD : ALT_SDCARD_ERR_TIMEOUT));
    check("...forgets the card, and does not retry a timeout",
          type_after == 0u && !retried);
    check("the next call reports no card", r2 == ALT_SDCARD_ERR_NO_CARD);
}

/* The dangerous one: a DIFFERENT card, of the other capacity class, fitted
 * between two calls. */
static void test_swap(void)
{
    static alt_u32 a[BLOCK / 4], b[BLOCK / 4];
    alt_u32 gen;
    int     r;

    printf("  -- the card is swapped between two calls --\n");
    fresh_card(SIM_CARD_HC);
    sim_budget("swap", 40000000);

    fill(a, 1, 0xA1);
    fill(b, 1, 0xB2);
    (void)alt_sdcard_write_blocks(&sdcard, 7u, a, 1);
    gen = alt_sdcard_generation(&sdcard);

    swap_to(SIM_CARD_SC);
    r = alt_sdcard_write_blocks(&sdcard, 7u, b, 1);
    check("the call that meets the new card fails rather than writing to it",
          r == (cd() ? ALT_SDCARD_ERR_CHANGED : ALT_SDCARD_ERR_TIMEOUT));
    check("...and the old identification is gone",
          sdcard.type == ALT_SDCARD_TYPE_NONE &&
          alt_sdcard_generation(&sdcard) == gen);

    r = alt_sdcard_write_blocks(&sdcard, 7u, b, 1);
    check("the next call identifies the new card and writes",
          r == ALT_SDCARD_OK && sdcard.type == ALT_SDCARD_TYPE_SDSC &&
          cid_serial() == 0x53430002u &&
          alt_sdcard_generation(&sdcard) == gen + 1u);
    /* Byte addressing: had the driver kept the SDHC identification, block 7
     * would have been sent as byte 7 and landed inside block 0. */
    check("...at the new card's block 7, in its own addressing",
          on_card(SIM_CARD_SC, 7u, (alt_u8 *)b, 1));
    check("the old card still holds what was written to it",
          on_card(SIM_CARD_HC, 7u, (alt_u8 *)a, 1));

    swap_to(SIM_CARD_HC);
    r = alt_sdcard_read_blocks(&sdcard, 7u, rbuf, 1);
    check("swapping back is noticed the same way",
          r == (cd() ? ALT_SDCARD_ERR_CHANGED : ALT_SDCARD_ERR_TIMEOUT));
    r = alt_sdcard_read_blocks(&sdcard, 7u, rbuf, 1);
    check("...and the first card's data reads back",
          r == ALT_SDCARD_OK && memcmp(rbuf, a, BLOCK) == 0 &&
          sdcard.type == ALT_SDCARD_TYPE_SDHC);
}

/* Races a swap between two block calls cannot reach. */
static void test_swap_inside_calls(void)
{
    int r_raw, r_after_raw, r_after_reset, r_probe;
    alt_sdcard_type type_after_probe;

    printf("  -- swaps the next block call must still see --\n");
    fresh_card(SIM_CARD_HC);
    sim_budget("swaps inside calls", 40000000);

    /* A raw command in between. It goes through the same issue path as every
     * command, which once cleared IRQ_STATUS wholesale - latched card events
     * included - before anything had looked at them. */
    swap_to(SIM_CARD_SC);
    r_raw       = alt_sdcard_command(&sdcard, 13, 0, ALT_SDCARD_RESP_AUTO, 0, 0, 0);
    r_after_raw = alt_sdcard_read_blocks(&sdcard, 7u, rbuf, 1);

    /* The same for the application's own data-path reset, which clears
     * IRQ_STATUS too. */
    fresh_card(SIM_CARD_HC);
    swap_to(SIM_CARD_SC);
    alt_sdcard_reset_datapath(&sdcard);
    r_after_reset = alt_sdcard_read_blocks(&sdcard, 7u, rbuf, 1);

    /* A swap that completes inside a probe, after its last command: straight
     * after the third write of 512 to BLK_SIZE, which ends the CID read. Every
     * command of the identification succeeded, and it describes a card that is
     * no longer the one in the socket. */
    sim_card_select(SIM_CARD_NONE);
    sim_card_select(SIM_CARD_HC);
    sim_swap_on_write(ALT_SDCARD_BLK_SIZE_OFST, 512u, 3u, SIM_CARD_HC);
    r_probe = alt_sdcard_probe(&sdcard);
    type_after_probe = sdcard.type;
    sim_swap_on_write(0u, 0u, 0u, SIM_CARD_NONE);

    check("a raw command to the swapped-in card fails", r_raw == ALT_SDCARD_ERR_TIMEOUT);
    check("...and does not hide the swap from the next block call, nor does a data-path reset",
          r_after_raw   == (cd() ? ALT_SDCARD_ERR_CHANGED : ALT_SDCARD_ERR_TIMEOUT) &&
          r_after_reset == (cd() ? ALT_SDCARD_ERR_CHANGED : ALT_SDCARD_ERR_TIMEOUT));
    check("a swap inside a probe, after its last command, fails that probe where there is a switch",
          cd() ? (r_probe == ALT_SDCARD_ERR_CHANGED &&
                  type_after_probe == ALT_SDCARD_TYPE_NONE)
               : (r_probe == ALT_SDCARD_OK));
}

static void test_check(void)
{
    alt_u32 cmds;
    int     r_ok, r_swap, r_after, r_empty;

    printf("  -- alt_sdcard_check: what the socket says, without a command --\n");
    fresh_card(SIM_CARD_HC);
    sim_budget("check", 20000000);

    cmds    = sdcard.cmd_count;
    r_ok    = alt_sdcard_check(&sdcard);
    swap_to(SIM_CARD_SC);
    r_swap  = alt_sdcard_check(&sdcard);
    r_after = alt_sdcard_check(&sdcard);
    sim_card_select(SIM_CARD_NONE);
    r_empty = alt_sdcard_check(&sdcard);

    check("check reports an identified card as OK", r_ok == ALT_SDCARD_OK);
    /* Without a switch there is no evidence to consult: the swap is invisible
     * here, and is found by the first command instead (test_swap). */
    check("a swap is reported once where there is a switch, and forgotten",
          cd() ? (r_swap == ALT_SDCARD_ERR_CHANGED &&
                  r_after == ALT_SDCARD_ERR_NOT_READY)
               : (r_swap == ALT_SDCARD_OK && r_after == ALT_SDCARD_OK));
    check("an empty socket is reported where there is a switch",
          r_empty == (cd() ? ALT_SDCARD_ERR_NO_CARD : ALT_SDCARD_OK));
    check("...and none of it sent the card a single command",
          sdcard.cmd_count == cmds);
}

static void test_poll(void)
{
    int r_ok, r_gone, r_empty, r_back, r_swap, r_reset;
    alt_sdcard_type type_after_reset;

    printf("  -- alt_sdcard_poll --\n");
    fresh_card(SIM_CARD_HC);
    sim_budget("poll", 40000000);

    r_ok = alt_sdcard_poll(&sdcard);
    sim_card_select(SIM_CARD_NONE);
    r_gone  = alt_sdcard_poll(&sdcard);
    r_empty = alt_sdcard_poll(&sdcard);
    sim_card_select(SIM_CARD_HC);
    r_back  = alt_sdcard_poll(&sdcard);
    (void)alt_sdcard_probe(&sdcard);
    swap_to(SIM_CARD_SC);
    r_swap  = alt_sdcard_poll(&sdcard);

    /* Reset behind the driver's back: answering, but in idle state. */
    fresh_card(SIM_CARD_HC);
    (void)alt_sdcard_command(&sdcard, 0, 0, ALT_SDCARD_RESP_AUTO, 0, 0, 0);
    r_reset = alt_sdcard_poll(&sdcard);
    type_after_reset = sdcard.type;

    check("an identified card that answers polls OK", r_ok == ALT_SDCARD_OK);
    check("a pulled card is noticed by the next poll",
          r_gone == (cd() ? ALT_SDCARD_ERR_NO_CARD : ALT_SDCARD_ERR_TIMEOUT));
    check("an empty socket polls as no card, or as nothing identified",
          r_empty == (cd() ? ALT_SDCARD_ERR_NO_CARD : ALT_SDCARD_ERR_NOT_READY));
    check("a card fitted but not identified polls NOT_READY, and poll leaves it so",
          r_back == ALT_SDCARD_ERR_NOT_READY && sdcard.type == ALT_SDCARD_TYPE_NONE);
    check("a swapped card is noticed by the next poll",
          r_swap == (cd() ? ALT_SDCARD_ERR_CHANGED : ALT_SDCARD_ERR_TIMEOUT));
    check("a card sent CMD0 behind the driver's back fails the next poll, and is forgotten",
          r_reset != ALT_SDCARD_OK && type_after_reset == ALT_SDCARD_TYPE_NONE);
}

static int     events_seen;
static alt_u32 events_bits;

static void on_event(alt_sdcard_dev *dev, alt_u32 st)
{
    (void)dev;
    events_seen++;
    events_bits |= st;
}

/* The ISR, card events, and the completion poll sharing IRQ_STATUS. */
static void test_interrupts(void)
{
    alt_u32 en, en_app, latched;
    int     r;

    printf("  -- interrupts --\n");
    fresh_card(SIM_CARD_HC);
    sim_budget("interrupts", 40000000);

    alt_sdcard_set_event_handler(&sdcard, on_event);
    en = ALT_SDCARD_RD(sdcard.base, ALT_SDCARD_IRQ_ENABLE_OFST);
    check("installing a handler enables the card events, where there are any",
          (en & ALT_SDCARD_IRQ_CARD_MSK) == (cd() ? ALT_SDCARD_IRQ_CARD_MSK : 0u));

    /* A clean read leaves CMD_DONE latched - a bit the handler did not enable. */
    (void)alt_sdcard_read_blocks(&sdcard, 7u, rbuf, 1);

    events_seen = 0;
    events_bits = 0;
    swap_to(SIM_CARD_HC);
    sim_idle(16);
    latched = ALT_SDCARD_RD_IRQ_STATUS(sdcard.base);
    check("a swap calls the handler with both edges, where there is a switch",
          cd() ? (events_bits & ALT_SDCARD_IRQ_CARD_MSK) == ALT_SDCARD_IRQ_CARD_MSK
               : events_seen == 0);
    check("...and the ISR leaves latched what it was not enabled for",
          (latched & ALT_SDCARD_IRQ_CMD_DONE_MSK) != 0u);

    /* The ISR acknowledged both edges, so IRQ_STATUS no longer shows them. The
     * driver must still notice - through the count the ISR keeps. */
    r = alt_sdcard_read_blocks(&sdcard, 7u, rbuf, 1);
    check("...and the driver still sees the change the ISR acknowledged",
          r == (cd() ? ALT_SDCARD_ERR_CHANGED : ALT_SDCARD_ERR_TIMEOUT));

    /* An application that enables every source. The ISR now acknowledges each
     * command's status as it lands; the completion poll must not lose it. */
    (void)alt_sdcard_probe(&sdcard);
    en_app = ALT_SDCARD_RD(sdcard.base, ALT_SDCARD_IRQ_ENABLE_OFST);
    ALT_SDCARD_WR_IRQ_ENABLE(sdcard.base, 0xFFFFFFFFu);
    sim_fault(SIM_INJ_BAD_DATA_CRC);
    r = alt_sdcard_read_blocks(&sdcard, 7u, rbuf, 1);
    sim_fault(0);
    check("with every interrupt enabled, an error is still reported",
          r == ALT_SDCARD_ERR_CRC);
    r = alt_sdcard_read_blocks(&sdcard, 7u, rbuf, 1);
    check("...and a clean read still succeeds", r == ALT_SDCARD_OK);
    ALT_SDCARD_WR_IRQ_ENABLE(sdcard.base, en_app);

    alt_sdcard_set_event_handler(&sdcard, 0);
    en = ALT_SDCARD_RD(sdcard.base, ALT_SDCARD_IRQ_ENABLE_OFST);
    check("removing the handler disables the card events again",
          (en & ALT_SDCARD_IRQ_CARD_MSK) == 0u);
}

static void test_write_protect(void)
{
    int r;

    printf("  -- write protect --\n");
    fresh_card(SIM_CARD_HC);
    sim_budget("write protect", 20000000);

    fill(wbuf, 1, 0x91);
    sim_write_protect(1);
    r = alt_sdcard_write_blocks(&sdcard, 600u, wbuf, 1);
    sim_write_protect(0);
    check("the write-protect switch is honoured where the socket has one",
          r == (cd() ? ALT_SDCARD_ERR_PROTECTED : ALT_SDCARD_OK));
}

/* -------------------------------------------------------------------------- */
/* Non-blocking transfers.
 *
 * Every check runs in every build. With the DMA each one holds the non-blocking
 * call to what the blocking call does in the same situation; without it, the
 * start is refused and nothing else changes. */

static int             nb_calls;
static int             nb_result;
static void           *nb_context;
static alt_sdcard_dev *nb_dev;

static void nb_done(alt_sdcard_dev *dev, int result, void *context)
{
    nb_calls++;
    nb_result  = result;
    nb_context = context;
    nb_dev     = dev;
}

/* A chain: the write's callback starts the read of what it wrote, and the
 * read's callback ends it. `context` is the buffer to read into. */
static int nb_chain_write, nb_chain_start;

static void nb_chain_write_done(alt_sdcard_dev *dev, int result, void *context)
{
    nb_chain_write = result;
    nb_chain_start = alt_sdcard_read_blocks_start(dev, 820u, context, 2u,
                                                  nb_done, 0);
}

/* The application getting on with something else: time passes and no driver
 * call is made. The harness takes the interrupt between clock ticks, as the
 * processor would. Returns once the callback has run, or after `cycles`. */
static void other_work(unsigned long long cycles)
{
    unsigned long long end = sim_cycles() + cycles;

    while (nb_calls == 0 && sim_cycles() < end) sim_idle(500);
}

/* Two blocks written and read back through a chain of callbacks, with the
 * interrupt connected or with alt_sdcard_transfer_status() polled. Returns 1 if
 * the read came back OK with what was written - and, polled, if the status call
 * that ran the write's callback returned the write's result. */
static int nb_chain(int polled)
{
    int irq_saved = sdcard.irq, polls, r, st, handed_over = 99;

    if (polled) sdcard.irq = -1;
    fill(wbuf, 2u, polled ? 0x71 : 0x17);
    memset(rbuf, 0, sizeof rbuf);
    nb_calls = 0;
    nb_chain_write = nb_chain_start = 99;
    r = alt_sdcard_write_blocks_start(&sdcard, 820u, wbuf, 2u,
                                      nb_chain_write_done, rbuf);
    for (polls = 0; r == ALT_SDCARD_OK && nb_calls == 0 && polls < 2000; polls++) {
        sim_idle(2000);
        if (!polled) continue;
        /* The status call whose callback started the read still reports the
         * write that ended. */
        st = alt_sdcard_transfer_status(&sdcard);
        if (nb_chain_write != 99 && handed_over == 99) handed_over = st;
    }
    sdcard.irq = irq_saved;
    return r == ALT_SDCARD_OK && nb_chain_write == ALT_SDCARD_OK
        && nb_chain_start == ALT_SDCARD_OK && nb_calls == 1
        && nb_result == ALT_SDCARD_OK
        && (!polled || handed_over == ALT_SDCARD_OK)
        && memcmp(rbuf, wbuf, 2u * BLOCK) == 0;
}

static void test_nonblocking(void)
{
    static int         token;
    int                dma = sim_cfg_dma();
    int                r, r2, r3, r4, r5, r6, irq_saved, polls, phase, lost;
    unsigned long long a0, used, end;
    alt_u32            cmds, retries, pieces;

    printf("  -- non-blocking transfers --\n");
    fresh_card(SIM_CARD_HC);
    sim_budget("non-blocking transfers", 60000000);

    pieces = (MAX_BLOCKS + ALT_SDCARD_MAX_BLOCKS_PER_TRANSFER - 1u)
           / ALT_SDCARD_MAX_BLOCKS_PER_TRANSFER;

    /* A write with a callback, and nothing but other work until it calls. */
    fill(wbuf, MAX_BLOCKS, 0x3C);
    nb_calls = 0;
    cmds = sdcard.cmd_count;
    a0   = sim_bus_accesses();
    r    = alt_sdcard_write_blocks_start(&sdcard, 800u, wbuf, MAX_BLOCKS,
                                         nb_done, &token);
    other_work(4000000);
    used = sim_bus_accesses() - a0;
    printf("  -- %u blocks in %u piece(s): %llu bus accesses, start to callback --\n",
           (unsigned)MAX_BLOCKS, (unsigned)pieces, used);
    check("a non-blocking write returns at once and calls back once with OK, where there is a DMA",
          dma ? (r == ALT_SDCARD_OK && nb_calls == 1 && nb_result == ALT_SDCARD_OK
                 && nb_context == &token && nb_dev == &sdcard
                 && sdcard.cmd_count - cmds == pieces
                 && on_card(SIM_CARD_HC, 800u, (alt_u8 *)wbuf, MAX_BLOCKS))
              : (r == ALT_SDCARD_ERR_PARAM && nb_calls == 0));

    /* What the blocking write spends polling STATUS - tens of thousands of
     * reads for these eight blocks on the harness's default processor - comes
     * down to the accesses that start each piece and end it, whatever the
     * transfer's length: 25 for one piece on that processor. The ISR re-reads
     * STATUS while the last byte leaves the shifter, so a processor with no
     * delay between accesses spends about twice that. */
    check("...for a few dozen bus accesses a piece, not a poll loop",
          !dma || used <= 64u * pieces);

    /* A read with no interrupt connected: transfer_status() alone moves it
     * along, and must say busy the moment the transfer has started - which a
     * bare CMD_BUSY read in the next cycle would not. */
    irq_saved  = sdcard.irq;
    sdcard.irq = -1;
    memset(rbuf, 0, sizeof rbuf);
    nb_calls = 0;
    r  = alt_sdcard_read_blocks_start(&sdcard, 800u, rbuf, MAX_BLOCKS, 0, 0);
    r2 = alt_sdcard_transfer_status(&sdcard);
    r3 = r2;
    for (polls = 0; r3 == ALT_SDCARD_ERR_BUSY && polls < 1000; polls++) {
        sim_idle(2000);
        r3 = alt_sdcard_transfer_status(&sdcard);
    }
    sdcard.irq = irq_saved;
    check("polled with no interrupt, a non-blocking read is busy at once, then OK with the data in place",
          dma ? (r == ALT_SDCARD_OK && r2 == ALT_SDCARD_ERR_BUSY && r3 == ALT_SDCARD_OK
                 && memcmp(rbuf, wbuf, MAX_BLOCKS * BLOCK) == 0)
              : (r == ALT_SDCARD_ERR_PARAM && r2 == ALT_SDCARD_OK && r3 == ALT_SDCARD_OK));

    /* While one runs, everything else that would talk to the card waits its
     * turn - and works once it is over. */
    nb_calls = 0;
    r  = alt_sdcard_read_blocks_start(&sdcard, 800u, rbuf, 1u, nb_done, 0);
    r2 = alt_sdcard_read_blocks(&sdcard, 800u, rbuf, 1u);
    r3 = alt_sdcard_read_blocks_start(&sdcard, 800u, rbuf, 1u, nb_done, 0);
    r4 = alt_sdcard_command(&sdcard, 13, 0, ALT_SDCARD_RESP_AUTO, 0, 0, 0);
    r6 = alt_sdcard_probe(&sdcard);
    other_work(1000000);
    r5 = alt_sdcard_read_blocks(&sdcard, 800u, rbuf, 1u);
    check("while a non-blocking transfer runs, the other calls get ERR_BUSY, and work once it ends",
          dma ? (r == ALT_SDCARD_OK && r2 == ALT_SDCARD_ERR_BUSY
                 && r3 == ALT_SDCARD_ERR_BUSY && r4 == ALT_SDCARD_ERR_BUSY
                 && r6 == ALT_SDCARD_ERR_BUSY
                 && nb_calls == 1 && r5 == ALT_SDCARD_OK)
              : (r == ALT_SDCARD_ERR_PARAM && r2 == ALT_SDCARD_OK
                 && r3 == ALT_SDCARD_ERR_PARAM && r4 == ALT_SDCARD_OK
                 && r6 == ALT_SDCARD_OK && r5 == ALT_SDCARD_OK));

    /* A read CRC error, retried from the ISR. */
    retries = sdcard.retry_count;
    memset(rbuf, 0, sizeof rbuf);
    nb_calls = 0;
    sim_fault_once(SIM_INJ_BAD_DATA_CRC);
    r = alt_sdcard_read_blocks_start(&sdcard, 800u, rbuf, 2u, nb_done, 0);
    other_work(2000000);
    sim_fault(0);
    check("a non-blocking read's CRC error is retried, and the read succeeds",
          dma ? (r == ALT_SDCARD_OK && nb_calls == 1 && nb_result == ALT_SDCARD_OK
                 && sdcard.retry_count == retries + 1u
                 && memcmp(rbuf, wbuf, 2u * BLOCK) == 0)
              : r == ALT_SDCARD_ERR_PARAM);

    /* A written block rejected on CRC: stopped with CMD12, retried, landed. */
    retries = sdcard.retry_count;
    fill(wbuf, 2u, 0x5D);
    nb_calls = 0;
    sim_fault_once(SIM_INJ_WRITE_CRC);
    r = alt_sdcard_write_blocks_start(&sdcard, 810u, wbuf, 2u, nb_done, 0);
    other_work(4000000);
    sim_fault(0);
    check("a block a non-blocking write had rejected on CRC is recovered with CMD12, retried, and lands",
          dma ? (r == ALT_SDCARD_OK && nb_calls == 1 && nb_result == ALT_SDCARD_OK
                 && sdcard.retry_count == retries + 1u
                 && on_card(SIM_CARD_HC, 810u, (alt_u8 *)wbuf, 2u))
              : r == ALT_SDCARD_ERR_PARAM);

    /* A callback may start the next transfer, in either context it runs in:
     * the ISR, or a status call - which returns the result of the transfer
     * that ended, though the next is already running. */
    r  = nb_chain(0);
    r2 = nb_chain(1);
    check("a completion callback can start the next transfer, from the ISR and from a status call",
          dma ? (r && r2) : (!r && !r2 && nb_calls == 0));

    /* An event handler installed while a transfer recovers from an error.
     * Installing one reads IRQ_ENABLE and writes it back; an ISR in between
     * that adds CMD_DONE for the CMD12 stopping the card must not have that
     * written over, or the CMD12's end raises nothing and the transfer is never
     * heard from again. The harness takes an interrupt after any bus access, so
     * the handler is installed over and over while the transfer runs, from
     * eight starting phases - more than one bus access's worth of clock cycles
     * on the processors the DMA builds run on - until the two meet. Only a
     * socket with a switch has events to enable; without one, installing a
     * handler makes no bus access, so time would not pass in the loop, and the
     * transfer is simply left to finish. */
    alt_sdcard_set_event_handler(&sdcard, on_event);
    (void)alt_sdcard_probe(&sdcard);
    lost = 0;
    for (phase = 0; phase < 8; phase++) {
        nb_calls = 0;
        sim_fault_once(SIM_INJ_BAD_DATA_CRC);
        r = alt_sdcard_read_blocks_start(&sdcard, 800u, rbuf, 2u, nb_done, 0);
        sim_idle((unsigned)phase);
        end = sim_cycles() + 2000000u;
        while (r == ALT_SDCARD_OK && nb_calls == 0 && sim_cycles() < end) {
            if (cd()) alt_sdcard_set_event_handler(&sdcard, on_event);
            else      sim_idle(500);
        }
        sim_fault(0);
        if (r != ALT_SDCARD_OK || nb_calls != 1 || nb_result != ALT_SDCARD_OK)
            lost++;
        /* Finish one the interrupt lost track of, so one loss stays one. */
        for (polls = 0; alt_sdcard_transfer_status(&sdcard) == ALT_SDCARD_ERR_BUSY
                        && polls < 1000; polls++)
            sim_idle(2000);
    }
    alt_sdcard_set_event_handler(&sdcard, 0);
    check("an event handler installed while a non-blocking transfer recovers loses none of its interrupts",
          dma ? lost == 0 : lost == 8);

    /* A card that stops answering: reported, and forgotten. */
    nb_calls = 0;
    sim_fault(SIM_INJ_NO_RESPONSE);
    r = alt_sdcard_read_blocks_start(&sdcard, 800u, rbuf, 1u, nb_done, 0);
    other_work(2000000);
    sim_fault(0);
    check("a non-blocking read that times out says so and forgets the card, as the blocking read does",
          dma ? (r == ALT_SDCARD_OK && nb_calls == 1 && nb_result == ALT_SDCARD_ERR_TIMEOUT
                 && sdcard.type == ALT_SDCARD_TYPE_NONE)
              : r == ALT_SDCARD_ERR_PARAM);
    fresh_card(SIM_CARD_HC);

    r = alt_sdcard_read_blocks_start(&sdcard, 800u, (alt_u8 *)rbuf + 1, 1u, nb_done, 0);
    check("a misaligned buffer is refused by the non-blocking calls, not bounced",
          r == ALT_SDCARD_ERR_PARAM);

    /* A card swapped before the start: seen by the switch, where there is one,
     * or by the new card - still in SD mode - not answering. */
    swap_to(SIM_CARD_SC);
    nb_calls = 0;
    r = alt_sdcard_read_blocks_start(&sdcard, 3u, rbuf, 1u, nb_done, 0);
    other_work(2000000);
    check("a card swapped before a non-blocking read is caught, by the switch or by the silence",
          !dma ? r == ALT_SDCARD_ERR_PARAM
               : cd() ? (r == ALT_SDCARD_ERR_CHANGED && nb_calls == 0)
                      : (r == ALT_SDCARD_OK && nb_calls == 1
                         && nb_result == ALT_SDCARD_ERR_TIMEOUT
                         && sdcard.type == ALT_SDCARD_TYPE_NONE));
    fresh_card(SIM_CARD_HC);

    /* A data-path reset part-way through abandons the transfer. */
    nb_calls = 0;
    r = alt_sdcard_read_blocks_start(&sdcard, 800u, rbuf, MAX_BLOCKS, nb_done, 0);
    sim_idle(20000);
    alt_sdcard_reset_datapath(&sdcard);
    r2 = alt_sdcard_transfer_status(&sdcard);
    sim_idle(20000);
    check("resetting the data path abandons a non-blocking transfer with ERR_TIMEOUT, and no callback",
          dma ? (r == ALT_SDCARD_OK && r2 == ALT_SDCARD_ERR_TIMEOUT && nb_calls == 0)
              : (r == ALT_SDCARD_ERR_PARAM && r2 == ALT_SDCARD_OK));
    fresh_card(SIM_CARD_HC);
}

static void test_fatfs_glue(void)
{
    /* Misaligned by one byte: FatFs hands over whatever buffer it has.
     *
     * Every result is captured the moment it exists and checked at the end.
     * Reading live state at the end instead - the buffer, the card's write
     * count - checked what the LATER steps had done to it, and failed on two
     * things that were right. */
    static BYTE raw[2 * BLOCK + 1];
    static BYTE back[2 * BLOCK + 1];
    LBA_t    sectors = 0, sectors2 = 0;
    WORD     ssize = 0;
    unsigned written_sc, landed, written_hc, landed_other;
    alt_u32  gen_init, gen_again;
    unsigned busy_before, busy_after;
    int      same;
    alt_u32  i;
    DSTATUS  s_before, s_nodrive, s_init, s_swap, s_init2, s_wp, s_empty;
    DRESULT  w_ok, r_ok, sync, w_stale, r_stale, r_new, w_other, w_wp, r_far;
    alt_sdcard_type type_after_stale;

    printf("  -- the FatFs disk I/O glue --\n");
    sim_card_select(SIM_CARD_NONE);
    sim_card_select(SIM_CARD_HC);
    sim_budget("fatfs glue", 60000000);

    for (i = 0; i < 2 * BLOCK; i++) raw[1 + i] = (BYTE)(0x31u + i * 5u);

    s_before  = disk_status(0);
    s_nodrive = disk_status(1);
    s_init    = disk_initialize(0);
    /* Mounting again on the same card must not identify it again - that is
     * hundreds of milliseconds at 400 kHz on real hardware, for nothing. */
    gen_init  = alt_sdcard_generation(&sdcard);
    (void)disk_initialize(0);
    gen_again = alt_sdcard_generation(&sdcard);
    (void)disk_ioctl(0, GET_SECTOR_COUNT, &sectors);
    (void)disk_ioctl(0, GET_SECTOR_SIZE, &ssize);

    w_ok = disk_write(0, raw + 1, 100, 2);
    r_ok = disk_read(0, back + 1, 100, 2);
    same = (memcmp(back + 1, raw + 1, 2 * BLOCK) == 0) &&
           on_card(SIM_CARD_HC, 100u, raw + 1, 2);

    /* CTRL_SYNC is FatFs asking for the write to be finished - the point after
     * which the card may lose power. A card with a long programming time is
     * still busy when disk_write returns, and stays so until something clocks
     * it; the sync has to be what does. */
    sim_card_set_prog_bytes(SIM_CARD_HC, 2000u);
    (void)disk_write(0, raw + 1, 102, 1);
    busy_before = sim_card_busy(SIM_CARD_HC);
    sync = disk_ioctl(0, CTRL_SYNC, 0);
    busy_after  = sim_card_busy(SIM_CARD_HC);
    sim_card_set_prog_bytes(SIM_CARD_HC, 4u);

    /* The other card goes in behind the mounted volume. */
    swap_to(SIM_CARD_SC);
    written_sc = sim_card_blocks_written(SIM_CARD_SC);
    s_swap  = disk_status(0);
    w_stale = disk_write(0, raw + 1, 100, 2);
    r_stale = disk_read(0, back + 1, 100, 1);
    type_after_stale = sdcard.type;
    landed = sim_card_blocks_written(SIM_CARD_SC) - written_sc;

    s_init2 = disk_initialize(0);
    (void)disk_ioctl(0, GET_SECTOR_COUNT, &sectors2);
    r_new = disk_read(0, back + 1, 100, 1);

    /* Swapped again - and this time the APPLICATION identifies the new card
     * before FatFs looks, which consumes the latched events the glue would
     * otherwise have seen. The generation is what still ties the volume to
     * the card it was mounted from. */
    swap_to(SIM_CARD_HC);
    (void)alt_sdcard_probe(&sdcard);
    written_hc = sim_card_blocks_written(SIM_CARD_HC);
    w_other = disk_write(0, raw + 1, 100, 1);
    landed_other = sim_card_blocks_written(SIM_CARD_HC) - written_hc;
    (void)disk_initialize(0);

    sim_write_protect(1);
    s_wp = disk_status(0);
    w_wp = disk_write(0, raw + 1, 100, 1);
    sim_write_protect(0);

    /* 2^32, where LBA_t has room for it. */
    r_far = (sizeof(LBA_t) > 4)
          ? disk_read(0, back + 1, (LBA_t)(((LBA_t)1 << 16) << 16), 1)
          : RES_PARERR;

    sim_card_select(SIM_CARD_NONE);
    s_empty = disk_status(0);

    check("before disk_initialize: STA_NOINIT, and STA_NODISK for a drive with no controller",
          s_before == STA_NOINIT && s_nodrive == (STA_NOINIT | STA_NODISK));
    check("disk_initialize accepts the card and reports its size in 512-byte sectors",
          s_init == 0 && sectors == (LBA_t)HC_BLOCKS && ssize == 512);
    check("...and a second disk_initialize on the same card does not identify it again",
          gen_again == gen_init);
    check("disk_write and disk_read round-trip a buffer the DMA cannot address",
          w_ok == RES_OK && r_ok == RES_OK && same);
    check("CTRL_SYNC returns only once the card has finished programming",
          sync == RES_OK && busy_before != 0u && busy_after == 0u);
    /* With a switch the swap is seen from its latched events. Without one,
     * disk_status asks the card with CMD13, which a card still in SD mode
     * cannot answer. It once waited for a transfer to fail instead, and real
     * FatFs showed why that is not enough: a lookup answered from its cached
     * directory sector said "no such file" about a card it never read. */
    check("a swap drops the volume at the next disk_status, with or without a switch",
          s_swap == STA_NOINIT && w_stale == RES_NOTRDY);
    check("no write meant for the old card lands on the new one, and no read is served by it",
          landed == 0u && r_stale == RES_NOTRDY &&
          type_after_stale == ALT_SDCARD_TYPE_NONE);
    check("disk_initialize then mounts the new card",
          s_init2 == 0 && sectors2 == (LBA_t)SC_BLOCKS && r_new == RES_OK);
    check("a card identified by someone else is still not the mounted one",
          w_other == RES_NOTRDY && landed_other == 0u);
    check("write protect gives STA_PROTECT and RES_WRPRT where the socket has a switch",
          cd() ? (s_wp == STA_PROTECT && w_wp == RES_WRPRT)
               : (s_wp == 0 && w_wp == RES_OK));
    check("a sector number past 32 bits is refused, not truncated",
          r_far == RES_PARERR);
    check("an empty socket: STA_NODISK where there is a switch, STA_NOINIT where there is not",
          s_empty == (cd() ? (STA_NOINIT | STA_NODISK) : STA_NOINIT));
}

int driver_tests(void)
{
    unsigned bad;

    test_init();
    test_lazy_identification();

    bad = probe_card(SIM_CARD_HC);
    check("SDHC: probe returns OK", !(bad & PROBE_RETURN));
    check("SDHC: probe finds the high-capacity class", !(bad & PROBE_CLASS));
    check("SDHC: probe reads the capacity from the CSD", !(bad & PROBE_CAPACITY));
    check("SDHC: probe reads this card's CID", !(bad & PROBE_CID));
    check("SDHC: probe advances the generation by one", !(bad & PROBE_GEN));

    bad = round_trip(SIM_CARD_HC, 1000u, 1u, 0x11)
        | round_trip(SIM_CARD_HC, 2000u, 5u, 0x22);
    check("SDHC: single and multi-block writes return OK", !(bad & RT_WRITE_RET));
    check("SDHC: ...and the data is on the card, at the right blocks",
          !(bad & RT_ON_CARD));
    check("SDHC: the reads return OK", !(bad & RT_READ_RET));
    check("SDHC: ...and return what was written", !(bad & RT_READ_BACK));
    check("SDHC: the data went through the DMA exactly when the build has one",
          !(bad & RT_DATA_PATH));

    test_resp_auto();
    test_retries();
    test_range();
    test_misaligned();
    test_split();
    test_removal();
    test_swap();
    test_swap_inside_calls();
    test_check();
    test_poll();
    test_interrupts();
    test_write_protect();
    test_fatfs_glue();
    test_nonblocking();

    bad = probe_card(SIM_CARD_SC);
    check("SDSC: probe returns OK", !(bad & PROBE_RETURN));
    check("SDSC: probe finds the standard-capacity class", !(bad & PROBE_CLASS));
    check("SDSC: probe reads the capacity from the v1 CSD", !(bad & PROBE_CAPACITY));
    check("SDSC: probe reads this card's CID", !(bad & PROBE_CID));
    check("SDSC: probe advances the generation by one", !(bad & PROBE_GEN));

    /* Byte addressed: a block number sent unconverted lands inside block 0. */
    bad = round_trip(SIM_CARD_SC, 3u, 1u, 0x33)
        | round_trip(SIM_CARD_SC, 40u, 4u, 0x44);
    check("SDSC: single and multi-block writes return OK", !(bad & RT_WRITE_RET));
    check("SDSC: ...and the data is on the card, at the right blocks",
          !(bad & RT_ON_CARD));
    check("SDSC: the reads return OK", !(bad & RT_READ_RET));
    check("SDSC: ...and return what was written", !(bad & RT_READ_BACK));
    check("SDSC: the data went through the DMA exactly when the build has one",
          !(bad & RT_DATA_PATH));

    /* A processor slower than the card made reads wait for it.
     *
     * The run meant to show that once cost 82 clock cycles per word read
     * through DATA - a STATUS read and a DATA read at 41 each, as the loop was
     * then - against the card's 128 at the run divider, so it was never slower
     * than the card at all, and a core that dropped every byte it had no room
     * for passed it. The same core with a processor slower still returned OK
     * from a 5-block read with the wrong data. So a run whose processor takes
     * at least twice the card's time per word must see blocks held, and with
     * reads of 4, 5 and 8 blocks against a 256-word buffer, one at twice cannot
     * avoid it. A word now costs one bus access - the check after this one
     * holds the loop to that - so that is the cost counted here. */
    {
        unsigned access        = sim_cpu_cycles() + 1u;
        unsigned cpu_per_word  = access;
        unsigned card_per_word = 4u * 8u * 2u * (unsigned)sdcard.clkdiv_run;
        int      slow = !sim_cfg_dma() && (cpu_per_word >= 2u * card_per_word);
        unsigned long long t0, per_word;
        int      r;

        printf("  -- read through DATA: %u clocks a word, card %u; %u blocks held --\n",
               cpu_per_word, card_per_word, sim_read_holds());
        check("a processor at least twice slower than the card makes reads wait rather than lose data",
              !slow || sim_read_holds() > 0u);

        /* ...and the PIO loops cost one bus access per word, not two.
         *
         * They read STATUS before every DATA access, which is invisible while
         * the card is the slower side and halves the speed of every transfer
         * where the processor is. On a processor that slow the time a transfer
         * takes is the loop's own cost, so clock cycles per word measure
         * accesses per word: one access is `access` cycles, and 1.5 of them
         * separates the batched loops, about 1.05, from the old ones at 2.
         * Both directions, because they are two loops. */
        sim_budget("the PIO loops' cost per word", 10000000);
        {
            unsigned long long wr_per_word;
            int w;

            fill(wbuf, 4u, 0x6B);
            t0 = sim_cycles();
            w  = alt_sdcard_write_blocks(&sdcard, 44u, wbuf, 4u);
            wr_per_word = (sim_cycles() - t0) / (4u * 128u);

            memset(rbuf, 0, sizeof rbuf);
            t0 = sim_cycles();
            r  = alt_sdcard_read_blocks(&sdcard, 44u, rbuf, 4u);
            per_word = (sim_cycles() - t0) / (4u * 128u);

            printf("  -- 4 blocks: write %llu, read %llu clocks a word, %u a bus access --\n",
                   wr_per_word, per_word, access);
            check("PIO reads and writes cost about one bus access per word where the processor limits them",
                  w == ALT_SDCARD_OK && r == ALT_SDCARD_OK
                  && on_card(SIM_CARD_SC, 44u, (alt_u8 *)wbuf, 4u)
                  && memcmp(rbuf, wbuf, 4u * BLOCK) == 0
                  && (!slow || (2u * wr_per_word <= 3u * access
                                && 2u * per_word <= 3u * access)));
        }
    }

    printf("  === %d checks, %d failures ===\n", checks_run, checks_fail);
    if (checks_fail == 0) printf("  *** PASS ***\n");
    return checks_fail ? 1 : 0;
}
