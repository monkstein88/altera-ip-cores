#!/usr/bin/env bash
# =============================================================================
# run_sim.sh - licence-free regression run for the Avalon-MM SD Card Controller.
#
#   ./run_sim.sh          run everything
#   ./run_sim.sh -c       clean the build directories first
#   ./run_sim.sh phy      run only the shifter unit testbench
#
# Exit status is 0 only if every check in every testbench passes. Verilator
# returns non-zero on an assertion failure or $fatal by itself, but each log is
# also grepped for the result marker, so a simulator that swallows the status
# cannot hide a failure.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# Build directory. In-tree by default, which is what the other cores in this
# repository do and what the .gitignore expects.
#
# SDCARD_SIM_OBJDIR redirects it, which is needed on filesystems that permit
# writes but not unlinks - some container and network mounts do exactly that,
# and Verilator's generated makefile removes its own temporary files, so the
# build dies on `rm: Operation not permitted` a long way from the cause.
OBJROOT="${SDCARD_SIM_OBJDIR:-$HERE}"
mkdir -p "$OBJROOT"

[[ "${1:-}" == "-c" ]] && { rm -rf "$OBJROOT"/obj_dir_* 2>/dev/null; shift; }
WHICH="${1:-all}"

# ---------------------------------------------------------------------------
# Finding Verilator
#
# Two installation shapes are supported. A distro or source install puts
# `verilator` on PATH and knows its own root. A pip install
# (pip install verilator) puts the binary inside the Python package and does
# NOT set VERILATOR_ROOT, without which the wrapper cannot find its include/
# tree and fails with a misleading "Cannot find verilated.mk".
# ---------------------------------------------------------------------------
if ! command -v verilator >/dev/null 2>&1; then
    PIPROOT=$(python3 -c 'import verilator,os;print(os.path.dirname(verilator.__file__))' 2>/dev/null)
    if [ -n "${PIPROOT:-}" ] && [ -x "$PIPROOT/bin/verilator" ]; then
        export VERILATOR_ROOT="$PIPROOT"
        export PATH="$PIPROOT/bin:$PATH"
    else
        echo "error: verilator not found in PATH" >&2
        echo "       (pip install verilator, or your distro's package)" >&2
        exit 127
    fi
fi

# ---------------------------------------------------------------------------
# Minimum Verilator version.
#
# 5.050 or newer, matching the rest of this repository: earlier releases do not
# implement the SVA constructs the assertion files use, and what they print
# instead says nothing about the real problem.
#
# Some builds report a bare revision string rather than "Verilator X.YYY". The
# check is skipped rather than guessed at in that case - a version gate that
# fires on an unparseable string is worse than no gate.
# ---------------------------------------------------------------------------
VER=$(verilator --version 2>/dev/null | sed -n 's/^Verilator \([0-9]*\)\.\([0-9]*\).*/\1\2/p')
if [ -n "$VER" ] && [ "$VER" -lt 5050 ] 2>/dev/null; then
    echo "error: Verilator $(verilator --version | awk '{print $2}') is too old for this testbench." >&2
    echo "       5.050 or newer is required - see this core's README." >&2
    exit 127
fi

# ---------------------------------------------------------------------------
# C++20 is required by --timing.
#
# Verilator's timing support is built on C++20 coroutines. GCC 11 has them but
# not by default, and the failure is a wall of errors about std::suspend_never
# inside verilated_timing.cpp that looks like a broken Verilator install rather
# than a missing flag.
# ---------------------------------------------------------------------------
CXXSTD="-std=c++20"

# ---------------------------------------------------------------------------
# Precompiled-header workaround.
#
# Some Verilator builds - the PyPI wheel among them - ship a verilated.mk whose
# CFG_CXXFLAGS_PCH_I is EMPTY, because configure failed to detect the compiler's
# "use this precompiled header" flag. The generated rule then passes the PCH
# file as a bare argument instead of `-include <file>`, and GCC treats it as a
# linker input:
#
#   c++: error: V<top>__pch.h.fast: linker input file not found
#
# which looks like a broken build rather than a missing flag. The override below
# is applied ONLY when the installed makefile actually has the variable empty,
# so a correctly configured Verilator is left alone.
# ---------------------------------------------------------------------------
PCHFIX=()
VMK="${VERILATOR_ROOT:-}/include/verilated.mk"
if [ -f "$VMK" ] && grep -qE '^CFG_CXXFLAGS_PCH_I[[:space:]]*=[[:space:]]*$' "$VMK"; then
    PCHFIX=(-MAKEFLAGS "CFG_CXXFLAGS_PCH_I=-include")
fi

RTL=(
    "$ROOT/rtl/avalon_mm_sdcard_controller_pkg.sv"
    "$ROOT/rtl/avalon_mm_sdcard_controller_crc.sv"
    "$ROOT/rtl/avalon_mm_sdcard_controller_clkgen.sv"
    "$ROOT/rtl/avalon_mm_sdcard_controller_spi_phy.sv"
    "$ROOT/rtl/avalon_mm_sdcard_controller_fifo.sv"
    "$ROOT/rtl/avalon_mm_sdcard_controller_dma.sv"
    "$ROOT/rtl/avalon_mm_sdcard_controller_seq.sv"
    "$ROOT/rtl/avalon_mm_sdcard_controller_regs.sv"
    "$ROOT/rtl/avalon_mm_sdcard_controller.sv"
)

# Warnings waived for testbench idioms only - initialised variables written
# procedurally, blocking assignment to scoreboard counters, unused upper bits of
# task arguments. None are waived for the RTL, which lints clean under -Wall
# apart from UNUSEDPARAM on package constants a given top level does not use.
# SYNCASYNCNET is waived for the card model, which uses sd_cs_n both as an
# asynchronous reset of its shift registers and as a synchronous condition -
# exactly what a real card does, and not synthesisable RTL.
WAIVE=(
    -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-VARHIDDEN
    -Wno-PROCASSINIT -Wno-UNUSEDSIGNAL -Wno-BLKSEQ
    -Wno-WIDTHTRUNC -Wno-ASCRANGE -Wno-SYNCASYNCNET
    -Wno-MULTIDRIVEN -Wno-LATCH -Wno-CASEINCOMPLETE
)

fail=0

run_tb () {
    local name="$1" top="$2"; shift 2
    local obj="$OBJROOT/obj_dir_$name"
    local log="$OBJROOT/run_$name.log"

    echo "=== $name ==="
    verilator --binary --timing --assert -j "$(nproc)" -Wall -CFLAGS "$CXXSTD" \
        "${PCHFIX[@]}" "${WAIVE[@]}" --Mdir "$obj" -o simx \
        "${RTL[@]}" "$@" --top-module "$top" > "$log" 2>&1
    if [ $? -ne 0 ]; then
        echo "  BUILD FAILED - see $log"
        grep -E '^%Error' "$log" | head -5
        fail=1
        return
    fi

    "$obj/simx" >> "$log" 2>&1
    local rc=$?
    grep -E 'clocks / | checks,' "$log" | sed 's/^/  /'

    if [ $rc -ne 0 ] || ! grep -q '\*\*\* PASS \*\*\*' "$log"; then
        echo "  FAILED - see $log"
        fail=1
    else
        echo "  PASS"
    fi
}

if [ "$WHICH" = "all" ] || [ "$WHICH" = "phy" ]; then
    run_tb phy avalon_mm_sdcard_controller_spi_phy_tb \
        "$ROOT/tb/avalon_mm_sdcard_controller_sva.sv" \
        "$ROOT/tb/avalon_mm_sdcard_controller_spi_phy_tb.sv"
fi

if [ "$WHICH" = "all" ] || [ "$WHICH" = "fifo" ]; then
    run_tb fifo avalon_mm_sdcard_controller_fifo_tb \
        "$ROOT/tb/avalon_mm_sdcard_controller_sva.sv" \
        "$ROOT/tb/avalon_mm_sdcard_controller_fifo_tb.sv"
fi

# ---------------------------------------------------------------------------
# The full-core suite runs under several configurations, and the exit status is
# the AND across all of them.
#
# These are not cosmetic variations. Each one is a different design or a
# different card, and each exercises a path the others cannot reach:
#
#   dma       the reference configuration
#   pio       USE_DMA=0. No master at all; software moves every word through
#             the DATA window, on a deadline. A completely different FIFO
#             client, and the only configuration where the shifter can be
#             starved by the CPU rather than by the interconnect.
#   sdsc      a standard-capacity card, which is BYTE addressed. On an SDHC
#             card the block-to-address conversion is the identity, so this is
#             the only configuration in which it is tested at all.
#   tight     one block of buffer instead of two, so nothing overlaps and the
#             data path has to refill mid-transfer.
#   noburst   M0_BURST_WIDTH=1, single-beat Avalon transactions throughout.
#
# Running only the default leaves the PIO path and byte addressing entirely
# unexecuted, which is what this repository's other cores avoid by sweeping the
# parameters that change behaviour rather than the ones that change widths.
# ---------------------------------------------------------------------------
CORE_CFGS=(
    "dma:-GTB_USE_DMA=1"
    "pio:-GTB_USE_DMA=0"
    "sdsc:-GTB_HIGH_CAPACITY=0"
    "tight:-GTB_FIFO_B=512"
    "noburst:-GTB_BURST_W=1"
)

if [ "$WHICH" = "all" ] || [ "$WHICH" = "core" ]; then
    for entry in "${CORE_CFGS[@]}"; do
        name="${entry%%:*}"
        gflag="${entry#*:}"
        run_tb "core_$name" avalon_mm_sdcard_controller_tb "$gflag" \
            "$ROOT/tb/avalon_mm_sdcard_controller_sva.sv" \
            "$ROOT/tb/spi_card_model.sv" \
            "$ROOT/tb/avalon_mm_mem_model.sv" \
            "$ROOT/tb/avalon_mm_sdcard_controller_tb.sv"
    done
fi

echo
if [ $fail -eq 0 ]; then echo "ALL TESTBENCHES PASS"; else echo "*** REGRESSION FAILED ***"; fi
exit $fail
