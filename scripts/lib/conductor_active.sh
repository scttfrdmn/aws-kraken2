#!/usr/bin/env bash
# scripts/lib/conductor_active.sh COHORT (docs/conductor.md, "One driver per cohort"): is a conductor
# driving this cohort now? Reads every conductor.json under the results bucket's staging prefix; one
# that has not ended, names COHORT, and whose instance is pending or running is active. make
# ladder-campaign on the laptop refuses to start while one is (two drivers of one cohort would both
# launch its rungs). A conductor.json that never ended but whose instance is gone (a TTL kill) is
# reported and ignored. Exit 0: none; 1: active (one line each on stdout); 2: cannot judge.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
# shellcheck source=/dev/null
. scripts/ak2.env
export AWS_PROFILE
C=${1:-}
[[ "$C" =~ ^[1-9][0-9]*$ ]] || { echo "conductor_active: usage: conductor_active.sh COHORT" >&2; exit 2; }
B=$AK2_RESULTS_BUCKET_us_west_2
P="$AK2_RESULTS_ROOT/$AK2_STAGING_DIR/"
KEYS=$(aws s3api list-objects-v2 --region us-west-2 --bucket "$B" --prefix "$P" \
  --query "Contents[?ends_with(Key, '/conductor.json')].Key" --output text 2>&1) ||
  { echo "conductor_active: list-objects-v2 s3://$B/$P failed: $(echo "$KEYS" | head -c 200)" >&2; exit 2; }
FOUND=0
for k in $KEYS; do
  [ "$k" = None ] && continue
  J=$(aws s3 cp --only-show-errors --region us-west-2 "s3://$B/$k" - 2>&1) || { echo "conductor_active: cannot read s3://$B/$k" >&2; exit 2; }
  ROW=$(echo "$J" | jq -r '[(.ended|tostring), ((.cohort // ((.params // "") | capture("COHORT=(?<c>[0-9]+)").c? // "0")) | tostring),
                           (.instance_id // ""), .conductor_run_id] | @tsv' 2>/dev/null) || { echo "conductor_active: s3://$B/$k does not parse" >&2; exit 2; }
  IFS=$'\t' read -r ENDED CC IID RID <<< "$ROW"
  [ "$ENDED" = false ] && [ "$CC" = "$C" ] || continue
  ST=None
  if [ -n "$IID" ]; then
    ST=$(aws ec2 describe-instances --region us-west-2 --instance-ids "$IID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>&1)
    case "$ST" in *InvalidInstanceID.NotFound*) ST=gone ;; pending|running|stopping|stopped|shutting-down|terminated) ;;
      *) echo "conductor_active: describe-instances $IID failed: $(echo "$ST" | head -c 200)" >&2; exit 2 ;; esac
  fi
  case "$ST" in
    pending|running) echo "conductor $RID (instance $IID, $ST) is driving cohort $C: drain it (make ladder-campaign-drain CAMPAIGN=$RID) or wait"; FOUND=1 ;;
    *) echo "conductor_active: note: conductor $RID never ended but its instance is ${ST:-unknown}; not counted (make harvest PARTIAL=1 CAMPAIGN=$RID)" >&2 ;;
  esac
done
exit "$FOUND"
