#!/usr/bin/env bash
# Build and run wave_capture_tb, producing wave.vcd for the figure renderer.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CXX_EXTRA=""
if [[ "$(g++ -dumpversion | cut -d. -f1)" -lt 12 ]]; then
    CXX_EXTRA="-std=gnu++20 -fcoroutines"
fi
FLAGS=(--binary --timing --trace -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME
       --top-module wave_capture_tb -o wcap -Mdir "$HERE/obj_dir")
[[ -n "$CXX_EXTRA" ]] && FLAGS+=(-CFLAGS "$CXX_EXTRA")
rm -rf "$HERE/obj_dir"
verilator "${FLAGS[@]}" \
    "$HERE/../rtl/avl_mm_firewall_pkg.sv" \
    "$HERE/../rtl/avl_mm_firewall_regs.sv" \
    "$HERE/../rtl/avl_mm_firewall_top.sv" \
    "$HERE/wave_capture_tb.sv" \
  || make -C "$HERE/obj_dir" -f Vwave_capture_tb.mk CFG_CXXFLAGS_PCH_I=-include
cd "$HERE" && ./obj_dir/wcap
echo "wave.vcd written to $HERE"
