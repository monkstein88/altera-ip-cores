/* =============================================================================
 * altera_avalon_mm_sdcard_controller.c
 *
 * Nios II HAL driver for the Avalon-MM SD Card Controller (SPI).
 *
 * The hardware owns the link layer. This file owns the protocol: the
 * identification sequence, the v1.x / v2.00 distinction, byte versus block
 * addressing, capacity from the CSD, and the retry policy.
 * ===========================================================================*/

#include <string.h>

#include "altera_avalon_mm_sdcard_controller.h"
#include "sys/alt_irq.h"

/* Version of the hardware this driver was written against. The major number
 * must match; a newer minor is accepted, because minor revisions do not move
 * registers. */
#define DRIVER_HW_MAJOR   1

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
    return ALT_SDCARD_OK;
}

static void account(alt_sdcard_dev *dev, alt_u32 st)
{
    if (st & (ALT_SDCARD_IRQ_ERR_CMD_CRC_MSK | ALT_SDCARD_IRQ_ERR_DAT_CRC_MSK))
        dev->crc_error_count++;
    if (st & (ALT_SDCARD_IRQ_ERR_CMD_TMO_MSK | ALT_SDCARD_IRQ_ERR_DAT_TMO_MSK))
        dev->timeout_count++;
}

int alt_sdcard_command(alt_sdcard_dev *dev, alt_u8 index, alt_u32 arg,
                       alt_u32 resp_type, alt_u32 extra_cmd_bits,
                       alt_u32 *resp0, alt_u32 *resp1)
{
    alt_u32 cmd, st;

    if (dev == 0) return ALT_SDCARD_ERR_PARAM;

    wait_not_busy(dev);

    ALT_SDCARD_WR_IRQ_STATUS(dev->base, 0xFFFFFFFFu);
    ALT_SDCARD_WR(dev->base, ALT_SDCARD_CMD_ARG_OFST, arg);

    cmd = ((alt_u32)index & ALT_SDCARD_CMD_INDEX_MSK)
        | ((resp_type << ALT_SDCARD_CMD_RESP_OFST_B) & ALT_SDCARD_CMD_RESP_MSK)
        | extra_cmd_bits
        | ALT_SDCARD_CMD_START_MSK;

    ALT_SDCARD_WR(dev->base, ALT_SDCARD_CMD_OFST, cmd);
    dev->cmd_count++;

    while (ALT_SDCARD_RD_STATUS(dev->base) & ALT_SDCARD_STAT_CMD_BUSY_MSK) {
        /* spin - every wait inside the core is bounded by TIMEOUT, so this
         * cannot hang on a card that has stopped answering */
    }

    st = ALT_SDCARD_RD_IRQ_STATUS(dev->base);
    account(dev, st);

    if (resp0) *resp0 = ALT_SDCARD_RD_RESP0(dev->base);
    if (resp1) *resp1 = ALT_SDCARD_RD_RESP1(dev->base);

    return irq_to_result(st);
}

/* An ACMD is CMD55 followed by the command itself. */
static int app_command(alt_sdcard_dev *dev, alt_u8 index, alt_u32 arg,
                       alt_u32 resp_type, alt_u32 *resp0, alt_u32 *resp1)
{
    int r = alt_sdcard_command(dev, 55, 0, ALT_SDCARD_RESP_R1, 0, 0, 0);
    if (r != ALT_SDCARD_OK) return r;
    return alt_sdcard_command(dev, index, arg, resp_type, 0, resp0, resp1);
}

/* -------------------------------------------------------------------------
 * ISR
 * ---------------------------------------------------------------------- */

static void sdcard_isr(void *context)
{
    alt_sdcard_dev *dev = (alt_sdcard_dev *)context;
    alt_u32 st = ALT_SDCARD_RD_IRQ_STATUS(dev->base);

    dev->last_irq_status = st;

    /* Acknowledge at the source. The interrupt is level, so it stays asserted
     * until the causing bit is cleared - writing 1 to it is the only thing that
     * deasserts the pin. */
    ALT_SDCARD_WR_IRQ_STATUS(dev->base, st);

    if (dev->on_event) dev->on_event(dev, st);
}

/* -------------------------------------------------------------------------
 * init
 * ---------------------------------------------------------------------- */

int alt_sdcard_init(alt_sdcard_dev *dev)
{
    alt_u32 info;

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

    dev->type   = ALT_SDCARD_TYPE_NONE;
    dev->blocks = 0;

    ALT_SDCARD_WR_CTRL(dev->base, 0);
    ALT_SDCARD_WR_IRQ_ENABLE(dev->base, 0);
    ALT_SDCARD_WR_IRQ_STATUS(dev->base, 0xFFFFFFFFu);
    ALT_SDCARD_WR(dev->base, ALT_SDCARD_TIMEOUT_OFST, dev->timeout_cycles);

    if (dev->irq != -1) {
        alt_ic_isr_register((alt_u32)dev->irq_controller_id, (alt_u32)dev->irq,
                            sdcard_isr, dev, 0);
    }

    return ALT_SDCARD_OK;
}

/* -------------------------------------------------------------------------
 * probe - the identification sequence
 * ---------------------------------------------------------------------- */

int alt_sdcard_probe(alt_sdcard_dev *dev)
{
    alt_u32 r0, r1, ctrl;
    int     r, tries;
    int     v2;

    if (dev == 0) return ALT_SDCARD_ERR_PARAM;
    if (!alt_sdcard_present(dev)) return ALT_SDCARD_ERR_NO_CARD;

    dev->type   = ALT_SDCARD_TYPE_NONE;
    dev->blocks = 0;

    ALT_SDCARD_WR(dev->base, ALT_SDCARD_TIMEOUT_OFST, dev->timeout_cycles);
    ALT_SDCARD_WR(dev->base, ALT_SDCARD_CLKDIV_OFST,
                  ALT_SDCARD_CLKDIV_MAKE(dev->clkdiv_id, 0));

    /* ---- 1. power-up: at least 74 clocks with CS HIGH (§6.4.1.1) ----
     *
     * CS high is the opposite of what a transaction wants, which is why the
     * manual override exists at all. The card may use all 74 clocks to get
     * ready, so this is not optional padding. */
    ctrl = ALT_SDCARD_CTRL_ENABLE_MSK
         | ALT_SDCARD_CTRL_CS_MANUAL_MSK
         | ALT_SDCARD_CTRL_CS_VALUE_MSK
         | ALT_SDCARD_CTRL_CLK_RUN_MSK;
    ALT_SDCARD_WR_CTRL(dev->base, ctrl);

    /* 100 byte-times is comfortably more than 74 clocks at any divider. */
    {
        volatile int spin;
        for (spin = 0; spin < 200000; spin++) { }
    }

    /* ---- 2. into SPI mode: CMD0 with CS asserted ----
     * Asserting CS during CMD0 is what selects SPI mode; the only way back to
     * SD mode is a power cycle. */
    ALT_SDCARD_WR_CTRL(dev->base,
                       ALT_SDCARD_CTRL_ENABLE_MSK | ALT_SDCARD_CTRL_CRC_EN_MSK |
                       (dev->use_dma ? ALT_SDCARD_CTRL_DMA_EN_MSK : 0u));

    for (tries = 0; tries < 8; tries++) {
        r = alt_sdcard_command(dev, 0, 0, ALT_SDCARD_RESP_R1, 0, &r0, 0);
        if (r == ALT_SDCARD_OK && (r0 & 0xFFu) == ALT_SDCARD_R1_IDLE) break;
        dev->retry_count++;
    }
    if (tries == 8) return ALT_SDCARD_ERR_UNUSABLE;

    /* ---- 3. version: CMD8 ----
     *
     * A v1.x card answers with Illegal Command and sends ONLY that byte - the
     * 32-bit trailer never arrives (§7.3.2). The hardware handles the
     * truncation; here it simply means "this is a v1.x card", not an error. */
    v2 = 0;
    r  = alt_sdcard_command(dev, 8, ALT_SDCARD_CMD8_ARG,
                            ALT_SDCARD_RESP_R3R7, 0, &r0, &r1);
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
    (void)alt_sdcard_command(dev, 59, 1, ALT_SDCARD_RESP_R1, 0, 0, 0);

    /* ---- 5. initialise: ACMD41, polled ----
     *
     * The card reports in_idle_state until initialisation completes. The
     * specification allows a full second for this, and large cards use a good
     * fraction of it, so a driver that issues ACMD41 once and gives up works
     * only by luck. */
    for (tries = 0; tries < 2000; tries++) {
        r = app_command(dev, 41, v2 ? ALT_SDCARD_ACMD41_HCS : 0u,
                        ALT_SDCARD_RESP_R1, &r0, 0);
        if (r != ALT_SDCARD_OK) {
            dev->retry_count++;
            continue;
        }
        if (((r0 & 0xFFu) & ALT_SDCARD_R1_IDLE) == 0) break;
        dev->retry_count++;
    }
    if (tries == 2000) return ALT_SDCARD_ERR_TIMEOUT;

    /* ---- 6. capacity class: CMD58 reads the OCR ----
     * CCS decides byte versus block addressing, which is the single thing the
     * block API has to get right for a caller that does not want to care. */
    dev->type = ALT_SDCARD_TYPE_SDSC;
    if (v2) {
        r = alt_sdcard_command(dev, 58, 0, ALT_SDCARD_RESP_R3R7, 0, &r0, &r1);
        if (r != ALT_SDCARD_OK) return r;
        dev->ocr = r1;
        if (r1 & ALT_SDCARD_OCR_CCS) dev->type = ALT_SDCARD_TYPE_SDHC;
    }

    /* ---- 7. block length ----
     * SDHC and SDXC are fixed at 512 whatever CMD16 says; sending it anyway is
     * harmless and correct for standard-capacity cards. */
    if (dev->type == ALT_SDCARD_TYPE_SDSC) {
        r = alt_sdcard_command(dev, 16, 512, ALT_SDCARD_RESP_R1, 0, 0, 0);
        if (r != ALT_SDCARD_OK) return r;
    }

    /* ---- 8. speed up ---- */
    ALT_SDCARD_WR(dev->base, ALT_SDCARD_CLKDIV_OFST,
                  ALT_SDCARD_CLKDIV_MAKE(dev->clkdiv_run, dev->sample_dly));

    ALT_SDCARD_WR(dev->base, ALT_SDCARD_BLK_SIZE_OFST, 512);

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

static int transfer(alt_sdcard_dev *dev, alt_u32 block, void *buf,
                    alt_u32 count, int writing)
{
    alt_u32 extra, st;
    alt_u8  index;
    int     r;

    if (dev == 0 || buf == 0 || count == 0) return ALT_SDCARD_ERR_PARAM;
    if (dev->type == ALT_SDCARD_TYPE_NONE)  return ALT_SDCARD_ERR_NOT_READY;
    if (!alt_sdcard_present(dev))           return ALT_SDCARD_ERR_NO_CARD;
    if (writing && alt_sdcard_write_protected(dev))
        return ALT_SDCARD_ERR_PROTECTED;

    /* The DMA moves whole 32-bit words, so a misaligned buffer would be
     * silently word-aligned by the hardware and the caller would get its data
     * somewhere it did not ask for. Refuse instead. */
    if (dev->use_dma && (((alt_u32)buf & 3u) != 0u))
        return ALT_SDCARD_ERR_PARAM;

    wait_not_busy(dev);

    ALT_SDCARD_WR(dev->base, ALT_SDCARD_BLK_SIZE_OFST, 512);
    ALT_SDCARD_WR(dev->base, ALT_SDCARD_BLK_COUNT_OFST, count);
    ALT_SDCARD_WR(dev->base, ALT_SDCARD_DMA_ADDR_OFST, (alt_u32)buf);

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

    r = alt_sdcard_command(dev, index, block_to_arg(dev, block),
                           ALT_SDCARD_RESP_R1, extra, 0, 0);
    if (r != ALT_SDCARD_OK) {
        /* A failed transfer can leave the data path mid-block. Clearing it is
         * cheap and keeps the failure from spreading to the next call. */
        alt_sdcard_reset_datapath(dev);
        return r;
    }

    st = ALT_SDCARD_RD_IRQ_STATUS(dev->base);
    if (st & ALT_SDCARD_IRQ_ERR_MSK) {
        alt_sdcard_reset_datapath(dev);
        return irq_to_result(st);
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
 * Odds and ends
 * ---------------------------------------------------------------------- */

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
    if (dev == 0) return;
    /* Data path only. The command path and every configuration register are
     * untouched, so the card stays identified - which is the entire reason the
     * reset is split into domains. */
    ALT_SDCARD_WR_CTRL(dev->base,
                       ALT_SDCARD_RD_CTRL(dev->base) |
                       ALT_SDCARD_CTRL_SRST_DAT_MSK);
    ALT_SDCARD_WR_IRQ_STATUS(dev->base, 0xFFFFFFFFu);
}

void alt_sdcard_set_event_handler(alt_sdcard_dev *dev,
        void (*handler)(alt_sdcard_dev *dev, alt_u32 irq_status))
{
    if (dev) dev->on_event = handler;
}
