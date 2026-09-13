/* =============================================================================
 * altera_avalon_mm_sdcard_controller.h
 *
 * Nios II HAL driver for the Avalon-MM SD Card Controller (SPI).
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS DRIVER IS FOR
 * ---------------------------------------------------------------------------
 * The hardware does the SPI link layer: framing, CRC7 and CRC16, tokens, bus
 * timing, multi-block streaming, busy polling and DMA. It does NOT do the card
 * protocol, and that division is deliberate.
 *
 * Everything below the line - the identification sequence, deciding whether a
 * card is v1.x or v2.00, byte versus block addressing, parsing the CSD for
 * capacity, the retry policy for ACMD41 - is where every SD implementation
 * accumulates its card-specific workarounds. Those belong in software, because
 * a workaround here is a recompile and a workaround in the RTL is a new
 * bitstream.
 *
 * ---------------------------------------------------------------------------
 * WHAT alt_sys_init() DOES AND DOES NOT DO
 * ---------------------------------------------------------------------------
 * The _sw.tcl sets auto_initialize, so the BSP constructs every instance in
 * alt_sys_init.c and calls alt_sdcard_init() before main(). That establishes
 * the base address and interrupt from system.h, checks CORE_INFO against the
 * version this driver was written for, and registers the ISR.
 *
 * It does NOT identify the card. Identification takes hundreds of milliseconds
 * in the worst case (the specification allows a full second for ACMD41), it can
 * fail for reasons the application needs to know about, and there may be no
 * card in the socket. Doing it before main() would mean an application that
 * cannot boot without a card present.
 *
 * ---------------------------------------------------------------------------
 * USING IT
 * ---------------------------------------------------------------------------
 * The block calls identify the card themselves the first time they need to, so
 * the shortest correct program is a read:
 *
 *     alt_sdcard_read_blocks(&sdcard, 0, buf, 1);
 *
 * alt_sdcard_probe() does the same thing explicitly, for an application that
 * wants the identification - and its failure - at a moment of its choosing.
 *
 * ---------------------------------------------------------------------------
 * CARD CHANGES
 * ---------------------------------------------------------------------------
 * A card can be pulled and another fitted between any two calls, and the new
 * one may be a different capacity class - which changes the unit a block
 * number is sent in. So the driver never carries an identification across a
 * change it can see:
 *
 *   - with a card-detect switch, the latched CARD_INSERT / CARD_REMOVE events
 *     and the switch itself are checked at the start of every call, including
 *     events an interrupt handler has already acknowledged;
 *   - without one, a card that stops answering is taken to be gone - a card
 *     swapped in behind the driver's back is still in SD mode and cannot
 *     answer - and alt_sdcard_poll() asks the card directly.
 *
 * The call that discovers a change fails with ALT_SDCARD_ERR_CHANGED, or
 * ALT_SDCARD_ERR_NO_CARD if the socket is empty, and the next call identifies
 * whatever is there. Failing once is deliberate: a caller holding anything it
 * learned from the old card - a filesystem's allocation tables, say - must not
 * have its next write land on the new card. `generation` counts successful
 * identifications, for callers that would rather compare than catch the error;
 * the FatFs glue in software/fatfs uses exactly that.
 *
 * ---------------------------------------------------------------------------
 * RETRIES
 * ---------------------------------------------------------------------------
 * A CRC error means the link corrupted something, not that the card refused:
 * a command whose CRC fails is not executed, a block whose CRC16 fails is
 * read again, and a written block the card rejected on CRC was never
 * programmed. Those are retried, up to `retries` times, inside the block calls,
 * alt_sdcard_probe() and alt_sdcard_poll(). Nothing else is. A timeout, a
 * card-reported error or a write the card refused for any other reason is
 * returned to the caller at once, and alt_sdcard_command() retries nothing.
 * ===========================================================================*/

#ifndef __ALTERA_AVALON_MM_SDCARD_CONTROLLER_H__
#define __ALTERA_AVALON_MM_SDCARD_CONTROLLER_H__

#include "alt_types.h"
#include "sys/alt_dev.h"
#include "altera_avalon_mm_sdcard_controller_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------- results ---- */

typedef enum
{
    ALT_SDCARD_OK            =  0,
    ALT_SDCARD_ERR_NO_CARD   = -1,  /* card-detect says the socket is empty,
                                       or without it nothing answered CMD0    */
    ALT_SDCARD_ERR_TIMEOUT   = -2,  /* the card stopped answering             */
    ALT_SDCARD_ERR_CRC       = -3,  /* command or data CRC rejected           */
    ALT_SDCARD_ERR_UNUSABLE  = -4,  /* not an SD card, or wrong voltage       */
    ALT_SDCARD_ERR_WRITE     = -5,  /* the card refused a written block       */
    ALT_SDCARD_ERR_PARAM     = -6,  /* bad argument from the caller           */
    ALT_SDCARD_ERR_NOT_READY = -7,  /* probe() has not run, or it failed      */
    ALT_SDCARD_ERR_VERSION   = -8,  /* CORE_INFO is not a version we know     */
    ALT_SDCARD_ERR_PROTECTED = -9,  /* write-protect switch is set            */
    ALT_SDCARD_ERR_PIO       = -10, /* a DATA access the buffer could not serve*/
    ALT_SDCARD_ERR_CHANGED   = -11  /* the card was removed or replaced since
                                       it was identified; call again          */
} alt_sdcard_result;

/* Instances alt_sdcard_instance() can find. */
#define ALT_SDCARD_MAX_INSTANCES (4u)

/* For alt_sdcard_command(): pick the response format from the command index,
 * so a caller need not know that CMD13 answers R2 and CMD38 R1b. */
#define ALT_SDCARD_RESP_AUTO     (0xFFFFFFFFu)

/* -------------------------------------------------------------- card ------ */

typedef enum
{
    ALT_SDCARD_TYPE_NONE = 0,
    ALT_SDCARD_TYPE_SDSC,     /* v1.x or v2 standard capacity: BYTE addressed */
    ALT_SDCARD_TYPE_SDHC      /* v2 high capacity:            BLOCK addressed */
} alt_sdcard_type;

typedef struct alt_sdcard_dev_s
{
    /* ---- from system.h, filled in by the _INSTANCE macro ---- */
    alt_u32          base;
    alt_32           irq_controller_id;   /* -1 if the interrupt is unconnected */
    alt_32           irq;                 /* -1 if the interrupt is unconnected */
    const char      *name;

    /* ---- learned at probe() ---- */
    alt_sdcard_type  type;
    alt_u32          blocks;              /* capacity, in 512-byte blocks       */
    alt_u32          ocr;
    alt_u8           cid[16];
    alt_u8           csd[16];

    /* ---- configuration ---- */
    alt_u32          clkdiv_id;           /* divider for identification (~400 kHz) */
    alt_u32          clkdiv_run;          /* divider once the card is up           */
    alt_u8           sample_dly;          /* 0..CLKDIV_RUN-2; see the regs header  */
    alt_u32          timeout_cycles;
    int              use_dma;             /* honoured only if CORE_INFO says so    */

    /* ---- learned from CORE_INFO ---- */
    alt_u32          version;
    alt_u32          fifo_bytes;
    int              has_dma;
    int              has_card_detect;

    /* ---- statistics, useful when a card is marginal ---- */
    alt_u32          cmd_count;
    alt_u32          retry_count;
    alt_u32          crc_error_count;
    alt_u32          timeout_count;

    /* ---- optional application callback, called from the ISR ---- */
    void           (*on_event)(struct alt_sdcard_dev_s *dev, alt_u32 irq_status);
    volatile alt_u32 last_irq_status;

    /* ---- card changes and retries. Appended here, at the end, because
     *      _INSTANCE initialises this structure by position: a field inserted
     *      anywhere else would silently shift every value after it ---- */
    alt_u32          retries;             /* extra attempts after a CRC error   */
    alt_u32          generation;          /* successful identifications so far  */
    volatile alt_u32 isr_card_events;     /* card-detect edges the ISR took     */
    alt_u32          card_events_seen;    /* ...of which already acted upon     */
    volatile alt_u32 isr_status;          /* other bits the ISR acknowledged    */
} alt_sdcard_dev;

/* -----------------------------------------------------------------------
 * BSP integration.
 *
 * These two macro names are dictated by the component's hw_class_name and are
 * what nios2-bsp-generate-files emits into alt_sys_init.c. They must match
 * exactly; a mismatch produces no code and no diagnostic.
 * ----------------------------------------------------------------------- */

#define ALTERA_AVALON_MM_SDCARD_CONTROLLER_INSTANCE(name, dev)                \
    alt_sdcard_dev dev = {                                                    \
        name##_BASE,                                                          \
        name##_IRQ_INTERRUPT_CONTROLLER_ID,                                   \
        name##_IRQ,                                                           \
        #name,                                                                \
        ALT_SDCARD_TYPE_NONE,                                                 \
        0u, 0u, {0}, {0},                                                     \
        125u,          /* ~400 kHz from a 100 MHz clock */                    \
        2u,            /* 25 MHz  from a 100 MHz clock */                     \
        0u,                                                                   \
        0x02000000u,                                                          \
        1,                                                                    \
        0u, 0u, 0, 0,                                                         \
        0u, 0u, 0u, 0u,                                                       \
        (void (*)(struct alt_sdcard_dev_s *, alt_u32))0,                      \
        0u,                                                                   \
        2u,            /* retries */                                          \
        0u, 0u, 0u, 0u                                                        \
    }

#define ALTERA_AVALON_MM_SDCARD_CONTROLLER_INIT(name, dev)                    \
    alt_sdcard_init(&dev)

/* -----------------------------------------------------------------------
 * API
 * ----------------------------------------------------------------------- */

/* Bind to the hardware: check CORE_INFO, learn the build-time configuration,
 * register the ISR, leave the core disabled. Called from alt_sys_init(). */
int alt_sdcard_init(alt_sdcard_dev *dev);

/* Run the identification sequence and leave the card ready for block access.
 * The block calls do this themselves when they need to; call it directly to
 * choose when it happens, or to re-identify on demand. */
int alt_sdcard_probe(alt_sdcard_dev *dev);

/* Block access. `block` is a 512-byte block number in both cases - the driver
 * converts to a byte address for standard-capacity cards, which is the whole
 * reason the caller does not have to care which kind of card is fitted.
 *
 * Any buffer works. A word-aligned one is moved by the DMA in a single
 * multi-block stream; a misaligned one, which the DMA cannot address, goes a
 * block at a time through a bounce buffer on the stack - correct, and slower.
 * Either way the buffer must be memory the DMA master can reach. */
int alt_sdcard_read_blocks (alt_sdcard_dev *dev, alt_u32 block,
                            void *buf, alt_u32 count);
int alt_sdcard_write_blocks(alt_sdcard_dev *dev, alt_u32 block,
                            const void *buf, alt_u32 count);

/* Has anything changed that the driver can see without asking the card?
 *
 *   ALT_SDCARD_OK            a card is identified, and nothing says otherwise
 *   ALT_SDCARD_ERR_NO_CARD   the socket is empty (card-detect builds only)
 *   ALT_SDCARD_ERR_CHANGED   the identified card was removed or replaced -
 *                            reported once; it is forgotten, as the next block
 *                            call would forget it
 *   ALT_SDCARD_ERR_NOT_READY a card may be present, but none is identified
 *
 * Sends nothing: it reads the socket switch and consumes the latched
 * insert/remove events, so it is cheap enough to call before every operation,
 * which is what a filesystem does. Without a switch there is nothing to read,
 * and it reports only what an earlier transfer already found out. */
int alt_sdcard_check(alt_sdcard_dev *dev);

/* alt_sdcard_check(), and then - if a card is identified - is it answering?
 *
 * Returns what alt_sdcard_check() does, or the result of CMD13 when that
 * found nothing wrong: any failure means the card stopped answering, and it is
 * no longer considered identified. Without a card-detect switch this is the
 * only way to find out before a transfer does. The hardware's pre-emptive busy
 * check means it also returns only once a write in progress has been
 * programmed. Never identifies a card itself. */
int alt_sdcard_poll(alt_sdcard_dev *dev);

/* Successful identifications since init. Changes exactly when a different
 * card - or the same one, re-identified - is behind the block calls. */
alt_u32 alt_sdcard_generation(alt_sdcard_dev *dev);

/* The n-th instance in alt_sys_init() order, or 0. For code that is not handed
 * a device - a filesystem glue layer, say - in a system with one controller. */
alt_sdcard_dev *alt_sdcard_instance(unsigned n);

/* Raw command access, for anything the block API does not cover.
 *
 * `resp_type` is one of ALT_SDCARD_RESP_R1 / _R1B / _R2 / _R3R7, or
 * ALT_SDCARD_RESP_AUTO to take it from the command index. Nothing is retried
 * here: after CMD55, repeating a failed application command would send it
 * again as the ordinary command with the same number, which for ACMD23 and
 * ACMD42 is a different command altogether. */
int alt_sdcard_command(alt_sdcard_dev *dev, alt_u8 index, alt_u32 arg,
                       alt_u32 resp_type, alt_u32 extra_cmd_bits,
                       alt_u32 *resp0, alt_u32 *resp1);

/* Present / write-protected. Both read 1 / 0 when the core was built without
 * card detect, so an application need not special-case that. */
int alt_sdcard_present(alt_sdcard_dev *dev);
int alt_sdcard_write_protected(alt_sdcard_dev *dev);

/* Capacity in 512-byte blocks, 0 if the card has not been probed. */
alt_u32 alt_sdcard_block_count(alt_sdcard_dev *dev);

/* Clear a wedged data path without losing the card's initialised state. */
void alt_sdcard_reset_datapath(alt_sdcard_dev *dev);

/* Install a callback invoked from the ISR with the bits that raised it.
 *
 * On a core with card detect and a connected interrupt, installing a handler
 * enables the CARD_INSERT and CARD_REMOVE interrupts, and removing it (0)
 * disables them: a handler for events that can never arrive is a handler that
 * silently does nothing. Other sources stay as the application set them. The
 * ISR acknowledges only enabled bits, so enabling one never hides it from the
 * driver's own completion polling. */
void alt_sdcard_set_event_handler(alt_sdcard_dev *dev,
        void (*handler)(alt_sdcard_dev *dev, alt_u32 irq_status));

#ifdef __cplusplus
}
#endif

#endif /* __ALTERA_AVALON_MM_SDCARD_CONTROLLER_H__ */
