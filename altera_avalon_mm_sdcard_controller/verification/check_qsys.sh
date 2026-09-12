#!/usr/bin/env bash
# =============================================================================
# check_qsys.sh - open the Platform Designer component for real.
#
#   ./verification/check_qsys.sh
#   QUARTUS_ROOT=/opt/altera/25.1std ./verification/check_qsys.sh
#
# Exit 0 if the component loads, elaborates and generates; 1 if it does not;
# 2 if no Quartus installation could be found, which is not a pass.
#
# -----------------------------------------------------------------------------
# WHY THIS IS NOT check_hw_tcl.tcl
# -----------------------------------------------------------------------------
# verification/check_hw_tcl.tcl executes the _hw.tcl against STUBBED Qsys
# commands. That is worth having - it needs no Quartus at all and it catches a
# renamed parameter or a port added to an interface that does not exist - but a
# stub agrees with whatever the script says. It cannot tell you that a property
# name is spelled the way this release spells it, that the elaboration callback
# actually removes an interface, or that the thing generates.
#
# This runs the real qsys-script and qsys-generate, so what it checks is the
# component as Platform Designer sees it:
#
#   it loads from the _hw.tcl and can be instantiated
#   its interfaces are the six expected ones
#   the elaboration callback really does remove m0 when USE_DMA is off
#   a complete system containing it generates synthesisable RTL
#
# The generated output is thrown away. What matters is that generation succeeds
# and emits the core's own files.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$(cd "$HERE/.." && pwd)"

find_quartus () {
    if [ -n "${QUARTUS_ROOT:-}" ] && \
       [ -x "$QUARTUS_ROOT/quartus/sopc_builder/bin/qsys-generate" ]; then
        echo "$QUARTUS_ROOT"; return 0
    fi
    for q in /opt/altera/25.1std /opt/intelFPGA/18.1 /opt/intelFPGA_lite/*; do
        [ -x "$q/quartus/sopc_builder/bin/qsys-generate" ] && { echo "$q"; return 0; }
    done
    return 1
}

QROOT="$(find_quartus)" || {
    echo ""
    echo "=== Platform Designer: INCOMPLETE ==="
    echo ""
    echo "    No Quartus found. Set QUARTUS_ROOT to enable."
    echo "    Reported as incomplete rather than as a pass: the component was"
    echo "    never opened, which is the whole point of this check."
    echo ""
    exit 2
}

QB="$QROOT/quartus/sopc_builder/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ""
echo "=== Platform Designer: the component as Qsys sees it ==="
echo ""

fail=0
ok ()  { echo "  PASS  $1"; }
bad () { echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "$2" | head -3 | sed 's/^/          /'; fail=1; }

# ---- 1. load, instantiate, and look at what came back ----------------------
cat > "$WORK/probe.tcl" <<'TCL'
package require -exact qsys 14.0
create_system probe
set_project_property DEVICE_FAMILY {MAX 10}
set_project_property DEVICE 10M50DAF484C7G
add_instance sd altera_avalon_mm_sdcard_controller
puts "PROBE_IFACES [lsort [get_instance_interfaces sd]]"
puts "PROBE_M0_PORTS [llength [get_instance_interface_ports sd m0]]"
set_instance_parameter_value sd USE_DMA {0}
puts "PROBE_IFACES_NODMA [lsort [get_instance_interfaces sd]]"
TCL
( cd "$WORK" && "$QB/qsys-script" --script=probe.tcl \
      --search-path="$CORE,\$" > probe.log 2>&1 )

IFACES=$(grep -m1 '^PROBE_IFACES ' "$WORK/probe.log" | cut -d' ' -f2-)
M0PORTS=$(grep -m1 '^PROBE_M0_PORTS ' "$WORK/probe.log" | awk '{print $2}')
NODMA=$(grep -m1 '^PROBE_IFACES_NODMA ' "$WORK/probe.log" | cut -d' ' -f2-)

if [ -n "$IFACES" ]; then
    ok "the component loads and instantiates"
else
    bad "the component loads and instantiates" "$(grep -i error "$WORK/probe.log")"
    echo ""; echo "*** FAIL ***"; echo ""; exit 1
fi

[ "$IFACES" = "clock csr irq m0 reset sd" ] \
    && ok "its interfaces are the six expected ones" \
    || bad "its interfaces are the six expected ones" "got: $IFACES"

# 10 signals on m0: address, read, write, writedata, byteenable, burstcount,
# waitrequest, readdata, readdatavalid, response.
[ "${M0PORTS:-0}" -eq 10 ] \
    && ok "m0 carries its 10 signals" \
    || bad "m0 carries its 10 signals" "got: ${M0PORTS:-none}"

# The elaboration callback is the only thing that removes the master, since
# SystemVerilog cannot drop ports on a parameter.
[ "$NODMA" = "clock csr irq reset sd" ] \
    && ok "USE_DMA=0 removes m0 (the elaboration callback runs)" \
    || bad "USE_DMA=0 removes m0 (the elaboration callback runs)" "got: $NODMA"

# ---- 2. generate a complete system ----------------------------------------
cat > "$WORK/mk.tcl" <<'TCL'
package require -exact qsys 14.0
create_system sdsys
set_project_property DEVICE_FAMILY {MAX 10}
set_project_property DEVICE 10M50DAF484C7G
add_instance clk0 clock_source
set_instance_parameter_value clk0 clockFrequency {100000000}
add_instance sd altera_avalon_mm_sdcard_controller
add_connection clk0.clk sd.clock
add_connection clk0.clk_reset sd.reset
set_interface_property csr EXPORT_OF sd.csr
set_interface_property irq EXPORT_OF sd.irq
set_interface_property m0  EXPORT_OF sd.m0
set_interface_property sd  EXPORT_OF sd.sd
set_interface_property clk EXPORT_OF clk0.clk_in
set_interface_property rst EXPORT_OF clk0.clk_in_reset
save_system sdsys.qsys
TCL
if ( cd "$WORK" && "$QB/qsys-script" --script=mk.tcl \
        --search-path="$CORE,\$" > mk.log 2>&1 ); then
    ok "a system containing it can be built and saved"
else
    bad "a system containing it can be built and saved" "$(grep -i error "$WORK/mk.log")"
fi

if ( cd "$WORK" && "$QB/qsys-generate" sdsys.qsys --synthesis=VERILOG \
        --search-path="$CORE,\$" > gen.log 2>&1 ); then
    ok "the system generates for QUARTUS_SYNTH"
else
    bad "the system generates for QUARTUS_SYNTH" "$(grep -iE '^.*Error' "$WORK/gen.log")"
fi

# Every RTL file should have been carried into the generated output. A component
# that generates while leaving a source behind fails at compile, not here.
missing=""
for f in pkg crc clkgen spi_phy fifo dma seq regs; do
    [ -f "$WORK/sdsys/synthesis/submodules/avalon_mm_sdcard_controller_$f.sv" ] \
        || missing="$missing ${f}"
done
[ -f "$WORK/sdsys/synthesis/submodules/avalon_mm_sdcard_controller.sv" ] \
    || missing="$missing top"

[ -z "$missing" ] \
    && ok "all 9 RTL files reached the generated output" \
    || bad "all 9 RTL files reached the generated output" "missing:$missing"

echo ""
if [ $fail -eq 0 ]; then echo "*** PASS ***"; else echo "*** FAIL ***"; fi
echo ""
exit $fail
