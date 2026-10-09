#!/usr/bin/env bash
# make instance-types (docs/util.md): the installed capacity utilisation is measured against, for
# every instance type a manifest under results/ names, from `aws ec2 describe-instance-types`
# (read-only, no charge). Writes results/instance-types/<region>.json:
#   {region, queried_at, source, aws_cli, types: {<type>: {vcpus, memory_mib, network_performance,
#    baseline_gbps, peak_gbps}}}
# scripts/lib/util.py and util_backfill.py read it for runs whose manifest has no
# instance.type_info (run.sh records that at launch since the sampler landed).
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel) || exit 2
cd "$ROOT" || exit 2
. scripts/ak2.env
export AWS_PROFILE
REGION=${REGION:-us-west-2}
TYPES=$(cat results/*/*/manifest.json 2>/dev/null | jq -r 'select(.region == null or .region == "'"$REGION"'") | .instance.type // empty' | sort -u)
[ -n "$TYPES" ] || { echo "instance-types: no instance types in results/*/*/manifest.json" >&2; exit 2; }
OUT="results/instance-types/$REGION.json"
mkdir -p results/instance-types
# shellcheck disable=SC2086
J=$(aws ec2 describe-instance-types --region "$REGION" --instance-types $TYPES --output json) ||
  { echo "instance-types: describe-instance-types failed" >&2; exit 1; }
echo "$J" | jq --arg r "$REGION" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cli "$(aws --version 2>&1 | cut -d' ' -f1)" '{
  region:$r, queried_at:$at, source:"aws ec2 describe-instance-types", aws_cli:$cli,
  types:(.InstanceTypes | map({key:.InstanceType, value:{vcpus:.VCpuInfo.DefaultVCpus, memory_mib:.MemoryInfo.SizeInMiB,
    network_performance:.NetworkInfo.NetworkPerformance, baseline_gbps:.NetworkInfo.NetworkCards[0].BaselineBandwidthInGbps,
    peak_gbps:.NetworkInfo.NetworkCards[0].PeakBandwidthInGbps}}) | sort_by(.key) | from_entries)}' > "$OUT" ||
  { echo "instance-types: could not write $OUT" >&2; exit 1; }
echo "instance-types: $(jq '.types | length' "$OUT") type(s) -> $OUT"
