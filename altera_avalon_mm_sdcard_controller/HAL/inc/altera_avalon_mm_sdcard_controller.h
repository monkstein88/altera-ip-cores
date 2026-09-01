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
 * cannot boot without a card present. Call alt_sdcard_probe() when you are
 * ready to use the card.
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
    ALT_SDCARD_ERR_NO_CARD   = -1,  /* card-detect says the socket is empty   */
    ALT_SDCARD_ERR_TIMEOUT   = -2,  /* the card stopped answering             */
    ALT_SDCARD_ERR_CRC       = -3,  /* command or data CRC rejected           */
    ALT_SDCARD_ERR_UNUSABLE  = -4,  /* not an SD card, or wrong voltage       */
    ALT_SDCARD_ERR_WRITE     = -5,  /* the card refused a written block       */
    ALT_SDCARD_ERR_PARAM     = -6,  /* bad argument from the caller           */
    ALT_SDCARD_ERR_NOT_READY = -7,  /* probe() has not run, or it failed      */
    ALT_SDCARD_ERR_VERSION   = -8,  /* CORE_INFO is not a version we know     */
    ALT_SDCARD_ERR_PROTECTED = -9   /* write-protect switch is set            */
} alt_sdcard_result;

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
        0u                                                                    \
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
 * Safe to call again to re-probe after a card change. */
int alt_sdcard_probe(alt_sdcard_dev *dev);

/* Block access. `block` is a 512-byte block number in both cases - the driver
 * converts to a byte address for standard-capacity cards, which is the whole
 * reason the caller does not have to care which kind of card is fitted.
 *
 * `buf` must be 32-bit aligned when the DMA is in use. */
int alt_sdcard_read_blocks (alt_sdcard_dev *dev, alt_u32 block,
                            void *buf, alt_u32 count);
int alt_sdcard_write_blocks(alt_sdcard_dev *dev, alt_u32 block,
                            const void *buf, alt_u32 count);

/* Raw command access, for anything the block API does not cover. */
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

/* Install a callback invoked from the ISR with the latched IRQ_STATUS. */
void alt_sdcard_set_event_handler(alt_sdcard_dev *dev,
        void (*handler)(alt_sdcard_dev *dev, alt_u32 irq_status));

#ifdef __cplusplus
}
#endif

#endif /* __ALTERA_AVALON_MM_SDCARD_CONTROLLER_H__ */
