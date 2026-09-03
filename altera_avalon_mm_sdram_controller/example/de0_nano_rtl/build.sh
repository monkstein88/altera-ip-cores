#!/usr/bin/env bash
# =============================================================================
# build.sh - build the SDRAM controller RTL example end to end (DE0-Nano).
#
#   ./build.sh          everything: Platform Designer system, then Quartus
#   ./build.sh qsys     just regenerate the Platform Designer system
#   ./build.sh fpga     just the Quartus compile
#   ./build.sh sim      generate the SDRAM memory model and run the testbench
#   ./build.sh clean    remove build artifacts (leaves sdram_nano_sys.qsys)
#
# Quartus 18.1 Standard is what this was built and verified with. There is no
# CPU here, so a newer Quartus Standard that still supports Cyclone IV E
# should also work - but the numbers in README.md come from 18.1.
#
# EDITING THE CONTROLLER? RUN `qsys` (or the full build), NOT JUST `fpga`.
#
# qsys-generate COPIES rtl/avalon_mm_sdram_controller.sv into
# qsys/<system>/synthesis/submodules/. Everything downstream - Quartus AND the
# board-level simulation - compiles that copy, not the file you edited. So
# `./build.sh fpga` after a change to the controller silently builds the
# PREVIOUS controller, and a stale copy left behind by an interrupted build
# keeps being simulated until someone regenerates.
#
# Both failure modes have happened here: a fault-injection run that appeared to
# prove the design immune to a fault never present in the bitstream, and a
# board-level testbench that failed four scenarios against a controller the
# working tree no longer contained.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../.."                      # the altera_avalon_mm_sdram_controller component

QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"
QSYS="$QUARTUS_ROOT/quartus/sopc_builder/bin"

# Where Platform Designer looks for components. The controller is found here
# rather than through your global IP settings, so this builds the same way on
# any machine.
SEARCH="$CORE,\$"

export QUARTUS_ROOTDIR="$QUARTUS_ROOT/quartus"

step_qsys() {
    echo "=== Platform Designer system ==="
    cd "$HERE/qsys"
    "$QSYS/qsys-script"   --script=build_system.tcl --search-path="$SEARCH"
    "$QSYS/qsys-generate" sdram_nano_sys.qsys --synthesis=VERILOG \
        --search-path="$SEARCH" --output-directory=sdram_nano_sys
}

step_sim() {
    # Verilator, not Questa: the device model is this project's own, so the
    # board-level simulation needs no licence and no memory model generated
    # from a Quartus installation.
    echo "=== board-level simulation ==="
    "$HERE/simulation/verilator/run_sim.sh"
}

step_fpga() {
    echo "=== Quartus ==="
    cd "$HERE/quartus"
    "$QUARTUS_ROOT/quartus/bin/quartus_sh" --flow compile de0_nano_sdram_demo
}

step_clean() {
    rm -rf "$HERE/qsys/sdram_nano_sys" "$HERE/qsys/.qsys_edit" \
           "$HERE/simulation/verilator/.build" \
           "$HERE/quartus/db" "$HERE/quartus/incremental_db" \
           "$HERE/quartus/output_files"
    echo "cleaned (sdram_nano_sys.qsys kept - it is tracked)"
}

case "${1:-all}" in
    qsys)  step_qsys ;;
    sim)   step_sim ;;
    fpga)  step_fpga ;;
    clean) step_clean ;;
    all)   step_qsys; step_fpga ;;
    *) echo "usage: $0 [all|qsys|sim|fpga|clean]" >&2; exit 1 ;;
esac
echo "done."
