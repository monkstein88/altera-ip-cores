#!/usr/bin/env bash
# =============================================================================
# build.sh - build the Nios II SDRAM controller example end to end (DE10-Lite).
#
#   ./build.sh            everything: Qsys system, BSP, application, bitstream
#   ./build.sh qsys       just regenerate the Platform Designer system
#   ./build.sh sw         just the BSP and the application
#   ./build.sh fpga       just the Quartus compile
#   ./build.sh clean      remove build artifacts (leaves sdram_nios_sys.qsys)
#
# QUARTUS 18.1 IS REQUIRED, for one specific reason: newer Quartus Standard
# releases no longer ship the Nios II PROCESSOR IP. In 25.1std the catalog
# directory ip/altera/nios2_ip/ is empty, so Platform Designer cannot
# instantiate altera_nios2_gen2 and this system will not build there.
#
# Note what is NOT the reason. 25.1std still ships the Nios II software tools
# (nios2eds/sdk2/bin: nios2-bsp, nios2-download, nios2-terminal), and it still
# supports MAX 10 - quartus/common/devkits/max10_de10_lite and the MAX 10
# ALTPLL libraries are both present. It is only the CPU component that is
# missing.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../.."                      # the altera_avalon_mm_sdram_controller component
COMMON="$HERE/../common"

QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"
QSYS="$QUARTUS_ROOT/quartus/sopc_builder/bin"
N2="$QUARTUS_ROOT/nios2eds/sdk2/bin"

# Where Platform Designer and the BSP generator look for components. The core
# and the demo peripheral are found here rather than through your global IP
# settings, so this builds the same way on any machine.
SEARCH="$CORE,$COMMON,\$"

export SOPC_KIT_NIOS2="$QUARTUS_ROOT/nios2eds"
export QUARTUS_ROOTDIR="$QUARTUS_ROOT/quartus"

# The BSP tools shell out to each other by bare name, so they have to be on
# PATH - nios2-bsp calls nios2-bsp-create-settings, which calls more of them.
# Invoking them by absolute path alone gets as far as the first hand-off and
# then fails with "command not found".
export PATH="$SOPC_KIT_NIOS2/sdk2/bin:$SOPC_KIT_NIOS2/bin:$QUARTUS_ROOTDIR/bin:$PATH"
export PATH="$SOPC_KIT_NIOS2/bin/gnu/H-x86_64-pc-linux-gnu/bin:$PATH"

step_qsys() {
    echo "=== Platform Designer system ==="
    cd "$HERE/qsys"
    "$QSYS/qsys-script" --script=build_system.tcl --search-path="$SEARCH"
    "$QSYS/qsys-generate" sdram_nios_sys.qsys --synthesis=VERILOG \
        --search-path="$SEARCH" --output-directory=sdram_nios_sys
}

step_sw() {
    echo "=== BSP ==="
    cd "$HERE/software"
    rm -rf bsp
    # There is no driver to pull in: the SDRAM controller presents plain
    # memory, so software reaches it with a pointer and needs no HAL device
    # layer. What the BSP does provide is system.h, from which main.c takes
    # SDRAM_BASE and SDRAM_SPAN - so the test addresses whatever the preset
    # actually configured rather than a constant typed twice.
    "$N2/nios2-bsp" hal bsp "$HERE/qsys/sdram_nios_sys.sopcinfo" \
        --script "$SOPC_KIT_NIOS2/sdk2/bin/bsp-set-defaults.tcl" \
        --cmd set_setting hal.enable_reduced_device_drivers false \
        --cmd set_setting hal.enable_sim_optimize false \
        --cmd set_setting hal.stdout jtag_uart \
        --cmd set_setting hal.stderr jtag_uart \
        --cmd set_setting hal.timestamp_timer timer \
        --cmd set_setting hal.sys_clk_timer timer \
        --default_sections_mapping onchip_ram

    echo "=== application ==="
    cd "$HERE/software"
    rm -rf obj Makefile sdram_memtest.elf
    "$N2/nios2-app-generate-makefile" --bsp-dir bsp --elf-name sdram_memtest.elf \
        --src-files main.c --set APP_CFLAGS_WARNINGS "-Wall -Wextra" \
        --set APP_CFLAGS_OPTIMIZATION "-Os"
    make
}

step_fpga() {
    echo "=== Quartus ==="
    cd "$HERE/quartus"
    "$QUARTUS_ROOT/quartus/bin/quartus_sh" --flow compile de10_lite_sdram_nios
}

step_clean() {
    rm -rf "$HERE/qsys/sdram_nios_sys" "$HERE/qsys/.qsys_edit" \
           "$HERE/software/bsp" "$HERE/software/obj" \
           "$HERE/software/Makefile" "$HERE/software"/*.elf \
           "$HERE/software"/*.objdump "$HERE/software"/*.map \
           "$HERE/quartus/db" "$HERE/quartus/incremental_db" \
           "$HERE/quartus/output_files"
    echo "cleaned (sdram_nios_sys.qsys kept - it is tracked)"
}

case "${1:-all}" in
    qsys)  step_qsys ;;
    sw)    step_sw ;;
    fpga)  step_fpga ;;
    clean) step_clean ;;
    all)   step_qsys; step_fpga; step_sw ;;
    *) echo "usage: $0 [all|qsys|sw|fpga|clean]" >&2; exit 1 ;;
esac
echo "done."
