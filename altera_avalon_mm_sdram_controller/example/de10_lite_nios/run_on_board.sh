#!/usr/bin/env bash
# =============================================================================
# run_on_board.sh - program a DE10-Lite, download the application, and report.
#
#   ./run_on_board.sh               program the FPGA, download, run, report
#   ./run_on_board.sh --no-program  skip the FPGA, just download and run
#
# Exit status is 0 only if every check passed. Non-interactive, so it can be
# driven over the board's USB connection - which matters here, because half
# the checks involve deliberately wedging a peripheral and none of them can be
# seen by looking at the board.
#
# TWO QUARTUS INSTALLATIONS. 18.1 has Nios II EDS and MAX 10 support, so it
# builds everything and owns nios2-download / nios2-terminal. A newer Quartus
# reads this board's JTAG chain more reliably, so it does the programming. Set
# JTAG_ROOT=$QUARTUS_ROOT if you have only one installation.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"
JTAG_ROOT="${JTAG_ROOT:-/opt/altera/25.1std}"
[[ -x "$JTAG_ROOT/quartus/bin/quartus_pgm" ]] || JTAG_ROOT="$QUARTUS_ROOT"

export SOPC_KIT_NIOS2="$QUARTUS_ROOT/nios2eds"
export QUARTUS_ROOTDIR="$QUARTUS_ROOT/quartus"
export PATH="$SOPC_KIT_NIOS2/sdk2/bin:$SOPC_KIT_NIOS2/bin:$QUARTUS_ROOTDIR/bin:$PATH"
# nios2-download shells out to nios2-elf-objcopy to make the .srec it
# actually sends. Without the GNU toolchain on PATH it fails with
# "command not found" and then "Unable to open input file", and still
# exits 0 - so it looks like a board that downloaded nothing.
export PATH="$SOPC_KIT_NIOS2/bin/gnu/H-x86_64-pc-linux-gnu/bin:$PATH"

SOF="$HERE/quartus/output_files/de10_lite_sdram_nios.sof"
ELF="$HERE/software/sdram_memtest.elf"

[[ -f "$ELF" ]] || { echo "error: $ELF not found - run ./build.sh first" >&2; exit 1; }

if [[ "${1:-}" != "--no-program" ]]; then
    [[ -f "$SOF" ]] || { echo "error: $SOF not found - run ./build.sh first" >&2; exit 1; }
    echo "=== programming the FPGA ==="
    "$JTAG_ROOT/quartus/bin/quartus_pgm" -m jtag -o "p;$SOF" 2>&1 \
        | grep -iE "Configuration succeeded|Error" || true
fi

echo
echo "=== downloading the software ==="
nios2-download -g "$ELF" 2>&1 | grep -iE "Downloaded|Verified|Error" || true

echo
echo "=== capturing the JTAG UART ==="
# The application ends in an idle loop refreshing the LEDs, so the terminal
# never closes on its own; --quit-after bounds it. (It is --quit-after=SECS,
# not --quit-after-ms; the wrong spelling is accepted silently and the
# terminal then never returns.) The marker below decides pass or fail, not
# the exit status of nios2-terminal.
OUT=$(timeout 120 nios2-terminal --quit-after=30 2>&1)
echo "$OUT" | sed -n '/Avalon-MM Firewall/,$p' | head -80

echo
if grep -q '\*\*\* ALL CHECKS PASSED \*\*\*' <<<"$OUT"; then
    echo "PASSED: every check passed on hardware."
    exit 0
else
    echo "FAILED: see the transcript above."
    exit 1
fi
