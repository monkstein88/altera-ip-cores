#!/usr/bin/env bash
# =============================================================================
# check_synthesis.sh - put the RTL through Quartus and report what it costs.
#
#   ./verification/check_synthesis.sh
#   QUARTUS_ROOT=/opt/altera/25.1std ./verification/check_synthesis.sh
#
# Exit 0 if it synthesises, fits and meets its clock constraint; 1 if any of
# those fail; 2 if no Quartus installation could be found, which is not a pass.
#
# -----------------------------------------------------------------------------
# WHY THIS EXISTS
# -----------------------------------------------------------------------------
# Everything else here runs on open-source tools, and for the behaviour of the
# design that is the right trade. But this core is a Quartus IP component, and
# two things only Quartus can tell you:
#
#   IS IT EVEN LEGAL SYSTEMVERILOG TO QUARTUS?  Verilator and Questa both
#   accepted package imports written in the module HEADER - between the module
#   name and the parameter list, IEEE 1800-2017 26.4. Quartus implements no such
#   thing, in 18.1 or in 25.1 Standard, and rejected all six modules that used
#   it. The RTL did not compile for its own target platform at all, and every
#   simulation-based check in this repository passed while that was true.
#
#   WHAT DOES IT COST?  Area and Fmax are not opinions. They are also the only
#   way to know whether a structural choice made for simulation reasons was
#   affordable - see the note on the buffer below.
#
# -----------------------------------------------------------------------------
# THE NUMBERS ARE CHECKED, NOT JUST PRINTED
# -----------------------------------------------------------------------------
# A report nobody compares against anything is a report nobody reads. The
# budgets below are the measured figures with headroom, so a change that makes
# the core substantially bigger or slower fails here instead of being noticed
# whenever somebody next happens to look.
#
# Raise them deliberately and say why. Lowering them is the point of the
# exercise.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# The DE10-Lite part, which is what this repository's other cores target. Chosen
# over a faster family deliberately: a number measured on a part nobody is going
# to use is not a number.
FAMILY="MAX 10"
DEVICE="10M50DAF484C7G"

# The system clock the documentation assumes throughout. Every SPI rate in the
# register map is derived from it, so it is the constraint that matters.
CLK_NS=10.000

# --- budgets -----------------------------------------------------------------
# Logic cells for the whole core, and separately for the buffer, because the
# buffer has been most of the core and that is the thing worth watching.
# Measured 1719 cells, 888 registers, 111.53 MHz. The headroom is for the
# parameter variations and for ordinary fitter noise, not for drift.
#
# These were 13000 / 10500 / 75 when the buffer was a register file. Anyone
# raising them back towards those numbers is undoing that fix, which is why the
# figures are in the file and not just in a report.
MAX_LOGIC_CELLS=2200
MAX_REGISTERS=1100
MIN_FMAX_MHZ=100

find_quartus () {
    if [ -n "${QUARTUS_ROOT:-}" ] && [ -x "$QUARTUS_ROOT/quartus/bin/quartus_map" ]; then
        echo "$QUARTUS_ROOT"; return 0
    fi
    for q in /opt/altera/25.1std /opt/intelFPGA/18.1 /opt/intelFPGA_lite/*; do
        [ -x "$q/quartus/bin/quartus_map" ] && { echo "$q"; return 0; }
    done
    return 1
}

QROOT="$(find_quartus)" || {
    echo ""
    echo "=== synthesis: INCOMPLETE ==="
    echo ""
    echo "    No Quartus found. Set QUARTUS_ROOT to enable."
    echo "    Do what the figure checker does and report this as incomplete"
    echo "    rather than as a pass: nothing was synthesised."
    echo ""
    exit 2
}

BIN="$QROOT/quartus/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ""
echo "=== synthesis: $FAMILY $DEVICE ==="
echo "    $("$BIN/quartus_sh" --version 2>/dev/null | grep -i version | head -1)"
echo ""

# Compile order matters: the package defines what every other file elaborates
# against, and the CRC file defines a second package the sequencer uses.
ORDER=(pkg crc clkgen spi_phy fifo dma seq regs)
{
    echo "set_global_assignment -name FAMILY \"$FAMILY\""
    echo "set_global_assignment -name DEVICE $DEVICE"
    echo "set_global_assignment -name TOP_LEVEL_ENTITY avalon_mm_sdcard_controller"
    echo "set_global_assignment -name SDC_FILE syn.sdc"
    for f in "${ORDER[@]}"; do
        echo "set_global_assignment -name SYSTEMVERILOG_FILE $ROOT/rtl/avalon_mm_sdcard_controller_$f.sv"
    done
    echo "set_global_assignment -name SYSTEMVERILOG_FILE $ROOT/rtl/avalon_mm_sdcard_controller.sv"
} > "$WORK/syn.qsf"

# The conduit to the card is source-synchronous and closed with input delays in
# a real project's own constraints; here only the internal paths are analysed, so
# one clock and the derived uncertainty is the whole constraint.
{
    echo "create_clock -name clk -period $CLK_NS [get_ports clk]"
    echo "derive_clock_uncertainty"
} > "$WORK/syn.sdc"

fail=0
step () {
    local tool="$1" label="$2"
    if ( cd "$WORK" && "$BIN/$tool" syn > "$tool.log" 2>&1 ); then
        echo "  PASS  $label"
    else
        echo "  FAIL  $label"
        grep -E '^Error|Error \(' "$WORK/$tool.log" | head -3 | sed 's/^/          /'
        fail=1
        return 1
    fi
}

step quartus_map "Analysis & Synthesis"            || { echo ""; exit 1; }
step quartus_fit "Fitter (place and route)"        || { echo ""; exit 1; }
step quartus_sta "Timing Analyzer"                 || { echo ""; exit 1; }

# --- pull the figures out of the reports -------------------------------------
rpt_num () {  # rpt_num <file> <row label>  -> first integer in that row
    grep -m1 -E "^; *$2 " "$1" 2>/dev/null \
        | sed -E 's/.*; *([0-9,]+).*/\1/; s/,//g' | grep -E '^[0-9]+$' || echo ""
}

LC=$(rpt_num "$WORK/syn.fit.rpt" "Total logic elements")
REGS=$(rpt_num "$WORK/syn.fit.rpt" "Total registers")
MEMBITS=$(rpt_num "$WORK/syn.fit.rpt" "Total memory bits")
# The report pads its table titles with spaces before the closing ';', so match
# the title text alone rather than assuming the column width.
# Anchored to the TABLE title, which starts with '; '. The report opens with a
# table of contents listing the same titles unadorned, so an unanchored match
# finds that instead and comes back with nothing.
FMAX=$(grep -A6 -m1 '^; .*Model Fmax Summary' "$WORK/syn.sta.rpt" \
       | grep -oE '[0-9]+\.[0-9]+ MHz' | head -1 | cut -d' ' -f1)
SLACK=$(grep -A8 -m1 '^; .*Model Setup Summary' "$WORK/syn.sta.rpt" \
        | grep -m1 -E '^; clk ' | sed -E 's/^; clk *; *(-?[0-9.]+).*/\1/')

echo ""
echo "    logic cells      ${LC:-?}"
echo "    registers        ${REGS:-?}"
echo "    memory bits      ${MEMBITS:-?}"
echo "    Fmax             ${FMAX:-?} MHz   (slow 85C corner)"
echo "    setup slack      ${SLACK:-?} ns    (at ${CLK_NS} ns)"
echo ""

# Where it goes, because the total on its own never says what to do about it.
echo "    by entity:"
grep -E '^;    \|avalon_mm_sdcard_controller_[a-z_]+:' "$WORK/syn.fit.rpt" \
    | sed -E 's/^; *\|avalon_mm_sdcard_controller_([a-z_0-9]+):[^;]*; *([0-9,]+)[^;]*;.*/\1 \2/' \
    | sed 's/,//g' | sort -k2 -rn \
    | awk '{printf "        %-10s %6d\n", $1, $2}' | head -8
echo ""

num_ok () { [ -n "$1" ] && [ "$1" -le "$2" ] 2>/dev/null; }

if num_ok "${LC:-}" "$MAX_LOGIC_CELLS"; then
    echo "  PASS  logic cells within budget ($LC <= $MAX_LOGIC_CELLS)"
else
    echo "  FAIL  logic cells over budget (${LC:-?} > $MAX_LOGIC_CELLS)"; fail=1
fi

if num_ok "${REGS:-}" "$MAX_REGISTERS"; then
    echo "  PASS  registers within budget ($REGS <= $MAX_REGISTERS)"
else
    echo "  FAIL  registers over budget (${REGS:-?} > $MAX_REGISTERS)"; fail=1
fi

if [ -n "${FMAX:-}" ] && awk "BEGIN{exit !($FMAX >= $MIN_FMAX_MHZ)}"; then
    echo "  PASS  Fmax at or above floor ($FMAX >= $MIN_FMAX_MHZ MHz)"
else
    echo "  FAIL  Fmax below floor (${FMAX:-?} < $MIN_FMAX_MHZ MHz)"; fail=1
fi

# The clock constraint is now MET, so missing it is a failure rather than a note.
# It used to fail by 2.629 ns, which was reported and tolerated because the
# alternative - loosening the constraint - would have hidden the one number a
# reader most needs. There is nothing to tolerate any more.
if [ -n "${SLACK:-}" ] && awk "BEGIN{exit !($SLACK >= 0)}"; then
    echo "  PASS  meets the ${CLK_NS} ns constraint (slack $SLACK ns)"
else
    echo "  FAIL  does NOT meet ${CLK_NS} ns (slack ${SLACK:-?} ns)"
    echo "        Every SPI rate in the register map is derived from a 100 MHz"
    echo "        system clock, so this is the constraint that matters."
    fail=1
fi

echo ""
if [ $fail -eq 0 ]; then echo "*** PASS ***"; else echo "*** FAIL ***"; fi
echo ""
exit $fail
