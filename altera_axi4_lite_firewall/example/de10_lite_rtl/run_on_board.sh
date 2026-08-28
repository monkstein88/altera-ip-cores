#!/usr/bin/env bash
# =============================================================================
# run_on_board.sh - program a DE10-Lite with the RTL demo and check it, over JTAG.
#
#   ./run_on_board.sh              program, then drive and check over JTAG
#   ./run_on_board.sh --no-program  just re-check what is already loaded
#
# Exit status is 0 only if every scenario passed. No one has to look at the
# board: the design carries an In-System Sources and Probes instance that
# exposes the sequencer's controls and its pass bitmap over the same USB
# connection used to program it.
#
# Requires a build with ENABLE_ISSP, which the project sets by default.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"
# A newer Quartus reads this board's JTAG chain reliably where 18.1's server is
# intermittent; use it for programming when it is available. See the Nios
# example's README for the full story.
JTAG_ROOT="${JTAG_ROOT:-/opt/altera/25.1std}"
[[ -x "$JTAG_ROOT/quartus/bin/quartus_pgm" ]] || JTAG_ROOT="$QUARTUS_ROOT"

SOF="$HERE/quartus/output_files/de10_lite_axi4_lite_firewall_demo.sof"
STP="$QUARTUS_ROOT/quartus/bin/quartus_stp"

if [[ "${1:-}" != "--no-program" ]]; then
    [[ -f "$SOF" ]] || { echo "error: $SOF not found - compile the project first" >&2; exit 1; }
    echo "=== programming ==="
    "$JTAG_ROOT/quartus/bin/quartus_pgm" -m jtag -o "p;$SOF" 2>&1 \
        | grep -iE "Configuration succeeded|Error" || true
fi

echo
echo "=== driving the demo over JTAG ==="
"$STP" -t "$HERE/board/issp_run.tcl" 2>&1 \
    | grep -vE "^Info: |^    Info|^Info \(" | sed '/^$/N;/^\n$/D'
rc=${PIPESTATUS[0]}
exit $rc
