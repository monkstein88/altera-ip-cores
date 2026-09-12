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

# --- the configurations to synthesise ----------------------------------------
# name : parameter overrides : expected memory bits
#
# Lint sweeps ten configurations and the simulation sweeps five; this used to
# synthesise one. That is the configuration least likely to be wrong, which is
# the wrong one to check alone - the buffer's depth is a parameter, and whether
# it lands in a memory block is the single thing most worth not losing.
#
# The memory expectation is DEPTH_BYTES x 8, exact rather than a threshold.
# "Some memory was used" would pass a design that put half the buffer in flops;
# only the exact figure says the whole store is in the block.
CFGS=(
    "default:            :8192"
    "tight:FIFO_DEPTH_BYTES=512:4096"
    "big:FIFO_DEPTH_BYTES=8192:65536"
    "nodma:USE_DMA=0:8192"
    "noburst:M0_BURST_WIDTH=1:8192"
)

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

fail=0

# -----------------------------------------------------------------------------
# One configuration: synthesise, fit, time, and hold the result to the budget.
# -----------------------------------------------------------------------------
run_cfg () {
    local name="$1" params="$2" want_mem="$3"
    local d="$WORK/$name"
    rm -rf "$d"; mkdir -p "$d"

    {
        echo "set_global_assignment -name FAMILY \"$FAMILY\""
        echo "set_global_assignment -name DEVICE $DEVICE"
        echo "set_global_assignment -name TOP_LEVEL_ENTITY avalon_mm_sdcard_controller"
        echo "set_global_assignment -name SDC_FILE syn.sdc"
        for f in "${ORDER[@]}"; do
            echo "set_global_assignment -name SYSTEMVERILOG_FILE $ROOT/rtl/avalon_mm_sdcard_controller_$f.sv"
        done
        echo "set_global_assignment -name SYSTEMVERILOG_FILE $ROOT/rtl/avalon_mm_sdcard_controller.sv"
        # Parameter overrides, one per entry, comma separated in CFGS.
        if [ -n "$params" ]; then
            local IFS=','
            for kv in $params; do
                echo "set_parameter -name ${kv%%=*} ${kv##*=}"
            done
        fi
    } > "$d/syn.qsf"

    # The conduit to the card is source-synchronous and closed with input delays
    # in a real project's own constraints; here only the internal paths are
    # analysed, so one clock and the derived uncertainty is the whole constraint.
    {
        echo "create_clock -name clk -period $CLK_NS [get_ports clk]"
        echo "derive_clock_uncertainty"
    } > "$d/syn.sdc"

    local tool
    for tool in quartus_map quartus_fit quartus_sta; do
        if ! ( cd "$d" && "$BIN/$tool" syn > "$tool.log" 2>&1 ); then
            echo "  FAIL  $name: $tool"
            grep -E '^Error|Error \(' "$d/$tool.log" | head -3 | sed 's/^/          /'
            fail=1
            return 1
        fi
    done

    # --- pull the figures out of the reports ---
    local lc regs mem fmax slack
    lc=$(rpt_num "$d/syn.fit.rpt"   "Total logic elements")
    regs=$(rpt_num "$d/syn.fit.rpt" "Total registers")
    mem=$(rpt_num "$d/syn.fit.rpt"  "Total memory bits")
    # Anchored to the TABLE title, which starts with '; '. The report opens with
    # a table of contents listing the same titles unadorned, so an unanchored
    # match finds that instead and comes back with nothing.
    fmax=$(grep -A6 -m1 '^; .*Model Fmax Summary' "$d/syn.sta.rpt" \
           | grep -oE '[0-9]+\.[0-9]+ MHz' | head -1 | cut -d' ' -f1)
    slack=$(grep -A8 -m1 '^; .*Model Setup Summary' "$d/syn.sta.rpt" \
            | grep -m1 -E '^; clk ' | sed -E 's/^; clk *; *(-?[0-9.]+).*/\1/')

    printf '  %-9s %6s cells  %5s regs  %6s membits  %7s MHz  %7s ns\n' \
        "$name" "${lc:-?}" "${regs:-?}" "${mem:-?}" "${fmax:-?}" "${slack:-?}"

    local bad=""
    num_le "${lc:-}"   "$MAX_LOGIC_CELLS" || bad="$bad cells(${lc:-?}>$MAX_LOGIC_CELLS)"
    num_le "${regs:-}" "$MAX_REGISTERS"   || bad="$bad regs(${regs:-?}>$MAX_REGISTERS)"

    # Exact, not a threshold. The whole store belongs in the memory block; half
    # of it in flops would pass any "some memory was used" test.
    [ "${mem:-x}" = "$want_mem" ] || bad="$bad membits(${mem:-?}!=$want_mem)"

    if [ -z "${fmax:-}" ] || ! awk "BEGIN{exit !($fmax >= $MIN_FMAX_MHZ)}"; then
        bad="$bad Fmax(${fmax:-?}<$MIN_FMAX_MHZ)"
    fi
    if [ -z "${slack:-}" ] || ! awk "BEGIN{exit !($slack >= 0)}"; then
        bad="$bad slack(${slack:-?})"
    fi

    if [ -n "$bad" ]; then
        echo "        FAIL:$bad"
        fail=1
        return 1
    fi
    return 0
}

rpt_num () {  # rpt_num <file> <row label>  -> first integer in that row
    grep -m1 -E "^; *$2 " "$1" 2>/dev/null \
        | sed -E 's/.*; *([0-9,]+).*/\1/; s/,//g' | grep -E '^[0-9]+$' || echo ""
}

num_le () { [ -n "$1" ] && [ "$1" -le "$2" ] 2>/dev/null; }

echo "  budget: <= $MAX_LOGIC_CELLS cells, <= $MAX_REGISTERS regs,"
echo "          Fmax >= $MIN_FMAX_MHZ MHz, slack >= 0 at $CLK_NS ns"
echo ""

for entry in "${CFGS[@]}"; do
    IFS=':' read -r cname cparams cmem <<< "$entry"
    # Strip the padding the table alignment adds.
    cparams="$(echo "$cparams" | tr -d ' ')"
    run_cfg "$cname" "$cparams" "$cmem"
done

# --- where the area goes, for the reference configuration --------------------
# The total on its own never says what to do about it.
echo ""
echo "    default, by entity:"
grep -E '^;    \|avalon_mm_sdcard_controller_[a-z_]+:' "$WORK/default/syn.fit.rpt" \
    | sed -E 's/^; *\|avalon_mm_sdcard_controller_([a-z_0-9]+):[^;]*; *([0-9,]+)[^;]*;.*/\1 \2/' \
    | sed 's/,//g' | sort -k2 -rn \
    | awk '{printf "        %-10s %6d\n", $1, $2}' | head -8

echo ""
if [ $fail -eq 0 ]; then
    echo "*** PASS ***"
else
    echo "*** FAIL ***"
fi
echo ""
exit $fail
