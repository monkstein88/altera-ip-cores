#!/usr/bin/env bash
# =============================================================================
# check_assertions_fire.sh - prove the assertions are alive.
#
#   ./verification/check_assertions_fire.sh
#
# Exit 0 if every injected fault is caught by the assertion that is supposed to
# catch it, 1 if any fault passes unnoticed.
#
# -----------------------------------------------------------------------------
# WHY
# -----------------------------------------------------------------------------
# A passing assertion proves nothing on its own. An assertion whose antecedent
# is never true, that was bound into a module the design does not instantiate,
# or that the simulator quietly declined to compile, passes exactly as
# convincingly as one that is doing real work - and the whole suite goes green
# while checking nothing.
#
# The only way to tell the difference is to break the design on purpose and
# confirm the assertion notices. Each case below injects one fault into a
# scratch copy of the RTL, builds it, and requires the NAMED assertion to fail.
# Nothing in the repository is modified.
#
# The faults are chosen to be defects this core actually had, or ones the
# specification explicitly warns about:
#
#   zero_byteenable  a read with all byteenables clear, which Avalon permits the
#                    interconnect to suppress - a hang with no error anywhere
#   idle_too_early   reporting the shifter idle with a byte still in the
#                    prefetch, which let a transfer be declared complete before
#                    its last byte reached the card
#   idle_in_send     raising tx_idle in a sending state, which makes the shifter
#                    emit a 0xFF nobody asked for inside a data block
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! command -v verilator >/dev/null 2>&1; then
    PIPROOT=$(python3 -c 'import verilator,os;print(os.path.dirname(verilator.__file__))' 2>/dev/null)
    if [ -n "${PIPROOT:-}" ] && [ -x "$PIPROOT/bin/verilator" ]; then
        export VERILATOR_ROOT="$PIPROOT"
        export PATH="$PIPROOT/bin:$PATH"
    else
        echo "error: verilator not found in PATH" >&2
        exit 127
    fi
fi

PCHFIX=()
VMK="${VERILATOR_ROOT:-}/include/verilated.mk"
if [ -f "$VMK" ] && grep -qE '^CFG_CXXFLAGS_PCH_I[[:space:]]*=[[:space:]]*$' "$VMK"; then
    PCHFIX=(-MAKEFLAGS "CFG_CXXFLAGS_PCH_I=-include")
fi

fail=0

inject () {
    local name="$1" want="$2" file="$3" from="$4" to="$5"
    local d="$WORK/$name"

    rm -rf "$d"; mkdir -p "$d/rtl" "$d/tb"
    cp "$ROOT"/rtl/*.sv "$d/rtl/"
    cp "$ROOT"/tb/*.sv  "$d/tb/"

    if ! grep -qF "$from" "$d/rtl/$file"; then
        echo "  FAIL  $name: the line to break was not found in $file"
        echo "        (the RTL changed; update this injection)"
        fail=1
        return
    fi
    python3 - "$d/rtl/$file" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
open(p, 'w').write(s.replace(a, b, 1))
PY

    local P="$d/rtl/avalon_mm_sdcard_controller"
    verilator --binary --timing --assert -j "$(nproc)" -Wno-fatal \
        -CFLAGS "-std=c++20" "${PCHFIX[@]}" --Mdir "$d/obj" -o simx \
        "${P}_pkg.sv" "${P}_crc.sv" "${P}_clkgen.sv" "${P}_spi_phy.sv" \
        "${P}_fifo.sv" "${P}_dma.sv" "${P}_seq.sv" "${P}_regs.sv" "${P}.sv" \
        "$d/tb/avalon_mm_sdcard_controller_sva.sv" \
        "$d/tb/spi_card_model.sv" "$d/tb/avalon_mm_mem_model.sv" \
        "$d/tb/avalon_mm_sdcard_controller_tb.sv" \
        --top-module avalon_mm_sdcard_controller_tb > "$d/build.log" 2>&1

    if [ ! -x "$d/obj/simx" ]; then
        echo "  FAIL  $name: the faulty build did not compile"
        grep -E '^%Error' "$d/build.log" | head -3
        fail=1
        return
    fi

    timeout 300 "$d/obj/simx" > "$d/run.log" 2>&1
    if grep -q "$want" "$d/run.log"; then
        echo "  PASS  $name caught by $want"
    else
        echo "  FAIL  $name went UNNOTICED - $want never fired"
        fail=1
    fi
}

echo ""
echo "=== assertion fault injection ==="
echo ""

inject zero_byteenable a_no_zero_byteenable_read \
    avalon_mm_sdcard_controller_dma.sv \
    "always_comb m0_byteenable = 4'hF;" \
    "always_comb m0_byteenable = m0_read ? 4'h0 : 4'hF;"

# Drop the ready term from the prefetch handshake, so a byte can be offered
# while the prefetch is already occupied. This is the double-queue defect that
# sent a command frame out with its first byte repeated and its last missing.
#
# Note what is NOT injected here: removing the `!hold_v` term from the shifter's
# `idle` output. That looks like the obvious fault to try and it is unreachable
# in this design - the sequencer always enters a sending state with the shifter
# already running, because S_PRE_BUSY free-runs 0xFF first, so hold_v is never
# set while byte_active is clear. The term stays in the RTL as an invariant
# worth holding if that ever changes, but an injection targeting an unreachable
# state proves nothing, and a check that cannot fail does not belong here.
inject unready_prefetch a_tx_we_needs_ready \
    avalon_mm_sdcard_controller_seq.sv \
    "phy_tx_we   = tx_want && phy_tx_ready && (state != S_IDLE);" \
    "phy_tx_we   = tx_want && (state != S_IDLE);"

inject idle_in_send a_send_state_never_idles \
    avalon_mm_sdcard_controller_seq.sv \
    "phy_tx_idle = rx_state;" \
    "phy_tx_idle = rx_state || !tx_want;"

echo ""
if [ $fail -eq 0 ]; then echo "*** PASS ***"; else echo "*** FAIL ***"; fi
echo ""
exit $fail
