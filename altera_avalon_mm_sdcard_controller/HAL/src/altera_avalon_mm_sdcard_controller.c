/* =============================================================================
 * altera_avalon_mm_sdcard_controller.c
 *
 * Nios II HAL driver for the Avalon-MM SD Card Controller (SPI).
 *
 * The hardware owns the link layer. This file owns the protocol: the
 * identification sequence, the v1.x / v2.00 distinction, byte versus block
 * addressing, capacity from the CSD, card changes, and the retry policy.
 * ===========================================================================*/

#include <stdint.h>
#include <string.h>

#include "altera_avalon_mm_sdcard_controller.h"
#include "sys/alt_irq.h"

/* Version of the hardware this driver was written against. The major number
 * must match; a newer minor is accepted, because minor revisions do not move
 * registers. */
#define DRIVER_HW_MAJOR   1

/* §6.4.1.1 asks for at least 74; the rest is margin for a first clock period
 * that starts part-way through. */
#define POWER_UP_CLOCKS   80u

/* ACMD41 attempts before giving up on initialisation.
 *
 * The specification gives the card one second (§4.2.3), and the bound has to
 * cover that however quickly the attempts go by. Each attempt is CMD55 plus
 * ACMD41 - at least 2 x (6 command bytes + 1 response byte) x 8 = 112 clocks -
 * and identification runs at no more than 400 kHz, so no attempt can take less
 * than 280 us. One second is therefore at most 3572 of them. The previous
 * bound of 2000 could give up after 0.56 s on a card still within its rights.
 */
#define ACMD41_TRIES      4000u

/* BLK_COUNT is 16 bits wide. A larger count written to it is truncated - to
 * zero for exactly 65536 blocks, which the sequencer runs as a single block -
 * so a longer transfer is issued in pieces.
 *
 * Overridable only so the splitting can be exercised without a 32 MiB
 * transfer; a value above 0xFFFF is clamped, because it cannot work. */
#ifndef ALT_SDCARD_MAX_BLOCKS_PER_TRANSFER
#define ALT_SDCARD_MAX_BLOCKS_PER_TRANSFER  0xFFFFu
#endif
#define MAX_BLOCKS_PER_TRANSFER \
    ((ALT_SDCARD_MAX_BLOCKS_PER_TRANSFER) > 0xFFFFu ? 0xFFFFu \
                                                    : (ALT_SDCARD_MAX_BLOCKS_PER_TRANSFER))

static alt_sdcard_dev *instances[ALT_SDCARD_MAX_INSTANCES];

/* The non-blocking engine, which the ISR calls and which lives beside the
 * transfers it mirrors. */
static int async_service(alt_sdcard_dev *dev, int in_isr);

/* -------------------------------------------------------------------------
 * Low-level helpers
 * ---------------------------------------------------------------------- */

static void wait_not_busy(alt_sdcard_dev *dev)
{
    /* CMD writes are ignored while the core is busy - which is correct, since a
     * second command must not corrupt a transfer in flight, but it means a
     * caller that does not check loses the command with no diagnostic. Polling
     * afterwards does not catch it either: busy is already clear, so the poll
     * returns immediately for a command that never happened. */
    while (ALT_SDCARD_RD_STATUS(dev->base) & ALT_SDCARD_STAT_CMD_BUSY_MSK) {
        /* spin */
    }
}

/* Let at least `clocks` SPI clock periods pass at divider `div`.
 *
 * Counted in bus transfers, not in loop iterations. A read of STATUS occupies
 * at least one cycle of the core's clock whatever the processor - the slave has
 * read latency 1 - and one SPI period is 2 * CLKDIV of those cycles, so the
 * count below is a lower bound on elapsed time that no CPU can beat. A spin
 * loop is not: the previous 200000 empty iterations were a wait on a slow
 * processor and next to nothing on a fast one, and in the driver-in-the-loop
 * harness - where only bus accesses move time - they gave the card no power-up
 * clocks at all and identification failed on every card. */
static void run_clocks(alt_sdcard_dev *dev, alt_u32 div, alt_u32 clocks)
{
    alt_u32 n = clocks * 2u * (div ? div : 1u);    /* CLKDIV 0 runs as 1 */

    while (n--) {
        (void)ALT_SDCARD_RD_STATUS(dev->base);
    }
}

static int irq_to_result(alt_u32 st)
{
    if (st & (ALT_SDCARD_IRQ_ERR_CMD_TMO_MSK | ALT_SDCARD_IRQ_ERR_DAT_TMO_MSK))
        return ALT_SDCARD_ERR_TIMEOUT;
    if (st & (ALT_SDCARD_IRQ_ERR_CMD_CRC_MSK | ALT_SDCARD_IRQ_ERR_DAT_CRC_MSK))
        return ALT_SDCARD_ERR_CRC;
    if (st & (ALT_SDCARD_IRQ_ERR_WRITE_MSK | ALT_SDCARD_IRQ_ERR_DAT_TOKEN_MSK))
        return ALT_SDCARD_ERR_WRITE;
    if (st & ALT_SDCARD_IRQ_ERR_DMA_MSK)
        return ALT_SDCARD_ERR_WRITE;
    if (st & ALT_SDCARD_IRQ_ERR_CMD_ILL_MSK)
        return ALT_SDCARD_ERR_UNUSABLE;
    /* Reported last because it is a fault in this driver's own pacing rather
     * than anything the card did: a DATA write with the buffer full, or a read
     * with it empty. Both are dropped silently by the hardware, so if the core
     * says it happened the data moved through PIO is not trustworthy. */
    if (st & ALT_SDCARD_IRQ_ERR_PIO_MSK)
        return ALT_SDCARD_ERR_PIO;
    return ALT_SDCARD_OK;
}

static void account(alt_sdcard_dev *dev, alt_u32 st)
{
    if (st & (ALT_SDCARD_IRQ_ERR_CMD_CRC_MSK | ALT_SDCARD_IRQ_ERR_DAT_CRC_MSK))
        dev->crc_error_count++;
    if (st & (ALT_SDCARD_IRQ_ERR_CMD_TMO_MSK | ALT_SDCARD_IRQ_ERR_DAT_TMO_MSK))
        dev->timeout_count++;
}

/* Issue a command and return immediately.
 *
 * Split out from alt_sdcard_command because the PIO data path has to move
 * words WHILE the transfer runs: with no DMA, nothing else drains the buffer,
 * and a blocking issue leaves no opportunity to. On a write it is stricter than
 * that - the sequencer reaches the data phase about ten byte-times after the
 * command goes out, and if the buffer is still empty the shifter simply stalls.
 */
static void issue(alt_sdcard_dev *dev, alt_u8 index, alt_u32 arg,
                  alt_u32 resp_type, alt_u32 extra_cmd_bits)
{
    alt_u32 cmd;

    wait_not_busy(dev);

    /* Clear the previous command's status - but NOT the card-detect events.
     * Those belong to card_changed(), which reads them at the start of the next
     * call; clearing them here, as this once did with 0xFFFFFFFF, threw away a
     * removal that happened between two commands before anything looked. */
    ALT_SDCARD_WR_IRQ_STATUS(dev->base, ~ALT_SDCARD_IRQ_CARD_MSK);
    dev->isr_status = 0;
    ALT_SDCARD_WR(dev->base, ALT_SDCARD_CMD_ARG_OFST, arg);

    cmd = ((alt_u32)index & ALT_SDCARD_CMD_INDEX_MSK)
        | ((resp_type << ALT_SDCARD_CMD_RESP_OFST_B) & ALT_SDCARD_CMD_RESP_MSK)
        | extra_cmd_bits
        | ALT_SDCARD_CMD_START_MSK;

    ALT_SDCARD_WR(dev->base, ALT_SDCARD_CMD_OFST, cmd);
    dev->cmd_count++;
}

/* Reset the data path. Data path only: the command path and every
 * configuration register are untouched, so the card stays identified - which
 * is the entire reason the reset is split into domains. Card events survive
 * too, for card_changed(). */
static void datapath_reset(alt_sdcard_dev *dev)
{
    ALT_SDCARD_WR_CTRL(dev->base,
                       ALT_SDCARD_RD_CTRL(dev->base) |
                       ALT_SDCARD_CTRL_SRST_DAT_MSK);
    ALT_SDCARD_WR_IRQ_STATUS(dev->base, ~ALT_SDCARD_IRQ_CARD_MSK);
}

/* What the core has latched about the command running now: IRQ_STATUS, plus
 * anything an application-enabled interrupt acknowledged first, less the card
 * events, which belong to card_changed(). issue() cleared both. */
static alt_u32 latched(alt_sdcard_dev *dev)
{
    return (ALT_SDCARD_RD_IRQ_STATUS(dev->base) | dev->isr_status)
           & ~ALT_SDCARD_IRQ_CARD_MSK;
}

/* Every command ends with one of these latched, whatever the outcome: CMD_DONE
 * when one without a data phase succeeds, DATA_DONE when a transfer ends and
 * whenever anything fails. */
#define ENDED_MSK (ALT_SDCARD_IRQ_CMD_DONE_MSK | ALT_SDCARD_IRQ_DATA_DONE_MSK)

/* STATUS reads showing neither busy nor an end that mean the command never
 * started - the core is disabled - rather than that it has not started YET. */
#define NEVER_STARTED 8u

/* Has the command issued last finished?
 *
 * Not "is CMD_BUSY clear". The core takes two clock cycles to show a command
 * it has just been given as busy, so a processor whose STATUS read lands in
 * the cycle after its CMD write reads an idle core and would take a command
 * that has not started for one that has finished. The driver harness runs one:
 * with no delay between bus accesses, identification failed on every card.
 * An end is latched as well as busy being clear, or the command has not run.
 * `quiet` counts the reads that saw neither, so a command a disabled core
 * ignored is given up on rather than waited for: the gap is one read at most,
 * and NEVER_STARTED is margin. */
static int ended(alt_sdcard_dev *dev, alt_u32 st, alt_u32 *quiet)
{
    if (st & ALT_SDCARD_STAT_CMD_BUSY_MSK) {
        *quiet = 0;
        return 0;
    }
    if (latched(dev) & ENDED_MSK) return 1;
    return ++*quiet >= NEVER_STARTED;
}

/* Wait for the command to finish and turn the latched status into a result.
 * `st_out`, if given, receives the status bits the result was made from. */
static int complete(alt_sdcard_dev *dev, alt_u32 *resp0, alt_u32 *resp1,
                    alt_u32 *st_out)
{
    alt_u32 st, quiet = 0;

    while (!ended(dev, ALT_SDCARD_RD_STATUS(dev->base), &quiet)) {
        /* spin - every wait inside the core is bounded by TIMEOUT, so this
         * cannot hang on a card that has stopped answering */
    }

    st = latched(dev);
    account(dev, st);

    if (resp0)  *resp0  = ALT_SDCARD_RD_RESP0(dev->base);
    if (resp1)  *resp1  = ALT_SDCARD_RD_RESP1(dev->base);
    if (st_out) *st_out = st;

    /* No end latched at all: the core never ran it. */
    return (st & ENDED_MSK) ? irq_to_result(st) : ALT_SDCARD_ERR_NOT_READY;
}

/* The SPI-mode response format of each command (§7.3.2, table 7-3).
 *
 * One table serves commands and application commands alike, because the index
 * never collides where it matters: CMD13 and ACMD13 both answer R2, and every
 * other application command answers R1. */
static alt_u32 resp_for(alt_u8 index)
{
    switch (index) {
    case 8:  return ALT_SDCARD_RESP_R3R7;     /* R7 */
    case 58: return ALT_SDCARD_RESP_R3R7;     /* R3 */
    case 13: return ALT_SDCARD_RESP_R2;
    case 12:                                  /* STOP_TRANSMISSION         */
    case 28:                                  /* SET_WRITE_PROT            */
    case 29:                                  /* CLR_WRITE_PROT            */
    case 38: return ALT_SDCARD_RESP_R1B;      /* ERASE                     */
    default: return ALT_SDCARD_RESP_R1;
    }
}

int alt_sdcard_command(alt_sdcard_dev *dev, alt_u8 index, alt_u32 arg,
                       alt_u32 resp_type, alt_u32 extra_cmd_bits,
                       alt_u32 *resp0, alt_u32 *resp1)
{
    if (dev == 0 || index > 63u) return ALT_SDCARD_ERR_PARAM;
    if (dev->async.running) return ALT_SDCARD_ERR_BUSY;

    if (resp_type == ALT_SDCARD_RESP_AUTO)
        resp_type = resp_for(index);
    else if (resp_type > ALT_SDCARD_RESP_R3R7)
        return ALT_SDCARD_ERR_PARAM;   /* was silently masked to two bits */

    issue(dev, index, arg, resp_type, extra_cmd_bits);
    return complete(dev, resp0, resp1, 0);
}

/* A command the driver itself sends, retried on a command CRC error.
 *
 * Safe for exactly the reason the error exists: a card that finds the command
 * CRC wrong does not execute the command (§7.2.2), so sending it again cannot
 * do anything twice. Nothing else is retried here. */
static int command_retried(alt_sdcard_dev *dev, alt_u8 index, alt_u32 arg,
                           alt_u32 resp_type, alt_u32 *resp0, alt_u32 *resp1)
{
    alt_u32 st, attempt;
    int     r;

    for (attempt = 0; ; attempt++) {
        issue(dev, index, arg, resp_type, 0);
        r = complete(dev, resp0, resp1, &st);
        if (!(st & ALT_SDCARD_IRQ_ERR_CMD_CRC_MSK) || attempt >= dev->retries)
            return r;
        dev->retry_count++;
    }
}

/* An ACMD is CMD55 followed by the command itself.
 *
 * CMD55 is retried on a CRC error like any command. The application command is
 * NOT retried here, deliberately: a card that rejected it has already left
 * application mode, so repeating it alone would send the ordinary command with
 * the same index. The one caller, the ACMD41 poll, repeats the whole pair on
 * any failure anyway. */
static int app_command(alt_sdcard_dev *dev, alt_u8 index, alt_u32 arg,
                       alt_u32 resp_type, alt_u32 *resp0, alt_u32 *resp1)
{
    int r = command_retried(dev, 55, 0, ALT_SDCARD_RESP_R1, 0, 0);
    if (r != ALT_SDCARD_OK) return r;
    return alt_sdcard_command(dev, index, arg, resp_type, 0, resp0, resp1);
}

/* -------------------------------------------------------------------------
 * PIO data movement, used when the core was built or configured without DMA.
 *
 * One STATUS read per batch, not per word. STATUS.LEVEL says how many bytes
 * the buffer holds, so a read can take every whole word waiting and a write
 * can fill every word of room, back to back, before looking again. The loops
 * used to read STATUS before every word, which doubled the bus traffic, and
 * when the processor is what limits a PIO transfer that is the whole transfer
 * time: a read on a processor slower than the card ran at half the speed it
 * needed to.
 *
 * Back-to-back DATA accesses need nothing from STATUS in between. The buffer
 * presents its next word the cycle after a pop, and a word LEVEL counts is
 * already readable by the time the access after the STATUS read reaches it.
 * LEVEL counts the byte staging registers too, which is why both loops take
 * whole words only: a read never counts a partial word as available, and a
 * write never counts the part of a word still going out as room.
 *
 * Both loops end early only once the transfer has - ended() below, not a bare
 * CMD_BUSY, for the reason given there - so one that fails part-way ends the
 * loop instead of leaving it waiting on a buffer that will never fill or drain.
 *
 * A write leaves one word of room unused each time it looks. A DATA write
 * reaches the buffer a cycle after the access, so a STATUS read in the very
 * next cycle can still count the last word written as room; taking all of it
 * would then overfill the buffer by one, which the core refuses and reports as
 * ERR_PIO. The margin costs one STATUS read in 255 words. No test reaches the
 * case it guards: the harness's run with no delay between accesses passes
 * without it, because the word the sequencer has taken to send is still
 * counted in LEVEL, and the overcount only shows in the cycle or two between
 * one such word being sent and the next being taken.
 *
 * Words are copied with memcpy rather than through an alt_u32 pointer, so the
 * caller's buffer need not be aligned: a misaligned 32-bit load on Nios II is
 * not trapped, it is quietly word-aligned by the bus.
 * ---------------------------------------------------------------------- */

static alt_u32 status_level(alt_u32 st)
{
    return (st & ALT_SDCARD_STAT_LEVEL_MSK) >> ALT_SDCARD_STAT_LEVEL_OFST_B;
}

static int pio_read(alt_sdcard_dev *dev, alt_u8 *dst, alt_u32 words)
{
    alt_u32 got = 0, quiet = 0;
    alt_u32 st, n, w;

    while (got < words) {
        st = ALT_SDCARD_RD_STATUS(dev->base);
        n  = status_level(st) / 4u;            /* whole words waiting */
        if (n == 0u) {
            if (ended(dev, st, &quiet))
                break;  /* transfer over and the buffer is drained */
            continue;
        }
        if (n > words - got) n = words - got;
        while (n-- > 0u) {
            w = ALT_SDCARD_RD(dev->base, ALT_SDCARD_DATA_OFST);
            memcpy(dst + 4u * got, &w, 4);
            got++;
        }
    }
    return (got == words) ? ALT_SDCARD_OK : ALT_SDCARD_ERR_TIMEOUT;
}

static int pio_write(alt_sdcard_dev *dev, const alt_u8 *src, alt_u32 words)
{
    alt_u32 put = 0, quiet = 0;
    alt_u32 st, n, w, level;

    while (put < words) {
        st = ALT_SDCARD_RD_STATUS(dev->base);
        level = status_level(st);
        n = (level < dev->fifo_bytes) ? (dev->fifo_bytes - level) / 4u : 0u;
        if (n > 0u) n--;                       /* the margin, see above */
        if (n == 0u) {
            if (ended(dev, st, &quiet))
                break;  /* the transfer gave up before we finished feeding it */
            continue;
        }
        if (n > words - put) n = words - put;
        while (n-- > 0u) {
            memcpy(&w, src + 4u * put, 4);
            ALT_SDCARD_WR(dev->base, ALT_SDCARD_DATA_OFST, w);
            put++;
        }
    }
    return (put == words) ? ALT_SDCARD_OK : ALT_SDCARD_ERR_TIMEOUT;
}

/* -------------------------------------------------------------------------
 * Read one of the 16-byte card registers (CSD via CMD9, CID via CMD10).
 *
 * These come back through the ordinary data path with a block length of 16
 * rather than 512, which is the only place in the driver that BLK_SIZE moves.
 * A CRC error on either the command or the 16 bytes is retried: reading a
 * register twice has no side effect.
 * ---------------------------------------------------------------------- */
static int read_reg16(alt_sdcard_dev *dev, alt_u8 index, alt_u8 *out16)
{
    alt_u32 buf[4];
    alt_u32 st, attempt;
    int     r;

    for (attempt = 0; ; attempt++) {
        ALT_SDCARD_WR(dev->base, ALT_SDCARD_BLK_SIZE_OFST, 16);
        ALT_SDCARD_WR(dev->base, ALT_SDCARD_BLK_COUNT_OFST, 1);
        ALT_SDCARD_WR(dev->base, ALT_SDCARD_DMA_ADDR_OFST, (alt_u32)(uintptr_t)buf);

        issue(dev, index, 0, ALT_SDCARD_RESP_R1, ALT_SDCARD_CMD_DATA_EN_MSK);

        if (!dev->use_dma) (void)pio_read(dev, (alt_u8 *)buf, 4);

        r = complete(dev, 0, 0, &st);

        ALT_SDCARD_WR(dev->base, ALT_SDCARD_BLK_SIZE_OFST, 512);

        if (r == ALT_SDCARD_OK) break;
        datapath_reset(dev);
        if (!(st & (ALT_SDCARD_IRQ_ERR_CMD_CRC_MSK | ALT_SDCARD_IRQ_ERR_DAT_CRC_MSK))
                || attempt >= dev->retries)
            return r;
        dev->retry_count++;
    }

    memcpy(out16, buf, 16);
    return ALT_SDCARD_OK;
}

/* -------------------------------------------------------------------------
 * Capacity from the CSD.
 *
 * The two structure versions are genuinely different arithmetic, not a field
 * that moved:
 *
 *   v1 (SDSC)  blocks = (C_SIZE+1) * 2^(C_SIZE_MULT+2) * 2^READ_BL_LEN / 512
 *   v2 (SDHC)  blocks = (C_SIZE+1) * 1024
 *
 * Reading a v2 card with the v1 formula produces a plausible number that is
 * wrong by orders of magnitude, which is why the version is checked rather
 * than assumed from the OCR's CCS bit.
 * ---------------------------------------------------------------------- */
static alt_u32 csd_blocks(const alt_u8 *csd)
{
    alt_u32 c_size, mult, read_bl_len;

    if ((csd[0] >> 6) == 1u) {                       /* CSD version 2 */
        c_size = (((alt_u32)csd[7] & 0x3Fu) << 16)
               | ((alt_u32)csd[8] << 8)
               |  (alt_u32)csd[9];
        return (c_size + 1u) * 1024u;
    }

    /* CSD version 1 */
    read_bl_len = (alt_u32)(csd[5] & 0x0Fu);
    c_size      = (((alt_u32)csd[6] & 0x03u) << 10)
                | ((alt_u32)csd[7] << 2)
                | ((alt_u32)csd[8] >> 6);
    mult        = ((((alt_u32)csd[9] & 0x03u) << 1)
                | ((alt_u32)csd[10] >> 7)) + 2u;

    /* (C_SIZE+1) << (mult + read_bl_len) bytes, then / 512 for blocks. */
    return ((c_size + 1u) << (mult + read_bl_len)) >> 9;
}

/* -------------------------------------------------------------------------
 * Card changes
 * ---------------------------------------------------------------------- */

/* Forget the card. Everything learned from it goes, so nothing stale can be
 * mistaken for a description of whatever is fitted next. */
static void invalidate(alt_sdcard_dev *dev)
{
    dev->type   = ALT_SDCARD_TYPE_NONE;
    dev->blocks = 0;
    dev->ocr    = 0;
    memset(dev->cid, 0, sizeof dev->cid);
    memset(dev->csd, 0, sizeof dev->csd);
}

/* Has the card in the socket possibly changed since anything last looked?
 *
 * Three pieces of evidence, all consumed here: the socket switch reading
 * empty now, a CARD_INSERT or CARD_REMOVE the hardware latched, and one the
 * ISR took first. The latched events are what make a FAST swap visible - out
 * and back in between two calls, with the switch reading "present" both times.
 *
 * Without a card-detect switch there is no evidence to consume, and a change
 * shows up instead as a card that stops answering. */
static int card_changed(alt_sdcard_dev *dev)
{
    alt_u32 ev;
    int     changed = 0;

    if (!dev->has_card_detect) return 0;

    ev = ALT_SDCARD_RD_IRQ_STATUS(dev->base) & ALT_SDCARD_IRQ_CARD_MSK;
    if (ev) {
        /* Only the bits seen: one that sets between the read and this write is
         * left for the next look rather than lost. */
        ALT_SDCARD_WR_IRQ_STATUS(dev->base, ev);
        changed = 1;
    }

    ev = dev->isr_card_events;
    if (ev != dev->card_events_seen) {
        dev->card_events_seen = ev;
        changed = 1;
    }

    if (!(ALT_SDCARD_RD_STATUS(dev->base) & ALT_SDCARD_STAT_CARD_PRES_MSK))
        changed = 1;

    return changed;
}

int alt_sdcard_check(alt_sdcard_dev *dev)
{
    if (dev == 0) return ALT_SDCARD_ERR_PARAM;
    if (dev->async.running) return ALT_SDCARD_ERR_BUSY;

    if (card_changed(dev) && dev->type != ALT_SDCARD_TYPE_NONE) {
        /* Fail THIS call; the next one identifies whatever is there. The caller
         * may be holding something it learned from the old card - see the
         * header. */
        invalidate(dev);
        return alt_sdcard_present(dev) ? ALT_SDCARD_ERR_CHANGED
                                       : ALT_SDCARD_ERR_NO_CARD;
    }
    if (!alt_sdcard_present(dev))          return ALT_SDCARD_ERR_NO_CARD;
    if (dev->type == ALT_SDCARD_TYPE_NONE) return ALT_SDCARD_ERR_NOT_READY;
    return ALT_SDCARD_OK;
}

/* The start of every block call: act on a change, then make sure an identified
 * card is there, identifying one if none is. */
static int ensure_ready(alt_sdcard_dev *dev)
{
    int r = alt_sdcard_check(dev);
    return (r == ALT_SDCARD_ERR_NOT_READY) ? alt_sdcard_probe(dev) : r;
}

/* -------------------------------------------------------------------------
 * ISR
 * ---------------------------------------------------------------------- */

static void sdcard_isr(void *context)
{
    alt_sdcard_dev *dev = (alt_sdcard_dev *)context;
    alt_u32 st;

    /* Only the bits that can have raised the interrupt; the rest stay latched
     * for whoever polls them. What this acknowledges is kept below, so the
     * driver's own completion poll still finds it: acknowledging and
     * discarding, as this once did, cleared a command's status out from under
     * that poll whenever an application enabled any source at all. */
    st  = ALT_SDCARD_RD_IRQ_STATUS(dev->base);
    st &= ALT_SDCARD_RD(dev->base, ALT_SDCARD_IRQ_ENABLE_OFST);

    dev->last_irq_status = st;

    /* Acknowledge at the source. The interrupt is level, so it stays asserted
     * until the causing bit is cleared - writing 1 to it is the only thing that
     * deasserts the pin. */
    ALT_SDCARD_WR_IRQ_STATUS(dev->base, st);

    /* Keep what was acknowledged where the driver will still find it: card
     * events as a count - only this ISR writes it, so the main line reads it
     * without a race - and everything else for complete(). */
    if (st & ALT_SDCARD_IRQ_CARD_MSK) dev->isr_card_events++;
    dev->isr_status |= st & ~ALT_SDCARD_IRQ_CARD_MSK;

    if (dev->on_event) dev->on_event(dev, st);

    /* A non-blocking transfer's step may have ended: take the next one. */
    if (dev->async.running && async_service(dev, 1) && dev->async.done)
        dev->async.done(dev, dev->async.result, dev->async.context);
}

/* -------------------------------------------------------------------------
 * init
 * ---------------------------------------------------------------------- */

int alt_sdcard_init(alt_sdcard_dev *dev)
{
    alt_u32 info;
    unsigned i;

    if (dev == 0) return ALT_SDCARD_ERR_PARAM;

    info = ALT_SDCARD_RD_CORE_INFO(dev->base);

    dev->version         = info;
    dev->has_dma         = (info & ALT_SDCARD_INFO_HAS_DMA_MSK) ? 1 : 0;
    dev->has_card_detect = (info & ALT_SDCARD_INFO_HAS_CD_MSK)  ? 1 : 0;
    dev->fifo_bytes      = 1u << ((info & ALT_SDCARD_INFO_FIFO_LOG2_MSK)
                                        >> ALT_SDCARD_INFO_FIFO_LOG2_OFST_B);

    /* Refuse to drive hardware whose register map this driver does not know.
     * A BSP is far easier to copy between projects than to keep in step with
     * one, so the check is worth its few instructions. */
    if (((info & ALT_SDCARD_INFO_VER_MAJOR_MSK)
            >> ALT_SDCARD_INFO_VER_MAJOR_OFST_B) != DRIVER_HW_MAJOR) {
        return ALT_SDCARD_ERR_VERSION;
    }

    /* A core built without the DMA cannot use it however the caller asked. */
    if (!dev->has_dma) dev->use_dma = 0;

    /* NOT generation, which only ever counts up: a second init followed by an
     * identification must not reproduce a number a caller already holds for
     * a card it thinks it knows. */
    invalidate(dev);
    dev->isr_card_events  = 0;
    dev->card_events_seen = 0;
    dev->isr_status       = 0;

    memset(&dev->async, 0, sizeof dev->async);

    ALT_SDCARD_WR_CTRL(dev->base, 0);
    ALT_SDCARD_WR_IRQ_ENABLE(dev->base, 0);
    /* Everything, card events included: the card, if any, is unidentified. */
    ALT_SDCARD_WR_IRQ_STATUS(dev->base, 0xFFFFFFFFu);
    ALT_SDCARD_WR(dev->base, ALT_SDCARD_TIMEOUT_OFST, dev->timeout_cycles);

    if (dev->irq != -1) {
        alt_ic_isr_register((alt_u32)dev->irq_controller_id, (alt_u32)dev->irq,
                            sdcard_isr, dev, 0);
    }

    for (i = 0; i < ALT_SDCARD_MAX_INSTANCES; i++) {
        if (instances[i] == dev) break;
        if (instances[i] == 0) { instances[i] = dev; break; }
    }

    return ALT_SDCARD_OK;
}

/* -------------------------------------------------------------------------
 * probe - the identification sequence
 * ---------------------------------------------------------------------- */

static int identify(alt_sdcard_dev *dev)
{
    alt_u32 r0, r1, ctrl, tries;
    alt_sdcard_type type;
    int     r;
    int     v2;

    ALT_SDCARD_WR(dev->base, ALT_SDCARD_TIMEOUT_OFST, dev->timeout_cycles);
    ALT_SDCARD_WR(dev->base, ALT_SDCARD_CLKDIV_OFST,
                  ALT_SDCARD_CLKDIV_MAKE(dev->clkdiv_id, 0));

    /* ---- 1. power-up: at least 74 clocks with CS HIGH (§6.4.1.1) ----
     *
     * CS high is the opposite of what a transaction wants, which is why the
     * manual override exists at all. The card may use all 74 clocks to get
     * ready, so this is not optional padding - and it is timed by the bus, see
     * run_clocks(). */
    ctrl = ALT_SDCARD_CTRL_ENABLE_MSK
         | ALT_SDCARD_CTRL_CS_MANUAL_MSK
         | ALT_SDCARD_CTRL_CS_VALUE_MSK
         | ALT_SDCARD_CTRL_CLK_RUN_MSK;
    ALT_SDCARD_WR_CTRL(dev->base, ctrl);
    run_clocks(dev, dev->clkdiv_id, POWER_UP_CLOCKS);

    /* ---- 2. into SPI mode: CMD0 with CS asserted ----
     * Asserting CS during CMD0 is what selects SPI mode; the only way back to
     * SD mode is a power cycle. */
    ALT_SDCARD_WR_CTRL(dev->base,
                       ALT_SDCARD_CTRL_ENABLE_MSK | ALT_SDCARD_CTRL_CRC_EN_MSK |
                       (dev->use_dma ? ALT_SDCARD_CTRL_DMA_EN_MSK : 0u));

    for (tries = 0; tries < 8u; tries++) {
        r = alt_sdcard_command(dev, 0, 0, ALT_SDCARD_RESP_R1, 0, &r0, 0);
        if (r == ALT_SDCARD_OK && (r0 & 0xFFu) == ALT_SDCARD_R1_IDLE) break;
        dev->retry_count++;
    }
    if (tries == 8u) {
        /* Nothing answered. On a socket without card detect that is also what
         * an empty one looks like, and it is worth saying so. */
        return dev->has_card_detect ? ALT_SDCARD_ERR_UNUSABLE
                                    : ALT_SDCARD_ERR_NO_CARD;
    }

    /* ---- 3. version: CMD8 ----
     *
     * A v1.x card answers with Illegal Command and sends ONLY that byte - the
     * 32-bit trailer never arrives (§7.3.2). The hardware handles the
     * truncation; here it simply means "this is a v1.x card", not an error. */
    v2 = 0;
    r  = command_retried(dev, 8, ALT_SDCARD_CMD8_ARG,
                         ALT_SDCARD_RESP_R3R7, &r0, &r1);
    if (r == ALT_SDCARD_OK) {
        if ((r1 & 0xFFu) != (ALT_SDCARD_CMD8_ARG & 0xFFu)) {
            /* The check pattern did not come back. Communication is not
             * trustworthy; the specification recommends retrying, but a card
             * that fails this twice is not one to rely on. */
            return ALT_SDCARD_ERR_UNUSABLE;
        }
        v2 = 1;
    } else if (r != ALT_SDCARD_ERR_UNUSABLE) {
        return r;                       /* a real failure, not "v1.x card" */
    }

    /* ---- 4. CRC checking on, before ACMD41 (§7.2.2 recommends this order) */
    (void)command_retried(dev, 59, 1, ALT_SDCARD_RESP_R1, 0, 0);

    /* ---- 5. initialise: ACMD41, polled ----
     *
     * The card reports in_idle_state until initialisation completes. The
     * specification allows a full second for this, and large cards use a good
     * fraction of it, so a driver that issues ACMD41 once and gives up works
     * only by luck. See ACMD41_TRIES for why the bound is what it is. */
    for (tries = 0; tries < ACMD41_TRIES; tries++) {
        r = app_command(dev, 41, v2 ? ALT_SDCARD_ACMD41_HCS : 0u,
                        ALT_SDCARD_RESP_R1, &r0, 0);
        if (r != ALT_SDCARD_OK) {
            dev->retry_count++;
            continue;
        }
        if (((r0 & 0xFFu) & ALT_SDCARD_R1_IDLE) == 0) break;
        dev->retry_count++;
    }
    if (tries == ACMD41_TRIES) return ALT_SDCARD_ERR_TIMEOUT;

    /* ---- 6. capacity class: CMD58 reads the OCR ----
     * CCS decides byte versus block addressing, which is the single thing the
     * block API has to get right for a caller that does not want to care.
     *
     * The class is held locally and published only when identification has
     * finished. Setting dev->type here, as this once did, left a card whose
     * CSD read then failed looking identified - with a capacity of zero. */
    type = ALT_SDCARD_TYPE_SDSC;
    if (v2) {
        r = command_retried(dev, 58, 0, ALT_SDCARD_RESP_R3R7, &r0, &r1);
        if (r != ALT_SDCARD_OK) return r;
        dev->ocr = r1;
        if (r1 & ALT_SDCARD_OCR_CCS) type = ALT_SDCARD_TYPE_SDHC;
    }

    /* ---- 7. block length ----
     * SDHC and SDXC are fixed at 512 whatever CMD16 says; sending it anyway is
     * harmless and correct for standard-capacity cards. */
    if (type == ALT_SDCARD_TYPE_SDSC) {
        r = command_retried(dev, 16, 512, ALT_SDCARD_RESP_R1, 0, 0);
        if (r != ALT_SDCARD_OK) return r;
    }

    /* ---- 8. speed up ----
     * Before reading the card registers, so identification does not spend
     * milliseconds at 400 kHz reading two 16-byte blocks. */
    ALT_SDCARD_WR(dev->base, ALT_SDCARD_CLKDIV_OFST,
                  ALT_SDCARD_CLKDIV_MAKE(dev->clkdiv_run, dev->sample_dly));

    ALT_SDCARD_WR(dev->base, ALT_SDCARD_BLK_SIZE_OFST, 512);

    /* ---- 9. identity and capacity: CMD9 and CMD10 ----
     *
     * The CSD is the only place the card reports its size. Note the version is
     * taken from the CSD itself rather than inferred from the OCR's CCS bit:
     * the two agree on every card that follows the specification, and when they
     * disagree the CSD is the one describing the layout being parsed.
     */
    r = read_reg16(dev, 9, dev->csd);
    if (r != ALT_SDCARD_OK) return r;

    r = read_reg16(dev, 10, dev->cid);
    if (r != ALT_SDCARD_OK) return r;

    dev->blocks = csd_blocks(dev->csd);
    dev->type   = type;
    return ALT_SDCARD_OK;
}

int alt_sdcard_probe(alt_sdcard_dev *dev)
{
    int r;

    if (dev == 0) return ALT_SDCARD_ERR_PARAM;
    if (dev->async.running) return ALT_SDCARD_ERR_BUSY;

    /* Whatever happened in the socket before now is superseded by what is
     * about to be identified. */
    (void)card_changed(dev);
    invalidate(dev);

    if (!alt_sdcard_present(dev)) return ALT_SDCARD_ERR_NO_CARD;

    r = identify(dev);

    /* A card pulled - or a switch still bouncing - DURING identification has
     * produced an identification of nothing in particular. */
    if (r == ALT_SDCARD_OK && card_changed(dev)) {
        r = alt_sdcard_present(dev) ? ALT_SDCARD_ERR_CHANGED
                                    : ALT_SDCARD_ERR_NO_CARD;
    }

    if (r != ALT_SDCARD_OK) {
        invalidate(dev);
        return r;
    }

    dev->generation++;
    return ALT_SDCARD_OK;
}

/* -------------------------------------------------------------------------
 * Block access
 * ---------------------------------------------------------------------- */

/* Standard-capacity cards address by BYTE, high-capacity by BLOCK. Converting
 * here is the whole reason a caller can pass a block number without knowing
 * which kind of card is fitted. */
static alt_u32 block_to_arg(alt_sdcard_dev *dev, alt_u32 block)
{
    return (dev->type == ALT_SDCARD_TYPE_SDHC) ? block : (block * 512u);
}

/* Put things back after a failed transfer.
 *
 * Resetting the data path clears the CONTROLLER, which is all it claims to do
 * and all it can do. It does not touch the card, and a failed transfer leaves
 * the card in the middle of something. A failed read, first:
 *
 *   The card goes on sending. A multi-block read runs until CMD12 whatever
 *   happened at the host - a CRC error the card never learns of, a block the
 *   core held for room and gave up on, a DMA error - and so does a single
 *   block the core stopped part-way. Deselecting the card does not end it. A
 *   card left sending answers the next command as illegal, and this driver used
 *   to say reads needed nothing: a 2-block read with one corrupt block in the
 *   driver harness came back as a timeout, and the card as unusable after it.
 *   CMD12 ends any of these; a card that had already finished answers it as an
 *   illegal command, which costs one command and changes nothing.
 *
 * And a failed write:
 *
 *   Stopped at a block boundary - a multi-block write that failed between
 *   blocks - the card is waiting for the next data token, and §7.3.3.1 says the
 *   host terminates a FAILED stream with CMD12 rather than the stop-tran token.
 *   That is recoverable, and it is what the CMD12 below is for. Without it every
 *   command afterwards is swallowed as write data and comes back as a timeout.
 *
 *   Stopped MID-BLOCK - the data phase starved, or the core aborted inside it -
 *   the card is waiting for the rest of a block it will never be sent. Nothing
 *   the host can issue fixes that: CMD12's own bytes are consumed as data like
 *   anything else. The card needs the block finished or a power cycle, and this
 *   driver can do neither. It is a real limitation of abandoning a write, not an
 *   artefact of how the failure was detected, and it is the strongest argument
 *   for keeping the buffer fed - which is what IRQ_ERR_PIO now reports on.
 *
 * The two cases are indistinguishable from outside the core, so CMD12 is issued
 * for every failed write. In the recoverable case it costs one command; in the
 * other it costs one TIMEOUT period, because the card eats it and never answers.
 * That is bounded, and it is the right trade - the alternative is leaving a
 * recoverable card wedged to save a wait on an unrecoverable one.
 *
 * So every failed transfer, read or write, is followed by CMD12, and its result
 * is not looked at: whether the card was sending, receiving or finished, the
 * data path is reset again behind it and the caller gets the original error.
 */
static void recover(alt_sdcard_dev *dev)
{
    datapath_reset(dev);
    (void)alt_sdcard_command(dev, 12, 0, ALT_SDCARD_RESP_R1B, 0, 0, 0);
    datapath_reset(dev);
}

/* Put one transfer of `count` blocks under way: block size and count, the
 * buffer the DMA works on, and the read or write command. Both the blocking
 * and the non-blocking paths go through here, so they send the same thing. */
static void issue_transfer(alt_sdcard_dev *dev, alt_u32 block, void *buf,
                           alt_u32 count, int writing)
{
    alt_u32 extra;
    alt_u8  index;

    wait_not_busy(dev);

    ALT_SDCARD_WR(dev->base, ALT_SDCARD_BLK_SIZE_OFST, 512);
    ALT_SDCARD_WR(dev->base, ALT_SDCARD_BLK_COUNT_OFST, count);
    ALT_SDCARD_WR(dev->base, ALT_SDCARD_DMA_ADDR_OFST, (alt_u32)(uintptr_t)buf);

    extra = ALT_SDCARD_CMD_DATA_EN_MSK;
    if (writing) extra |= ALT_SDCARD_CMD_DATA_DIR_MSK;

    if (count > 1) {
        /* Multi-block streams the whole transfer in hardware: the card's access
         * latency is paid once instead of once per block, which is most of the
         * difference between this and a per-block loop. AUTO_STOP terminates it
         * without software - CMD12 for a read, the stop-tran token for a write. */
        extra |= ALT_SDCARD_CMD_MULTI_MSK | ALT_SDCARD_CMD_AUTO_STOP_MSK;
        index  = writing ? 25 : 18;
    } else {
        index  = writing ? 24 : 17;
    }

    issue(dev, index, block_to_arg(dev, block), ALT_SDCARD_RESP_R1, extra);
}

/* May a transfer that failed with status `st` be tried again?
 *
 * A command CRC error, a read whose CRC16 failed, or a written block the card
 * rejected ON CRC (data response 0bxxx01011). The last has to be told apart
 * from a genuine write error, which reports through the same status bit, so
 * this reads the data response - before any reset can clear it. A multi-block
 * write retried from the start rewrites blocks that did land - with the same
 * data, at the same address.
 *
 * One cause at a time is enough: the sequencer stops at the first error, so a
 * timeout never arrives alongside a CRC error to be retried by mistake. */
static int retryable(alt_sdcard_dev *dev, alt_u32 st, int writing)
{
    if (st & (ALT_SDCARD_IRQ_ERR_CMD_CRC_MSK | ALT_SDCARD_IRQ_ERR_DAT_CRC_MSK))
        return 1;
    return writing && (st & ALT_SDCARD_IRQ_ERR_WRITE_MSK) &&
           ((ALT_SDCARD_RD_ERR_INFO(dev->base) & 0x1Fu) == 0x0Bu);
}

/* One attempt at one transfer of at most MAX_BLOCKS_PER_TRANSFER blocks, from
 * or to a word-aligned buffer. `*retry` says whether a failure is one that may
 * safely be tried again. */
static int transfer_once(alt_sdcard_dev *dev, alt_u32 block, void *buf,
                         alt_u32 count, int writing, int *retry)
{
    alt_u32 st;
    int     r;

    *retry = 0;

    issue_transfer(dev, block, buf, count, writing);

    /* Without the DMA nothing else moves the data, so software must, while the
     * transfer runs - the buffer is cleared when the command starts, so it
     * cannot be filled beforehand. Being late costs time, not data: a write
     * whose next word has not arrived stops the SPI clock until it does, and a
     * read block waits for room. Only a stall longer than TIMEOUT fails. */
    if (!dev->use_dma) {
        if (writing) (void)pio_write(dev, (const alt_u8 *)buf, count * 128u);
        else         (void)pio_read (dev, (alt_u8 *)buf,       count * 128u);
    }

    /* complete() folds in everything the ISR acknowledged as well, so its result
     * is the whole story. This once read IRQ_STATUS a second time to look for
     * errors complete() had missed - which there cannot be, and which would not
     * have included the ones an interrupt handler had already taken. */
    r = complete(dev, 0, 0, &st);
    if (r == ALT_SDCARD_OK) return ALT_SDCARD_OK;

    *retry = retryable(dev, st, writing);
    recover(dev);
    return r;
}

static int transfer_retried(alt_sdcard_dev *dev, alt_u32 block, void *buf,
                            alt_u32 count, int writing)
{
    alt_u32 attempt;
    int     r, retry;

    for (attempt = 0; ; attempt++) {
        r = transfer_once(dev, block, buf, count, writing, &retry);
        if (r == ALT_SDCARD_OK) return r;
        if (!retry || attempt >= dev->retries) break;
        dev->retry_count++;
    }

    /* A card that stopped answering can no longer be vouched for: it may have
     * been pulled from a socket with no switch, swapped, or reset. Identify
     * again before the next transfer rather than address it on trust. */
    if (r == ALT_SDCARD_ERR_TIMEOUT) invalidate(dev);
    return r;
}

/* A misaligned buffer through the DMA, a block at a time via a bounce buffer.
 * Separate so its 512 bytes of stack are paid only by callers who need it. */
static int transfer_bounced(alt_sdcard_dev *dev, alt_u32 block, alt_u8 *buf,
                            alt_u32 count, int writing)
{
    alt_u32 bounce[128];
    alt_u32 i;
    int     r;

    for (i = 0; i < count; i++) {
        if (writing) memcpy(bounce, buf + 512u * i, 512);
        r = transfer_retried(dev, block + i, bounce, 1, writing);
        if (r != ALT_SDCARD_OK) return r;
        if (!writing) memcpy(buf + 512u * i, bounce, 512);
    }
    return ALT_SDCARD_OK;
}

static int transfer(alt_sdcard_dev *dev, alt_u32 block, void *buf,
                    alt_u32 count, int writing)
{
    alt_u32 n;
    int     r;

    if (dev == 0 || buf == 0 || count == 0) return ALT_SDCARD_ERR_PARAM;

    /* ensure_ready() goes through alt_sdcard_check(), which refuses while a
     * non-blocking transfer runs - so this does too. */
    r = ensure_ready(dev);
    if (r != ALT_SDCARD_OK) return r;

    /* Past the end of the card is refused rather than sent. On a standard-
     * capacity card the byte address would otherwise wrap at 4 GiB and land
     * near block 0 - the partition table. */
    if (block >= dev->blocks || count > dev->blocks - block)
        return ALT_SDCARD_ERR_PARAM;

    if (writing && alt_sdcard_write_protected(dev))
        return ALT_SDCARD_ERR_PROTECTED;

    /* The DMA moves whole 32-bit words and cannot address a misaligned buffer
     * - the hardware would silently word-align it and the data would go
     * somewhere the caller did not ask for. */
    if (dev->use_dma && (((uintptr_t)buf & 3u) != 0u))
        return transfer_bounced(dev, block, (alt_u8 *)buf, count, writing);

    while (count) {
        n = (count > MAX_BLOCKS_PER_TRANSFER) ? MAX_BLOCKS_PER_TRANSFER : count;
        r = transfer_retried(dev, block, buf, n, writing);
        if (r != ALT_SDCARD_OK) return r;
        block += n;
        count -= n;
        buf    = (alt_u8 *)buf + 512u * n;
    }
    return ALT_SDCARD_OK;
}

int alt_sdcard_read_blocks(alt_sdcard_dev *dev, alt_u32 block,
                           void *buf, alt_u32 count)
{
    return transfer(dev, block, buf, count, 0);
}

int alt_sdcard_write_blocks(alt_sdcard_dev *dev, alt_u32 block,
                            const void *buf, alt_u32 count)
{
    return transfer(dev, block, (void *)buf, count, 1);
}

/* -------------------------------------------------------------------------
 * Non-blocking transfers - see NON-BLOCKING TRANSFERS in the header.
 *
 * transfer(), one step at a time. A step issues a command and returns; its end
 * is noticed by async_service(), from the ISR or from
 * alt_sdcard_transfer_status(), which takes the next step - the next piece of
 * a transfer longer than BLK_COUNT, a retry, the CMD12 that stops a failed
 * write - or delivers the result. No step waits on the card, which is what
 * makes it fit to run in the ISR, and each makes the same decision the
 * blocking path makes at the same point.
 * ---------------------------------------------------------------------- */

/* The interrupt sources the step running now ends on, added to whatever the
 * application enabled and taken away again afterwards. A data step ends on
 * DATA_DONE; the CMD12 of a recovery has no data phase and ends on CMD_DONE.
 * Every failure latches DATA_DONE as well, so no error bit is needed. Without a
 * connected interrupt nothing is enabled, and transfer_status() does the work.
 *
 * It reads IRQ_ENABLE and writes it back, and so does the ISR's step, so it is
 * only ever called from the ISR or with interrupts held off: an ISR between the
 * two would have its change written over - the CMD_DONE of a recovery's CMD12
 * lost, and the transfer never heard from again. */
static void async_irq(alt_sdcard_dev *dev, alt_u32 bits)
{
    alt_u32 en;

    if (dev->irq == -1) return;
    en  = ALT_SDCARD_RD(dev->base, ALT_SDCARD_IRQ_ENABLE_OFST);
    en &= ~dev->async.irq_added;
    dev->async.irq_added = bits & ~en;
    ALT_SDCARD_WR_IRQ_ENABLE(dev->base, en | bits);
}

/* The next piece: as many of the blocks left as one BLK_COUNT can carry. */
static void async_piece(alt_sdcard_dev *dev)
{
    alt_u32 n = dev->async.left;

    if (n > MAX_BLOCKS_PER_TRANSFER) n = MAX_BLOCKS_PER_TRANSFER;
    dev->async.piece    = n;
    dev->async.stopping = 0;
    issue_transfer(dev, dev->async.block, dev->async.buf, n, dev->async.writing);
}

/* Deliver the result. The callback is left to the caller of async_service(),
 * which may still hold the interrupts off. */
static int async_end(alt_sdcard_dev *dev, int r)
{
    async_irq(dev, 0);
    dev->async.result  = r;
    dev->async.running = 0;
    return 1;
}

/* If the step running now has ended, take the next one. Returns 1 when that
 * was the end of the transfer.
 *
 * The end is latched about a byte before the core goes idle - the last byte
 * leaving the shifter, and the DMA's last write - and the next command cannot
 * go out until it is. The ISR will not be called again for this end, so it
 * waits that out; a status call reports busy and is simply asked again. */
static int async_service(alt_sdcard_dev *dev, int in_isr)
{
    alt_u32 want, st;
    int     r;

    if (!dev->async.running) return 0;

    want = dev->async.stopping ? ENDED_MSK : ALT_SDCARD_IRQ_DATA_DONE_MSK;
    st   = latched(dev);
    if (!(st & want)) return 0;

    while (ALT_SDCARD_RD_STATUS(dev->base) & ALT_SDCARD_STAT_CMD_BUSY_MSK) {
        if (!in_isr) return 0;
    }

    account(dev, st);
    r = irq_to_result(st);

    if (!dev->async.stopping) {
        if (r == ALT_SDCARD_OK) {
            dev->async.block   += dev->async.piece;
            dev->async.buf     += 512u * dev->async.piece;
            dev->async.left    -= dev->async.piece;
            dev->async.attempt  = 0;
            if (dev->async.left == 0u) return async_end(dev, ALT_SDCARD_OK);
            async_piece(dev);
            async_irq(dev, ALT_SDCARD_IRQ_DATA_DONE_MSK);
            return 0;
        }

        /* transfer_once(): whether to retry, decided before the reset; then
         * recover(), with its CMD12 as a step of its own. */
        dev->async.error    = r;
        dev->async.retry    = retryable(dev, st, dev->async.writing);
        dev->async.stopping = 1;
        datapath_reset(dev);
        issue(dev, 12, 0, ALT_SDCARD_RESP_R1B, 0);
        async_irq(dev, ENDED_MSK);
        return 0;
    } else {
        /* The CMD12 has ended, however it went - recover() does not look
         * either - and the data path is reset again behind it. */
        datapath_reset(dev);
    }

    /* transfer_retried(). */
    if (dev->async.retry && dev->async.attempt < dev->retries) {
        dev->async.attempt++;
        dev->retry_count++;
        async_piece(dev);
        async_irq(dev, ALT_SDCARD_IRQ_DATA_DONE_MSK);
        return 0;
    }
    if (dev->async.error == ALT_SDCARD_ERR_TIMEOUT) invalidate(dev);
    return async_end(dev, dev->async.error);
}

static int transfer_start(alt_sdcard_dev *dev, alt_u32 block, void *buf,
                          alt_u32 count, int writing,
                          alt_sdcard_done_fn done, void *context)
{
    alt_irq_context ctx;
    int             r;

    if (dev == 0 || buf == 0 || count == 0) return ALT_SDCARD_ERR_PARAM;
    if (dev->async.running) return ALT_SDCARD_ERR_BUSY;

    /* Without the DMA the processor moves every word and has nothing to hand
     * back; a misaligned buffer needs the bounce buffer transfer() keeps on
     * its stack, which does not outlive this call. */
    if (!dev->use_dma || (((uintptr_t)buf & 3u) != 0u)) return ALT_SDCARD_ERR_PARAM;

    /* The same checks transfer() makes, identification included. */
    r = ensure_ready(dev);
    if (r != ALT_SDCARD_OK) return r;
    if (block >= dev->blocks || count > dev->blocks - block)
        return ALT_SDCARD_ERR_PARAM;
    if (writing && alt_sdcard_write_protected(dev))
        return ALT_SDCARD_ERR_PROTECTED;

    dev->async.writing = writing;
    dev->async.block   = block;
    dev->async.buf     = (alt_u8 *)buf;
    dev->async.left    = count;
    dev->async.attempt = 0;
    dev->async.retry   = 0;
    dev->async.error   = ALT_SDCARD_OK;
    dev->async.done    = done;
    dev->async.context = context;

    /* In this order. issue() clears the previous command's status, including
     * a DATA_DONE the ISR may have saved; `running` set any earlier would let
     * an interrupt in between take that for this transfer's end. And the
     * interrupt is enabled last, so an end latched in the meantime raises it
     * the moment it is. The issue itself may wait for the core, so only what
     * follows it holds the interrupts off. */
    async_piece(dev);
    ctx = alt_irq_disable_all();
    dev->async.running = 1;
    async_irq(dev, ALT_SDCARD_IRQ_DATA_DONE_MSK);
    alt_irq_enable_all(ctx);
    return ALT_SDCARD_OK;
}

int alt_sdcard_read_blocks_start(alt_sdcard_dev *dev, alt_u32 block,
                                 void *buf, alt_u32 count,
                                 alt_sdcard_done_fn done, void *context)
{
    return transfer_start(dev, block, buf, count, 0, done, context);
}

int alt_sdcard_write_blocks_start(alt_sdcard_dev *dev, alt_u32 block,
                                  const void *buf, alt_u32 count,
                                  alt_sdcard_done_fn done, void *context)
{
    return transfer_start(dev, block, (void *)buf, count, 1, done, context);
}

int alt_sdcard_transfer_status(alt_sdcard_dev *dev)
{
    alt_irq_context ctx;
    int ended_now, r;

    if (dev == 0) return ALT_SDCARD_ERR_PARAM;

    /* Held off so the ISR cannot take a step at the same time as this. The
     * callback runs after, not inside, the critical section. */
    ctx = alt_irq_disable_all();
    ended_now = async_service(dev, 0);
    r = dev->async.running ? ALT_SDCARD_ERR_BUSY : dev->async.result;
    alt_irq_enable_all(ctx);

    if (ended_now && dev->async.done)
        dev->async.done(dev, r, dev->async.context);
    return r;
}

/* -------------------------------------------------------------------------
 * Odds and ends
 * ---------------------------------------------------------------------- */

int alt_sdcard_poll(alt_sdcard_dev *dev)
{
    int r;

    r = alt_sdcard_check(dev);
    if (r != ALT_SDCARD_OK) return r;

    /* CMD13, SEND_STATUS: harmless, answered in any data-transfer state, and
     * the one command a card swapped in behind the driver's back - still in SD
     * mode - cannot answer. The hardware's pre-emptive busy check also means it
     * returns only once any write in progress has been programmed. */
    /* A card sent CMD0 behind the driver's back is answering, but in idle
     * state, where CMD13 is not a legal command - so that case needs no test of
     * its own: it fails here like any other. */
    r = command_retried(dev, 13, 0, ALT_SDCARD_RESP_R2, 0, 0);
    if (r != ALT_SDCARD_OK) invalidate(dev);
    return r;
}

alt_u32 alt_sdcard_generation(alt_sdcard_dev *dev)
{
    return (dev == 0) ? 0u : dev->generation;
}

alt_sdcard_dev *alt_sdcard_instance(unsigned n)
{
    return (n < ALT_SDCARD_MAX_INSTANCES) ? instances[n] : 0;
}

int alt_sdcard_present(alt_sdcard_dev *dev)
{
    if (dev == 0) return 0;
    /* A core built without card detect reports "present" so an application
     * need not special-case the configuration. */
    if (!dev->has_card_detect) return 1;
    return (ALT_SDCARD_RD_STATUS(dev->base) & ALT_SDCARD_STAT_CARD_PRES_MSK)
           ? 1 : 0;
}

int alt_sdcard_write_protected(alt_sdcard_dev *dev)
{
    if (dev == 0) return 0;
    if (!dev->has_card_detect) return 0;
    return (ALT_SDCARD_RD_STATUS(dev->base) & ALT_SDCARD_STAT_CARD_WP_MSK)
           ? 1 : 0;
}

alt_u32 alt_sdcard_block_count(alt_sdcard_dev *dev)
{
    return (dev == 0) ? 0u : dev->blocks;
}

void alt_sdcard_reset_datapath(alt_sdcard_dev *dev)
{
    alt_irq_context ctx;

    if (dev == 0) return;

    /* A non-blocking transfer running now will never see its end latched once
     * the data path is reset under it, so it is ended here, with the ISR held
     * off while that happens. */
    ctx = alt_irq_disable_all();
    if (dev->async.running) (void)async_end(dev, ALT_SDCARD_ERR_TIMEOUT);
    datapath_reset(dev);
    alt_irq_enable_all(ctx);
}

void alt_sdcard_set_event_handler(alt_sdcard_dev *dev,
        void (*handler)(alt_sdcard_dev *dev, alt_u32 irq_status))
{
    alt_irq_context ctx;
    alt_u32         en;

    if (dev == 0) return;
    dev->on_event = handler;

    /* With the interrupts held off, for the reason given at async_irq(): the
     * ISR may be changing IRQ_ENABLE for a non-blocking transfer. */
    if (dev->has_card_detect && dev->irq != -1) {
        ctx = alt_irq_disable_all();
        en  = ALT_SDCARD_RD(dev->base, ALT_SDCARD_IRQ_ENABLE_OFST);
        if (handler) en |=  ALT_SDCARD_IRQ_CARD_MSK;
        else         en &= ~ALT_SDCARD_IRQ_CARD_MSK;
        ALT_SDCARD_WR_IRQ_ENABLE(dev->base, en);
        alt_irq_enable_all(ctx);
    }
}
