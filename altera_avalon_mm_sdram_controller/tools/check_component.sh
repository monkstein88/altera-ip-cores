#!/usr/bin/env bash
# =============================================================================
# check_component.sh - verify the Platform Designer component actually works.
#
#   ./check_component.sh            (needs QUARTUS_ROOT; no licence required)
#
# A _hw.tcl is a program, and every failure mode it has is quiet. A malformed
# preset file leaves the Presets list silently empty. A parameter of the wrong
# type reaches the HDL as something that is not a number. A validation callback
# with a typo in it simply never fires. None of that shows up in simulation,
# because simulation never runs the component description at all.
#
# So this script exercises it end to end against a real Quartus installation:
#
#   1. the component and its presets load with no errors
#   2. a system builds, generates, and produces no errors or warnings
#   3. the preset lands its datasheet values on the instance
#   4. EVERY HDL parameter arrives as an unquoted number
#   5. each validation rule fires on a configuration that should trip it
#
# Check 4 is the important one. Platform Designer emits a FLOAT parameter into
# the generated Verilog as a quoted string - `.T_RC_NS("60.0")` - and a string
# assigned to a `parameter real` is its ASCII bytes read as a number, so a 60 ns
# tRC arrives as 909127216.0 and becomes 90 million cycles. It compiles, it
# elaborates, and it is catastrophically wrong. The controller now takes integer
# picoseconds so this cannot happen, and this check is what keeps it that way.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$(cd "$HERE/.." && pwd)"
QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"
export PATH="$QUARTUS_ROOT/quartus/sopc_builder/bin:$QUARTUS_ROOT/quartus/bin:$PATH"

command -v qsys-generate >/dev/null 2>&1 || {
    echo "error: qsys-generate not found. Set QUARTUS_ROOT to a Quartus install." >&2
    exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

SP="$CORE,\$"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; }
strip() { sed -E 's/^[0-9.:]+ //; s|</?b>||g'; }

echo "=== component: altera_avalon_mm_sdram_controller ==="
echo "=== quartus:   $QUARTUS_ROOT"
echo

# ---- 1. the component and its presets load -------------------------------
LOG=$(ip-catalog --search-path="$SP" --name=altera_avalon_mm_sdram_controller \
        --verbose 2>&1 | strip)
if grep -qi "^Error" <<<"$LOG"; then
    bad "component and presets load" "$(grep -i '^Error' <<<"$LOG" | head -2)"
else
    ok "component and presets load with no errors"
fi

# ---- 2 & 3. build a system, apply the preset, check the values ------------
PRESET="ISSI IS42S16320D-7 - DE10-Lite 64 MByte"
cat > build.tcl <<TCL
package require -exact qsys 14.0
create_system chk
set_project_property DEVICE_FAMILY {MAX 10}
set_project_property DEVICE {10M50DAF484C7G}
add_instance clk clock_source
set_instance_parameter_value clk {clockFrequency} {100000000.0}
set_instance_parameter_value clk {resetSynchronousEdges} {DEASSERT}
add_instance sdram altera_avalon_mm_sdram_controller
# deliberately wrong, so a preset that does nothing cannot look like success
set_instance_parameter_value sdram CAS_LAT 2
set_instance_parameter_value sdram ROW_BITS 11
set_instance_parameter_value sdram T_RC_NS 99.0
apply_preset sdram "$PRESET"
puts "PRESET_RESULT CAS=[get_instance_parameter_value sdram CAS_LAT] ROW=[get_instance_parameter_value sdram ROW_BITS] TRC=[get_instance_parameter_value sdram T_RC_NS]"
add_connection clk.clk       sdram.clk
add_connection clk.clk_reset sdram.reset
set_interface_property clk_in     EXPORT_OF clk.clk_in
set_interface_property reset_in   EXPORT_OF clk.clk_in_reset
set_interface_property sdram_s1   EXPORT_OF sdram.s1
set_interface_property sdram_wire EXPORT_OF sdram.wire
save_system chk.qsys
TCL

BLOG=$(qsys-script --search-path="$SP" --script=build.tcl 2>&1 | strip)
# apply_preset logs an error rather than raising one, so the log has to be read.
if grep -q "Error: apply_preset" <<<"$BLOG"; then
    bad "preset '$PRESET' is found" "$(grep 'Error: apply_preset' <<<"$BLOG" | head -1)"
elif grep -q "PRESET_RESULT CAS=3 ROW=13 TRC=60.0" <<<"$BLOG"; then
    ok "preset applies its datasheet values (CAS 2->3, ROW 11->13, tRC 99->60)"
else
    bad "preset applies its values" "$(grep PRESET_RESULT <<<"$BLOG")"
fi

GLOG=$(qsys-generate chk.qsys --synthesis=VERILOG --search-path="$SP" \
         --output-directory="$WORK/out" 2>&1 | strip)
if grep -qE "^(Error|Warning)" <<<"$GLOG"; then
    bad "system generates with no errors or warnings" \
        "$(grep -E '^(Error|Warning)' <<<"$GLOG" | head -3)"
else
    ok "system generates with no errors or warnings"
fi

# ---- 4. every HDL parameter arrives as an unquoted number ----------------
TOP="$WORK/out/synthesis/chk.v"
if [[ ! -f "$TOP" ]]; then
    bad "generated top level exists" "$TOP not found"
else
    INST=$(sed -n '/avalon_mm_sdram_controller #(/,/) sdram (/p' "$TOP")
    QUOTED=$(grep -oE '\.\w+ *\("[^"]*"\)' <<<"$INST" || true)
    if [[ -n "$QUOTED" ]]; then
        bad "no parameter reaches the HDL as a quoted string" \
            "$(tr '\n' ' ' <<<"$QUOTED")"
    else
        ok "every HDL parameter is an unquoted number ($(grep -c '^\s*\.' <<<"$INST") of them)"
    fi

    # the clock must come from the clock source, not from a typed-in default
    if grep -qE '\.CLK_KHZ *\(100000\)' <<<"$INST"; then
        ok "CLK_KHZ derived from the connected 100 MHz clock source"
    else
        bad "CLK_KHZ derived from the clock" "$(grep CLK_KHZ <<<"$INST")"
    fi
    # and the derived address width must match the geometry
    if grep -qE '\.ADDR_W *\(25\)' <<<"$INST"; then
        ok "ADDR_W derived from row+column+bank (13+10+2 = 25)"
    else
        bad "ADDR_W derived" "$(grep ADDR_W <<<"$INST")"
    fi
fi

# ---- 5. the validation rules fire ---------------------------------------
# Each case is a configuration that would otherwise build and be wrong.
check_rule() {   # $1 label   $2 expected text   $3... parameter settings
    local label="$1" want="$2"; shift 2
    { echo 'package require -exact qsys 14.0'
      echo "create_system r"
      echo 'set_project_property DEVICE_FAMILY {MAX 10}'
      echo 'add_instance clk clock_source'
      echo 'set_instance_parameter_value clk {clockFrequency} {100000000.0}'
      echo 'add_instance sdram altera_avalon_mm_sdram_controller'
      printf '%s\n' "$@"
      echo 'add_connection clk.clk sdram.clk'
      echo 'add_connection clk.clk_reset sdram.reset'
      echo 'save_system r.qsys'
    } > r.tcl
    qsys-script --search-path="$SP" --script=r.tcl >/dev/null 2>&1
    local out
    out=$(qsys-generate r.qsys --synthesis=VERILOG --search-path="$SP" \
            --output-directory="$WORK/ro" 2>&1 | strip)
    if grep -qF "$want" <<<"$out"; then
        ok "validation catches: $label"
    else
        bad "validation catches: $label" "expected text not found: $want"
    fi
    rm -rf "$WORK/ro"
}

check_rule "an address bus too narrow for the row" \
    "cannot carry a 13-bit row address" \
    'set_instance_parameter_value sdram {SA_BITS} {11}'

check_rule "tRAS mistyped longer than tRC" \
    "is longer than tRC" \
    'set_instance_parameter_value sdram {T_RAS_NS} {70.0}'

check_rule "a refresh rate the controller cannot sustain" \
    "The controller cannot keep up" \
    'set_instance_parameter_value sdram {REF_ROWS} {32768}' \
    'set_instance_parameter_value sdram {REF_PERIOD_MS} {1}'

check_rule "an address map that would move every address" \
    "will move every address in memory" \
    'set_instance_parameter_value sdram {ADDR_MAP} {1}'

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
