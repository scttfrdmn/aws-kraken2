#!/usr/bin/env bash
# make conductor-spec COHORT=<c> [RUNGS=S1,O0] [REPS=2] [CONCURRENCY=1] [FAMILY_LIMITS=X=2]
#   [DRY_RUN=1] [DRY_MAKE_RUN=1] [TTL=<minutes>] [TYPE=m8g.medium] [OUT=runs/conductor.json]
# (docs/conductor.md, "The spec"): the conductor's TaskSpec, from scripts/conductor.body.sh with the
# campaign's arguments as its @PARAMS@ block (in the payload, not in env).
#   - TYPE (default m8g.medium: 1 Graviton vCPU, 4 GiB, not burstable, so cost_usd is the bill; the
#     2 GiB types are tight for run.sh's go build of scripts/udsize);
#   - TTL (minutes, default AK2_CONDUCTOR_MAX_TTL_S / 60, 72 h; Scott 2026-10-14): the campaign drains itself before it
#     (AK2_CAMPAIGN_DEADLINE); cost_limit = the truffle on-demand price x TTL (+ $0.005, to the cent);
#   - DRY_RUN=1: the campaign prints its plan only; DRY_MAKE_RUN=1: before it, a DRY_RUN=1 make run of
#     the cheapest c<COHORT> rung (sizing, cost, quota and user data under the instance role).
# Commit the spec, push, then make run GATE=conductor SPEC=<OUT>. Deterministic for the same
# arguments and price.
set +e
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/ak2.env
# shellcheck source=/dev/null
. scripts/lib/tools_pin.sh
ak2_pin_tools "$PWD" || { echo "mkspec-conductor: the pinned truffle is not in place (make tools)" >&2; exit 2; }
COHORT=""; RUNGS=""; REPS=2; CONC=1; LIMITS=""; DRY=""; DMR=0; TTL=$((AK2_CONDUCTOR_MAX_TTL_S / 60)); TYPE=m8g.medium; OUT=runs/conductor.json
for kv in "$@"; do
  case "$kv" in
    *=) ;;   # an empty make variable keeps the default
    COHORT=*) COHORT=${kv#*=} ;; RUNGS=*) RUNGS=${kv#*=} ;; REPS=*) REPS=${kv#*=} ;; CONCURRENCY=*) CONC=${kv#*=} ;;
    FAMILY_LIMITS=*) LIMITS=${kv#*=} ;; DRY_RUN=*) DRY=${kv#*=} ;; DRY_MAKE_RUN=*) DMR=${kv#*=} ;; TTL=*) TTL=${kv#*=} ;;
    TYPE=*) TYPE=${kv#*=} ;; OUT=*) OUT=${kv#*=} ;;
    *) echo "mkspec-conductor: unknown argument $kv" >&2; exit 2 ;;
  esac
done
die() { echo "mkspec-conductor: $*" >&2; exit 2; }
[[ "$COHORT" =~ ^[1-9][0-9]*$ ]] || die "COHORT=$COHORT"
[[ "$RUNGS" =~ ^[A-Za-z0-9,-]*$ ]] || die "RUNGS=$RUNGS (rung names, comma-separated)"
[[ "$REPS" =~ ^[1-9][0-9]*$ ]] && [[ "$CONC" =~ ^[1-9][0-9]*$ ]] || die "REPS=$REPS CONCURRENCY=$CONC"
[[ "$LIMITS" =~ ^[A-Za-z+=0-9,]*$ ]] || die "FAMILY_LIMITS=$LIMITS"
[[ "$DRY" =~ ^1?$ ]] && [[ "$DMR" =~ ^[01]$ ]] || die "DRY_RUN=$DRY DRY_MAKE_RUN=$DMR"
[[ "$TTL" =~ ^[1-9][0-9]*$ ]] && [ $((TTL * 60)) -le "$AK2_CONDUCTOR_MAX_TTL_S" ] || die "TTL=$TTL minutes (at most AK2_CONDUCTOR_MAX_TTL_S=$AK2_CONDUCTOR_MAX_TTL_S s)"
case "$OUT" in runs/conductor*.json) ;; *) die "OUT=$OUT must be runs/conductor*.json (run.sh ties them to GATE=conductor)" ;; esac
ls runs/g3-l-*-c"$COHORT".json > /dev/null 2>&1 || die "no committed runs/g3-l-*-c$COHORT.json"
PRICE=$(truffle find "$TYPE" --regions us-west-2 --show-price --skip-azs -o json 2> /dev/null | jq -r '.[0].on_demand_price // empty')
[[ "$PRICE" =~ ^[0-9.]+$ ]] || die "truffle gave no on-demand price for $TYPE in us-west-2"
COST=$(awk -v p="$PRICE" -v t="$TTL" 'BEGIN{printf "%.2f", p * t / 60 + 0.005}')
P="COHORT=$COHORT; RUNGS=\"$RUNGS\"; REPS=$REPS; CONCURRENCY=$CONC; FAMILY_LIMITS=\"$LIMITS\"; DRY_RUN=$DRY; DRY_MAKE_RUN=$DMR; TTL_S=$((TTL * 60))"
H="# Conductor parameters (scripts/mkspec-conductor.sh; TTL ${TTL}m and cost_limit \$$COST at \$$PRICE/h for $TYPE: runaway backstops):"
BODY=$(awk -v p="$P" -v h="$H" '$0 == "@PARAMS@" {print h; print p; n++; next} {print} END {exit n != 1}' scripts/conductor.body.sh) ||
  die "scripts/conductor.body.sh has no single @PARAMS@ line"
RB=$AK2_RESULTS_BUCKET_us_west_2
jq -n --arg body "$BODY" --arg type "$TYPE" --arg ttl "${TTL}m" --argjson cost "$COST" \
  --arg ds "s3://kraken2-ncbi-refseq-complete-v205/Kraken2_RefSeqCompleteV205/ s3://$RB/$AK2_RESULTS_ROOT/" '{
  task_id: "conductor",
  command: ["bash", "-c", $body],
  resources: {instance_type: $type, architecture: "arm64", disk_gib: 30},
  env: {AK2_REGION: "us-west-2", AK2_ACCESSIONS: "", AK2_DATASETS: $ds},
  lifecycle: {ttl: $ttl, on_complete: "terminate", cost_limit: $cost}
}' > "$OUT" || exit 1
echo "mkspec-conductor: $OUT: $TYPE (\$$PRICE/h), TTL ${TTL}m, cost_limit \$$COST; $P"
