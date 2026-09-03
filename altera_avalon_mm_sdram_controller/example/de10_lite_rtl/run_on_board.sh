#!/usr/bin/env bash
# =============================================================================
# run_on_board.sh - program a DE10-Lite with the SDRAM demo and check it, over JTAG.
#
#   ./run_on_board.sh               program, then drive and check over JTAG
#   ./run_on_board.sh --no-program  just re-check what is already loaded
#
# Exit status is 0 only if every scenario passed. No one has to look at the
# board: the design carries an In-System Sources and Probes instance that
# exposes the sequencer's controls, its pass bitmap and its cycle counters
# over the same USB connection used to program it.
#
# Requires a build with ENABLE_ISSP, which the project sets by default.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 18.1 built and verified this design.
QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"
# A newer Quartus reads this board's JTAG chain reliably where 18.1's server is
# intermittent; use it for programming when it is available.
JTAG_ROOT="${JTAG_ROOT:-/opt/altera/25.1std}"
[[ -x "$JTAG_ROOT/quartus/bin/quartus_pgm" ]] || JTAG_ROOT="$QUARTUS_ROOT"

# -----------------------------------------------------------------------------
# Which cable? With two USB-Blasters attached - the normal state of a bench
# that has both boards - quartus_pgm, nios2-download and nios2-terminal all
# default to cable 1, which is a coin flip. Pick the one whose device matches
# this board and pass it explicitly.
# -----------------------------------------------------------------------------
DEV_MATCH='10M50'
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

SOF="$HERE/quartus/output_files/de10_lite_sdram_demo.sof"
# quartus_stp comes from JTAG_ROOT too, not from the Quartus that built the
# design. The ISSP behaviour is identical between the two versions - this was
# checked - but the JTAG stack is not: on this setup 18.1's jtagd reports
# "JTAG chain broken" on a board that 25.1's reads first time. Both tools talk
# to whichever jtagd is running, so mixing them just means the older daemon
# wins and the session fails for no visible reason.
STP="$JTAG_ROOT/quartus/bin/quartus_stp"
[[ -x "$STP" ]] || STP="$QUARTUS_ROOT/quartus/bin/quartus_stp"

if [[ "${1:-}" != "--no-program" ]]; then
    [[ -f "$SOF" ]] || { echo "error: $SOF not found - compile the project first" >&2; exit 1; }
    echo "=== programming ==="
    "$JTAG_ROOT/quartus/bin/quartus_pgm" -c "$CABLE" -m jtag -o "p;$SOF" 2>&1 \
        | grep -iE "Configuration succeeded|Error" || true
fi

echo
echo "=== driving the demo over JTAG ==="
"$STP" -t "$HERE/board/issp_run.tcl" 2>&1 \
    | grep -vE "^Info: |^    Info|^Info \(" | sed '/^$/N;/^\n$/D'
rc=${PIPESTATUS[0]}
exit $rc
