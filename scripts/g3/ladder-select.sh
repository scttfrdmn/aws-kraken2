#!/usr/bin/env bash
# make ladder-select COHORT=<c> [RUNG=<rung>[,<rung>...]] [DRY_RUN=1] (docs/ladder.md, "Selection"):
# applies the registered select rules of scripts/g3/ladder.levers.tsv at one cohort, from a fresh
# make g3-ladder (into a scratch dir), and writes the winners as rows of
# scripts/g3/ladder.resolved.tsv, each citing its runs and a snapshot of the tables under
# results/g3/ladder-select/ with sha256. DRY_RUN=1 writes nothing. It launches nothing and commits
# nothing. The program is scripts/lib/ladder_select.py.
#
# Deliberately not `set -e`: every status is checked by hand.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
echo "ladder-select: shell flags $-"
COHORT=${1:-}; RUNG=${2:-}
[[ "$COHORT" =~ ^[1-9][0-9]*$ ]] || { echo "usage: make ladder-select COHORT=<n> [RUNG=<rung>[,<rung>...]] [DRY_RUN=1]" >&2; exit 2; }
ARGS=()
[ -n "$RUNG" ] && ARGS+=(--rung "$RUNG")
[ "${DRY_RUN:-}" = 1 ] && ARGS+=(--dry-run)
python3 -u scripts/lib/ladder_select.py select "$COHORT" ${ARGS[@]+"${ARGS[@]}"}
rc=$?
echo "ladder-select: exit $rc"
exit $rc
