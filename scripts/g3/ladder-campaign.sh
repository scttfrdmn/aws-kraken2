#!/usr/bin/env bash
# make ladder-campaign COHORT=<c> [REPS=2] [RUNGS=S1,S2a] [CONCURRENCY=1] [FAMILY_LIMITS=X=2] [DRY_RUN=1]
# (docs/ladder.md, "The campaign"): every committed runs/g3-l-*-c<c>.json, REPS times, cheapest
# first (rep 2 reversed), skipping what the record already has, through make run with
# NODES = WANT_N and AK2_LADDER_REP; make orphans and make g3-ladder after every run. DRY_RUN=1
# prints the plan for the record and launches nothing. The planner and driver are
# scripts/lib/ladder_campaign.py. It commits nothing.
#
# Deliberately not `set -e`: every status is checked by hand.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
echo "ladder-campaign: shell flags $-"
COHORT=${1:-}; REPS=${2:-2}; RUNGS=${3:-}; LIMITS=${4:-}; CONC=${5:-1}
[[ "$COHORT" =~ ^[1-9][0-9]*$ ]] || { echo "usage: make ladder-campaign COHORT=<n> [REPS=2] [RUNGS=...] [CONCURRENCY=1] [FAMILY_LIMITS=X=2] [DRY_RUN=1]" >&2; exit 2; }
[[ "$REPS" =~ ^[1-9][0-9]*$ ]] || { echo "ladder-campaign: REPS=$REPS" >&2; exit 2; }
[[ "$CONC" =~ ^[1-9][0-9]*$ ]] || { echo "ladder-campaign: CONCURRENCY=$CONC" >&2; exit 2; }
for t in python3 git jq; do command -v "$t" >/dev/null || { echo "ladder-campaign: $t not on PATH" >&2; exit 2; }; done
MODE=run; [ "${DRY_RUN:-}" = 1 ] && MODE=plan
ARGS=(--reps "$REPS" --concurrency "$CONC")
[ -n "$RUNGS" ] && ARGS+=(--rungs "$RUNGS")
[ -n "$LIMITS" ] && ARGS+=(--family-limits "$LIMITS")
python3 -u scripts/lib/ladder_campaign.py "$MODE" "$COHORT" "${ARGS[@]}"
rc=$?
echo "ladder-campaign: exit $rc"
exit $rc
