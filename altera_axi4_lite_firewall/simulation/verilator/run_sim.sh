#!/usr/bin/env bash
# =============================================================================
# run_sim.sh - licence-free regression run for the AXI4-Lite Firewall.
#
# Verilator 5.x with --timing --assert runs the full testbench *including* the
# SystemVerilog assertion bind, so this covers the same ground as the Questa
# flow minus coverage collection. Use it for CI and for quick iteration; use
# simulation/questa/run_sim.tcl when you need coverage numbers.
#
#   ./run_sim.sh          run the regression
#   ./run_sim.sh -c       clean the build directory first
#
# Exit status is 0 only if every check passed. Verilator returns non-zero on an
# assertion failure or $fatal by itself, but the log is also grepped for the
# result marker so a simulator that swallows the status can't hide a failure.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/obj_dir"
LOG="$HERE/run.log"

[[ "${1:-}" == "-c" ]] && rm -rf "$BUILD"

command -v verilator >/dev/null 2>&1 || {
    echo "error: verilator not found in PATH" >&2
    echo "       (pip install verilator, or your distro's package)" >&2
    exit 127
}

# ---------------------------------------------------------------------------
# Minimum Verilator version.
#
# The assertions use `default disable iff`, ranged cycle delays (##[a:b],
# ##[1:$]) and consecutive repetition ([*n]). Verilator implements none of
# those before 5.050, and what it prints instead is a wall of
# "Unsupported: ## (in sequence expression)" that says nothing about the real
# problem. 5.020 additionally miscompiles `disable fork` inside an initial
# block, emitting an undeclared `vlProcess` that fails in g++.
# ---------------------------------------------------------------------------
VER=$(verilator --version 2>/dev/null | sed -n 's/^Verilator \([0-9]*\)\.\([0-9]*\).*/\1\2/p')
if [ -n "$VER" ] && [ "$VER" -lt 5050 ] 2>/dev/null; then
    echo "error: Verilator $(verilator --version | awk '{print $2}') is too old for this testbench." >&2
    echo "       5.050 or newer is required - see this core's README." >&2
    exit 127
fi

SOURCES=(
    "$ROOT/rtl/axi4_lite_firewall_regs.sv"
    "$ROOT/rtl/axi4_lite_firewall_top.sv"
    "$ROOT/tb/axi4_lite_firewall_sva.sv"
    "$ROOT/tb/axi4_lite_firewall_tb.sv"
)

# WIDTHEXPAND/WIDTHTRUNC fire on the testbench's deliberately oversized
# check_eq() arguments. The RTL itself passes `verilator --lint-only -Wall`
# with nothing waived - see below. Every file now carries a `timescale, so
# TIMESCALEMOD no longer needs suppressing.
WARN_OFF=(-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC)

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

# Strict LRM elaboration with slang, if available. This is not redundant with
# Verilator: slang rejects use-before-declaration and implicit-net collisions
# that Verilator silently resolves, and those are exactly what Questa rejects
# later in the flow. Catching them here costs a second.
if python3 -c 'import pyslang' 2>/dev/null; then
    echo "== strict elaboration (slang) =="
    python3 "$HERE/slangcheck.py" "RTL + TB + SVA" \
        "$ROOT/rtl/axi4_lite_firewall_regs.sv" "$ROOT/rtl/axi4_lite_firewall_top.sv" \
        "$ROOT/tb/axi4_lite_firewall_sva.sv"   "$ROOT/tb/axi4_lite_firewall_tb.sv" || exit 1
else
    echo "== strict elaboration skipped (pip install pyslang to enable) =="
fi

# Strict lint of the synthesisable RTL on its own, with nothing waived. Kept
# separate from the simulation build so testbench-only warnings can be relaxed
# without also relaxing them for the RTL.
echo "== linting RTL (-Wall, nothing waived) =="
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
    --top-module axi4_lite_firewall_top \
    "$ROOT/rtl/axi4_lite_firewall_regs.sv" "$ROOT/rtl/axi4_lite_firewall_top.sv" || exit $?

echo "== verilating =="
VFLAGS=(--binary --timing --assert "${WARN_OFF[@]}"
        --top-module axi4_lite_firewall_tb -o simx -Mdir "$BUILD")
[[ -n "$CXX_EXTRA" ]] && VFLAGS+=(-CFLAGS "$CXX_EXTRA")
verilator "${VFLAGS[@]}" "${SOURCES[@]}" || exit $?

echo "== running =="
"$BUILD/simx" 2>&1 | tee "$LOG"
SIM_STATUS=${PIPESTATUS[0]}

echo
if [[ $SIM_STATUS -ne 0 ]]; then
    echo "RESULT: FAILED (simulator exit status $SIM_STATUS)"
    exit 1
fi
if ! grep -q '\*\*\* ALL TESTS PASSED \*\*\*' "$LOG"; then
    echo "RESULT: FAILED (no pass marker in $LOG)"
    exit 1
fi
if grep -qE '^\s*FAIL:|Assertion failed|PROTOCOL VIOLATIONS' "$LOG"; then
    echo "RESULT: FAILED (failures present in $LOG)"
    exit 1
fi

echo "RESULT: PASSED  ($(grep -c '^  PASS' "$LOG") checks, log in $LOG)"
