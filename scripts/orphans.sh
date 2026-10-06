#!/usr/bin/env bash
# make orphans -- list pending/running/shutting-down/stopping/stopped instances launched by this
# repo in EVERY region enabled in the account. Exit 0 if none, 1 if any, 2 if a region could not
# be queried. See docs/orphans.md.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$HERE/ak2.env"
export AWS_PROFILE

REGIONS=$(aws ec2 describe-regions --region us-west-2 --query 'Regions[].RegionName' --output text 2>&1) ||
  { echo "orphans: describe-regions failed: $REGIONS" >&2; exit 2; }
TMP=$(mktemp -d)
# One call per region, in parallel. tag-key values are ORed; the jq filter then keeps instances
# tagged ak2:project=<project> or spawn:task-id=<prefix>*, the latter catching an instance whose
# post-launch create-tags never happened.
for r in $REGIONS; do
  (
    out=$(aws ec2 describe-instances --region "$r" \
      --filters "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
                "Name=tag-key,Values=ak2:project,spawn:task-id" --output json 2>&1) ||
      { echo "$out" > "$TMP/$r.err"; exit 0; }
    echo "$out" | jq -r --arg r "$r" --arg p "$AK2_TAG_PROJECT" --arg t "$AK2_TASK_PREFIX" '
      .Reservations[].Instances[]
      | (reduce (.Tags // [])[] as $x ({}; .[$x.Key] = $x.Value)) as $tags
      | select($tags["ak2:project"] == $p or (($tags["spawn:task-id"] // "") | startswith($t)))
      | [$r, .InstanceId, .State.Name, .InstanceType, .LaunchTime, ($tags["spawn:task-id"] // "-")] | @tsv' \
      > "$TMP/$r.out"
  ) &
done
wait
found=0; failed=0
for r in $REGIONS; do
  if [ -s "$TMP/$r.err" ]; then echo "orphans: $r: $(head -c 300 "$TMP/$r.err")" >&2; failed=1; fi
  if [ -s "$TMP/$r.out" ]; then cat "$TMP/$r.out"; found=1; fi
done
N=$(echo "$REGIONS" | wc -w | tr -d ' ')
rm -rf "$TMP"
if [ "$failed" -ne 0 ]; then echo "orphans: could not query every region" >&2; exit 2; fi
if [ "$found" -ne 0 ]; then echo "orphans: instances above are still alive" >&2; exit 1; fi
echo "orphans: none in $N regions"
