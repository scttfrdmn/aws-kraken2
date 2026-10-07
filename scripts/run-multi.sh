#!/usr/bin/env bash
# make run GATE=<gate> SPEC=runs/<file>.json NODES=<n> -- a cohort of n coordinated instances
# (the multi-node engine, #24), each one a full scripts/run.sh run of the same spec with its own
# rank. See docs/run.md, "Multi-node runs".
#
# What this adds to run.sh, and why:
#   - one cohort id for the n members; member k is run <cohort>-r<k> with its own run dir,
#     manifest, log stream, TTL, cost_limit and orphan check, exactly as a single run;
#   - the engine env for each member (AK2_ENGINE_N/RANK/RENDEZVOUS, AK2_COHORT_PREFIX), set by
#     run.sh from AK2_COHORT_* (a spec cannot set them);
#   - preconditions a cohort needs and a single run does not: the spec pins instance_type and
#     placement.availability_zone (all members in one AZ), n x cost_limit is within the
#     AK2_MAX_COST_USD backstop, and the region's default-VPC default security group (where
#     spawn task run puts every instance; spawn adds no rules) admits itself and nothing beyond
#     22/tcp and ICMP;
#   - fail fast: once any member's run.sh exits non-zero, the other members' instances are
#     terminated (their run.sh then finalises as for any terminated instance);
#   - on every exit (normal, error, INT/TERM/HUP), the finish trap: terminates any member
#     instance still alive if the cohort did not end normally, aborts unfinished multipart uploads
#     under the cohort prefix (the instance role cannot abort them, and the bucket has no
#     lifecycle rule, so stale parts would be billed indefinitely), fetches and tags the cohort
#     prefix, writes cohort.json, and runs the global orphan check.
#
# Deliberately not `set -e`: every step's status is checked by hand.
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel) || exit 2
cd "$ROOT" || exit 2
# shellcheck source=/dev/null
. scripts/ak2.env
export AWS_PROFILE
echo "run-multi: shell flags $-" >&2

GATE=${1:-}; SPEC=${2:-}; NODES=${3:-}
die() { echo "make run (multi): $*" >&2; exit 2; }
say() { echo "make run (multi): $*" >&2; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
for t in jq aws git; do command -v "$t" >/dev/null || die "$t not on PATH"; done
[[ "$GATE" =~ ^[a-z0-9]+$ ]] || die "usage: make run GATE=<gate> SPEC=runs/<file>.json NODES=<n>"
[[ "$NODES" =~ ^[1-9][0-9]*$ ]] && [ "$NODES" -le 64 ] || die "NODES=$NODES: want 1 to 64"
case "$SPEC" in runs/*.json) ;; *) die "SPEC must be a checked-in runs/*.json" ;; esac
[ -f "$SPEC" ] || die "$SPEC: no such file"
DIRTY_PATHS=$(git status --porcelain -- scripts runs cmd internal upstream go.mod go.sum Makefile)
[ -z "$DIRTY_PATHS" ] || die "uncommitted changes; commit first:
$DIRTY_PATHS"
q() { jq -r "$1" "$SPEC"; }
REGION=$(q '.env.AK2_REGION // empty')
[ -n "$REGION" ] || die "spec has no env.AK2_REGION"
ITYPE=$(q '.resources.instance_type // empty')
[ -n "$ITYPE" ] || die "a cohort spec must pin resources.instance_type (every member the same box)"
AZ=$(q '.placement.availability_zone // empty')
[ -n "$AZ" ] || die "a cohort spec must pin placement.availability_zone (every member in one AZ)"
[[ "$AZ" == "$REGION"* ]] || die "placement.availability_zone $AZ is not in $REGION"
COST=$(q '.lifecycle.cost_limit // 0')
awk -v c="$COST" -v n="$NODES" -v m="$AK2_MAX_COST_USD" 'BEGIN{exit !(c*n <= m+0)}' ||
  die "$NODES x cost_limit \$$COST exceeds AK2_MAX_COST_USD=\$$AK2_MAX_COST_USD"
RB_VAR="AK2_RESULTS_BUCKET_${REGION//-/_}"; RESULTS_BUCKET=${!RB_VAR:-}
[ -n "$RESULTS_BUCKET" ] || die "no results bucket for $REGION ($RB_VAR in scripts/ak2.env)"

# The network precondition. spawn task run attaches the default VPC's default security group (an
# account-wide group: every task run instance in the region shares it) and adds no rules, so the
# members can reach each other only if it admits itself. Anything else it admits is refused:
# beyond the stock 22/tcp and ICMP, a rule would expose the engine's unauthenticated ports.
VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text) ||
  die "describe-vpcs failed in $REGION"
SG_JSON=$(aws ec2 describe-security-groups --region "$REGION" --filters Name=vpc-id,Values="$VPC" Name=group-name,Values=default \
  --query 'SecurityGroups[0]' --output json) || die "describe-security-groups failed"
SG=$(echo "$SG_JSON" | jq -r .GroupId)
SELF=$(echo "$SG_JSON" | jq --arg sg "$SG" '[.IpPermissions[] | select(.IpProtocol == "-1")
  | select(any(.UserIdGroupPairs[]?; .GroupId == $sg))] | length')
[ "${SELF:-0}" -gt 0 ] || die "the default security group $SG of $VPC ($REGION) has no self-referencing all-traffic rule; members could not reach each other"
OTHER=$(echo "$SG_JSON" | jq -c --arg sg "$SG" '[.IpPermissions[]
  | select(
      (.IpProtocol == "-1" and ([.UserIdGroupPairs[]?.GroupId] == [$sg]) and ((.IpRanges // []) | length) == 0
         and ((.Ipv6Ranges // []) | length) == 0 and ((.PrefixListIds // []) | length) == 0)
      or (.IpProtocol == "tcp" and .FromPort == 22 and .ToPort == 22)
      or (.IpProtocol == "icmp")
    | not)]')
[ "$OTHER" = "[]" ] || die "the default security group $SG admits more than itself, 22/tcp and ICMP: $OTHER"
say "network: default VPC $VPC, account-wide security group $SG admits itself, 22/tcp and ICMP only; members in $AZ"

COHORT_ID="$(date -u +%Y%m%d-%H%M%S)-$(git rev-parse --short=7 HEAD)-n$NODES"
CPREFIX="s3://$RESULTS_BUCKET/$AK2_RESULTS_ROOT/$GATE/$COHORT_ID"
CDIR="results/$GATE/$COHORT_ID"
[ ! -e "$CDIR" ] || die "$CDIR exists"
mkdir -p "$CDIR" || die "cannot create $CDIR"
START=$(now)
say "cohort $COHORT_ID: $NODES x $ITYPE in $AZ -> $CPREFIX"

if [ "${DRY_RUN:-}" = 1 ]; then
  say "DRY_RUN=1: rank 0's plan only"
  AK2_COHORT_ID=$COHORT_ID AK2_COHORT_RANK=0 AK2_COHORT_N=$NODES DRY_RUN=1 scripts/run.sh "$GATE" "$SPEC"
  rc=$?; rm -rf "$CDIR"; exit $rc
fi

PIDS=(); RCS=(); TAILPID=""; ENDED=""; FINISHED=0; EARLY_TERMINATED='[]'
task_id() { echo "${AK2_TASK_PREFIX}${GATE}-${COHORT_ID}-r$1"; }

# terminate_members WHY [SKIP_RANK]: terminate every member instance still alive (found by its
# spawn:task-id tag, so a member whose run.sh has not recorded its instance id yet is covered).
terminate_members() {
  local why=$1 skip=${2:--1} k ids
  for ((k = 0; k < NODES; k++)); do
    [ "$k" = "$skip" ] && continue
    ids=$(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:spawn:task-id,Values=$(task_id "$k")" Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)
    [ -n "$ids" ] && [ "$ids" != None ] || continue
    # shellcheck disable=SC2086
    if aws ec2 terminate-instances --region "$REGION" --instance-ids $ids > /dev/null; then
      say "terminated rank $k ($ids): $why"
      EARLY_TERMINATED=$(jq -c --argjson k "$k" --arg ids "$ids" --arg why "$why" '. + [{rank:$k, instances:$ids, why:$why}]' <<< "$EARLY_TERMINATED")
    else
      say "WARNING: could not terminate rank $k ($ids)"
    fi
  done
}

# finish: on every exit. Idempotent.
finish() {
  local rc=$? k
  [ "$FINISHED" = 1 ] && return
  FINISHED=1
  trap '' INT TERM HUP
  [ -n "$TAILPID" ] && { kill "$TAILPID" 2>/dev/null; wait "$TAILPID" 2>/dev/null; }
  if [ -z "$ENDED" ]; then
    ENDED="interrupted (exit $rc)"
    terminate_members "the cohort driver ended before its members ($ENDED)"
    for k in "${!PIDS[@]}"; do
      kill -TERM "${PIDS[$k]}" 2>/dev/null
      [ -z "${RCS[$k]:-}" ] && RCS[$k]=interrupted
    done
    say "members' run dirs may need scripts/refinalise.sh (docs/run.md)"
  fi
  local STOP; STOP=$(now)
  # Unfinished multipart uploads under the cohort prefix, aborted here (the instance role has no
  # s3:AbortMultipartUpload; the bucket has no lifecycle rule).
  local KP="${CPREFIX#s3://$RESULTS_BUCKET/}/" UPS ABORTED=0 ABORT_FAIL=0 key id
  UPS=$(aws s3api list-multipart-uploads --region "$REGION" --bucket "$RESULTS_BUCKET" --prefix "$KP" \
    --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null) || UPS="LISTFAIL"
  if [ "$UPS" = LISTFAIL ]; then ABORT_FAIL=1; say "WARNING: list-multipart-uploads failed; check $CPREFIX/ by hand"
  else
    while read -r key id; do
      [ -n "${key:-}" ] && [ "$key" != None ] || continue
      if aws s3api abort-multipart-upload --region "$REGION" --bucket "$RESULTS_BUCKET" --key "$key" --upload-id "$id"; then
        ABORTED=$((ABORTED + 1)); say "aborted unfinished upload of $key"
      else ABORT_FAIL=$((ABORT_FAIL + 1)); say "WARNING: could not abort the upload of $key"; fi
    done <<< "$UPS"
  fi
  local FETCHED=no i
  for i in 1 2 3; do
    if aws s3 cp --only-show-errors --recursive --region "$REGION" "$CPREFIX/" "$CDIR/prefix/"; then FETCHED=yes; break; fi
    sleep $((10 * i))
  done
  local TAGLINE; TAGLINE=$(scripts/tag-objects.sh "$CPREFIX/" 2>&1) || say "WARNING: tagging: $TAGLINE"
  local MEMBERS='[]' m row
  for ((k = 0; k < NODES; k++)); do
    m="results/$GATE/$COHORT_ID-r$k/manifest.json"
    row=$(jq -c --arg rc "${RCS[$k]:-unknown}" --argjson k "$k" '{rank:$k, run_id, rc:$rc, instance_id:.launch.instance_id,
      type:.instance.type, az:.instance.az, final_state:.instance.final_state, cost_usd, exit_code:.task.exit_code,
      own_gone:.orphan_check.own_gone, finalised:(.manifest_finalised_at != null)}' "$m" 2>/dev/null) ||
      row=$(jq -nc --arg rc "${RCS[$k]:-unknown}" --argjson k "$k" '{rank:$k, rc:$rc, manifest:"missing"}')
    MEMBERS=$(jq -c --argjson r "$row" '. + [$r]' <<< "$MEMBERS")
  done
  scripts/orphans.sh > "$CDIR/orphans.txt" 2>&1; local ORC=$?
  jq -n --arg id "$COHORT_ID" --arg gate "$GATE" --arg spec "$SPEC" --arg sha "$(git rev-parse HEAD)" \
    --argjson n "$NODES" --arg type "$ITYPE" --arg az "$AZ" --arg region "$REGION" --arg prefix "$CPREFIX" \
    --arg vpc "$VPC" --arg sg "$SG" --arg start "$START" --arg stop "$STOP" --argjson members "$MEMBERS" \
    --arg ended "$ENDED" --argjson early "$EARLY_TERMINATED" \
    --arg fetched "$FETCHED" --argjson aborted "$ABORTED" --argjson abort_fail "$ABORT_FAIL" --argjson orc "$ORC" '{
      cohort_id:$id, gate:$gate, spec:$spec, commit:$sha, nodes:$n, instance_type:$type, az:$az, region:$region,
      prefix:$prefix, network:{vpc:$vpc, security_group:$sg, admits:"itself, 22/tcp, ICMP"}, start:$start, stop:$stop,
      ended:$ended, terminated_early:$early, members:$members,
      cost_usd:(if ($members | all(.cost_usd != null)) then ($members | map(.cost_usd) | add * 1e6 | round / 1e6) else null end),
      cost_basis:"sum of the members manifest cost_usd (on-demand truffle price x billed seconds, compute only)",
      prefix_fetched:($fetched == "yes"), multipart_aborted:$aborted, multipart_abort_failures:$abort_fail,
      orphans_rc:$orc}' > "$CDIR/cohort.json" || say "WARNING: could not write cohort.json"
  say "cohort dir: $CDIR  ended: $ENDED  cost \$$(jq -r .cost_usd "$CDIR/cohort.json" 2>/dev/null)  orphans rc $ORC"
  local WORST=$rc r
  for r in "${RCS[@]}"; do [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -gt "$WORST" ] && WORST=$r; done
  [ "$ORC" = 0 ] || { say "ORPHANS: see $CDIR/orphans.txt"; [ "$WORST" = 0 ] && WORST=3; }
  [ "$FETCHED" = yes ] || { say "WARNING: cohort prefix not fetched"; [ "$WORST" = 0 ] && WORST=4; }
  [ "$ABORT_FAIL" = 0 ] || { [ "$WORST" = 0 ] && WORST=5; }
  exit "$WORST"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

for ((k = 0; k < NODES; k++)); do
  AK2_COHORT_ID=$COHORT_ID AK2_COHORT_RANK=$k AK2_COHORT_N=$NODES scripts/run.sh "$GATE" "$SPEC" > "$CDIR/rank-$k.run.log" 2>&1 &
  PIDS+=($!)
  RCS+=("")
  sleep 2
done
say "launched $NODES members; following rank 0 (each member's driver log: $CDIR/rank-<k>.run.log)"
tail -n +1 -f "$CDIR/rank-0.run.log" >&2 &
TAILPID=$!

# Monitor: fail fast. The first member whose run.sh exits non-zero ends the cohort: the others'
# instances are terminated, and their run.sh finalise as for any terminated instance.
LEFT=$NODES; FAILED_FAST=""
while [ "$LEFT" -gt 0 ]; do
  for k in "${!PIDS[@]}"; do
    [ -n "${RCS[$k]}" ] && continue
    kill -0 "${PIDS[$k]}" 2>/dev/null && continue
    wait "${PIDS[$k]}"; RCS[$k]=$?
    LEFT=$((LEFT - 1))
    say "rank $k: run.sh exited ${RCS[$k]} ($LEFT still running)"
    if [ "${RCS[$k]}" != 0 ] && [ -z "$FAILED_FAST" ] && [ "$LEFT" -gt 0 ]; then
      FAILED_FAST="rank $k exited ${RCS[$k]}"
      terminate_members "fail fast: $FAILED_FAST" "$k"
    fi
  done
  [ "$LEFT" -gt 0 ] && sleep 10
done
ENDED="members done${FAILED_FAST:+ (fail fast: $FAILED_FAST)}"
say "member exits: ${RCS[*]}"
exit 0
