#!/usr/bin/env bash
# =============================================================================
# gen_mem_model.sh - generate the functional SDRAM memory model.
#
#   ./gen_mem_model.sh [output_dir]      (default: ./.gen)
#
# Intel's functional SDRAM model lives in a separate component from the SDRAM
# controller - altera_sdram_partner_module, under
#
#     $QUARTUS_ROOT/ip/altera/alt_mem_if/alt_mem_if_mem_models/
#
# It is Intel's file, so it is generated here rather than committed.
#
# WHAT THIS MODEL DOES AND DOES NOT DO
# ------------------------------------
# It is a FUNCTIONAL model: a memory array behind a command decoder. It
# decodes LOAD MODE REGISTER, ACTIVATE, READ and WRITE, and pipelines read
# data by the CAS latency.
#
# It does NOT model tRCD, tRP, tRC, tRAS, tRRD, tWR or tMRD, does NOT enforce
# the refresh interval, and does NOT model retention. PRECHARGE and AUTO
# REFRESH are decoded and then ignored.
#
# That has a direct consequence for a benchmark: a controller can violate
# every timing parameter on the part and still return correct data here. So
# throughput measured against this model is only meaningful alongside
# sdram_timing_check.sv, which checks the command stream against the same
# nanosecond parameters and is what makes an illegal-but-fast result fail.
#
# The geometry MUST match gen_dut.sh and sdram_bench_tb.sv: the DE10-Lite's
# ISSI IS42S16320D, 4 banks x 8192 rows x 1024 columns x 16 bits, CAS 3.
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
