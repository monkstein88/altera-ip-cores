#!/usr/bin/env bash
# =============================================================================
# run_all.sh - everything that can be checked without a board or a licence.
#
#   ./verification/run_all.sh
#
# Exit 0 only if every suite passes. Each one prints its own result; this script
# reports the roll-up and the exit status is the AND of them all.
#
# Five suites, deliberately different in kind:
#
#   lint          the RTL under -Wall, across every parameter configuration
#                 that changes what gets built
#   simulation    three Verilator testbenches against a card model and a
#                 memory model
#   hw.tcl        the Platform Designer component executed against stubbed
#                 Qsys commands
#   driver        the HAL driver compiled against stubbed Nios II headers
#   assertions    three faults injected into scratch copies of the RTL, each
#                 required to be caught by the assertion meant to catch it -
#                 because an assertion that cannot fail passes just as
#                 convincingly as one doing real work
#   facts         every number in the documentation re-derived from source
#
# The last three need no simulator at all, which matters: they catch the dull
# mechanical faults - a renamed parameter, a port on an interface that does not
# exist, a typo in the driver, a stale figure in the README - that otherwise
# survive until someone with the full Quartus toolchain tries to build.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

fail=0
summary=()

run () {
    local name="$1"; shift
    if "$@" > /tmp/runall.$$ 2>&1; then
        summary+=("  PASS  $name")
    else
        summary+=("  FAIL  $name")
        echo "--- $name ---"
        tail -25 /tmp/runall.$$
        fail=1
    fi
    rm -f /tmp/runall.$$
}

# ---------------------------------------------------------------------------
# Lint, across the configurations that change what is built.
# ---------------------------------------------------------------------------
lint_all () {
    if ! command -v verilator >/dev/null 2>&1; then
        PIPROOT=$(python3 -c 'import verilator,os;print(os.path.dirname(verilator.__file__))' 2>/dev/null)
        [ -n "${PIPROOT:-}" ] && { export VERILATOR_ROOT="$PIPROOT"; export PATH="$PIPROOT/bin:$PATH"; }
    fi
    command -v verilator >/dev/null 2>&1 || { echo "verilator not found"; return 1; }

    local P="$ROOT/rtl/avalon_mm_sdcard_controller"
    local ORDER=("${P}_pkg.sv" "${P}_crc.sv" "${P}_clkgen.sv" "${P}_spi_phy.sv"
                 "${P}_fifo.sv" "${P}_dma.sv" "${P}_seq.sv" "${P}_regs.sv" "${P}.sv")
    local rc=0
    for cfg in USE_DMA=1 USE_DMA=0 USE_CARD_DETECT=0 USE_CRC=0 \
               M0_BURST_WIDTH=1 FIFO_DEPTH_BYTES=512 FIFO_DEPTH_BYTES=8192 \
               MAX_BLOCK_BYTES=512 CLKDIV_WIDTH=16 TIMEOUT_WIDTH=32; do
        local out n
        out=$(verilator --lint-only -Wall -Wno-UNUSEDPARAM -Wno-DECLFILENAME \
                "${ORDER[@]}" "-G$cfg" --top-module avalon_mm_sdcard_controller 2>&1)
        # Verilator prints a Verilation Report on success too, so the presence
        # of output means nothing. Count actual diagnostics.
        n=$(printf '%s\n' "$out" | grep -cE '^%(Error|Warning)')
        if [ "$n" -eq 0 ]; then
            echo "  $cfg: clean"
        else
            echo "  $cfg: $n diagnostic(s)"
            printf '%s\n' "$out" | grep -E '^%(Error|Warning)' | head -4
            rc=1
        fi
    done
    return $rc
}

echo ""
echo "======================================================================"
echo " avalon_mm_sdcard_controller - full check"
echo "======================================================================"

run "lint, 10 parameter configurations"  lint_all
run "simulation, 3 testbenches"          "$ROOT/simulation/verilator/run_sim.sh"
run "Platform Designer component"        tclsh "$ROOT/verification/check_hw_tcl.tcl"
run "HAL driver compiles"                "$ROOT/verification/check_driver_builds.sh"
run "assertions actually fire"           "$ROOT/verification/check_assertions_fire.sh"
run "documentation facts"                python3 "$ROOT/doc/tools/check_facts.py"
run "CRC reference vectors"              python3 "$ROOT/verification/models/crc_reference.py"

echo ""
printf '%s\n' "${summary[@]}"
echo ""
if [ $fail -eq 0 ]; then
    echo "*** ALL CHECKS PASS ***"
else
    echo "*** SOMETHING FAILED ***"
fi
echo ""
exit $fail
