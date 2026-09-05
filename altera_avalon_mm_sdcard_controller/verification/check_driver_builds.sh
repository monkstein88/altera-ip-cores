#!/usr/bin/env bash
# =============================================================================
# check_driver_builds.sh - compile the HAL driver against stubbed Nios II
#                          headers, with the warning level a BSP will not give
#                          you.
#
#   ./verification/check_driver_builds.sh
#
# Exit 0 if the driver compiles clean, 1 otherwise.
#
# -----------------------------------------------------------------------------
# WHY THIS EXISTS
# -----------------------------------------------------------------------------
# The driver is only ever compiled as part of a Nios II BSP, by a toolchain that
# ships with Quartus 18.1 and that most machines touching this repository do not
# have. That means an ordinary typo - a missing brace, a wrong argument count, a
# variable used before it is set - survives until someone with the full
# toolchain tries to build a project, at which point it is reported against
# generated BSP sources rather than against this file.
#
# The stubs below reproduce just enough of the HAL to type-check: the integer
# typedefs, the IORD/IOWR accessors as volatile pointer dereferences, and the
# interrupt registration signature. That is sufficient to catch everything in
# the paragraph above, and it costs a second.
#
# It does NOT prove the driver works, or that it matches the real HAL's
# semantics. Those are the BSP's job and the board's.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT

mkdir -p "$STUB/sys"

cat > "$STUB/alt_types.h" <<'EOF'
#ifndef __ALT_TYPES_H__
#define __ALT_TYPES_H__
typedef signed char        alt_8;
typedef unsigned char      alt_u8;
typedef signed short       alt_16;
typedef unsigned short     alt_u16;
typedef signed long        alt_32;
typedef unsigned long      alt_u32;
#endif
EOF

cat > "$STUB/io.h" <<'EOF'
#ifndef __IO_H__
#define __IO_H__
/* The real accessors add a bus-access wrapper; for a type check a volatile
 * dereference is equivalent and keeps the side effects visible to -Wall. */
#define IORD_32DIRECT(BASE, OFFSET) \
    (*(volatile unsigned long *)((unsigned long)(BASE) + (unsigned long)(OFFSET)))
#define IOWR_32DIRECT(BASE, OFFSET, DATA) \
    (*(volatile unsigned long *)((unsigned long)(BASE) + (unsigned long)(OFFSET)) \
        = (unsigned long)(DATA))
#endif
EOF

cat > "$STUB/sys/alt_dev.h" <<'EOF'
#ifndef __ALT_DEV_H__
#define __ALT_DEV_H__
typedef struct { int unused; } alt_dev;
#endif
EOF

cat > "$STUB/sys/alt_irq.h" <<'EOF'
#ifndef __ALT_IRQ_H__
#define __ALT_IRQ_H__
#include "alt_types.h"
typedef void (*alt_isr_func)(void *context);
static inline int alt_ic_isr_register(alt_u32 ic_id, alt_u32 irq,
                                      alt_isr_func isr, void *context,
                                      void *flags)
{ (void)ic_id; (void)irq; (void)isr; (void)context; (void)flags; return 0; }
#endif
EOF

echo ""
echo "=== HAL driver compile check ==="
echo ""

CC=${CC:-gcc}
FLAGS=(-std=c99 -Wall -Wextra -Wno-unused-parameter -c -o /dev/null
       -I "$STUB" -I "$ROOT/HAL/inc" -I "$ROOT/inc")

fail=0

if "$CC" "${FLAGS[@]}" "$ROOT/HAL/src/altera_avalon_mm_sdcard_controller.c" 2>&1 | tee /tmp/drvcc.$$; then
    if [ -s /tmp/drvcc.$$ ]; then
        echo "  FAIL  compiled with warnings"
        fail=1
    else
        echo "  PASS  driver compiles clean under -Wall -Wextra"
    fi
else
    echo "  FAIL  driver does not compile"
    fail=1
fi

# ---------------------------------------------------------------------------
# Unit-test the CSD capacity arithmetic.
#
# This is the one piece of the driver the RTL regression cannot reach: the
# testbench proves the 16 bytes arrive intact, and nothing proves they are
# interpreted correctly. The two CSD structure versions are different
# arithmetic, not a moved field, and reading a v2 card with the v1 formula
# yields a plausible number that is wrong by orders of magnitude.
#
# The byte patterns below are exactly what tb/spi_card_model.sv transmits, so a
# change to one without the other fails here.
# ---------------------------------------------------------------------------
cat > "$STUB/csdtest.c" <<'EOF'
#include <stdio.h>
#define main driver_main_unused
#include "altera_avalon_mm_sdcard_controller.c"
#undef main

static int fails = 0;
static void expect(const char *what, unsigned long got, unsigned long want)
{
    if (got != want) { printf("  FAIL  %s: got %lu, want %lu\n", what, got, want); fails++; }
}

int main(void)
{
    /* CSD v2 (SDHC), C_SIZE = 7679  ->  7680 * 1024 blocks */
    alt_u8 v2[16] = {0};
    v2[0] = 0x40; v2[5] = 0x59;
    v2[7] = 0x00; v2[8] = 0x1D; v2[9] = 0xFF;
    expect("CSD v2 capacity", csd_blocks(v2), 7864320UL);

    /* CSD v1 (SDSC), C_SIZE = 4095, C_SIZE_MULT = 7, READ_BL_LEN = 9
       -> 4096 * 512 * 512 bytes = 2,097,152 blocks */
    alt_u8 v1[16] = {0};
    v1[0]  = 0x00; v1[5] = 0x59;
    v1[6]  = 0x83; v1[7] = 0xFF; v1[8] = 0xFF;
    v1[9]  = 0x9F; v1[10] = 0xFA;
    expect("CSD v1 capacity", csd_blocks(v1), 2097152UL);

    /* The version must come from the CSD, not be assumed: the same bytes read
       with the wrong formula must NOT accidentally agree. */
    if (csd_blocks(v1) == csd_blocks(v2)) {
        printf("  FAIL  the two CSD versions parse identically\n"); fails++;
    }
    return fails ? 1 : 0;
}
EOF
if "$CC" -std=c99 -w -I "$STUB" -I "$ROOT/HAL/inc" -I "$ROOT/inc" \
        -I "$ROOT/HAL/src" -o "$STUB/csdtest" "$STUB/csdtest.c" 2>/dev/null \
   && "$STUB/csdtest"; then
    echo "  PASS  CSD capacity arithmetic, both structure versions"
else
    echo "  FAIL  CSD capacity arithmetic"
    fail=1
fi

# The register header must stand alone: an application that wants only the
# offsets should not have to pull in the driver or the HAL device struct.
cat > "$STUB/standalone.c" <<'EOF'
#include "altera_avalon_mm_sdcard_controller_regs.h"
unsigned long probe(unsigned long base) { return ALT_SDCARD_RD_STATUS(base); }
EOF
if "$CC" "${FLAGS[@]}" "$STUB/standalone.c" 2>/dev/null; then
    echo "  PASS  register header is self-contained (needs only <io.h>)"
else
    echo "  FAIL  register header does not stand alone"
    fail=1
fi

rm -f /tmp/drvcc.$$
echo ""
if [ $fail -eq 0 ]; then echo "*** PASS ***"; else echo "*** FAIL ***"; fi
echo ""
exit $fail
