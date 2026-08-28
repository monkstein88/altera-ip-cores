#!/usr/bin/env bash
# =============================================================================
# run_sim.sh - licence-free regression for the DE10-Lite firewall demo.
#
# Runs the board-level testbench under Verilator 5.x: it drives the board's
# pins and checks its LEDs and displays. Passing here means the hardware demo
# behaves as documented, including all sixteen firewall scenarios.
#
#   ./run_sim.sh          run the regression
#   ./run_sim.sh -c       clean the build directory first
#
# Exit status is 0 only if every check passed. The log is also grepped for the
# result marker, because $finish's argument is a verbosity level and does not
# set a process exit code - the same trap the core's own runner documents.
#
# This does not replace the core's suite in ../../../../simulation/. That one
# binds SVA and collects coverage against the core in isolation; this one
# exercises the core from synthesisable hardware, through the same RTL that
# gets programmed into the FPGA.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$HERE/../.." && pwd)"
CORE="$(cd "$DEMO/../.." && pwd)"
BUILD="$HERE/obj_dir"
LOG="$HERE/run.log"

[[ "${1:-}" == "-c" ]] && rm -rf "$BUILD"

command -v verilator >/dev/null 2>&1 || {
    echo "error: verilator not found in PATH" >&2
    exit 127
}

SOURCES=(
    "$CORE/rtl/axi4_lite_firewall_regs.sv"
    "$CORE/rtl/axi4_lite_firewall_top.sv"
    "$DEMO/rtl/demo_axi4_lite_master.sv"
    "$DEMO/../common/demo_axi4_lite_target_slave.sv"
    "$DEMO/rtl/demo_sequencer.sv"
    "$DEMO/rtl/hex7seg.sv"
    "$DEMO/rtl/key_debounce.sv"
    "$DEMO/rtl/de10_lite_axi4_lite_firewall_demo.sv"
)

# ---------------------------------------------------------------------------
# Lint the synthesisable sources first, with -Wall and nothing waived beyond
# the two the core's own flow waives. A lint regression is cheaper to read
# than a functional one, so it goes first and stops the run.
# ---------------------------------------------------------------------------
echo "=== lint (-Wall) ==="
# -Wno-PROCASSINIT: the demo's power-on-reset shift register and the KEY[1]
# synchroniser are declared with `= '0`, which is a REGISTER POWER-UP VALUE
# that Quartus honours and simulators start from - the standard MAX 10 idiom,
# and documented as deliberate at the declaration. Verilator 5.050 added this
# lint; 5.020 did not have it.
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PROCASSINIT \
    --top-module de10_lite_axi4_lite_firewall_demo "${SOURCES[@]}" || {
    echo "error: lint failed" >&2
    exit 1
}
echo "lint clean"

# WIDTHEXPAND/WIDTHTRUNC fire on the testbench's deliberately oversized
# check_eq() arguments, not on the RTL - which lints clean above.
echo
echo "=== build + run ==="
verilator --binary --timing -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-PROCASSINIT \
    +define+DEMO_TRACE \
    --top-module de10_lite_axi4_lite_firewall_demo_tb \
    -o simx -Mdir "$BUILD" \
    "${SOURCES[@]}" "$DEMO/tb/de10_lite_axi4_lite_firewall_demo_tb.sv" || {
    echo "error: verilator build failed" >&2
    exit 1
}

"$BUILD/simx" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

echo
if [[ $rc -ne 0 ]]; then
    echo "FAILED: simulator exited $rc"
    exit $rc
fi
if ! grep -q "ALL TESTS PASSED" "$LOG"; then
    echo "FAILED: result marker not found in $LOG"
    exit 1
fi
echo "PASSED - see $LOG"
exit 0
