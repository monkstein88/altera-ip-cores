#!/usr/bin/env bash
# =============================================================================
# run_on_board.sh - program a DE10-Lite, run the demo, and report the result.
#
#   ./run_on_board.sh              program the FPGA, run, check the output
#   ./run_on_board.sh --no-program  skip programming; just re-run the software
#   ./run_on_board.sh --check       only check that a board is reachable
#
# Exit status is 0 only if the application reported every check passing. The
# whole run is non-interactive so it can be driven remotely over the USB
# connection - which is the only way anyone gets to see the scenarios that
# involve deliberately wedging a peripheral.
#
# Requires a built design; run ./build.sh first.
# =============================================================================
set -uo pipefail

# nios2_command_shell.sh sets `IFS=` for its own path handling. Inheriting
# that silently breaks word splitting in everything downstream - `pgrep -f
# jtagd` stops matching, so the board check concluded no JTAG server was
# running and started a second one, which wedged the first. Restore it.
IFS=$' \t\n'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TWO Quartus installations, on purpose.
#
#   QUARTUS_ROOT   the one that built the design. 18.1 is required because
#                  newer Quartus Standard releases no longer ship the Nios II
#                  processor IP (ip/altera/nios2_ip/ is empty in 25.1std), so
#                  the system cannot be generated there. The software tools
#                  used below - nios2-download, nios2-terminal - do still ship
#                  in 25.1std; only the CPU component is missing.
#   JTAG_ROOT      a newer installation, used ONLY for the JTAG stack.
#
# This split is not tidiness, it is a workaround. The 18.1 JTAG server reads
# this board's chain intermittently - "JTAG chain broken", "Server error" and
# "cable not detected" all appear from one unchanged setup - while the 25.1
# jtagd/jtagconfig/quartus_pgm read it every time. Programming therefore uses
# the new tools, and the Nios II download uses the old ones against the JTAG
# server the new tools started. If you only have one installation, set both
# variables to it; expect the flakiness if that one is 18.1.
QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/intelFPGA/18.1}"
JTAG_ROOT="${JTAG_ROOT:-/opt/altera/25.1std}"
[[ -x "$JTAG_ROOT/quartus/bin/jtagconfig" ]] || JTAG_ROOT="$QUARTUS_ROOT"

export QUARTUS_ROOTDIR="$QUARTUS_ROOT/quartus"
export SOPC_KIT_NIOS2="$QUARTUS_ROOT/nios2eds"
JTAG_BIN="$JTAG_ROOT/quartus/bin"

# Re-exec inside the Nios II Command Shell unless we are already in it.
#
# This is not belt-and-braces. Run with a hand-built PATH, jtagconfig here
# hangs indefinitely and jtagd wedges with "Server error"; run through the
# command shell, the same command answers immediately. The shell sets
# LD_LIBRARY_PATH and the JTAG server environment that the JTAG tools need,
# and getting that subtly wrong looks exactly like a dead board.
if [[ -z "${NIOS2_SHELL_ACTIVE:-}" ]]; then
    CMD_SHELL="$SOPC_KIT_NIOS2/nios2_command_shell.sh"
    if [[ -x "$CMD_SHELL" ]]; then
        export NIOS2_SHELL_ACTIVE=1
        exec "$CMD_SHELL" bash "$0" "$@"
    fi
    echo "warning: $CMD_SHELL not found; falling back to a hand-built PATH." >&2
    export PATH="$SOPC_KIT_NIOS2/sdk2/bin:$SOPC_KIT_NIOS2/bin:$QUARTUS_ROOTDIR/bin:$PATH"
fi

SOF="$HERE/quartus/output_files/de10_lite_nios.sof"
ELF="$HERE/software/axi4_lite_firewall_demo.elf"
LOG="$HERE/run_on_board.log"
CAPTURE_SECS="${CAPTURE_SECS:-90}"

program=1
case "${1:-}" in
    --no-program) program=0 ;;
    --check)      program=2 ;;
    "")           ;;
    *) echo "usage: $0 [--no-program|--check]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Is a board actually there?
#
# An enumerated USB-Blaster is NOT the same as a reachable FPGA: the blaster
# is its own USB device and shows up whether or not the board on the other end
# is powered. "Unable to read device chain - Hardware not attached" means the
# cable is fine and the board is not.
# ---------------------------------------------------------------------------
echo "=== looking for a board ==="

# Ask first; restart only on evidence of a problem.
#
# An earlier version started jtagd whenever pgrep failed to find one. That is
# the wrong order - a SECOND jtagd wedges the first, so the check meant to
# protect the setup was what broke it. Probe, then intervene.
probe_chain() { timeout 90 "$JTAG_BIN/jtagconfig" 2>&1; }

chain=$(probe_chain)
rc=$?

if [[ $rc -eq 124 || -z "${chain// /}" ]] || echo "$chain" | grep -qi "server error"; then
    echo "(JTAG server not answering - restarting it)"
    pkill -9 -f jtagd 2>/dev/null || true
    sleep 3
    setsid nohup "$JTAG_BIN/jtagd" --user-start --config "$HOME/.jtagd.conf" </dev/null >/dev/null 2>&1 &
    sleep 8
    chain=$(probe_chain)
    rc=$?
fi
echo "${chain:-(no output)}"

# Three distinct failures, all of which used to read as success:
#   - jtagconfig hangs and is killed by the timeout (rc 124), which happens
#     when jtagd is wedged;
#   - it returns nothing at all, which happens when jtagd is not running;
#   - it lists a cable but cannot read the chain behind it.
# An empty chain is not an absent error message, so test for it explicitly.
if [[ $rc -eq 124 ]]; then
    echo >&2
    echo "ERROR: jtagconfig timed out - the JTAG server is wedged." >&2
    echo "       Try:  killall -9 jtagd && jtagd --user-start" >&2
    exit 1
fi
if [[ -z "${chain// /}" ]]; then
    echo >&2
    echo "ERROR: jtagconfig returned nothing - jtagd is probably not running." >&2
    echo "       Try:  jtagd --user-start" >&2
    exit 1
fi
if echo "$chain" | grep -qi "chain broken"; then
    cat >&2 <<'MSG'

ERROR: the USB-Blaster is responding, but the JTAG chain behind it is broken.

That is a wiring or power fault, not a software one - the cable is talking, and
nothing is answering on TDO. In order of likelihood:
  1. the board is not powered (the DE10-Lite's power LED is off),
  2. the JTAG ribbon is not seated, or is on the wrong header, or reversed,
  3. the ribbon is connected to a board that is powered from a different
     supply that is off.
MSG
    exit 1
fi
if echo "$chain" | grep -qi "unable to read device chain\|No JTAG hardware available\|Error when scanning"; then
    cat >&2 <<'MSG'

ERROR: a USB-Blaster is present but no FPGA is responding on its JTAG chain.

Check, in this order:
  1. the DE10-Lite is powered (its power LED is lit),
  2. the JTAG ribbon actually reaches the board's JTAG header,
  3. nothing else holds the cable - close Quartus Programmer and SignalTap,
     then:  killall jtagd
  4. the DE10-Lite's ONBOARD blaster enumerates as USB 09fb:6810. A bare
     09fb:6001 is a standalone USB-Blaster cable, which means the board is
     powered separately - check that supply.
MSG
    exit 1
fi
if ! echo "$chain" | grep -q "10M50"; then
    echo >&2
    echo "ERROR: no 10M50 in the JTAG chain. What was found:" >&2
    echo "$chain" | sed 's/^/       /' >&2
    echo "       This example targets the DE10-Lite (10M50DAF484C7G)." >&2
    exit 1
fi
[[ $program -eq 2 ]] && { echo "board reachable."; exit 0; }

# ---------------------------------------------------------------------------
# Program and run
# ---------------------------------------------------------------------------
if [[ $program -eq 1 ]]; then
    [[ -f "$SOF" ]] || { echo "error: $SOF not found - run ./build.sh first" >&2; exit 1; }
    echo
    echo "=== programming the FPGA ==="
    timeout 300 "$JTAG_BIN/quartus_pgm" -m jtag -o "p;$SOF" \
        || { echo "error: programming failed" >&2; exit 1; }
fi

[[ -f "$ELF" ]] || { echo "error: $ELF not found - run ./build.sh sw first" >&2; exit 1; }

echo
echo "=== downloading the software ==="
timeout 300 nios2-download -g "$ELF" || { echo "error: nios2-download failed" >&2; exit 1; }

echo
echo "=== capturing the JTAG UART (up to ${CAPTURE_SECS}s) ==="
# nios2-terminal has no "stop on a marker" option, so it is run under a
# timeout and the log is polled for the terminator the application prints.
: > "$LOG"
timeout "$CAPTURE_SECS" nios2-terminal --quiet >> "$LOG" 2>&1 &
term_pid=$!
for _ in $(seq "$CAPTURE_SECS"); do
    grep -q "=== DEMO COMPLETE ===" "$LOG" 2>/dev/null && break
    kill -0 "$term_pid" 2>/dev/null || break
    sleep 1
done
kill "$term_pid" 2>/dev/null
wait "$term_pid" 2>/dev/null

echo
cat "$LOG"
echo
echo "============================================================"
if ! grep -q "=== DEMO COMPLETE ===" "$LOG"; then
    echo "FAILED: the application did not run to completion."
    echo "        Full capture is in $LOG"
    exit 1
fi
if grep -q "\*\*\* ALL CHECKS PASSED \*\*\*" "$LOG"; then
    echo "PASSED: every check passed on hardware."
    echo "        Full capture is in $LOG"
    exit 0
fi
echo "FAILED: the application reported failures:"
grep "  FAIL" "$LOG" || true
echo "        Full capture is in $LOG"
exit 1
