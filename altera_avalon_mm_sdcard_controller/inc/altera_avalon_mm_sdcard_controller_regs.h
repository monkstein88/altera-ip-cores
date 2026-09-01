/* =============================================================================
 * altera_avalon_mm_sdcard_controller_regs.h
 *
 * Register map for the Avalon-MM SD Card Controller (SPI), v1.0.
 *
 * This header is the low level: offsets, accessors and bit masks, and nothing
 * else. It depends only on <io.h>, so it is usable from a bare-metal
 * application, from an interrupt handler, or from a BSP with no HAL driver at
 * all. The driver in HAL/ is built on top of it.
 *
 * ---------------------------------------------------------------------------
 * BYTE OFFSETS vs WORD ADDRESSES
 * ---------------------------------------------------------------------------
 * The csr port is WORD-addressed in hardware - Platform Designer's default
 * addressUnits for an Avalon-MM agent - so the RTL decodes address 0,1,2,...
 * The interconnect converts, and software sees byte offsets 0x00,0x04,0x08,...
 *
 * Both are given below. The *_OFST macros are byte offsets, which is what the
 * IORD_32DIRECT/IOWR_32DIRECT accessors take and what the documentation
 * quotes. The *_REG macros are the word indices the RTL decodes, provided
 * because they are what you will see in a simulation waveform and because
 * getting the factor of four wrong is the easiest mistake to make with this
 * core.
 *
 * The accessors use IORD_32DIRECT rather than IORD, deliberately: IORD scales
 * its argument by SYSTEM_BUS_WIDTH, so it would silently do the wrong thing on
 * a system whose native word is not 32 bits. Every register here is 32 bits
 * wide regardless.
 *
 * ---------------------------------------------------------------------------
 * NAMING
 * ---------------------------------------------------------------------------
 * Register and field macros use the short ALT_SDCARD_ prefix for legibility.
 * The two macros the BSP generator emits into alt_sys_init.c - _INSTANCE and
 * _INIT - must instead match the component's hw_class_name exactly, so they
 * carry the full ALTERA_AVALON_MM_SDCARD_CONTROLLER_ prefix. That mismatch is
 * deliberate and load-bearing: get the long ones wrong and the BSP silently
 * generates nothing, which looks exactly like the driver having no effect.
 * ===========================================================================*/

#ifndef __ALTERA_AVALON_MM_SDCARD_CONTROLLER_REGS_H__
#define __ALTERA_AVALON_MM_SDCARD_CONTROLLER_REGS_H__

#include <io.h>

/* ------------------------------------------------- register word indices -- */

#define ALT_SDCARD_CTRL_REG            0
#define ALT_SDCARD_STATUS_REG          1
#define ALT_SDCARD_IRQ_ENABLE_REG      2
#define ALT_SDCARD_IRQ_STATUS_REG      3
#define ALT_SDCARD_CLKDIV_REG          4
#define ALT_SDCARD_TIMEOUT_REG         5
#define ALT_SDCARD_CMD_ARG_REG         6
#define ALT_SDCARD_CMD_REG             7
#define ALT_SDCARD_RESP0_REG           8
#define ALT_SDCARD_RESP1_REG           9
#define ALT_SDCARD_BLK_SIZE_REG        10
#define ALT_SDCARD_BLK_COUNT_REG       11
#define ALT_SDCARD_DMA_ADDR_REG        12
#define ALT_SDCARD_DMA_CTRL_REG        13
#define ALT_SDCARD_DATA_REG            14
#define ALT_SDCARD_ERR_INFO_REG        15
#define ALT_SDCARD_CORE_INFO_REG       16

/* ------------------------------------------------------- byte offsets ----- */

#define ALT_SDCARD_CTRL_OFST           0x00
#define ALT_SDCARD_STATUS_OFST         0x04
#define ALT_SDCARD_IRQ_ENABLE_OFST     0x08
#define ALT_SDCARD_IRQ_STATUS_OFST     0x0C
#define ALT_SDCARD_CLKDIV_OFST         0x10
#define ALT_SDCARD_TIMEOUT_OFST        0x14
#define ALT_SDCARD_CMD_ARG_OFST        0x18
#define ALT_SDCARD_CMD_OFST            0x1C
#define ALT_SDCARD_RESP0_OFST          0x20
#define ALT_SDCARD_RESP1_OFST          0x24
#define ALT_SDCARD_BLK_SIZE_OFST       0x28
#define ALT_SDCARD_BLK_COUNT_OFST      0x2C
#define ALT_SDCARD_DMA_ADDR_OFST       0x30
#define ALT_SDCARD_DMA_CTRL_OFST       0x34
#define ALT_SDCARD_DATA_OFST           0x38
#define ALT_SDCARD_ERR_INFO_OFST       0x3C
#define ALT_SDCARD_CORE_INFO_OFST      0x40

#define ALT_SDCARD_SPAN                0x44

/* ------------------------------------------------------------ accessors --- */

#define ALT_SDCARD_RD(base, ofst)        IORD_32DIRECT((base), (ofst))
#define ALT_SDCARD_WR(base, ofst, data)  IOWR_32DIRECT((base), (ofst), (data))

#define ALT_SDCARD_RD_CTRL(base)         ALT_SDCARD_RD(base, ALT_SDCARD_CTRL_OFST)
#define ALT_SDCARD_WR_CTRL(base, d)      ALT_SDCARD_WR(base, ALT_SDCARD_CTRL_OFST, d)
#define ALT_SDCARD_RD_STATUS(base)       ALT_SDCARD_RD(base, ALT_SDCARD_STATUS_OFST)
#define ALT_SDCARD_RD_IRQ_STATUS(base)   ALT_SDCARD_RD(base, ALT_SDCARD_IRQ_STATUS_OFST)
#define ALT_SDCARD_WR_IRQ_STATUS(base,d) ALT_SDCARD_WR(base, ALT_SDCARD_IRQ_STATUS_OFST, d)
#define ALT_SDCARD_WR_IRQ_ENABLE(base,d) ALT_SDCARD_WR(base, ALT_SDCARD_IRQ_ENABLE_OFST, d)
#define ALT_SDCARD_RD_RESP0(base)        ALT_SDCARD_RD(base, ALT_SDCARD_RESP0_OFST)
#define ALT_SDCARD_RD_RESP1(base)        ALT_SDCARD_RD(base, ALT_SDCARD_RESP1_OFST)
#define ALT_SDCARD_RD_ERR_INFO(base)     ALT_SDCARD_RD(base, ALT_SDCARD_ERR_INFO_OFST)
#define ALT_SDCARD_RD_CORE_INFO(base)    ALT_SDCARD_RD(base, ALT_SDCARD_CORE_INFO_OFST)

/* -------------------------------------------------------------- CTRL ------ */

#define ALT_SDCARD_CTRL_ENABLE_MSK     (0x00000001u)
#define ALT_SDCARD_CTRL_CS_MANUAL_MSK  (0x00000002u)
#define ALT_SDCARD_CTRL_CS_VALUE_MSK   (0x00000004u)
#define ALT_SDCARD_CTRL_CRC_EN_MSK     (0x00000008u)
#define ALT_SDCARD_CTRL_DMA_EN_MSK     (0x00000010u)
#define ALT_SDCARD_CTRL_CLK_RUN_MSK    (0x00000020u)

/* Software reset, one bit per domain. None clear configuration, so a wedged
 * data phase can be cleared without losing the card's initialised state. */
#define ALT_SDCARD_CTRL_SRST_CMD_MSK   (0x00000100u)
#define ALT_SDCARD_CTRL_SRST_DAT_MSK   (0x00000200u)
#define ALT_SDCARD_CTRL_SRST_ALL_MSK   (0x00000400u)

/* ------------------------------------------------------------ STATUS ------ */

#define ALT_SDCARD_STAT_CMD_BUSY_MSK   (0x00000001u)
#define ALT_SDCARD_STAT_DAT_BUSY_MSK   (0x00000002u)
#define ALT_SDCARD_STAT_DMA_BUSY_MSK   (0x00000004u)
#define ALT_SDCARD_STAT_CARD_BUSY_MSK  (0x00000008u)
#define ALT_SDCARD_STAT_FIFO_EMPTY_MSK (0x00000010u)
#define ALT_SDCARD_STAT_FIFO_FULL_MSK  (0x00000020u)
#define ALT_SDCARD_STAT_LEVEL_MSK      (0x00FFFF00u)   /* bytes held */
#define ALT_SDCARD_STAT_LEVEL_OFST_B   (8)
#define ALT_SDCARD_STAT_CARD_PRES_MSK  (0x01000000u)
#define ALT_SDCARD_STAT_CARD_WP_MSK    (0x02000000u)
#define ALT_SDCARD_STAT_ERROR_MSK      (0x80000000u)

/* ---------------------------------------- IRQ_ENABLE / IRQ_STATUS --------- */
/* One layout for both. IRQ_STATUS records every event unconditionally and is
 * write-1-to-clear; IRQ_ENABLE gates only whether the pin is driven, so
 * polling works whatever the mask says. */

#define ALT_SDCARD_IRQ_CMD_DONE_MSK    (0x00000001u)
#define ALT_SDCARD_IRQ_DATA_DONE_MSK   (0x00000002u)
#define ALT_SDCARD_IRQ_DMA_DONE_MSK    (0x00000004u)

#define ALT_SDCARD_IRQ_ERR_CMD_TMO_MSK   (0x00000100u)
#define ALT_SDCARD_IRQ_ERR_CMD_CRC_MSK   (0x00000200u)
#define ALT_SDCARD_IRQ_ERR_CMD_ILL_MSK   (0x00000400u)
#define ALT_SDCARD_IRQ_ERR_DAT_TMO_MSK   (0x00000800u)
#define ALT_SDCARD_IRQ_ERR_DAT_CRC_MSK   (0x00001000u)
#define ALT_SDCARD_IRQ_ERR_DAT_TOKEN_MSK (0x00002000u)
#define ALT_SDCARD_IRQ_ERR_WRITE_MSK     (0x00004000u)
#define ALT_SDCARD_IRQ_ERR_DMA_MSK       (0x00008000u)
#define ALT_SDCARD_IRQ_CARD_INSERT_MSK   (0x00010000u)
#define ALT_SDCARD_IRQ_CARD_REMOVE_MSK   (0x00020000u)

#define ALT_SDCARD_IRQ_ERR_MSK           (0x0003FF00u)

/* ------------------------------------------------------------ CLKDIV ------ */
/* SPI clock = clk / (2 * CLKDIV). SAMPLE_DLY delays MISO capture by N system
 * clocks and is bounded by SAMPLE_DLY <= CLKDIV - 2: beyond that the sample
 * lands on the next bit and every byte of the transfer shifts. At CLKDIV 1
 * and 2 the only legal delay is zero. */
#define ALT_SDCARD_CLKDIV_DIV_MSK      (0x000000FFu)
#define ALT_SDCARD_CLKDIV_SMPL_MSK     (0x00070000u)
#define ALT_SDCARD_CLKDIV_SMPL_OFST_B  (16)

#define ALT_SDCARD_CLKDIV_MAKE(div, dly) \
    (((div) & ALT_SDCARD_CLKDIV_DIV_MSK) | \
     (((dly) << ALT_SDCARD_CLKDIV_SMPL_OFST_B) & ALT_SDCARD_CLKDIV_SMPL_MSK))

/* --------------------------------------------------------------- CMD ------ */

#define ALT_SDCARD_CMD_INDEX_MSK       (0x0000003Fu)
#define ALT_SDCARD_CMD_RESP_MSK        (0x000000C0u)
#define ALT_SDCARD_CMD_RESP_OFST_B     (6)
#define ALT_SDCARD_CMD_DATA_EN_MSK     (0x00000100u)
#define ALT_SDCARD_CMD_DATA_DIR_MSK    (0x00000200u)  /* 1 = host -> card */
#define ALT_SDCARD_CMD_MULTI_MSK       (0x00000400u)
#define ALT_SDCARD_CMD_AUTO_STOP_MSK   (0x00000800u)
#define ALT_SDCARD_CMD_START_MSK       (0x80000000u)

/* Response formats, CMD[7:6]. */
#define ALT_SDCARD_RESP_R1             (0)
#define ALT_SDCARD_RESP_R1B            (1)
#define ALT_SDCARD_RESP_R2             (2)
#define ALT_SDCARD_RESP_R3R7           (3)

/* ---------------------------------------------------------- ERR_INFO ------ */

#define ALT_SDCARD_ERR_DATRESP_MSK     (0x000000FFu)
#define ALT_SDCARD_ERR_R1_MSK          (0x0000FF00u)
#define ALT_SDCARD_ERR_R1_OFST_B       (8)
#define ALT_SDCARD_ERR_DATERR_MSK      (0x00FF0000u)
#define ALT_SDCARD_ERR_DATERR_OFST_B   (16)
#define ALT_SDCARD_ERR_PHASE_MSK       (0x0F000000u)
#define ALT_SDCARD_ERR_PHASE_OFST_B    (24)

/* --------------------------------------------------------- CORE_INFO ------ */

#define ALT_SDCARD_INFO_VER_MINOR_MSK  (0x000000FFu)
#define ALT_SDCARD_INFO_VER_MAJOR_MSK  (0x0000FF00u)
#define ALT_SDCARD_INFO_VER_MAJOR_OFST_B (8)
#define ALT_SDCARD_INFO_FIFO_LOG2_MSK  (0x00FF0000u)
#define ALT_SDCARD_INFO_FIFO_LOG2_OFST_B (16)
#define ALT_SDCARD_INFO_HAS_DMA_MSK    (0x01000000u)
#define ALT_SDCARD_INFO_HAS_CD_MSK     (0x02000000u)
#define ALT_SDCARD_INFO_PHY_SPI_MSK    (0x04000000u)

/* ------------------------------------------------ SD protocol constants --- */
/* Here rather than in the driver so an application that bypasses the HAL layer
 * still has them, and so there is exactly one definition of each. */

#define ALT_SDCARD_R1_IDLE             (0x01u)
#define ALT_SDCARD_R1_ERASE_RESET      (0x02u)
#define ALT_SDCARD_R1_ILLEGAL_CMD      (0x04u)
#define ALT_SDCARD_R1_COM_CRC_ERR      (0x08u)
#define ALT_SDCARD_R1_ERASE_SEQ_ERR    (0x10u)
#define ALT_SDCARD_R1_ADDRESS_ERR      (0x20u)
#define ALT_SDCARD_R1_PARAM_ERR        (0x40u)

#define ALT_SDCARD_OCR_CCS             (0x40000000u)  /* block addressing */
#define ALT_SDCARD_OCR_BUSY            (0x80000000u)  /* power-up complete */

#define ALT_SDCARD_CMD8_ARG            (0x000001AAu)
#define ALT_SDCARD_ACMD41_HCS          (0x40000000u)

#endif /* __ALTERA_AVALON_MM_SDCARD_CONTROLLER_REGS_H__ */
