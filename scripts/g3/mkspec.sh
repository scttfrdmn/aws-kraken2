#!/usr/bin/env bash
# Generate a G3 campaign spec (#25) from scripts/g3/campaign.body.sh:
#
#   scripts/g3/mkspec.sh EXP TYPE N COHORT [KEY=VALUE...]   -> runs/g3-<EXP>-<TYPE>-n<N>.json
#
# KEY=VALUE overrides the body's parameters: THREADS (16), INFLIGHT (auto: vCPUs / 8, at least 1),
# CONTROL_MOD (1), REPEAT_LPT (1), C1_REPS (3), TTL (minutes, 60), AZ (us-west-2a).
# The root disk holds the inputs a node reads (its home samples in the LPT and mod batches, and
# sample 1), from runs.tsv's bytes. The node's memory must hold its shard of RODA v205's hash.k2d
# (1189 GB) plus 15%; the generator refuses a type that cannot. cost_limit per member is the
# truffle on-demand price x TTL.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
EXP=${1:?EXP}; TYPE=${2:?TYPE}; N=${3:?N}; COHORT=${4:?COHORT}; shift 4
THREADS=16 INFLIGHT=auto CONTROL_MOD=1 REPEAT_LPT=1 C1_REPS=3 TTL=60 AZ=us-west-2a
for kv in "$@"; do
  case "${kv%%=*}" in THREADS|INFLIGHT|CONTROL_MOD|REPEAT_LPT|C1_REPS|TTL|AZ) eval "${kv%%=*}=\${kv#*=}" ;;
    *) echo "mkspec: unknown $kv" >&2; exit 2 ;; esac
done
[[ "$EXP" =~ ^[a-z0-9]+$ && "$N" =~ ^[0-9]+$ && "$COHORT" =~ ^[0-9]+$ ]] || { echo "mkspec: bad EXP/N/COHORT" >&2; exit 2; }
INFO=$(truffle find "$TYPE" --regions us-west-2 --show-price -o json 2>/dev/null |
  jq -c '[.. | objects | select(has("on_demand_price") and .instance_type == "'"$TYPE"'")][0]')
[ -n "$INFO" ] && [ "$INFO" != null ] || { echo "mkspec: truffle knows no $TYPE in us-west-2" >&2; exit 1; }
PRICE=$(echo "$INFO" | jq -r .on_demand_price); MEM=$(echo "$INFO" | jq -r .memory_mib); VCPU=$(echo "$INFO" | jq -r .vcpus)
HASH=1189000000000
# Memory: the shard plus 15%, 8 GB, and 2 GB per sample in flight (E3 c8g.12xlarge, 96 GiB with 6 in
# flight, was OOM-killed at 306f827; a 200k-pair sample at T16 measured about 0.9 GB locally).
IFN=$INFLIGHT; [ "$IFN" = auto ] && IFN=$(( VCPU / 8 > 0 ? VCPU / 8 : 1 ))
awk -v m="$MEM" -v h="$HASH" -v n="$N" -v i="$IFN" 'BEGIN{exit !(m * 1048576 >= 1.15 * h / n + 8e9 + 2e9 * i)}' ||
  { echo "mkspec: $TYPE ($MEM MiB) cannot hold 1/$N of hash.k2d plus 15%, 8 GB and $IFN x 2 GB in flight" >&2; exit 1; }
RUNS=results/cohort/PRJNA398089/runs.tsv
BYTES=$(awk -F'\t' -v c="$COHORT" 'NR>1 && $1<=c {s += $7 + $10} END{print s}' "$RUNS")
S1=$(awk -F'\t' 'NR==2 {print $7 + $10}' "$RUNS")
SETS=1; [ "$CONTROL_MOD" = 1 ] && [ "$N" -gt 1 ] && SETS=2
DISK=$(awk -v b="$BYTES" -v s="$SETS" -v n="$N" -v s1="$S1" 'BEGIN{d = 30 + 1.3 * (s * b / n + s1) / 1073741824; printf "%d", (d < 40 ? 40 : d) + 0.999}')
COST=$(awk -v p="$PRICE" -v t="$TTL" 'BEGIN{printf "%.2f", p * t / 60 + 0.005}')
SPEC="runs/g3-$EXP-$TYPE-n$N.json"
PARAMS="EXP=$EXP; WANT_N=$N; COHORT=$COHORT; THREADS=$THREADS; INFLIGHT=$INFLIGHT; CONTROL_MOD=$CONTROL_MOD; REPEAT_LPT=$REPEAT_LPT; C1_REPS=$C1_REPS"
BODY=$(awk -v p="$PARAMS" '$0 == "@PARAMS@" {print "# Parameters (scripts/g3/mkspec.sh):"; print p; next} {print}' scripts/g3/campaign.body.sh)
R=s3://kraken2-ncbi-refseq-complete-v205/Kraken2_RefSeqCompleteV205
D=s3://aws-kraken2-942542972736-us-west-2/aws-kraken2/data
ACC=$(awk -F'\t' -v c="$COHORT" 'NR>1 && $1<=c {printf "%s%s", (NR>2?" ":""), $2}' "$RUNS")
jq -n --arg body "$BODY" --arg task "g3-$EXP-$TYPE-n$N" --arg type "$TYPE" --argjson disk "$DISK" --arg az "$AZ" \
  --arg ttl "${TTL}m" --argjson cost "$COST" --arg ds "$R/hash.k2d $R/opts.k2d $R/taxo.k2d $D/cohort/" --arg acc "$ACC" '{
  task_id: $task,
  command: ["bash", "-c", $body],
  resources: {instance_type: $type, architecture: "arm64", disk_gib: $disk, s3_read_write: ["s3://aws-kraken2-942542972736-us-west-2/aws-kraken2/data/"]},
  placement: {availability_zone: $az},
  env: {AK2_REGION: "us-west-2", AK2_ACCESSIONS: $acc, AK2_DATASETS: $ds},
  lifecycle: {ttl: $ttl, on_complete: "terminate", cost_limit: $cost}
}' > "$SPEC" || exit 1
printf 'mkspec: %s: %d x %s (%d vCPU, %d GiB, $%s/h), cohort %d, disk %d GiB, TTL %sm, cost_limit $%s per member ($%.2f for the cohort)\n' \
  "$SPEC" "$N" "$TYPE" "$VCPU" "$((MEM / 1024))" "$PRICE" "$COHORT" "$DISK" "$TTL" "$COST" "$(awk -v c="$COST" -v n="$N" 'BEGIN{print c * n}')"
ln -sf g3-campaign.cohort.sh "scripts/post/$(basename "$SPEC" .json).cohort.sh" || exit 1
