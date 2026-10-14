#!/usr/bin/env bash
# make ladder-types [CHECK=1] (docs/ladder.md, "Candidate rungs"): rewrite scripts/g3/ladder.types.tsv
# (the c8g, c9g, r8g and x8g types O2 and O3 choose among) from truffle, recording truffle's version
# and the query; CHECK=1 compares the committed table with truffle's answer now and writes nothing.
# truffle is read-only (a catalogue and price query): nothing is launched. The program is
# scripts/lib/ladder_types.py (its `validate` runs offline in make test).
#
# Deliberately not `set -e`: every status is checked by hand.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
# The pinned truffle (make tools; docs/run.md, "Pinned tools"), never the one on PATH.
# shellcheck source=/dev/null
. scripts/lib/tools_pin.sh
ak2_pin_tools "$PWD" || { echo "ladder-types: the pinned spawn/truffle are not in place (make tools)" >&2; exit 2; }
echo "ladder-types: shell flags $-"
command -v truffle > /dev/null || { echo "ladder-types: truffle not on PATH" >&2; exit 2; }
MODE=write; [ "${1:-}" = check ] && MODE=check
python3 -u scripts/lib/ladder_types.py "$MODE"
rc=$?
echo "ladder-types: exit $rc"
exit $rc
