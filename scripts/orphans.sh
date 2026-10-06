#!/usr/bin/env bash
# make orphans -- list pending/running/stopping/stopped instances launched by this repo, in every
# region in AK2_REGIONS. Exit 0 if none, 1 if any, 2 if a region could not be queried.
# See docs/orphans.md.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$HERE/ak2.env"
export AWS_PROFILE

STATES="Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down"
QUERY='Reservations[].Instances[].[InstanceId,State.Name,InstanceType,LaunchTime,Tags[?Key==`spawn:task-id`]|[0].Value]'
found=0; failed=0
for r in $AK2_REGIONS; do
  # Two selectors, unioned: the tag run.sh adds after launch, and the task-id prefix spawn
  # tags at launch (covers an instance whose create-tags never happened).
  a=$(aws ec2 describe-instances --region "$r" --filters "$STATES" "Name=tag:ak2:project,Values=$AK2_TAG_PROJECT" \
        --query "$QUERY" --output text 2>&1) || { echo "orphans: $r: $a" >&2; failed=1; continue; }
  b=$(aws ec2 describe-instances --region "$r" --filters "$STATES" "Name=tag:spawn:task-id,Values=${AK2_TASK_PREFIX}*" \
        --query "$QUERY" --output text 2>&1) || { echo "orphans: $r: $b" >&2; failed=1; continue; }
  rows=$(printf '%s\n%s\n' "$a" "$b" | grep . | sort -u)
  if [ -n "$rows" ]; then
    found=1
    printf '%s\n' "$rows" | sed "s/^/$r\t/"
  fi
done
if [ "$failed" -ne 0 ]; then echo "orphans: could not query every region" >&2; exit 2; fi
if [ "$found" -ne 0 ]; then echo "orphans: instances above are still alive" >&2; exit 1; fi
echo "orphans: none in $AK2_REGIONS"
