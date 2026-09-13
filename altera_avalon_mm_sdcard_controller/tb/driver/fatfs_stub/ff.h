/* =============================================================================
 * ff.h - stand-in for FatFs's ff.h, for building the disk I/O glue in the driver
 * harness without FatFs.
 *
 * The integer types the disk I/O interface is written in, and the one
 * configuration value the glue reads. Nothing of FatFs itself: the glue is
 * checked against the interface FatFs documents, and FatFs is not
 * redistributed here. SDCARD_STUB_LBA64 selects the 64-bit sector number
 * FF_LBA64 gives, so the glue's range check is compiled both ways.
 * ===========================================================================*/
#ifndef SDCARD_FATFS_STUB_FF_H
#define SDCARD_FATFS_STUB_FF_H

#include <stdint.h>

typedef unsigned int  UINT;
typedef unsigned char BYTE;
typedef uint16_t      WORD;
typedef uint32_t      DWORD;

#ifdef SDCARD_STUB_LBA64
typedef uint64_t      LBA_t;
#else
typedef DWORD         LBA_t;
#endif

#define FF_FS_READONLY 0

#endif
