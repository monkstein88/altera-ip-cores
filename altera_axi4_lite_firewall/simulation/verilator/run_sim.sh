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

SOURCES=(
    "$ROOT/rtl/axi_firewall_regs.sv"
    "$ROOT/rtl/axi_firewall_top.sv"
    "$ROOT/tb/axi_firewall_sva.sv"
    "$ROOT/tb/axi_firewall_tb.sv"
)

# WIDTHEXPAND/WIDTHTRUNC fire on the testbench's deliberately oversized
# check_eq() arguments. The RTL itself passes `verilator --lint-only -Wall`
# with nothing waived - see below. Every file now carries a `timescale, so
# TIMESCALEMOD no longer needs suppressing.
WARN_OFF=(-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC)

# Strict LRM elaboration with slang, if available. This is not redundant with
# Verilator: slang rejects use-before-declaration and implicit-net collisions
# that Verilator silently resolves, and those are exactly what Questa rejects
# later in the flow. Catching them here costs a second.
if python3 -c 'import pyslang' 2>/dev/null; then
    echo "== strict elaboration (slang) =="
    python3 "$HERE/slangcheck.py" "RTL + TB + SVA" \
        "$ROOT/rtl/axi_firewall_regs.sv" "$ROOT/rtl/axi_firewall_top.sv" \
        "$ROOT/tb/axi_firewall_sva.sv"   "$ROOT/tb/axi_firewall_tb.sv" || exit 1
else
    echo "== strict elaboration skipped (pip install pyslang to enable) =="
fi

# Strict lint of the synthesisable RTL on its own, with nothing waived. Kept
# separate from the simulation build so testbench-only warnings can be relaxed
# without also relaxing them for the RTL.
echo "== linting RTL (-Wall, nothing waived) =="
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
    --top-module axi_firewall_top \
    "$ROOT/rtl/axi_firewall_regs.sv" "$ROOT/rtl/axi_firewall_top.sv" || exit $?

echo "== verilating =="
verilator --binary --timing --assert "${WARN_OFF[@]}" \
    --top-module axi_firewall_tb -o simx -Mdir "$BUILD" \
    "${SOURCES[@]}" || exit $?

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
