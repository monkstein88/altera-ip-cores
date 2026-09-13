/* Nios II HAL integer types, for running the driver in the harness.
 *
 * 32 bits wide, as on the target. check_driver_builds.sh deliberately uses the
 * host's `unsigned long` instead, because that is what finds a width
 * assumption at compile time; here the driver has to RUN, and an alt_u32 of 64
 * bits would make every PIO word eight bytes and every 512-byte buffer 128
 * words too short. */
#ifndef __ALT_TYPES_H__
#define __ALT_TYPES_H__
typedef signed char        alt_8;
typedef unsigned char      alt_u8;
typedef signed short       alt_16;
typedef unsigned short     alt_u16;
typedef signed int         alt_32;
typedef unsigned int       alt_u32;
#endif
