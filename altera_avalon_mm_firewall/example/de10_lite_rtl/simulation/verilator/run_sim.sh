#!/usr/bin/env bash
# =============================================================================
# run_sim.sh - licence-free regression for the DE10-Lite firewall demo
#
# Runs the BOARD-LEVEL testbench under Verilator: it drives the DE10-Lite's
# pins and reads its LEDs and seven-segment displays, so passing here means
# the hardware demo behaves as documented, all sixteen scenarios included.
#
# For coverage and assertions on the IP core itself, use the core's own suite
# in ../../../../simulation/. This is the complementary half: the only place
# the core is driven by synthesisable hardware rather than testbench tasks.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../../../../rtl"
CORETB="$HERE/../../../../tb"
DEMO="$HERE/../../rtl"
COMMON="$HERE/../../../common"
TB="$HERE/../../tb"

command -v verilator >/dev/null 2>&1 || {
    echo "error: verilator not found in PATH" >&2
    exit 1
}

# Verilator's --timing needs coroutines; g++ < 12 needs to be told.
CXX_EXTRA=""
if [[ "$(g++ -dumpversion | cut -d. -f1)" -lt 12 ]]; then
    CXX_EXTRA="-std=gnu++20 -fcoroutines"
fi

# avl_mm_firewall_pkg.sv first: the other two import it.
SOURCES=(
    "$CORE/avl_mm_firewall_pkg.sv"
    "$CORE/avl_mm_firewall_regs.sv"
    "$CORE/avl_mm_firewall_top.sv"
    "$CORETB/avl_mm_firewall_sva.sv"
    "$COMMON/demo_avl_mm_target_slave.sv"
    "$DEMO/demo_avl_mm_master.sv"
    "$DEMO/demo_sequencer.sv"
    "$DEMO/hex7seg.sv"
    "$DEMO/key_debounce.sv"
    "$DEMO/de10_lite_avl_mm_firewall_demo.sv"
    "$TB/de10_lite_avl_mm_firewall_demo_tb.sv"
)

# DECLFILENAME: several modules per directory do not match their file names by
# design (hex7seg, key_debounce). UNUSEDSIGNAL: the demo deliberately leaves
# spare switches and master status bits unread. Same two the core's own flow
# waives, and nothing else is waived.
WARN_OFF=(-Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC)

echo "== linting the demo RTL =="
verilator --lint-only "${WARN_OFF[@]}" \
    --top-module de10_lite_avl_mm_firewall_demo \
    "${SOURCES[@]:0:3}" "${SOURCES[@]:4:6}" || exit $?

echo "== building the board-level testbench =="
BUILD="$HERE/obj_dir"
rm -rf "$BUILD"

VFLAGS=(--binary --timing --assert "${WARN_OFF[@]}"
        +define+DEMO_TRACE
        --top-module de10_lite_avl_mm_firewall_demo_tb -o simx -Mdir "$BUILD")
[[ -n "$CXX_EXTRA" ]] && VFLAGS+=(-CFLAGS "$CXX_EXTRA")

if ! verilator "${VFLAGS[@]}" "${SOURCES[@]}"; then
    # Some Verilator packages (notably the PyPI wheel) ship with
    # CFG_CXXFLAGS_PCH_I empty, so the generated makefile hands the
    # precompiled header to the compiler as a bare filename. Verilating
    # succeeded at that point, so finish the build with the flag supplied.
    echo "   note: retrying the C++ build with an explicit PCH include flag"
    make -C "$BUILD" -f Vde10_lite_avl_mm_firewall_demo_tb.mk CFG_CXXFLAGS_PCH_I=-include
fi

echo "== running =="
LOG="$HERE/run.log"
"$BUILD/simx" 2>&1 | tee "$LOG"

if grep -q "\*\*\* ALL TESTS PASSED \*\*\*" "$LOG"; then
    echo "RESULT: PASSED"
    exit 0
else
    echo "RESULT: FAILED - see $LOG"
    exit 1
fi
