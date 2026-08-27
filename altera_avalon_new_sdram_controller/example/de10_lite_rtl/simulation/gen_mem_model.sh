#!/usr/bin/env bash
# =============================================================================
# gen_mem_model.sh - generate the functional SDRAM memory model for simulation.
#
#   ./gen_mem_model.sh [output_dir]      (default: ./.gen)
#
# WHERE THE MODEL COMES FROM
# --------------------------
# Intel ships a functional SDRAM model generator, but NOT in the SDRAM
# controller's own component directory - it lives in a separate component,
# altera_sdram_partner_module, under
#
#     $QUARTUS_ROOT/ip/altera/alt_mem_if/alt_mem_if_mem_models/
#
# That is why altera_avalon_new_sdram_controller/ appears to be missing the
# make_sodimm routine its generate_rtl.pl calls: the routine was never in that
# directory. Setting `generateSimulationModel` on the controller makes
# qsys-generate reach across to the partner module and run exactly the command
# below, which is what this script calls directly - no full system
# regeneration, and the tracked .qsys stays untouched.
#
# THE MODEL IS NOT COMMITTED, ON PURPOSE
# --------------------------------------
# The generated file is Intel's, so it is not under this repository's MIT
# licence and is kept out of git (see .gitignore and ../../NOTICE). It is
# regenerated here from your own Quartus installation instead.
#
# WHAT THE MODEL DOES AND DOES NOT DO
# -----------------------------------
# It is a FUNCTIONAL model: a memory array behind a command decoder. It
# decodes LOAD MODE REGISTER (to pick up CAS latency), ACTIVATE (to latch
# row/bank), READ and WRITE, and pipelines read data by the CAS latency.
#
# It does NOT model tRCD, tRP, tRFC, tWR or tMRD, it does NOT enforce the
# refresh interval, and it does NOT model data retention. PRECHARGE and AUTO
# REFRESH are decoded and then ignored. So it will confirm that the controller
# is driving the right commands to the right addresses and returning the right
# data - it will NOT tell you that your timing parameters are wrong, and
# scenario 6 passes against it for free. For timing checks you need a
# vendor model; see README.md.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/.gen}"
QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"

GEN="$QUARTUS_ROOT/ip/altera/alt_mem_if/alt_mem_if_mem_models/altera_sdram_partner_module"
PERL="$QUARTUS_ROOT/quartus/linux64/perl/bin/perl"

if [[ ! -f "$GEN/em_altera_sodimm.pl" ]]; then
    echo "error: the SDRAM model generator was not found at" >&2
    echo "       $GEN" >&2
    echo "       Set QUARTUS_ROOT to a Quartus installation that has it." >&2
    exit 1
fi

mkdir -p "$OUT"

# The geometry MUST match qsys/build_system.tcl. These are the DE10-Lite's
# ISSI IS42S16320D: 4 banks x 8192 rows x 1024 columns x 16 bits, CAS 3.
"$PERL" \
    -I "$QUARTUS_ROOT/quartus/linux64/perl/lib" \
    -I "$QUARTUS_ROOT/quartus/sopc_builder/bin/europa" \
    -I "$QUARTUS_ROOT/quartus/sopc_builder/bin/perl_lib" \
    -I "$QUARTUS_ROOT/quartus/sopc_builder/bin" \
    -I "$GEN/" \
    -I "$QUARTUS_ROOT/ip/altera/sopc_builder_ip/altera_sdram_partner_module" \
    -- "$GEN/em_altera_sodimm.pl" \
    --output_dir="$OUT" \
    --quartus_dir="$QUARTUS_ROOT/quartus" \
    --language=verilog \
    --sdram_data_width=16 \
    --sdram_bank_width=2 \
    --sdram_col_width=10 \
    --sdram_row_width=13 \
    --sdram_num_chipselects=1 \
    --module_name=sdram_mem_model \
    --cas_latency=3 >/dev/null

echo "generated: $OUT/sdram_mem_model.v"
