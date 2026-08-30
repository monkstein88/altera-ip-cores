#!/usr/bin/env bash
# =============================================================================
# run_sim.sh - licence-free regression for avalon_mm_sdram_controller.
#
#   ./run_sim.sh            lint, self-test the timing checker, sweep the tb
#   ./run_sim.sh -q         quiet: summary lines only
#
# Four things run here, in order, because each one is worthless without the one
# before it:
#
#   1. LINT the RTL with -Wall and nothing waived. The testbench needs a couple
#      of waivers for its own idioms; the RTL gets none.
#   2. SELF-TEST the timing checker. It is the thing that decides whether the
#      controller drives the part legally, and it has been wrong before - in
#      two different ways, both of which made it reject legal command streams.
#      Measuring anything with an unchecked ruler is how that went unnoticed.
#   3. RUN the testbench across a parameter sweep. Not lint-only: every
#      configuration is simulated, because the configurations most likely to
#      break are the ones nobody simulates.
#   4. LINT the RTL again in each swept configuration, which catches width and
#      truncation faults that only appear at a particular geometry.
#
# Needs Verilator 5.050 or newer for `--binary --timing`. No licence, no
# Quartus, no vendor libraries.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/.build"
QUIET=0
[[ "${1:-}" == "-q" ]] && QUIET=1

RTL="$ROOT/rtl/avalon_mm_sdram_controller.sv"
TB="$ROOT/tb"

command -v verilator >/dev/null 2>&1 || {
    echo "error: verilator not found in PATH" >&2; exit 1; }

# --timing compiles to C++20 coroutines. GCC before 12 has them behind a flag
# and defaults to a standard that predates them, so a stock Ubuntu 22.04 host
# fails to build the runtime with "the coroutine header requires -fcoroutines".
CXX_EXTRA=""
if command -v g++ >/dev/null 2>&1; then
    GCC_MAJOR="$(g++ -dumpversion | cut -d. -f1)"
    [[ "$GCC_MAJOR" -lt 12 ]] && CXX_EXTRA="-std=gnu++20 -fcoroutines"
fi

# The pip-packaged Verilator writes a precompiled header path into its
# generated makefile and then does not create it, so the link fails with
# "linker input file not found: ...__pch.h.fast". Blanking the variables on
# MAKE's command line overrides the makefile's own assignment; exporting them
# into the environment does not, because a file assignment wins over the
# environment unless make is given -e.
MK_OVERRIDE="VK_PCH_I_FAST= VK_PCH_I_SLOW="

# The testbench needs these three: WIDTH* for its deliberately loose check
# arguments, and INITIALDLY because a stimulus driver assigning from an initial
# block is the point of a stimulus driver. The RTL is linted separately with
# nothing waived at all.
TB_WAIVERS=(-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME -Wno-INITIALDLY)

pass=0; fail=0
say()  { [[ $QUIET -eq 1 ]] || echo "$@"; }
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/        /'; }

mkdir -p "$BUILD"

# -----------------------------------------------------------------------------
# 1. Lint the RTL, nothing waived
# -----------------------------------------------------------------------------
say ""
say "== lint: RTL with -Wall, nothing waived =="
if OUT=$(verilator --lint-only -Wall -Wno-DECLFILENAME --top-module avalon_mm_sdram_controller \
            "$RTL" 2>&1); then
    ok "RTL lints clean (-Wall)"
else
    bad "RTL lint" "$OUT"
fi

# -----------------------------------------------------------------------------
# 2. The timing checker's own threshold self-test
# -----------------------------------------------------------------------------
say ""
say "== self-test: the timing checker fires at the right threshold =="
rm -rf "$BUILD/selftest"
verilator --binary --timing -Wno-WIDTHEXPAND -MAKEFLAGS "$MK_OVERRIDE" \
    --top-module timing_check_selftest -o selftest -Mdir "$BUILD/selftest" \
    ${CXX_EXTRA:+-CFLAGS "$CXX_EXTRA"} \
    "$TB/sdram_timing_check.sv" "$TB/timing_check_selftest.sv" \
    > "$BUILD/selftest.log" 2>&1
if [[ ! -x "$BUILD/selftest/selftest" ]]; then
    bad "timing checker self-test" "$(grep -E '%Error' "$BUILD/selftest.log" | head -3)"
else
    OUT=$("$BUILD/selftest/selftest" 2>&1)
    if grep -q "0 failed" <<<"$OUT"; then
        ok "timing checker self-test: $(grep -oE '[0-9]+ passed, [0-9]+ failed' <<<"$OUT")"
    else
        bad "timing checker self-test" "$(grep -E 'FAIL' <<<"$OUT" | head -3)"
    fi
fi

# -----------------------------------------------------------------------------
# 3. The testbench, across a parameter sweep
#
# Every one of these is simulated, not merely elaborated. CAS latency changes
# the read pipeline and the read-to-write turnaround; FIFO_DEPTH changes the
# backpressure path and how far look-ahead can see; LOOKAHEAD is a whole
# scheduling path; ADDR_MAP changes which access lands in which bank, so it
# re-runs every command-count expectation against a different geometry.
# -----------------------------------------------------------------------------
say ""
say "== testbench: parameter sweep =="
SWEEP=(
    ""                                          # defaults: CAS 3, depth 8, look-ahead on
    "-GCAS_LAT=2"
    "-GLOOKAHEAD=0"
    "-GFIFO_DEPTH=2"
    "-GFIFO_DEPTH=32"
    "-GADDR_MAP=1"
    "-GCAS_LAT=2 -GLOOKAHEAD=0 -GFIFO_DEPTH=2"
    "-GADDR_MAP=1 -GLOOKAHEAD=0"
)
for cfg in "${SWEEP[@]}"; do
    label="${cfg:-defaults}"
    dir="$BUILD/tb_$(echo "$label" | tr -cd 'A-Za-z0-9=' | tr '=' '_')"
    rm -rf "$dir"
    # shellcheck disable=SC2086
    if ! verilator --binary --timing --assert "${TB_WAIVERS[@]}" \
            -MAKEFLAGS "$MK_OVERRIDE" $cfg \
            --top-module avalon_mm_sdram_controller_tb -o tb -Mdir "$dir" \
            ${CXX_EXTRA:+-CFLAGS "$CXX_EXTRA"} \
            "$RTL" "$TB/sdram_device_model.sv" "$TB/sdram_timing_check.sv" \
            "$TB/avalon_mm_sdram_controller_sva.sv" \
            "$TB/avalon_mm_sdram_controller_tb.sv" > "$dir.log" 2>&1; then
        bad "build [$label]" "$(grep -E '%Error' "$dir.log" | head -3)"
        continue
    fi
    if OUT=$("$dir/tb" 2>&1) && grep -q "all tests passed" <<<"$OUT"; then
        ok "[$label] $(grep -oE '[0-9]+ checks passed, [0-9]+ failed' <<<"$OUT")"
    else
        bad "[$label]" "$(grep -E 'FAIL|VIOLATION|Assertion failed|MODEL ERROR' <<<"$OUT" | head -4)"
    fi
done

# -----------------------------------------------------------------------------
# 4. Lint each swept geometry
#
# A width fault that only shows up at, say, a 4-bank 9-column part will not
# appear at the default configuration no matter how long the testbench runs.
# -----------------------------------------------------------------------------
say ""
say "== lint: the RTL in other geometries =="
GEOM=(
    "-GDATA_BITS=32 -GROW_BITS=12 -GCOL_BITS=9  -GBANK_BITS=2 -GSA_BITS=12 -GADDR_W=23"
    "-GDATA_BITS=8  -GROW_BITS=11 -GCOL_BITS=8  -GBANK_BITS=1 -GSA_BITS=11 -GADDR_W=20"
    "-GROW_BITS=14 -GCOL_BITS=11 -GBANK_BITS=3 -GSA_BITS=14 -GADDR_W=28"
    "-GCLK_KHZ=200000 -GCAS_LAT=2"
)
for g in "${GEOM[@]}"; do
    # shellcheck disable=SC2086
    if OUT=$(verilator --lint-only -Wall -Wno-DECLFILENAME $g \
                --top-module avalon_mm_sdram_controller "$RTL" 2>&1); then
        ok "lint [$g]"
    else
        bad "lint [$g]" "$OUT"
    fi
done

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
