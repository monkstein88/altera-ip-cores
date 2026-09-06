#!/usr/bin/env bash
# =============================================================================
# measure_fit.sh - the standalone cost and speed numbers in README.md.
#
#   ./doc/tools/measure_fit.sh            both cores, the table as published
#   ./doc/tools/measure_fit.sh custom     only this project's core
#   ./doc/tools/measure_fit.sh intel      only the core being replaced
#
# Prints logic elements, registers and f_MAX for each, which is exactly the
# "Cost and speed" table in README.md.
#
# -----------------------------------------------------------------------------
# WHY THIS EXISTS
# -----------------------------------------------------------------------------
# Those three numbers were measured once, by hand, in a project that was never
# checked in. That made them unreproducible: nobody could confirm them, and
# nothing noticed when the RTL changed underneath them - which it did, in
# f5f735c, after which the published figures described a controller the
# repository no longer contained.
#
# check_facts.py deliberately does not verify measured results, on the sound
# reasoning that a checker which pretends to measure is theatre. The answer is
# not to make the checker lie, it is to make the measurement cheap enough to
# repeat. That is this script.
#
# -----------------------------------------------------------------------------
# WHAT IS BEING COMPARED, AND WHY IT IS FAIR
# -----------------------------------------------------------------------------
# Both controllers are fitted STANDALONE - no PLL, no master, no display - on
# the DE10-Lite's part, with one 100 MHz clock and the same optimisation mode.
# Standalone matters: inside a full design the fitter has other things to place
# and the numbers move with the neighbours. Same constraints matter: f_MAX is
# meaningless without them.
#
# The device is the DE10-Lite's MAX 10 rather than the DE0-Nano's Cyclone IV E
# because that is the part the published table names. The DE0-Nano figures in
# README.md come from the demonstration projects, not from here.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$CORE/.." && pwd)"

QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"
QBIN="$QUARTUS_ROOT/quartus/bin"
export QUARTUS_ROOTDIR="$QUARTUS_ROOT/quartus"

FAMILY="MAX 10"
DEVICE="10M50DAF484C7G"
PERIOD_NS="10.000"                       # the 100 MHz the demonstrations run at

BUILD="${TMPDIR:-/tmp}/sdram_fit.$$"
trap 'rm -rf "$BUILD"' EXIT

WHICH="${1:-both}"
SEEDS="${SEEDS:-5}"                      # fitter seeds per core; see sweep()

# Intel's controller is generated output, not tracked. It appears once its
# example has been built; without it the comparison column is skipped rather
# than guessed.
INTEL_V="$ROOT/altera_avalon_new_sdram_controller/example/de10_lite_rtl/qsys/sdram_sys/synthesis/submodules/sdram_sys_sdram.v"

if [[ ! -x "$QBIN/quartus_fit" ]]; then
    echo "  SKIP  no Quartus at $QUARTUS_ROOT (set QUARTUS_ROOT to enable)"
    exit 0
fi

# -----------------------------------------------------------------------------
# fit <label> <top module> <source file>
#
# Full compile, not just Analysis & Synthesis: logic elements come from the
# fitter and f_MAX from timing analysis, and neither exists after quartus_map.
# -----------------------------------------------------------------------------
fit () {
    local label="$1" top="$2" src="$3" seed="${4:-1}"
    local d="$BUILD/$top.$seed"
    mkdir -p "$d"

    cat > "$d/syn.qsf" <<QSF
set_global_assignment -name FAMILY "$FAMILY"
set_global_assignment -name DEVICE $DEVICE
set_global_assignment -name TOP_LEVEL_ENTITY $top
set_global_assignment -name SDC_FILE syn.sdc
set_global_assignment -name SEED $seed
QSF
    case "$src" in
        *.sv) echo "set_global_assignment -name SYSTEMVERILOG_FILE $src" >> "$d/syn.qsf" ;;
        *)    echo "set_global_assignment -name VERILOG_FILE $src"       >> "$d/syn.qsf" ;;
    esac

    # One clock, and nothing else constrained. The I/O are deliberately left
    # unconstrained: this is a core, its pin timing belongs to the board, and
    # constraining it here would measure the pins rather than the logic.
    cat > "$d/syn.sdc" <<SDC
create_clock -name clk -period $PERIOD_NS [get_ports clk]
derive_clock_uncertainty
SDC

    # The plain STA flow, not -t with report_clock_fmax_summary: that call
    # writes a report PANEL and prints nothing, so a script reading its stdout
    # silently gets no f_MAX at all. The default flow writes syn.sta.rpt, which
    # carries the same panel as text.
    ( cd "$d" && "$QBIN/quartus_map" syn && "$QBIN/quartus_fit" syn \
        && "$QBIN/quartus_sta" syn ) > "$d/build.log" 2>&1
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL  $label seed $seed - see $d/build.log" >&2
        grep -E '^Error' "$d/build.log" | head -3 >&2
        return 1
    fi

    # The fit report states resources once each, in its summary.
    local les regs fmax
    les=$(grep -m1 "Total logic elements" "$d/syn.fit.rpt" \
          | grep -oP '[\d,]+(?= /)' | head -1)
    regs=$(grep -m1 "Total registers"     "$d/syn.fit.rpt" \
          | grep -oP '(?<=; )[\d,]+' | head -1)

    # syn.sta.rpt holds one Fmax panel per timing model. The FIRST is the Slow
    # 1200mV 85C model, which is the corner the published table names and the
    # pessimistic one. Its row is "; <fmax> MHz ; <restricted> MHz ; clk ;".
    fmax=$(grep -oP '^; \K\d+\.\d+(?= MHz)' "$d/syn.sta.rpt" | head -1)

    echo "${les//,/} ${regs//,/} ${fmax}"
    return 0
}

# -----------------------------------------------------------------------------
# sweep <label> <top module> <source file>
#
# One fit is not a measurement here. The fitter's result moves with its seed by
# more than the differences this table reports - a spread of half a nanosecond
# on a 10 ns period was measured on this very core - so a single number cannot
# tell a real regression from placement luck. Every seed is reported, and the
# table quotes the median.
# -----------------------------------------------------------------------------

# med <values...> - median of a list of numbers.
med () {
    printf '%s\n' "$@" | sort -n \
        | awk '{a[NR]=$1} END{print (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2}'
}
rng () {
    local lo hi
    lo=$(printf '%s\n' "$@" | sort -n | head -1)
    hi=$(printf '%s\n' "$@" | sort -n | tail -1)
    [[ "$lo" == "$hi" ]] && echo "$lo" || echo "$lo-$hi"
}

sweep () {
    local label="$1" top="$2" src="$3"
    local -a fm=() le=() rg=() ; local out seed l r f

    for seed in $(seq 1 "$SEEDS"); do
        out=$(fit "$label" "$top" "$src" "$seed") || { FAILED=1; return 1; }
        read -r l r f <<<"$out"
        le+=("$l"); rg+=("$r"); fm+=("$f")
    done

    # Resources move with the seed too - less than f_MAX, but they move, and an
    # early version of this script reported whichever seed happened to run last
    # as though it were THE logic element count. Median and range for all three.
    printf '%-14s %8s %-13s %6s %-11s %9s MHz  %s\n' \
        "$label" \
        "$(med "${le[@]}")" "[$(rng "${le[@]}")]" \
        "$(med "${rg[@]}")" "[$(rng "${rg[@]}")]" \
        "$(med "${fm[@]}")" "[$(rng "${fm[@]}") MHz]"
}

FAILED=0

echo ""
echo "======================================================================"
echo " Standalone fit - $FAMILY $DEVICE, ${PERIOD_NS}ns clock, Slow 1200mV 85C"
echo "======================================================================"
echo ""
printf '%-14s %8s %-13s %6s %-11s %9s   %s\n' "" "LE med" "[range]" "reg" "[range]" "f_MAX med" "[range over $SEEDS seeds]"

if [[ "$WHICH" == "both" || "$WHICH" == "custom" ]]; then
    sweep "Custom core" avalon_mm_sdram_controller \
        "$CORE/rtl/avalon_mm_sdram_controller.sv"
fi

if [[ "$WHICH" == "both" || "$WHICH" == "intel" ]]; then
    if [[ -f "$INTEL_V" ]]; then
        sweep "Intel's core" sdram_sys_sdram "$INTEL_V"
    else
        echo "  SKIP  Intel's core - build altera_avalon_new_sdram_controller's"
        echo "        de10_lite_rtl example first; its generated output is not tracked"
    fi
fi

echo ""
exit $FAILED
