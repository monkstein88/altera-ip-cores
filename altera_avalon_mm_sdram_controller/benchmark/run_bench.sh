#!/usr/bin/env bash
# =============================================================================
# run_bench.sh - generate what is missing, build, and run the benchmark.
#
#   ./run_bench.sh                 measure INTEL'S CORE (sdram_mem_ctrl)
#   ./run_bench.sh <module> <file> measure any other controller instead
#
# The second form is how THE CUSTOM CORE is measured:
#
#   ./run_bench.sh avalon_mm_sdram_controller \
#       ../rtl/avalon_mm_sdram_controller.sv
#
# Identical stimulus either way, which is the entire point: "faster" has to be
# the same numbers on the same patterns, not a different benchmark.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/.gen"
BUILD="$HERE/.build"
TB="$(cd "$HERE/../tb" && pwd)"
QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"
export QUARTUS_ROOT

DUT_MODULE="${1:-sdram_mem_ctrl}"
DUT_FILE="${2:-$GEN/sdram_mem_ctrl.v}"

command -v verilator >/dev/null 2>&1 || {
    echo "error: verilator not found in PATH" >&2; exit 1; }

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

# ---- the ruler has to be checked before anything is measured with it --------
# The timing checker had two off-by-one bugs that made it reject legal command
# streams. Fault injection did not catch them; a threshold test does. It costs
# under a second, so there is no reason to make it optional.
echo "== timing checker self-test =="
verilator --binary --timing --top-module timing_check_selftest \
    -o selftest -Mdir "$BUILD.selftest" \
    ${CXX_EXTRA:+-CFLAGS "$CXX_EXTRA"} \
    -Wno-WIDTHEXPAND \
    "$TB/sdram_timing_check.sv" "$TB/timing_check_selftest.sv" || exit $?
"$BUILD.selftest/selftest" | grep -E "FAIL|passed" || exit $?

# ---- generate Intel's core, which is not ours and is never committed --------
# Only Intel's core needs Quartus. The memory model is ours
# (sdram_device_model.sv), so measuring this project's controller needs no
# Quartus installation at all.
if [[ "$DUT_FILE" == "$GEN/sdram_mem_ctrl.v" && ! -f "$DUT_FILE" ]]; then
    bash "$HERE/gen_dut.sh" "$GEN"
fi

[[ -f "$DUT_FILE" ]] || { echo "error: DUT not found: $DUT_FILE" >&2; exit 1; }

echo "== DUT: $DUT_MODULE  ($DUT_FILE)"

# UNOPTFLAT/WIDTH warnings come from Intel's generated RTL and its memory
# model, neither of which is ours to clean up. The harness's own sources are
# linted below with nothing waived.
WARN_OFF=(-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE
          -Wno-DECLFILENAME -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-LATCH
          -Wno-INITIALDLY -Wno-SYNCASYNCNET -Wno-COMBDLY -Wno-CASEX)

echo "== lint (harness sources only, nothing waived) =="
verilator --lint-only -Wall -Wno-DECLFILENAME \
    "$HERE/sdram_traffic_gen.sv" --top-module sdram_traffic_gen || exit $?
echo "lint clean"

echo "== verilating =="
VFLAGS=(--binary --timing --assert "${WARN_OFF[@]}"
        -DDUT_MODULE="$DUT_MODULE"
        --top-module sdram_bench_tb -o bench -Mdir "$BUILD")
[[ -n "$CXX_EXTRA" ]] && VFLAGS+=(-CFLAGS "$CXX_EXTRA")

verilator "${VFLAGS[@]}" \
    "$DUT_FILE" \
    "$TB/sdram_device_model.sv" "$HERE/sdram_traffic_gen.sv" \
    "$TB/sdram_timing_check.sv" "$HERE/sdram_bench_tb.sv" || exit $?

echo "== running =="
"$BUILD/bench"
