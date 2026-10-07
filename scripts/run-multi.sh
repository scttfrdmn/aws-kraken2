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
#     spawn task run puts every instance; spawn adds no rules) lets members reach each other;
#   - after the members: the cohort prefix (rendezvous records, the emitter's outputs) is fetched
#     to results/<gate>/<cohort>/, unfinished multipart uploads under it are aborted from here
#     (the instance role cannot abort), its objects are tagged, cohort.json sums the members'
#     costs, and the global orphan check runs.
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

# The network precondition: spawn task run attaches the default VPC's default security group
# and adds no rules, so members can reach each other only if that group admits itself.
VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text) ||
  die "describe-vpcs failed in $REGION"
SG_JSON=$(aws ec2 describe-security-groups --region "$REGION" --filters Name=vpc-id,Values="$VPC" Name=group-name,Values=default \
  --query 'SecurityGroups[0]' --output json) || die "describe-security-groups failed"
SG=$(echo "$SG_JSON" | jq -r .GroupId)
SELF=$(echo "$SG_JSON" | jq --arg sg "$SG" '[.IpPermissions[] | select(.IpProtocol == "-1" or (.IpProtocol == "tcp" and .FromPort == 0 and .ToPort == 65535))
  | select(any(.UserIdGroupPairs[]?; .GroupId == $sg))] | length')
[ "${SELF:-0}" -gt 0 ] || die "the default security group $SG of $VPC ($REGION) has no self-referencing all-TCP rule; members could not reach each other"
say "network: default VPC $VPC, security group $SG admits itself (all traffic); members in $AZ"

COHORT_ID="$(date -u +%Y%m%d-%H%M%S)-$(git rev-parse --short=7 HEAD)-n$NODES"
RB_VAR="AK2_RESULTS_BUCKET_${REGION//-/_}"; RESULTS_BUCKET=${!RB_VAR:-}
[ -n "$RESULTS_BUCKET" ] || die "no results bucket for $REGION ($RB_VAR)"
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

PIDS=()
for ((k = 0; k < NODES; k++)); do
  AK2_COHORT_ID=$COHORT_ID AK2_COHORT_RANK=$k AK2_COHORT_N=$NODES scripts/run.sh "$GATE" "$SPEC" > "$CDIR/rank-$k.run.log" 2>&1 &
  PIDS+=($!)
  sleep 2
done
say "launched $NODES members; following rank 0 (each member's log: $CDIR/rank-<k>.run.log)"
tail -n +1 -f "$CDIR/rank-0.run.log" >&2 &
TAILPID=$!
RCS=()
for k in "${!PIDS[@]}"; do wait "${PIDS[$k]}"; RCS+=($?); done
kill "$TAILPID" 2>/dev/null; wait "$TAILPID" 2>/dev/null
STOP=$(now)
say "member exits: ${RCS[*]}"

# The cohort prefix: rendezvous records and the emitter's outputs.
FETCHED=no
for i in 1 2 3; do
  if aws s3 cp --only-show-errors --recursive --region "$REGION" "$CPREFIX/" "$CDIR/prefix/"; then FETCHED=yes; break; fi
  sleep $((20 * i))
done
# Unfinished multipart uploads under the cohort prefix (a failed emitter cannot abort: the
# instance role has no s3:AbortMultipartUpload) are aborted here, so no parts are left billed.
KP="${CPREFIX#s3://$RESULTS_BUCKET/}/"
UPS=$(aws s3api list-multipart-uploads --region "$REGION" --bucket "$RESULTS_BUCKET" --prefix "$KP" \
  --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null) || UPS="LISTFAIL"
ABORTED=0; ABORT_FAIL=0
if [ "$UPS" = LISTFAIL ]; then ABORT_FAIL=1; say "WARNING: list-multipart-uploads failed"
else
  while read -r key id; do
    [ -n "${key:-}" ] && [ "$key" != None ] || continue
    if aws s3api abort-multipart-upload --region "$REGION" --bucket "$RESULTS_BUCKET" --key "$key" --upload-id "$id"; then
      ABORTED=$((ABORTED + 1)); say "aborted unfinished upload of $key"
    else ABORT_FAIL=$((ABORT_FAIL + 1)); fi
  done <<< "$UPS"
fi
TAGLINE=$(scripts/tag-objects.sh "$CPREFIX/" 2>&1) || say "WARNING: tagging: $TAGLINE"

MEMBERS='[]'
for ((k = 0; k < NODES; k++)); do
  m="results/$GATE/$COHORT_ID-r$k/manifest.json"
  row=$(jq -c --argjson rc "${RCS[$k]}" --argjson k "$k" '{rank:$k, run_id, rc:$rc, instance_id:.launch.instance_id,
    type:.instance.type, az:.instance.az, final_state:.instance.final_state, cost_usd, exit_code:.task.exit_code,
    own_gone:.orphan_check.own_gone}' "$m" 2>/dev/null) || row=$(jq -nc --argjson rc "${RCS[$k]}" --argjson k "$k" '{rank:$k, rc:$rc, manifest:"missing"}')
  MEMBERS=$(jq -c --argjson r "$row" '. + [$r]' <<< "$MEMBERS")
done
scripts/orphans.sh > "$CDIR/orphans.txt" 2>&1; ORC=$?
jq -n --arg id "$COHORT_ID" --arg gate "$GATE" --arg spec "$SPEC" --arg sha "$(git rev-parse HEAD)" \
  --argjson n "$NODES" --arg type "$ITYPE" --arg az "$AZ" --arg region "$REGION" --arg prefix "$CPREFIX" \
  --arg vpc "$VPC" --arg sg "$SG" --arg start "$START" --arg stop "$STOP" --argjson members "$MEMBERS" \
  --arg fetched "$FETCHED" --argjson aborted "$ABORTED" --argjson abort_fail "$ABORT_FAIL" --argjson orc "$ORC" '{
    cohort_id:$id, gate:$gate, spec:$spec, commit:$sha, nodes:$n, instance_type:$type, az:$az, region:$region,
    prefix:$prefix, network:{vpc:$vpc, security_group:$sg, self_referencing:true}, start:$start, stop:$stop,
    members:$members,
    cost_usd:(if ($members | all(.cost_usd != null)) then ($members | map(.cost_usd) | add * 1e6 | round / 1e6) else null end),
    cost_basis:"sum of the members manifest cost_usd (on-demand truffle price x billed seconds, compute only)",
    prefix_fetched:($fetched == "yes"), multipart_aborted:$aborted, multipart_abort_failures:$abort_fail,
    orphans_rc:$orc}' > "$CDIR/cohort.json" || say "WARNING: could not write cohort.json"
say "cohort dir: $CDIR  cost \$$(jq -r .cost_usd "$CDIR/cohort.json")  orphans rc $ORC"
WORST=0; for rc in "${RCS[@]}"; do [ "$rc" -gt "$WORST" ] && WORST=$rc; done
[ "$ORC" = 0 ] || { say "ORPHANS: see $CDIR/orphans.txt"; [ "$WORST" = 0 ] && WORST=3; }
[ "$FETCHED" = yes ] || { say "WARNING: cohort prefix not fetched"; [ "$WORST" = 0 ] && WORST=4; }
exit "$WORST"
