#!/usr/bin/env bash
# =============================================================================
# build.sh - build the whole Nios II/f firewall example, from scratch.
#
#   ./build.sh            everything: Qsys system, BSP, software, bitstream
#   ./build.sh qsys       just regenerate the Platform Designer system
#   ./build.sh sw         just the BSP and the application ELF
#   ./build.sh fpga       just the Quartus compilation
#   ./build.sh clean      remove every generated artifact
#
# Set QUARTUS_ROOT if Quartus is not at /opt/intelFPGA/18.1.
#
# Order matters and is not obvious: the BSP is generated FROM the .sopcinfo
# that qsys-generate writes, so the software cannot be built before the
# hardware. Changing the system clock in build_system.tcl and rebuilding only
# the software leaves ALT_CPU_FREQ stale and every HAL delay wrong.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$(cd "$HERE/../.." && pwd)"
COMMON="$(cd "$HERE/../common" && pwd)"

QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"
export QUARTUS_ROOTDIR="$QUARTUS_ROOT/quartus"
export SOPC_KIT_NIOS2="$QUARTUS_ROOT/nios2eds"
export PATH="$SOPC_KIT_NIOS2/sdk2/bin:$SOPC_KIT_NIOS2/bin:$SOPC_KIT_NIOS2/bin/gnu/H-x86_64-pc-linux-gnu/bin:$QUARTUS_ROOTDIR/sopc_builder/bin:$QUARTUS_ROOTDIR/bin:$PATH"

# The IP search path is how Platform Designer finds the firewall (in the core
# directory) and the protected peripheral (in example/common). Without it,
# add_instance fails with "No module type named altera_axi4_lite_firewall".
SEARCH="$CORE/,$COMMON/,\$"

command -v qsys-script >/dev/null || { echo "error: Quartus not found under $QUARTUS_ROOT" >&2; exit 127; }

do_qsys() {
    echo "=== Platform Designer system ==="
    cd "$HERE/qsys"
    rm -rf firewall_sys firewall_sys.sopcinfo
    qsys-script --script=build_system.tcl --search-path="$SEARCH"

    # The ALTPLL wizard stamps a timestamp-derived MIF name into the .qsys
    # (PT#RECONFIG_FILE ALTPLL<digits>.mif) on every run. It is GUI bookkeeping
    # for PLL reconfiguration, which this system does not use, but it is enough
    # to make the tracked .qsys show a one-line diff after every regeneration.
    # Pin it so regenerating an unchanged system produces an unchanged file.
    sed -i 's/PT#RECONFIG_FILE ALTPLL[0-9]*\.mif/PT#RECONFIG_FILE ALTPLL_firewall_sys.mif/' \
        firewall_sys.qsys

    qsys-generate firewall_sys.qsys --synthesis=VERILOG \
        --search-path="$SEARCH" --output-directory=firewall_sys
}

do_sw() {
    echo "=== Nios II BSP ==="
    cd "$HERE"
    [ -f qsys/firewall_sys.sopcinfo ] || { echo "error: run './build.sh qsys' first" >&2; exit 1; }
    rm -rf software/bsp
    nios2-bsp hal software/bsp qsys --cpu-name cpu

    echo "=== application ==="
    cd "$HERE/software"
    rm -rf obj axi4_lite_firewall_demo.elf axi4_lite_firewall_demo.map axi4_lite_firewall_demo.objdump Makefile
    # main.c only. The driver is NOT listed here and is not copied into this
    # directory: it comes from the component's axi4_lite_firewall_sw.tcl, which
    # the BSP generator matches to the hardware by hw_class_name. That is the
    # whole point of shipping a _sw.tcl - adding the component to a Platform
    # Designer system is enough.
    nios2-app-generate-makefile --bsp-dir bsp --app-dir . \
        --elf-name axi4_lite_firewall_demo.elf --src-files main.c
    make
}

do_fpga() {
    echo "=== Quartus compilation ==="
    cd "$HERE/quartus"
    quartus_sh --flow compile de10_lite_nios
}

do_clean() {
    cd "$HERE"
    # firewall_sys.qsys is tracked - regenerate it with './build.sh qsys',
    # never delete it here, or a clean would leave the working tree dirty.
    rm -rf qsys/firewall_sys qsys/firewall_sys.sopcinfo
    rm -rf software/bsp software/obj software/Makefile
    rm -f  software/axi4_lite_firewall_demo.elf software/axi4_lite_firewall_demo.map software/axi4_lite_firewall_demo.objdump
    rm -rf quartus/db quartus/incremental_db quartus/output_files
    (cd software/test && make clean >/dev/null 2>&1) || true
    echo "cleaned"
}

case "${1:-all}" in
    qsys)  do_qsys ;;
    sw)    do_sw ;;
    fpga)  do_fpga ;;
    clean) do_clean ;;
    all)   do_qsys; do_sw; do_fpga
           echo
           echo "=== done ==="
           echo "  bitstream : quartus/output_files/de10_lite_nios.sof"
           echo "  software  : software/axi4_lite_firewall_demo.elf"
           echo
           echo "To run it:"
           echo "  quartus_pgm -m jtag -o \"p;quartus/output_files/de10_lite_nios.sof\""
           echo "  nios2-download -g software/axi4_lite_firewall_demo.elf && nios2-terminal"
           ;;
    *)     echo "usage: $0 [all|qsys|sw|fpga|clean]" >&2; exit 2 ;;
esac
