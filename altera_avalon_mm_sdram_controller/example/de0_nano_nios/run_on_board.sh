#!/usr/bin/env bash
# =============================================================================
# run_on_board.sh - program a DE0-Nano, download the application, and report.
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

# -----------------------------------------------------------------------------
# Which cable? With two USB-Blasters attached - the normal state of a bench
# that has both boards - quartus_pgm, nios2-download and nios2-terminal all
# default to cable 1, which is a coin flip. Pick the one whose device matches
# this board and pass it explicitly.
# -----------------------------------------------------------------------------
DEV_MATCH='EP4CE22'
pick_cable() {
    local idx="" hit=""
    while IFS= read -r line; do
        case "$line" in
            [0-9]*\)*) idx="${line%%)*}" ;;
        esac
        case "$line" in
            *$DEV_MATCH*) [ -n "$idx" ] && { hit="$idx"; break; } ;;
        esac
    done < <("$JTAG_ROOT/quartus/bin/jtagconfig" 2>/dev/null)
    echo "$hit"
}
CABLE="$(pick_cable)"
if [[ -z "$CABLE" ]]; then
    echo "error: no $DEV_MATCH found on any USB-Blaster - is the board plugged in?" >&2
    exit 1
fi
echo "using JTAG cable $CABLE ($DEV_MATCH)"

SOF="$HERE/quartus/output_files/de0_nano_sdram_nios.sof"
ELF="$HERE/software/sdram_memtest.elf"

[[ -f "$ELF" ]] || { echo "error: $ELF not found - run ./build.sh first" >&2; exit 1; }

if [[ "${1:-}" != "--no-program" ]]; then
    [[ -f "$SOF" ]] || { echo "error: $SOF not found - run ./build.sh first" >&2; exit 1; }
    echo "=== programming the FPGA ==="
    "$JTAG_ROOT/quartus/bin/quartus_pgm" -c "$CABLE" -m jtag -o "p;$SOF" 2>&1 \
        | grep -iE "Configuration succeeded|Error" || true
fi

echo
echo "=== downloading the software ==="
nios2-download -c "$CABLE" -g "$ELF" 2>&1 | grep -iE "Downloaded|Verified|Error" || true

echo
echo "=== capturing the JTAG UART ==="
# The application ends in an idle loop, so the terminal never closes on its
# own.
# nios2-terminal comes from JTAG_ROOT, not from the Quartus that built the
# software. On a current Linux the 18.1 terminal connects to the JTAG UART and
# then reads nothing at all - the program is running and printing, and the
# output never arrives. The 25.1 one reads it correctly. (nios2-download must
# still come from 18.1: the 25.1 one shells out to nios2-elf-objcopy, which
# only 18.1 ships, and fails while exiting 0.)
TERM_BIN="$JTAG_ROOT/quartus/bin/nios2-terminal"
[[ -x "$TERM_BIN" ]] || TERM_BIN="nios2-terminal"

# The full march writes and verifies every word of the 32 MB device from a
# CPU, so this is minutes rather than seconds. --quit-after bounds it. (It is
# --quit-after=SECS, not --quit-after-ms; the wrong spelling is accepted
# silently and the terminal then never returns.) The marker below decides pass
# or fail, not the exit status of nios2-terminal.
# tee, not command substitution. The full march takes minutes, and a command
# substitution shows nothing until the terminal exits - so a working run looks
# indistinguishable from a hung one for the whole of it. The transcript is
# written to a file and echoed live, and the verdict below reads the file.
#
# And --quit-after is a hard bound, not an end-of-output detector: the
# application ends in an idle loop, so nios2-terminal has nothing to notice and
# holds the connection for the whole window even after a run that finished in
# seconds. That is indistinguishable from a hang from the outside, and it cost
# a full 10-minute wait on a run whose transcript had said ALL TESTS PASSED
# after thirty. So the terminal runs in the background and is stopped the
# moment the summary lands; --quit-after only bounds a run that never gets
# there.
LOG="$HERE/.run_on_board.log"
: >"$LOG"
"$TERM_BIN" --cable="$CABLE" --quit-after=420 >"$LOG" 2>&1 &
TERM_PID=$!

# Follows the log for as long as the terminal lives, then stops on its own.
tail -n +1 -f "$LOG" --pid="$TERM_PID" 2>/dev/null \
    | sed -n '/Avalon-MM SDRAM Controller/,$p' &
TAIL_PID=$!

for ((i = 0; i < 480; i++)); do
    kill -0 "$TERM_PID" 2>/dev/null || break
    if grep -q 'ALL TESTS PASSED\|THERE ARE FAILURES' "$LOG"; then
        sleep 1                              # let the closing banner land
        kill "$TERM_PID" 2>/dev/null
        break
    fi
    sleep 1
done
wait "$TERM_PID" 2>/dev/null
wait "$TAIL_PID" 2>/dev/null
OUT=$(cat "$LOG")

echo
if grep -q '\*\*\* ALL TESTS PASSED \*\*\*' <<<"$OUT"; then
    echo "PASSED: every check passed on hardware."
    exit 0
else
    echo "FAILED: see the transcript above."
    exit 1
fi
