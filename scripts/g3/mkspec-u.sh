#!/usr/bin/env bash
# Generate a G3 upstream spec (#25) from a body file:
#
#   scripts/g3/mkspec-u.sh NAME TYPE TTL_MIN BODY   -> runs/g3-NAME-TYPE.json
#
# A single instance (make run, no NODES); disk 60 GiB (U1 keeps everything on tmpfs; U2 on NVMe);
# cost_limit = truffle on-demand price x TTL. Datasets: RODA v205 and the staged cohort.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
NAME=${1:?NAME}; TYPE=${2:?TYPE}; TTL=${3:?TTL}; BODY=${4:?BODY}
PRICE=$(truffle find "$TYPE" --regions us-west-2 --show-price -o json 2>/dev/null |
  jq -r '[.. | objects | select(has("on_demand_price") and .instance_type == "'"$TYPE"'")][0].on_demand_price')
[[ "$PRICE" =~ ^[0-9.]+$ ]] || { echo "mkspec-u: no price for $TYPE" >&2; exit 1; }
COST=$(awk -v p="$PRICE" -v t="$TTL" 'BEGIN{printf "%.2f", p * t / 60 + 0.005}')
SPEC="runs/g3-$NAME-$TYPE.json"
R=s3://kraken2-ncbi-refseq-complete-v205/Kraken2_RefSeqCompleteV205
D=s3://aws-kraken2-942542972736-us-west-2/aws-kraken2/data
jq -n --rawfile body "$BODY" --arg task "g3-$NAME-$TYPE" --arg type "$TYPE" --arg ttl "${TTL}m" --argjson cost "$COST" \
  --arg ds "$R/hash.k2d $R/opts.k2d $R/taxo.k2d $D/cohort/ $D/reads/" '{
  task_id: $task,
  command: ["bash", "-c", $body],
  resources: {instance_type: $type, architecture: "arm64", disk_gib: 60, s3_read_write: ["s3://aws-kraken2-942542972736-us-west-2/aws-kraken2/data/"]},
  placement: {availability_zone: "us-west-2a"},
  env: {AK2_REGION: "us-west-2", AK2_ACCESSIONS: "", AK2_DATASETS: $ds},
  lifecycle: {ttl: $ttl, on_complete: "terminate", cost_limit: $cost}
}' > "$SPEC" || exit 1
echo "mkspec-u: $SPEC: $TYPE (\$$PRICE/h), TTL ${TTL}m, cost_limit \$$COST"
