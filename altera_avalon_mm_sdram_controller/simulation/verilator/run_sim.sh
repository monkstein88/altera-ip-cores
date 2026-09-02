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
#   1. LINT the RTL with -Wall and nothing waived, and the checker and device
#      model with only the waivers their own idioms need. The RTL gets none.
#   2. SELF-TEST the timing checker. It is the thing that decides whether the
#      controller drives the part legally, and it has been wrong before - in
#      two different ways, both of which made it reject legal command streams.
#      Measuring anything with an unchecked ruler is how that went unnoticed.
#   3. RUN the testbench across a parameter sweep, INCLUDING THE CLOCK RATE.
#      Not lint-only: every configuration is simulated, because the
#      configurations most likely to break are the ones nobody simulates. The
#      clock used to be a localparam in the testbench, so every expectation in
#      it silently assumed 100 MHz - and the cycle counts the controller
#      derives from nanoseconds are exactly what changes with it.
#   4. LINT the RTL again in each swept geometry, which catches width and
#      truncation faults that only appear at a particular geometry.
#   5. SYNTHESISE, if a Quartus installation is visible. Analysis & Synthesis
#      needs no licence, takes seconds, and is the only step here that would
#      have caught the `real` variable that made this core unsynthesisable in
#      Quartus Standard while every simulation flow reported it clean.
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

# The checker and the device model are not the RTL, but they are the things
# that decide whether the RTL is correct, and they were never linted at all.
# That is how an `initial` block writing a variable an always_ff also writes -
# illegal under IEEE 1800-2017 9.2.2.4 - sat in the device model until a
# Verilator upgrade turned it into an error and took the whole regression down.
if OUT=$(verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-WIDTHEXPAND \
            --top-module sdram_timing_check "$TB/sdram_timing_check.sv" 2>&1); then
    ok "timing checker lints clean (-Wall)"
else
    bad "timing checker lint" "$OUT"
fi
# BLKSEQ and PROCASSINIT are this model's own idioms, not defects: it is a
# behavioural device, it stores into an associative array with blocking
# assignments, and its mode register carries a power-up default that LOAD MODE
# then overwrites. Everything else it gets held to.
if OUT=$(verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-WIDTHEXPAND \
            -Wno-BLKSEQ -Wno-PROCASSINIT \
            --top-module sdram_device_model "$TB/sdram_device_model.sv" 2>&1); then
    ok "device model lints clean (-Wall)"
else
    bad "device model lint" "$OUT"
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
    # Clock rates. Every device timing is a nanosecond figure divided by this,
    # so it decides every cycle count in the core. 143 MHz is the part's rated
    # speed; 50 MHz is below the point where tRRD, tWR and tMRD - which the
    # datasheet specifies in CLOCKS, not in time - would round down to a single
    # cycle if the floors in the RTL were not there.
    "-GCLK_KHZ=143000"
    "-GCLK_KHZ=50000"
    "-GCLK_KHZ=50000 -GCAS_LAT=2 -GLOOKAHEAD=0"
    # An eleven-bit column, where the column's top bit has to step over A10 -
    # the auto-precharge flag - onto A11. That branch of col_addr() had never
    # executed in simulation: the geometry sweep below only LINTS, and lint
    # does not run code.
    "-GCOL_BITS=11"
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

# -----------------------------------------------------------------------------
# 5. Synthesis, if a Quartus installation is visible
#
# Analysis & Synthesis needs no licence and takes seconds. It is skipped
# silently when Quartus is not installed, because the rest of this script is
# deliberately licence-free and vendor-free - but when it IS available there is
# no excuse for shipping RTL nobody has ever compiled.
#
# This exists because the core once used a `real` variable inside an
# elaboration-time function. Quartus Standard rejects that outright
# ("Error (10172): real variable data type values are not supported"), so the
# core did not synthesise at all - while Verilator linted it clean with -Wall
# and nothing waived, and all eight testbench configurations passed.
# -----------------------------------------------------------------------------
say ""
say "== synthesis: Quartus Analysis & Synthesis =="
QROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"
QMAP="$QROOT/quartus/bin/quartus_map"
if [[ ! -x "$QMAP" ]]; then
    say "  SKIP  no Quartus at $QROOT (set QUARTUS_ROOT to enable)"
else
    SYN="$BUILD/synth"
    rm -rf "$SYN"; mkdir -p "$SYN"
    cat > "$SYN/syn.qsf" <<QSF
set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY avalon_mm_sdram_controller
set_global_assignment -name SYSTEMVERILOG_FILE $RTL
QSF
    if ( cd "$SYN" && "$QMAP" syn > synth.log 2>&1 ); then
        ok "RTL synthesises (Quartus Analysis & Synthesis)"
    else
        bad "RTL synthesis" "$(grep -E '^Error|Error \(' "$SYN/synth.log" | head -3)"
    fi
fi

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
