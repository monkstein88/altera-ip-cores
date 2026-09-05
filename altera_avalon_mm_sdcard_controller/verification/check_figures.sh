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
# check_facts.py verifies that the figures EXIST and that the numbers around
# them match the RTL. It cannot tell whether the SVG in the repository is what
# today's generator would produce - so a figure can be regenerated, committed,
# and then quietly left behind by a later change to its source or to the RTL it
# describes. A stale picture is worse than a missing one: a reader has no reason
# to distrust it.
#
# Two toolchains, and each degrades differently when its tools are absent:
#
#   Graphviz   block diagrams. Needs `dot`. Checked whenever it is installed.
#   WaveDrom   timing figures. Needs verification/wave.vcd, Node, and the
#              wavedrom module. The VCD is not tracked - it is a few megabytes
#              that regenerate in seconds - so on a fresh clone this half is
#              skipped rather than failed. "You have not run capture.sh" is not
#              the same finding as "a figure has drifted", and reporting them
#              the same way trains people to ignore the result.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
checked=0
skipped=""

compare () {
    local name="$1"
    local a="$ROOT/doc/figures/$name" b="$WORK/$name"
    checked=$((checked + 1))
    if [ ! -f "$a" ]; then
        echo "  FAIL  $name is not in doc/figures/"
        fail=1
    elif [ ! -f "$b" ]; then
        echo "  FAIL  $name was not produced by a fresh run"
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

# ---- block diagrams, via Graphviz -------------------------------------------
if ! command -v dot >/dev/null 2>&1; then
    skipped="$skipped
  --    block diagrams not checked: graphviz is not installed (apt install graphviz)."
else
    if ! python3 "$ROOT/doc/tools/diagrams/build_figures.py" "$WORK" \
            >/dev/null 2>&1; then
        echo "  FAIL  build_figures.py did not run"
        python3 "$ROOT/doc/tools/diagrams/build_figures.py" "$WORK" 2>&1 | tail -5
        exit 1
    fi
    for f in fig_context fig_internal fig_states fig_datapath; do
        compare "$f.dot"
        compare "$f.svg"
    done
fi

# ---- timing figures, via WaveDrom -------------------------------------------
VCD="$ROOT/verification/wave.vcd"
WAVE_JS="$ROOT/doc/tools/waveforms/render.js"
have_node=0
command -v node >/dev/null 2>&1 && have_node=1
command -v nodejs >/dev/null 2>&1 && have_node=1

if [ ! -s "$VCD" ]; then
    skipped="$skipped
  --    timing figures not checked: verification/wave.vcd is absent.
        Run ./verification/capture.sh to record it, then re-run this."
elif [ $have_node -eq 0 ]; then
    skipped="$skipped
  --    timing figures not checked: node is not installed.
        The WaveDrom JSON is still compared; only the SVG render needs Node."
    if python3 "$ROOT/doc/tools/waveforms/mkwaves.py" "$VCD" "$WORK" \
            >/dev/null 2>&1; then
        for f in fig_wave_bit fig_wave_cmd fig_wave_read fig_wave_write \
                 fig_wave_crcerr; do
            compare "$f.json"
        done
        compare "wave_facts.json"
    fi
else
    if ! python3 "$ROOT/doc/tools/waveforms/mkwaves.py" "$VCD" "$WORK" \
            >/dev/null 2>&1; then
        echo "  FAIL  mkwaves.py did not run against the recorded VCD"
        python3 "$ROOT/doc/tools/waveforms/mkwaves.py" "$VCD" "$WORK" 2>&1 | tail -5
        fail=1
    else
        for f in fig_wave_bit fig_wave_cmd fig_wave_read fig_wave_write \
                 fig_wave_crcerr; do
            compare "$f.json"
            compare "$f.svg"
        done
        compare "wave_facts.json"
    fi
fi

echo ""
[ -n "$skipped" ] && printf '%s\n\n' "${skipped# }"
if [ $fail -eq 0 ]; then
    echo "*** PASS *** ($checked files identical to a fresh render)"
else
    echo "*** FAIL ***"
fi
echo ""
exit $fail
