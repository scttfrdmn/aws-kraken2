#!/usr/bin/env bash
# Generate a #25 ladder rung's spec (#51; docs/ladder.md, "The generator"):
#
#   scripts/g3/mkspec-ladder.sh ARM RUNG COHORT [TTL=<minutes>]   -> runs/g3-l-<rung>-c<cohort>.json
#
# ARM is S (ladder 1, upstream) or O (ladder 2, ours) and must be the rung's arm in
# scripts/g3/ladder.levers.tsv. The rung's PARAMs (scripts/lib/ladder_levers.py params) become the
# @PARAMS@ block of scripts/g3/ladder.body.sh: in the payload, never in env. Refuses:
#   - a table that fails make ladder-check (one key-group per rung, counterparts, endpoints);
#   - any PARAM or host still a placeholder (@probe-tune, @select:...) after scripts/g3/ladder.resolved.tsv;
#   - a type whose memory (or NVMe device) cannot hold the rung at this cohort;
#   - above cohort 1 without TTL=, a rung whose TTL estimate (scripts/lib/ladder_ttl.py, from the
#     record's c1 runs of the rung or its nearest measured relative) cannot be made (exit 1) or is
#     above AK2_MAX_TTL_S (exit 5). The estimate and its basis go into the spec's TTL comment.
# The table's ttl_min_c1 is cohort 1's TTL; TTL= overrides either (by decision only).
# cost_limit per member = the truffle on-demand price x TTL (+ $0.005, to the cent), as
# scripts/g3/mkspec.sh; run.sh and run-multi.sh check it (docs/run.md, "cost_limit"). Every spec
# pins the type and the AZ, so make run and make dryrun-userdata use run-multi.sh with NODES =
# WANT_N (REPLICAS x SHARDS). Deterministic: the same table, cohort and price give the same bytes.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ARM=${1:?ARM (S or O)}; RUNG=${2:?RUNG}; COHORT=${3:?COHORT}; shift 3
TTL=""
for kv in "$@"; do
  case "$kv" in TTL=*) TTL=${kv#TTL=} ;; *) echo "mkspec-ladder: unknown argument $kv" >&2; exit 2 ;; esac
done
[[ "$ARM" =~ ^[SO]$ ]] || { echo "mkspec-ladder: ARM $ARM (S or O)" >&2; exit 2; }
[[ "$COHORT" =~ ^[1-9][0-9]*$ ]] || { echo "mkspec-ladder: COHORT $COHORT" >&2; exit 2; }
[ -z "$TTL" ] || [[ "$TTL" =~ ^[1-9][0-9]*$ ]] || { echo "mkspec-ladder: TTL=$TTL (minutes)" >&2; exit 2; }
L=scripts/lib/ladder_levers.py
# First without the memory check, for the type; then with it.
OUT=$(python3 "$L" params "$RUNG" "$COHORT") || { echo "mkspec-ladder: refused $RUNG at cohort $COHORT (above)" >&2; exit 1; }
WANT_ARM=$ARM; eval "$OUT"
[ "$WANT_ARM" = "$ARM" ] || { echo "mkspec-ladder: $RUNG is on arm $ARM, not $WANT_ARM" >&2; exit 2; }
TYPE=$INSTANCE
INFO=$(truffle find "$TYPE" --regions us-west-2 --show-price -o json 2>/dev/null |
  jq -c '[.. | objects | select(has("on_demand_price") and .instance_type == "'"$TYPE"'")][0]')
[ -n "$INFO" ] && [ "$INFO" != null ] || { echo "mkspec-ladder: truffle knows no $TYPE in us-west-2" >&2; exit 1; }
PRICE=$(echo "$INFO" | jq -r .on_demand_price); MEM=$(echo "$INFO" | jq -r .memory_mib); VCPU=$(echo "$INFO" | jq -r .vcpus)
[[ "$PRICE" =~ ^[0-9.]+$ ]] && [[ "$MEM" =~ ^[0-9]+$ ]] || { echo "mkspec-ladder: no price or memory for $TYPE" >&2; exit 1; }
python3 "$L" params "$RUNG" "$COHORT" --mem-mib "$MEM" --vcpus "$VCPU" > /dev/null || { echo "mkspec-ladder: refused $RUNG on $TYPE (above)" >&2; exit 1; }
EST=""
if [ -z "$TTL" ]; then
  if [ "$COHORT" = 1 ]; then
    TTL=$TTL_C1
  else
    # Above c1: the estimate from the record's c1 runs (scripts/lib/ladder_ttl.py; docs/ladder.md, "TTL above c1").
    EOUT=$(python3 scripts/lib/ladder_ttl.py estimate "$RUNG" "$COHORT" --vcpus "$VCPU"); erc=$?
    if [ "$erc" != 0 ]; then
      echo "mkspec-ladder: no TTL for $RUNG at cohort $COHORT (ladder_ttl.py exit $erc, above); give TTL=<minutes> only by decision" >&2
      exit "$([ "$erc" = 5 ] && echo 5 || echo 1)"
    fi
    eval "$EOUT"
    EST=$TTLNOTE
  fi
fi
COST=$(awk -v p="$PRICE" -v t="$TTL" 'BEGIN{printf "%.2f", p * t / 60 + 0.005}')
LOW=$(echo "$RUNG" | tr '[:upper:]' '[:lower:]')
SPEC="runs/g3-l-$LOW-c$COHORT.json"
if [ -n "$EST" ]; then
  TTLNOTE="# TTL ${TTL}m and cost_limit \$$COST: runaway backstops sized by estimate; $EST."
else
  TTLNOTE="# TTL ${TTL}m and cost_limit \$$COST: runaway backstops sized by estimate; the classic aws s3 cp rate is unmeasured, so the staging time of the default client is not known in advance."
fi
BODY=$(awk -v p="$PARAMS" -v t="$TTLNOTE" -v h="# Parameters (scripts/g3/mkspec-ladder.sh $ARM $RUNG $COHORT; manifest.params, by scripts/lib/ladder_levers.py spec-params):" \
  '$0 == "@PARAMS@" {print t; print h; print p; n++; next} {print} END {exit n != 1}' scripts/g3/ladder.body.sh) ||
  { echo "mkspec-ladder: scripts/g3/ladder.body.sh has no single @PARAMS@ line" >&2; exit 1; }
R=s3://kraken2-ncbi-refseq-complete-v205/Kraken2_RefSeqCompleteV205
D=s3://aws-kraken2-942542972736-us-west-2/aws-kraken2/data
ACC="@PRJNA398089:1-$COHORT"
scripts/lib/accessions.sh "$ACC" > /dev/null || { echo "mkspec-ladder: $ACC does not resolve" >&2; exit 1; }
jq -n --arg body "$BODY" --arg task "g3-l-$LOW-c$COHORT" --arg type "$TYPE" --arg az "$AZ" \
  --arg ttl "${TTL}m" --argjson cost "$COST" --arg ds "$R/hash.k2d $R/opts.k2d $R/taxo.k2d $D/cohort/" --arg acc "$ACC" '{
  task_id: $task,
  command: ["bash", "-c", $body],
  resources: {instance_type: $type, architecture: "arm64", disk_gib: 60, s3_read_write: ["s3://aws-kraken2-942542972736-us-west-2/aws-kraken2/data/"]},
  placement: {availability_zone: $az},
  env: {AK2_REGION: "us-west-2", AK2_ACCESSIONS: $acc, AK2_DATASETS: $ds},
  lifecycle: {ttl: $ttl, on_complete: "terminate", cost_limit: $cost}
}' > "$SPEC" || exit 1
printf 'mkspec-ladder: %s: %s %s, %d x %s (%d vCPU, %d GiB, $%s/h), cohort %d, TTL %sm, cost_limit $%s per member\n' \
  "$SPEC" "$ARM" "$RUNG" "$WANT_N" "$TYPE" "$VCPU" "$((MEM / 1024))" "$PRICE" "$COHORT" "$TTL" "$COST"
