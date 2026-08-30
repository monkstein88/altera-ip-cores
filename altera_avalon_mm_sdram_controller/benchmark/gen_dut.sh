#!/usr/bin/env bash
# =============================================================================
# gen_dut.sh - generate the incumbent Intel SDRAM controller as the baseline DUT.
#
#   ./gen_dut.sh [output_dir]        (default: ./.gen)
#
# The benchmark measures two controllers against identical stimulus: the
# incumbent (altera_avalon_new_sdram_controller) and this project's
# replacement. The incumbent's RTL is Intel's, is generated rather than
# committed - the same rule the SDRAM example follows - so this script produces
# it from your own Quartus installation.
#
# WHY qsys-generate AND NOT generate_rtl.pl
# -----------------------------------------
# The component ships a generate_rtl.pl, but it takes its configuration as a
# Perl data structure whose shape is internal to Intel's build. qsys-generate
# is the supported path, is what the SDRAM example already uses, and needs no
# licence for generation.
#
# The parameters below MUST match gen_mem_model.sh and the localparams in
# sdram_bench_tb.sv. They are the DE10-Lite's ISSI IS42S16320D at 100 MHz,
# identical to altera_avalon_new_sdram_controller/example/de10_lite_rtl, so the
# baseline being measured is the configuration that was verified on hardware.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/.gen}"
QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"
CORES="$(cd "$HERE/../.." && pwd)"

export PATH="$QUARTUS_ROOT/quartus/sopc_builder/bin:$QUARTUS_ROOT/quartus/bin:$PATH"

command -v qsys-script >/dev/null 2>&1 || {
    echo "error: qsys-script not found. Set QUARTUS_ROOT to a Quartus install." >&2
    exit 1
}

mkdir -p "$OUT"
WORK="$OUT/qsys"
rm -rf "$WORK" && mkdir -p "$WORK"

cat > "$WORK/build_dut.tcl" <<'TCL'
package require -exact qsys 14.0

create_system dut_sys
set_project_property DEVICE_FAMILY {MAX 10}
set_project_property DEVICE {10M50DAF484C7G}
set_project_property HIDE_FROM_IP_CATALOG {false}

add_instance clk clock_source
set_instance_parameter_value clk {clockFrequency} {100000000.0}
set_instance_parameter_value clk {resetSynchronousEdges} {DEASSERT}

add_instance sdram altera_avalon_new_sdram_controller
set_instance_parameter_value sdram {dataWidth}             {16}
set_instance_parameter_value sdram {numberOfBanks}         {4}
set_instance_parameter_value sdram {rowWidth}              {13}
set_instance_parameter_value sdram {columnWidth}           {10}
set_instance_parameter_value sdram {numberOfChipSelects}   {1}
set_instance_parameter_value sdram {casLatency}            {3}
set_instance_parameter_value sdram {refreshPeriod}         {7.8125}
set_instance_parameter_value sdram {TAC}                   {5.4}
set_instance_parameter_value sdram {TRCD}                  {15.0}
set_instance_parameter_value sdram {TRFC}                  {70.0}
set_instance_parameter_value sdram {TRP}                   {15.0}
set_instance_parameter_value sdram {TWR}                   {14.0}
set_instance_parameter_value sdram {TMRD}                  {3}
set_instance_parameter_value sdram {powerUpDelay}          {100.0}
set_instance_parameter_value sdram {initRefreshCommands}   {2}
set_instance_parameter_value sdram {initNOPDelay}          {0.0}
set_instance_parameter_value sdram {pinsSharedViaTriState} {false}
set_instance_parameter_value sdram {generateSimulationModel} {false}

add_connection clk.clk       sdram.clk
add_connection clk.clk_reset sdram.reset

set_interface_property clk_in     EXPORT_OF clk.clk_in
set_interface_property reset_in   EXPORT_OF clk.clk_in_reset
set_interface_property sdram_s1   EXPORT_OF sdram.s1
set_interface_property sdram_wire EXPORT_OF sdram.wire

save_system dut_sys.qsys
TCL

( cd "$WORK" && qsys-script \
      --search-path="$CORES/altera_avalon_new_sdram_controller,\$" \
      --script=build_dut.tcl ) >/dev/null

( cd "$WORK" && qsys-generate dut_sys.qsys \
      --synthesis=VERILOG \
      --search-path="$CORES/altera_avalon_new_sdram_controller,\$" \
      --output-directory="$WORK/out" ) >/dev/null

# The controller itself is one submodule of the generated system. Lift it out
# and give it the stable name the benchmark instantiates, so the harness does
# not depend on qsys's naming.
SRC="$(find "$WORK/out" -name '*_sdram.v' | head -1)"
[[ -n "$SRC" ]] || { echo "error: generated controller not found under $WORK/out" >&2; exit 1; }

sed -e 's/\bdut_sys_sdram\b/sdram_mem_ctrl/g' "$SRC" > "$OUT/sdram_mem_ctrl.v"
echo "generated: $OUT/sdram_mem_ctrl.v"
