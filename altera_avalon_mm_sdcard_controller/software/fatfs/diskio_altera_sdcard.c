/* =============================================================================
 * diskio_altera_sdcard.c
 *
 * FatFs disk I/O for the Avalon-MM SD Card Controller: the five functions FatFs
 * calls - disk_status, disk_initialize, disk_read, disk_write, disk_ioctl -
 * implemented on the HAL driver's block API. FatFs itself is not included; get
 * it from elm-chan.org (R0.14 or later, for LBA_t).
 *
 * ---------------------------------------------------------------------------
 * USING IT
 * ---------------------------------------------------------------------------
 * Add this file to the APPLICATION, in place of the diskio.c template FatFs
 * ships, and put FatFs's ff.h, diskio.h and ffconf.h on the include path. The
 * BSP does not build it: altera_avalon_mm_sdcard_controller_sw.tcl names only
 * the driver, so a system that does not use FatFs never compiles a file that
 * needs FatFs's headers.
 *
 * Drive number n is the n-th controller instance, in alt_sys_init() order - so
 * in the usual system with one controller, drive 0 ("0:") is the card. Provide
 * get_fattime() as FatFs requires, or set FF_FS_NORTC.
 *
 * If FatFs has other drives as well, these five functions cannot all be called
 * disk_*: define SDCARD_DISKIO_NAME to rename them, and call them from your own
 * dispatcher, e.g.
 *
 *     -D'SDCARD_DISKIO_NAME(fn)=sd_##fn'   ->   sd_disk_read(), ...
 *
 * ---------------------------------------------------------------------------
 * WHAT IT ADDS TO THE BLOCK API
 * ---------------------------------------------------------------------------
 * Only one thing, and it is the reason this file is not three lines per
 * function: a mounted volume is tied to the card it was mounted from.
 *
 * The block API identifies a card by itself when it needs to, which is the
 * convenient behaviour for a program that just reads blocks. Under a
 * filesystem it is the dangerous one: FatFs holds the old card's allocation
 * table, directory and free-cluster count in memory, and a write computed from
 * them must never reach a different card. So disk_read and disk_write here
 * refuse, with RES_NOTRDY, on anything but the identification disk_initialize
 * accepted - compared by alt_sdcard_generation(), which changes whenever a card
 * is identified - and disk_status reports STA_NOINIT, which is what makes
 * FatFs drop the volume and mount it afresh on the next call that names a path.
 * An open file on the old card fails with FR_INVALID_OBJECT, which is correct.
 *
 * With a card-detect switch a swap is seen before anything is sent, from the
 * latched insert and remove events, at no cost. Without one there is nothing
 * to consult, and waiting for a transfer to fail is not enough: FatFs answers
 * a good deal from memory - a directory lookup in the sector it read last, say
 * - and would report "no such file" about a card it never looked at. So on a
 * socket with no switch, disk_status asks the card, with CMD13. A card inserted
 * behind the driver's back is still in SD mode and cannot answer, and FatFs
 * calls disk_status before every operation, so no operation runs against a
 * volume from a card that is no longer there. It costs one command per FatFs
 * call, a few byte-times, which is small beside any file operation.
 *
 * ---------------------------------------------------------------------------
 * BUFFERS
 * ---------------------------------------------------------------------------
 * FatFs reads and writes its own sector window and, for large transfers, the
 * application's buffer directly. The driver moves a word-aligned buffer through
 * the DMA in one multi-block stream and anything else a block at a time through
 * a bounce buffer, so no buffer is refused - but with the DMA every one of them
 * must be memory the DMA master can reach. That includes the FATFS and FIL
 * objects, which carry the windows.
 * ===========================================================================*/

#include <string.h>

#include "ff.h"
#include "diskio.h"
#include "altera_avalon_mm_sdcard_controller.h"

#ifndef SDCARD_DISKIO_NAME
#define SDCARD_DISKIO_NAME(fn) fn
#endif

/* The identification each drive was initialised against. */
static alt_u32 mounted_gen[ALT_SDCARD_MAX_INSTANCES];
static int     mounted[ALT_SDCARD_MAX_INSTANCES];

static alt_sdcard_dev *drive(BYTE pdrv)
{
    return (pdrv < ALT_SDCARD_MAX_INSTANCES) ? alt_sdcard_instance(pdrv) : 0;
}

/* Still the card disk_initialize accepted?
 *
 * `ask` sends the card CMD13 when the socket has no switch to consult - see
 * the header. Transfers do not need to: one to a card that is not there fails
 * by itself, and the driver forgets the card when it does. */
static int same_card(BYTE pdrv, alt_sdcard_dev *dev, int ask)
{
    int r;

    if (!mounted[pdrv]) return 0;
    r = (ask && !dev->has_card_detect) ? alt_sdcard_poll(dev)
                                       : alt_sdcard_check(dev);
    if (r != ALT_SDCARD_OK ||
        alt_sdcard_generation(dev) != mounted_gen[pdrv]) {
        mounted[pdrv] = 0;
        return 0;
    }
    return 1;
}

DSTATUS SDCARD_DISKIO_NAME(disk_status)(BYTE pdrv)
{
    alt_sdcard_dev *dev = drive(pdrv);
    DSTATUS st = 0;

    if (dev == 0) return STA_NOINIT | STA_NODISK;

    if (!same_card(pdrv, dev, 1))    st |= STA_NOINIT;
    if (!alt_sdcard_present(dev))    st |= STA_NOINIT | STA_NODISK;
    if (alt_sdcard_write_protected(dev)) st |= STA_PROTECT;
    return st;
}

DSTATUS SDCARD_DISKIO_NAME(disk_initialize)(BYTE pdrv)
{
    alt_sdcard_dev *dev = drive(pdrv);
    int r;

    if (dev == 0) return STA_NOINIT | STA_NODISK;

    /* FatFs is about to read the volume afresh, so whatever card answers now is
     * the right one to accept. One already identified is kept rather than put
     * through identification again - but only if CMD13 says it is still there,
     * because without a switch nothing else would notice a swap. */
    r = alt_sdcard_poll(dev);
    if (r != ALT_SDCARD_OK) r = alt_sdcard_probe(dev);

    mounted[pdrv] = (r == ALT_SDCARD_OK);
    if (mounted[pdrv]) mounted_gen[pdrv] = alt_sdcard_generation(dev);

    return SDCARD_DISKIO_NAME(disk_status)(pdrv);
}

static DRESULT result(BYTE pdrv, int r)
{
    switch (r) {
    case ALT_SDCARD_OK:            return RES_OK;
    case ALT_SDCARD_ERR_PARAM:     return RES_PARERR;
    case ALT_SDCARD_ERR_PROTECTED: return RES_WRPRT;
    case ALT_SDCARD_ERR_NO_CARD:
    case ALT_SDCARD_ERR_CHANGED:
    case ALT_SDCARD_ERR_NOT_READY:
        mounted[pdrv] = 0;
        return RES_NOTRDY;
    default:
        /* A timeout leaves the driver's identification invalidated, so the
         * next disk_status reports STA_NOINIT without being told here. */
        return RES_ERROR;
    }
}

/* LBA_t is 64 bits when FF_LBA64 is set; the card's address space is not.
 * Shifted twice so the test is well-defined for a 32-bit LBA_t too. */
static int beyond_32_bits(LBA_t sector)
{
    return ((sector >> 16) >> 16) != 0;
}

DRESULT SDCARD_DISKIO_NAME(disk_read)(BYTE pdrv, BYTE *buff, LBA_t sector,
                                      UINT count)
{
    alt_sdcard_dev *dev = drive(pdrv);

    if (dev == 0 || !same_card(pdrv, dev, 0)) return RES_NOTRDY;
    if (count == 0 || beyond_32_bits(sector)) return RES_PARERR;

    return result(pdrv, alt_sdcard_read_blocks(dev, (alt_u32)sector, buff,
                                               (alt_u32)count));
}

#if FF_FS_READONLY == 0
DRESULT SDCARD_DISKIO_NAME(disk_write)(BYTE pdrv, const BYTE *buff,
                                       LBA_t sector, UINT count)
{
    alt_sdcard_dev *dev = drive(pdrv);

    if (dev == 0 || !same_card(pdrv, dev, 0)) return RES_NOTRDY;
    if (count == 0 || beyond_32_bits(sector)) return RES_PARERR;

    return result(pdrv, alt_sdcard_write_blocks(dev, (alt_u32)sector, buff,
                                                (alt_u32)count));
}
#endif

DRESULT SDCARD_DISKIO_NAME(disk_ioctl)(BYTE pdrv, BYTE cmd, void *buff)
{
    alt_sdcard_dev *dev = drive(pdrv);

    if (dev == 0 || !same_card(pdrv, dev, 0)) return RES_NOTRDY;

    switch (cmd) {
    case CTRL_SYNC:
        /* Nothing is cached here. CMD13 goes out only once the card has
         * finished programming - the core checks busy before every command -
         * so a successful poll is a completed write. */
        return result(pdrv, alt_sdcard_poll(dev));

    case GET_SECTOR_COUNT:
        *(LBA_t *)buff = (LBA_t)alt_sdcard_block_count(dev);
        return RES_OK;

    case GET_SECTOR_SIZE:
        *(WORD *)buff = 512;
        return RES_OK;

    case GET_BLOCK_SIZE:
        /* The erase block size, in sectors, for f_mkfs's alignment. FatFs
         * documents 1 as "unknown", which is honest: it lives in the SD Status
         * register, which this driver does not read. */
        *(DWORD *)buff = 1;
        return RES_OK;

#ifdef MMC_GET_CSD
    case MMC_GET_CSD:
        memcpy(buff, dev->csd, sizeof dev->csd);
        return RES_OK;
#endif
#ifdef MMC_GET_CID
    case MMC_GET_CID:
        memcpy(buff, dev->cid, sizeof dev->cid);
        return RES_OK;
#endif
#ifdef MMC_GET_OCR
    case MMC_GET_OCR: {
        /* In the order the card sent it, as FatFs's own MMC driver returns it. */
        BYTE *p = (BYTE *)buff;
        p[0] = (BYTE)(dev->ocr >> 24);
        p[1] = (BYTE)(dev->ocr >> 16);
        p[2] = (BYTE)(dev->ocr >> 8);
        p[3] = (BYTE)dev->ocr;
        return RES_OK;
    }
#endif

    default:
        /* Includes CTRL_TRIM, which FatFs sends only with FF_USE_TRIM and
         * whose result it ignores. Erasing needs CMD32/33/38 with a busy
         * period that can outlast any TIMEOUT a transfer wants; not doing it is
         * the safe default. */
        return RES_PARERR;
    }
}
