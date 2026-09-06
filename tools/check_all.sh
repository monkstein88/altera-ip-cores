#!/usr/bin/env bash
# =============================================================================
# check_all.sh - every check in the repository, from the top.
#
#   ./tools/check_all.sh              everything
#   ./tools/check_all.sh --fast       skip the suites that need a simulator
#
# Exit 0 unless something actually failed. Each core prints its own result;
# this script reports the roll-up.
#
# A suite can report three things. PASS, FAIL, and PART - "what I looked at was
# correct, but I could not look at all of it", which a fresh clone hits
# legitimately whenever an optional tool or an untracked recording is absent.
# PART does not fail the build and does not count as a pass; it gets its own
# row and the closing line says so. A green row here has to mean something was
# verified, or this file is decoration.
#
# -----------------------------------------------------------------------------
# WHY THIS EXISTS
# -----------------------------------------------------------------------------
# Each core's verification is self-contained and knows nothing about the others
# or about the file above them. That is the right boundary for the cores and the
# wrong one for the repository: a change inside one core can falsify a sentence
# in the top-level README, and for a long time nothing would notice - which is
# how the SD card controller came to be credited there with 19 assertions and 6
# cover points against a file holding 24 and 5.
#
# So the rule is: after changing anything, run this. It ends with
# tools/check_readme.py, which holds the top-level README against the tree.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

fail=0
partial=0
summary=()

# Three outcomes. Exit 2 from a suite means "what I checked was correct, but I
# could not check all of it" - graphviz absent, a VCD not recorded. It must not
# stop the build, because a fresh clone legitimately lacks those; it must not
# read as PASS either, because the whole point of this file is that a green row
# should mean something was verified. It gets its own row.
run () {
    local name="$1"; shift
    local log
    log=$(mktemp)
    "$@" > "$log" 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
        summary+=("  PASS  $name")
    elif [ $rc -eq 2 ]; then
        summary+=("  PART  $name - incomplete, see below")
        echo "--- $name (incomplete) ---"
        grep -E '^\s+--|INCOMPLETE|PART |Do what' "$log" | head -10
        partial=1
    else
        summary+=("  FAIL  $name")
        echo "--- $name ---"
        tail -20 "$log"
        fail=1
    fi
    rm -f "$log"
}

echo ""
echo "======================================================================"
echo " altera-ip-cores - repository-wide check"
echo "======================================================================"

# ---------------------------------------------------------------------------
# Each core's own documentation fact checker. These need only Python, so they
# run even in --fast mode: they are the cheapest way to catch a number that has
# drifted, and the most likely thing to have drifted after an edit.
# ---------------------------------------------------------------------------
for core in altera_avalon_mm_firewall altera_axi4_lite_firewall \
            altera_avalon_mm_sdram_controller altera_avalon_mm_sdcard_controller
do
    f="$ROOT/$core/doc/tools/check_facts.py"
    [ -f "$f" ] && run "$core: documentation facts" python3 "$f"
done

# ---------------------------------------------------------------------------
# Full per-core regressions. These need Verilator and take minutes, so --fast
# skips them - but only the runner is skipped, never a result is assumed.
# ---------------------------------------------------------------------------
if [ $FAST -eq 0 ]; then
    for core in altera_avalon_mm_sdcard_controller; do
        f="$ROOT/$core/verification/run_all.sh"
        [ -f "$f" ] && run "$core: full check" bash "$f"
    done
else
    summary+=("  --    per-core regressions skipped (--fast)")
fi

# ---------------------------------------------------------------------------
# The top-level README, last, because it describes everything above.
# ---------------------------------------------------------------------------
run "top-level README" python3 "$ROOT/tools/check_readme.py"

echo ""
printf '%s\n' "${summary[@]}"
echo ""
if [ $fail -ne 0 ]; then
    echo "*** SOMETHING FAILED ***"
elif [ $partial -ne 0 ]; then
    echo "*** ALL CHECKS PASS - BUT SOME WERE INCOMPLETE (see PART above) ***"
    echo "    Nothing has drifted. Something could not be looked at."
else
    echo "*** ALL CHECKS PASS ***"
fi
echo ""
exit $fail
