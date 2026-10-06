#!/usr/bin/env bash
# make orphans -- list pending/running/shutting-down/stopping/stopped instances launched by this
# repo in EVERY region enabled in the account. See docs/orphans.md.
#
#   orphans.sh                          global and strict: exit 0 if none, 1 if any are alive,
#                                       2 if a region could not be queried. Run it when no runs
#                                       are in flight.
#   orphans.sh --own TASK_ID [IID...]   run.sh's post-run check: exit 1 only if THIS run's
#                                       instance(s) or task id are still alive (2 if a region
#                                       could not be queried). Other live ak2 instances (concurrent
#                                       runs) are listed for information and do not fail it.
#
# In both modes an instance past its spawn:ttl-deadline + 15 min is flagged PROBABLE ORPHAN: a
# healthy run is terminated by spored at its TTL.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$HERE/ak2.env"
export AWS_PROFILE

OWN_TASK="" OWN_IIDS=""
if [ "${1:-}" = --own ]; then
  [ -n "${2:-}" ] || { echo "usage: orphans.sh --own TASK_ID [INSTANCE_ID...]" >&2; exit 2; }
  OWN_TASK=$2
  shift 2; OWN_IIDS="$*"
fi
GRACE_S=900

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
    echo "$out" | jq -c --arg r "$r" --arg p "$AK2_TAG_PROJECT" --arg t "$AK2_TASK_PREFIX" '
      .Reservations[].Instances[]
      | (reduce (.Tags // [])[] as $x ({}; .[$x.Key] = $x.Value)) as $tags
      | select($tags["ak2:project"] == $p or (($tags["spawn:task-id"] // "") | startswith($t)))
      | {region:$r, id:.InstanceId, state:.State.Name, type:.InstanceType, launch:.LaunchTime,
         task:($tags["spawn:task-id"] // "-"), ttl:($tags["spawn:ttl"] // "-"),
         deadline:($tags["spawn:ttl-deadline"] // null)}' > "$TMP/$r.out" ||
      { echo "jq could not parse the describe-instances output" > "$TMP/$r.err"; exit 0; }
  ) &
done
wait
failed=0
for r in $REGIONS; do
  if [ -s "$TMP/$r.err" ]; then echo "orphans: $r: $(head -c 300 "$TMP/$r.err")" >&2; failed=1; fi
done
N=$(echo "$REGIONS" | wc -w | tr -d ' ')
NOW=$(date -u +%s)
# Annotate each live instance: own (this run) or not, and probable orphan (past TTL + grace).
# A deadline that does not parse keeps its row, flagged: dropping it would fail open.
ROWS=$(cat "$TMP"/*.out 2>/dev/null | jq -c --arg task "$OWN_TASK" --arg iids " $OWN_IIDS " \
  --argjson now "$NOW" --argjson grace "$GRACE_S" '
  .id as $id
  | . + {own: ($task != "" and (.task == $task or ($iids | contains(" " + $id + " ")))),
         stale: (if .deadline == null then null
                 else (try (($now - (.deadline | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601)) > $grace)
                       catch "unparseable") end)}')
ROWS_RC=$?
rm -rf "$TMP"
[ "$ROWS_RC" = 0 ] || { echo "orphans: could not process the instance list (jq exit $ROWS_RC)" >&2; exit 2; }
row() { jq -r '[.region, .id, .state, .type, .launch, .task, "ttl=" + .ttl,
                (if .stale == true then "PROBABLE ORPHAN (past TTL deadline + 15 min)"
                 elif .stale == "unparseable" then "deadline unparseable (spawn:ttl-deadline=\(.deadline | tojson))"
                 elif .stale == null then "no ttl-deadline tag" else "within TTL" end)] | @tsv' ||
        { echo "orphans: could not format the instance list" >&2; exit 2; }; }

if [ -z "$OWN_TASK" ]; then
  if [ -n "$ROWS" ]; then echo "$ROWS" | row || exit 2; fi
  if [ "$failed" -ne 0 ]; then echo "orphans: could not query every region" >&2; exit 2; fi
  if [ -n "$ROWS" ]; then echo "orphans: instances above are still alive (run this when no runs are in flight)" >&2; exit 1; fi
  echo "orphans: none in $N regions"
  exit 0
fi

OWN=$(echo "$ROWS" | jq -c 'select(.own)') || { echo "orphans: jq failed selecting this run's instances" >&2; exit 2; }
OTHER=$(echo "$ROWS" | jq -c 'select(.own | not)') || { echo "orphans: jq failed selecting other instances" >&2; exit 2; }
if [ -n "$OTHER" ]; then
  echo "orphans: other live ak2 instances (concurrent runs; informational, not this run's):"
  echo "$OTHER" | row | sed 's/^/  /' || exit 2
  n_stale=$(echo "$OTHER" | jq -s 'map(select(.stale == true)) | length') || exit 2
  n_bad=$(echo "$OTHER" | jq -s 'map(select(.stale == "unparseable")) | length') || exit 2
  [ "$n_stale" -gt 0 ] && echo "orphans: $n_stale of them look like PROBABLE ORPHANS; run make orphans once no runs are in flight" >&2
  [ "$n_bad" -gt 0 ] && echo "orphans: $n_bad of them have an unparseable spawn:ttl-deadline; check them by hand" >&2
fi
if [ -n "$OWN" ]; then
  echo "orphans: THIS run's instance(s) (task $OWN_TASK) still alive:" >&2
  echo "$OWN" | row | sed 's/^/  /' >&2 || exit 2
  exit 1
fi
if [ "$failed" -ne 0 ]; then echo "orphans: could not query every region, so this run's instance could not be confirmed gone" >&2; exit 2; fi
echo "orphans: this run's instance(s) and task $OWN_TASK are gone ($N regions checked)"
