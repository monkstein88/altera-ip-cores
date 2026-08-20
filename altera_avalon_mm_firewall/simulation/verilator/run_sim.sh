#!/usr/bin/env bash
# =============================================================================
# run_sim.sh - licence-free regression run for the Avalon-MM Firewall.
#
# Verilator 5.x with --timing --assert runs the full testbench INCLUDING the
# SystemVerilog assertion bind, so this covers the same ground as the Questa
# flow minus coverage collection. Use it for CI and quick iteration; use
# simulation/questa/run_sim.tcl when you need coverage numbers.
#
#   ./run_sim.sh          run the regression
#   ./run_sim.sh -c       clean the build directories first
#
# THE SUITE RUNS TWICE, once with USE_WRITE_RESPONSE=0 and once with 1. Those
# are genuinely different designs on the write channel: without write responses
# a write completes when its last beat is accepted, with them it completes when
# the peripheral answers - different timeout scope, different abandonment path,
# different response arbitration against read data. Running only the default
# leaves half the write channel unexercised, so both are mandatory and the exit
# status is the AND of the two.
#
# Exit status is 0 only if every check in both passes. Verilator returns
# non-zero on an assertion failure or $fatal by itself, but the log is also
# grepped for the result marker so a simulator that swallows the status cannot
# hide a failure.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

[[ "${1:-}" == "-c" ]] && rm -rf "$HERE"/obj_dir_*

command -v verilator >/dev/null 2>&1 || {
    echo "error: verilator not found in PATH" >&2
    echo "       (pip install verilator, or your distro's package)" >&2
    exit 127
}

RTL=(
    "$ROOT/rtl/avl_mm_firewall_pkg.sv"
    "$ROOT/rtl/avl_mm_firewall_regs.sv"
    "$ROOT/rtl/avl_mm_firewall_top.sv"
)
SOURCES=( "${RTL[@]}" "$ROOT/tb/avl_mm_firewall_sva.sv" "$ROOT/tb/avl_mm_firewall_tb.sv" )

# WIDTHEXPAND/WIDTHTRUNC fire on the testbench's deliberately oversized
# check_eq() arguments. The RTL itself passes `verilator --lint-only -Wall`
# with nothing waived - see the separate lint pass below.
WARN_OFF=(-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME)

# --timing compiles to C++20 coroutines. GCC before 12 has them behind a flag
# and defaults to a standard that predates them, so a stock Ubuntu 22.04 host
# fails to build the runtime with "the coroutine header requires -fcoroutines".
CXX_EXTRA=""
if command -v g++ >/dev/null 2>&1; then
    GCC_MAJOR="$(g++ -dumpversion | cut -d. -f1)"
    if [[ "$GCC_MAJOR" -lt 12 ]]; then
        CXX_EXTRA="-std=gnu++20 -fcoroutines"
        echo "note: gcc $GCC_MAJOR - adding $CXX_EXTRA for --timing coroutines"
    fi
fi

# -----------------------------------------------------------------------------
# Strict LRM elaboration with slang, if available.
#
# Not redundant with Verilator: slang rejects use-before-declaration and
# implicit-net collisions that Verilator silently resolves, and those are
# exactly what Questa rejects later in the flow. Catching them here costs a
# second, so it runs first and stops on error.
# -----------------------------------------------------------------------------
if python3 -c 'import pyslang' 2>/dev/null; then
    echo "== strict elaboration (slang) =="
    python3 "$HERE/slangcheck.py" "RTL + TB + SVA" "${SOURCES[@]}" || exit 1
else
    echo "== strict elaboration skipped (pip install pyslang to enable) =="
fi

# -----------------------------------------------------------------------------
# Strict lint of the synthesisable RTL on its own, with nothing waived. Kept
# separate from the simulation build so testbench-only warnings can be relaxed
# without also relaxing them for the RTL.
#
# The parameter sweep matters more here than it would for a fixed-width core:
# the burst range check, the beat counters and the FAULT_INFO saturation are
# all sized from parameters, and the combinations most likely to break are the
# ones nobody simulates.
# -----------------------------------------------------------------------------
echo "== linting RTL (-Wall, nothing waived) =="
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
    --top-module avl_mm_firewall_top "${RTL[@]}" || exit $?

echo "== linting RTL across the parameter space =="
SWEEP=(
    "-GDATA_WIDTH=64 -GBURST_WIDTH=5"
    "-GDATA_WIDTH=8 -GBURST_WIDTH=1 -GNUM_RULES=1 -GCSR_ADDR_WIDTH=5"
    "-GADDR_WIDTH=16 -GBURST_WIDTH=11 -GNUM_RULES=64 -GCSR_ADDR_WIDTH=9"
    "-GDATA_WIDTH=128 -GMAX_PENDING_READS=1 -GUSE_WRITE_RESPONSE=1"
    "-GDATA_WIDTH=256 -GMAX_PENDING_READS=32 -GTIMEOUT_WIDTH=32"
)
for cfg in "${SWEEP[@]}"; do
    # shellcheck disable=SC2086
    if verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
         --top-module avl_mm_firewall_top $cfg "${RTL[@]}" 2>/tmp/avlfw_lint.$$; then
        echo "   ok   $cfg"
    else
        echo "   FAIL $cfg"; cat /tmp/avlfw_lint.$$; rm -f /tmp/avlfw_lint.$$; exit 1
    fi
done
rm -f /tmp/avlfw_lint.$$

# -----------------------------------------------------------------------------
# Build + run, once per USE_WRITE_RESPONSE setting.
# -----------------------------------------------------------------------------
OVERALL=0

for WRESP in 0 1; do
    BUILD="$HERE/obj_dir_wresp$WRESP"
    LOG="$HERE/run_wresp$WRESP.log"

    echo
    echo "=============================================================="
    echo "== USE_WRITE_RESPONSE=$WRESP"
    echo "=============================================================="

    VFLAGS=(--binary --timing --assert "${WARN_OFF[@]}"
            -GUSE_WRITE_RESPONSE=$WRESP
            --top-module avl_mm_firewall_tb -o simx -Mdir "$BUILD")
    [[ -n "$CXX_EXTRA" ]] && VFLAGS+=(-CFLAGS "$CXX_EXTRA")

    rm -rf "$BUILD"
    if ! verilator "${VFLAGS[@]}" "${SOURCES[@]}"; then
        # Some Verilator packages (notably the PyPI wheel) ship with
        # CFG_CXXFLAGS_PCH_I empty, so the generated makefile hands the
        # precompiled header to the compiler as a bare filename instead of
        # `-include <file>`, and the build dies on "linker input file not
        # found". Verilating succeeded at that point, so just finish the
        # build with the flag supplied.
        echo "   note: retrying the C++ build with an explicit PCH include flag"
        make -C "$BUILD" -f Vavl_mm_firewall_tb.mk CFG_CXXFLAGS_PCH_I=-include || {
            echo "RESULT: FAILED (build error, USE_WRITE_RESPONSE=$WRESP)"
            OVERALL=1; continue
        }
    fi

    "$BUILD/simx" 2>&1 | tee "$LOG"
    SIM_STATUS=${PIPESTATUS[0]}

    if [[ $SIM_STATUS -ne 0 ]]; then
        echo "RESULT: FAILED (simulator exit status $SIM_STATUS, USE_WRITE_RESPONSE=$WRESP)"
        OVERALL=1
    elif ! grep -q '\*\*\* ALL TESTS PASSED \*\*\*' "$LOG"; then
        echo "RESULT: FAILED (no pass marker in $LOG)"
        OVERALL=1
    elif grep -qE '^\s*FAIL:|Assertion failed|PROTOCOL VIOLATION' "$LOG"; then
        echo "RESULT: FAILED (failures present in $LOG)"
        OVERALL=1
    else
        echo "RESULT: PASSED  ($(grep -c '^  PASS' "$LOG") checks, log in $LOG)"
    fi
done

echo
if [[ $OVERALL -eq 0 ]]; then
    TOTAL=$(cat "$HERE"/run_wresp*.log | grep -c '^  PASS')
    echo "OVERALL: PASSED  ($TOTAL checks across both write-response settings)"
else
    echo "OVERALL: FAILED"
fi
exit $OVERALL
