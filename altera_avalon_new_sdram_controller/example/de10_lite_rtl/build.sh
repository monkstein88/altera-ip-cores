#!/usr/bin/env bash
# =============================================================================
# build.sh - build the SDRAM controller RTL example end to end.
#
#   ./build.sh          everything: Platform Designer system, then Quartus
#   ./build.sh qsys     just regenerate the Platform Designer system
#   ./build.sh fpga     just the Quartus compile
#   ./build.sh sim      generate the SDRAM memory model and run the testbench
#   ./build.sh clean    remove build artifacts (leaves sdram_sys.qsys)
#
# Quartus 18.1 Standard is what this was built and verified with. Unlike the
# Nios examples in this repository there is no CPU here, so a newer Quartus
# Standard that still supports MAX 10 should also work - but the numbers in
# README.md come from 18.1.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../.."                      # the altera_avalon_new_sdram_controller component

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
    "$QSYS/qsys-generate" sdram_sys.qsys --synthesis=VERILOG \
        --search-path="$SEARCH" --output-directory=sdram_sys
}

step_sim() {
    echo "=== SDRAM memory model ==="
    "$HERE/simulation/gen_mem_model.sh"
    echo "=== Questa ==="
    cd "$HERE/simulation/questa"
    vsim -c -do run_sim.tcl
}

step_fpga() {
    echo "=== Quartus ==="
    cd "$HERE/quartus"
    "$QUARTUS_ROOT/quartus/bin/quartus_sh" --flow compile de10_lite_avl_mm_sdram_demo
}

step_clean() {
    rm -rf "$HERE/qsys/sdram_sys" "$HERE/qsys/.qsys_edit" \
           "$HERE/simulation/.gen" "$HERE/simulation/questa/work" \
           "$HERE/simulation/questa/transcript" \
           "$HERE/quartus/db" "$HERE/quartus/incremental_db" \
           "$HERE/quartus/output_files"
    echo "cleaned (sdram_sys.qsys kept - it is tracked)"
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
