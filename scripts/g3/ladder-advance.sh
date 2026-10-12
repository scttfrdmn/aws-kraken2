#!/usr/bin/env bash
# make ladder-advance COHORT=<c> [DRY_RUN=1] (docs/ladder.md, "Advancing a cohort"): one step of a
# cohort above c1, stage by stage. It runs make ladder-select at the cohort, generates (with
# scripts/g3/mkspec-ladder.sh) every spec now fully determined and not committed, runs the static
# checks (make ladder-check, ladder_body_compat.py check and fresh), prints the stage plan (each
# stage's rungs, the selections pending and why, the summed cost_limit as an upper bound) and the
# rehearsal classes, writes results/g3/ladder-advance/c<c>.plan.tsv, and stops with what the
# coordinator does next. DRY_RUN=1 selects, generates and writes nothing. It never launches, commits
# or pushes. The program is scripts/lib/ladder_advance.py.
#
# Deliberately not `set -e`: every status is checked by hand.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
echo "ladder-advance: shell flags $-"
COHORT=${1:-}
[[ "$COHORT" =~ ^[1-9][0-9]*$ ]] || { echo "usage: make ladder-advance COHORT=<n> [DRY_RUN=1]" >&2; exit 2; }
ARGS=()
[ "${DRY_RUN:-}" = 1 ] && ARGS+=(--dry-run)
python3 -u scripts/lib/ladder_advance.py advance "$COHORT" ${ARGS[@]+"${ARGS[@]}"}
rc=$?
echo "ladder-advance: exit $rc"
exit $rc
