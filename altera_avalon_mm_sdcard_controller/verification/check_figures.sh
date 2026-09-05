#!/usr/bin/env bash
# =============================================================================
# check_figures.sh - the tracked figures must match what their generators emit.
#
#   ./verification/check_figures.sh
#
# Exit 0 if every SVG in doc/figures/ is byte-identical to a fresh render, 1 if
# any has drifted.
#
# -----------------------------------------------------------------------------
# WHY
# -----------------------------------------------------------------------------
# check_facts.py verifies that the figures EXIST and that the numbers claimed
# around them match the RTL. It cannot tell whether the SVG in the repository is
# what today's generator would produce - so a figure can be regenerated,
# committed, and then silently left behind by a later change to the diagram
# script or the RTL it describes. A stale picture is worse than a missing one,
# because a reader has no reason to distrust it.
#
# The block diagrams are checked unconditionally: their generator needs nothing
# but Python.
#
# The timing figures need verification/wave.vcd, which is NOT tracked - it is a
# few megabytes of recording that regenerates in seconds. If it is absent this
# script says so and skips them rather than failing, because "you have not run
# capture.sh" is not the same finding as "a figure has drifted". Run
# ./verification/capture.sh first to have them checked too.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
checked=0

compare () {
    local name="$1"
    local a="$ROOT/doc/figures/$name" b="$WORK/$name"
    checked=$((checked + 1))
    if [ ! -f "$a" ]; then
        echo "  FAIL  $name is not in doc/figures/"
        fail=1
    elif ! cmp -s "$a" "$b"; then
        echo "  FAIL  $name differs from a fresh render - regenerate and commit"
        fail=1
    else
        echo "  ok    $name"
    fi
}

echo ""
echo "=== figures match their generators ==="
echo ""

# ---- block diagrams ---------------------------------------------------------
if ! python3 "$ROOT/doc/tools/diagrams/build_figures.py" "$WORK" >/dev/null 2>&1
then
    echo "  FAIL  build_figures.py did not run"
    python3 "$ROOT/doc/tools/diagrams/build_figures.py" "$WORK" 2>&1 | tail -5
    exit 1
fi
for f in fig_context fig_internal fig_regmap fig_states fig_datapath; do
    compare "$f.svg"
done

# ---- timing figures ---------------------------------------------------------
VCD="$ROOT/verification/wave.vcd"
if [ ! -s "$VCD" ]; then
    echo ""
    echo "  --    timing figures not checked: verification/wave.vcd is absent."
    echo "        Run ./verification/capture.sh to record it, then re-run this."
else
    if ! python3 "$ROOT/doc/tools/waveforms/mkwaves.py" "$VCD" "$WORK" \
            >/dev/null 2>&1; then
        echo "  FAIL  mkwaves.py did not run against the recorded VCD"
        python3 "$ROOT/doc/tools/waveforms/mkwaves.py" "$VCD" "$WORK" 2>&1 | tail -5
        fail=1
    else
        for f in fig_wave_bit fig_wave_cmd fig_wave_read fig_wave_write \
                 fig_wave_crcerr; do
            compare "$f.svg"
        done
    fi
fi

echo ""
if [ $fail -eq 0 ]; then
    echo "*** PASS *** ($checked figures identical to a fresh render)"
else
    echo "*** FAIL ***"
fi
echo ""
exit $fail
