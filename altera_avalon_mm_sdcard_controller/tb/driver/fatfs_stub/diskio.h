/* =============================================================================
 * diskio.h - stand-in for FatFs's diskio.h: the disk I/O interface the glue in
 * software/fatfs implements, as FatFs documents it. See ff.h beside this file.
 * ===========================================================================*/
#ifndef SDCARD_FATFS_STUB_DISKIO_H
#define SDCARD_FATFS_STUB_DISKIO_H

#include "ff.h"

typedef BYTE DSTATUS;

typedef enum {
    RES_OK = 0,
    RES_ERROR,
    RES_WRPRT,
    RES_NOTRDY,
    RES_PARERR
} DRESULT;

DSTATUS disk_initialize(BYTE pdrv);
DSTATUS disk_status(BYTE pdrv);
DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count);
DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count);
DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff);

#define STA_NOINIT        0x01
#define STA_NODISK        0x02
#define STA_PROTECT       0x04

#define CTRL_SYNC         0
#define GET_SECTOR_COUNT  1
#define GET_SECTOR_SIZE   2
#define GET_BLOCK_SIZE    3
#define CTRL_TRIM         4

#define MMC_GET_CSD       51
#define MMC_GET_CID       52
#define MMC_GET_OCR       53

#endif
