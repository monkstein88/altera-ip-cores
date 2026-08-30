#!/usr/bin/env bash
# =============================================================================
# run_sim.sh - board-level simulation of the DE10-Lite demonstration.
#
#   ./run_sim.sh
#
# Simulates the whole demonstration: the sequencer, the Avalon-MM master, the
# Platform Designer system with the controller inside it, and an SDRAM device
# model with a row open per bank - plus the JEDEC timing checker bound to the
# memory bus.
#
# WHAT NEEDS QUARTUS AND WHAT DOES NOT
# ------------------------------------
# Generating the Platform Designer system needs qsys-generate, which is part of
# a Quartus installation but needs no licence. Once generated, everything else
# is Verilator. So the first run wants QUARTUS_ROOT; later ones do not, and
# neither ever wants a licence.
#
# WHAT THIS PROVES AND WHAT ONLY A BOARD PROVES
# ---------------------------------------------
# It proves the controller drives legal commands to the right addresses,
# returns the right data, and that the demonstration's scenarios and their
# checker behave. It does not prove data RETENTION - no functional model can,
# because none of them forget. Refresh correctness on silicon is what
# run_on_board.sh is for.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX="$(cd "$HERE/../.." && pwd)"
CORE="$(cd "$EX/../.." && pwd)"
BUILD="$HERE/.build"
SYS="$EX/qsys/sdram_perbank_sys"

QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"

command -v verilator >/dev/null 2>&1 || {
    echo "error: verilator not found in PATH" >&2; exit 1; }

# ---- generate the Platform Designer system if it is not there ---------------
if [[ ! -f "$SYS/synthesis/sdram_perbank_sys.v" ]]; then
    QSYS="$QUARTUS_ROOT/quartus/sopc_builder/bin"
    [[ -x "$QSYS/qsys-generate" ]] || {
        echo "error: the Platform Designer system has not been generated and" >&2
        echo "       qsys-generate was not found. Set QUARTUS_ROOT." >&2; exit 1; }
    echo "== generating the Platform Designer system =="
    ( cd "$EX/qsys" \
      && "$QSYS/qsys-script" --script=build_system.tcl --search-path="$CORE,\$" \
      && "$QSYS/qsys-generate" sdram_perbank_sys.qsys --synthesis=VERILOG \
             --search-path="$CORE,\$" --output-directory=sdram_perbank_sys ) \
      > "$HERE/.qsys.log" 2>&1 || {
        echo "error: system generation failed - see $HERE/.qsys.log" >&2; exit 1; }
fi

CXX_EXTRA=""
if command -v g++ >/dev/null 2>&1; then
    GCC_MAJOR="$(g++ -dumpversion | cut -d. -f1)"
    [[ "$GCC_MAJOR" -lt 12 ]] && CXX_EXTRA="-std=gnu++20 -fcoroutines"
fi
# See simulation/verilator/run_sim.sh at the core level for why this override
# has to reach make on its command line rather than through the environment.
MK_OVERRIDE="VK_PCH_I_FAST= VK_PCH_I_SLOW="

echo "== verilating =="
rm -rf "$BUILD"
# The generated system is Quartus's output, not ours, so its warnings are
# waived. Everything under rtl/ and tb/ is ours and is linted by the core-level
# regression with nothing waived.
verilator --binary --timing --assert -Wno-fatal \
    -MAKEFLAGS "$MK_OVERRIDE" \
    --top-module de10_lite_sdram_demo_tb -o demo -Mdir "$BUILD" \
    ${CXX_EXTRA:+-CFLAGS "$CXX_EXTRA"} \
    -I"$SYS/synthesis" -I"$SYS/synthesis/submodules" \
    "$SYS/synthesis/sdram_perbank_sys.v" \
    "$SYS/synthesis/submodules/avalon_mm_sdram_controller.sv" \
    "$EX/rtl/demo_sdram_seq.sv" "$EX/rtl/demo_avl_mm_master.sv" \
    "$CORE/tb/sdram_device_model.sv" "$CORE/tb/sdram_timing_check.sv" \
    "$EX/tb/de10_lite_sdram_demo_tb.sv" > "$HERE/.build.log" 2>&1

if [[ ! -x "$BUILD/demo" ]]; then
    echo "error: build failed" >&2
    grep -E "%Error" "$HERE/.build.log" | head -10 >&2
    exit 1
fi

echo "== running =="
"$BUILD/demo"
