#!/usr/bin/env bash
# make run GATE=<gate> SPEC=runs/<file>.json -- launch a checked-in TaskSpec through spawn with
# the hygiene law (CLAUDE.md Law 4) enforced, and record results/<gate>/<run-id>/. See docs/run.md.
#
# Deliberately not `set -e`: every step's status is checked by hand, so a failure reports why.
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel) || exit 2
cd "$ROOT" || exit 2
# shellcheck source=/dev/null
. scripts/pin.env
# shellcheck source=/dev/null
. scripts/ak2.env
export AWS_PROFILE

GATE=${1:-}
SPEC=${2:-}
die() { echo "make run: $*" >&2; exit 2; }
say() { echo "make run: $*" >&2; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

for t in jq spawn truffle aws curl git; do command -v "$t" >/dev/null || die "$t not on PATH"; done
[[ "$GATE" =~ ^[a-z0-9]+$ ]] || die "usage: make run GATE=<gate, e.g. g0a> SPEC=runs/<file>.json"
case "$SPEC" in runs/*.json) ;; *) die "SPEC must be a checked-in runs/*.json (got '$SPEC')" ;; esac
[ -f "$SPEC" ] || die "$SPEC: no such file"
git ls-files --error-unmatch "$SPEC" >/dev/null 2>&1 || die "$SPEC is not committed; commit it first"
git diff --quiet HEAD -- "$SPEC" || die "$SPEC has uncommitted changes; commit them first"
jq -e . "$SPEC" >/dev/null || die "$SPEC is not valid JSON"

q() { jq -r "$1" "$SPEC"; }

# ---- refuse specs that skip hygiene ----
TTL=$(q '.lifecycle.ttl // empty')
COST=$(q '.lifecycle.cost_limit // 0')
[ -n "$TTL" ] || die "spec has no lifecycle.ttl"
awk -v c="$COST" 'BEGIN{exit !(c+0 > 0)}' || die "spec has no positive lifecycle.cost_limit"
OC=$(q '.lifecycle.on_complete // "terminate"')
[ "$OC" = terminate ] || die "lifecycle.on_complete must be terminate (got $OC)"
[ -z "$(q '.container // empty')" ] ||
  die "spec.container is not supported: the preamble must run on the host. Run docker from the bash -c script."
[ -z "$(q '.results_prefix // empty')" ] || die "results_prefix is set by the harness; remove it from the spec"
jq -e '(.command|length)==3 and .command[0]=="bash" and .command[1]=="-c"' "$SPEC" >/dev/null ||
  die 'command must be ["bash","-c","<script>"] so the preamble can be prepended'
REGION=$(q '.env.AK2_REGION // empty')
[ -n "$REGION" ] || die "spec must declare env.AK2_REGION (the region to launch in)"
jq -e '.env | has("AK2_ACCESSIONS")' "$SPEC" >/dev/null ||
  die 'spec must declare env.AK2_ACCESSIONS (space-separated sample accessions; "" if none)'
ACCESSIONS=$(q '.env.AK2_ACCESSIONS')
DATASETS=$(q '.env.AK2_DATASETS // ""')

# ---- region of every s3:// the spec touches == the launch region ----
bucket_of() { local u=${1#s3://}; echo "${u%%/*}"; }
bucket_region() {
  curl -sI -m 10 "https://$1.s3.amazonaws.com/" | tr -d '\r' |
    awk -F': ' 'tolower($1)=="x-amz-bucket-region"{print $2}'
}
URIS=$( { for d in $DATASETS; do echo "$d"; done; q '.inputs[]?.source'; } | grep '^s3://' )
BUCKETS=$(for u in $URIS; do bucket_of "$u"; done | sort -u | tr '\n' ' ')
BUCKETS=${BUCKETS% }
DECLARED=$(q '.env.BUCKET_REGION // empty')
REGIONS_SEEN=""
for b in $BUCKETS; do
  r=$(bucket_region "$b")
  [ -n "$r" ] || die "cannot determine the region of bucket $b"
  say "bucket $b is in $r"
  REGIONS_SEEN="$REGIONS_SEEN $r"
done
DISTINCT=$(for r in $REGIONS_SEEN; do echo "$r"; done | sort -u)
if [ -n "$DECLARED" ]; then
  EXPECT=$DECLARED
  for r in $DISTINCT; do [ "$r" = "$DECLARED" ] || die "a bucket is in $r, spec declares BUCKET_REGION=$DECLARED"; done
else
  [ "$(echo "$DISTINCT" | grep -c .)" -le 1 ] || die "spec buckets span regions: $(echo $DISTINCT)"
  EXPECT=${DISTINCT:-$REGION}
fi
[ "$EXPECT" = "$REGION" ] || die "launch region $REGION != bucket region $EXPECT"

RB_VAR="AK2_RESULTS_BUCKET_${REGION//-/_}"
RESULTS_BUCKET=${!RB_VAR:-}
[ -n "$RESULTS_BUCKET" ] || die "no results bucket configured for $REGION ($RB_VAR in scripts/ak2.env)"
[ "$(bucket_region "$RESULTS_BUCKET")" = "$REGION" ] || die "results bucket $RESULTS_BUCKET is not in $REGION"

# ---- identities ----
SHA=$(git rev-parse HEAD)
DIRTY=false; git diff --quiet HEAD || DIRTY=true
RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$(git rev-parse --short=7 HEAD)"
TASK_ID="${AK2_TASK_PREFIX}${GATE}-${RUN_ID}"
PREFIX="s3://$RESULTS_BUCKET/$AK2_RESULTS_ROOT/$GATE/$RUN_ID"
RUN_DIR="results/$GATE/$RUN_ID"
mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
M="$RUN_DIR/manifest.json"
say "run $RUN_ID  task $TASK_ID  ->  $PREFIX"

# ---- resolve the spec: preamble, harness env, task id, results prefix ----
RESOLVED="$RUN_DIR/spec.resolved.json"
jq --rawfile pre scripts/preamble.sh --arg tid "$TASK_ID" --arg prefix "$PREFIX" \
   --arg expect "$EXPECT" --arg buckets "$BUCKETS" --arg run "$RUN_ID" --arg gate "$GATE" '
  .task_id = $tid
  | .results_prefix = ($prefix + "/spawn")
  | .lifecycle.on_complete = "terminate"
  | .command[2] = ($pre + "\n" + .command[2])
  | .env += {AK2_EXPECT_REGION: $expect, AK2_BUCKETS: $buckets, AK2_S3_PREFIX: $prefix,
             AK2_RUN_ID: $run, AK2_GATE: $gate}
  | if .outputs then .outputs |= map(.destination |= gsub("\\$\\{AK2_OUT\\}"; $prefix + "/out")) else . end
' "$SPEC" > "$RESOLVED" || die "could not resolve spec"
cp "$SPEC" "$RUN_DIR/spec.json"

# ---- datasets: ETag and version, recorded at launch ----
head_obj() {
  local u=${1#s3://} b k out
  b=${u%%/*}; k=${u#*/}
  out=$(aws s3api head-object --region "$REGION" --bucket "$b" --key "$k" 2>/dev/null ||
        aws s3api head-object --region "$REGION" --no-sign-request --bucket "$b" --key "$k" 2>/dev/null) ||
    { jq -n --arg uri "$1" '{uri:$uri, error:"head-object failed"}'; return; }
  echo "$out" | jq --arg uri "$1" '{uri:$uri, etag:(.ETag|gsub("\"";"")), version_id:(.VersionId // null),
    size:.ContentLength, last_modified:.LastModified}'
}
DS_JSON=$(for u in $URIS; do head_obj "$u"; done | jq -s .)
PAYER_JSON=$(for b in $BUCKETS; do
  p=$(aws s3api get-bucket-request-payment --bucket "$b" --query Payer --output text 2>/dev/null ||
      aws s3api get-bucket-request-payment --no-sign-request --bucket "$b" --query Payer --output text 2>/dev/null ||
      echo UNKNOWN)
  jq -n --arg b "$b" --arg p "$p" '{bucket:$b, payer:$p}'
done | jq -s .)

jq -n --arg gate "$GATE" --arg run "$RUN_ID" --arg task "$TASK_ID" --arg spec "$SPEC" \
  --arg spec_sha "$(shasum -a 256 "$SPEC" | cut -d' ' -f1)" --arg sha "$SHA" --argjson dirty "$DIRTY" \
  --arg urepo "$UPSTREAM_REPO" --arg upin "$UPSTREAM_PIN" --arg region "$REGION" \
  --arg spawn_v "$(spawn version 2>/dev/null | awk '/Version:/{print $2}')" \
  --arg truffle_v "$(truffle version 2>/dev/null | awk '/Version:/{print $2}')" \
  --arg ttl "$TTL" --argjson cost "$COST" --arg prefix "$PREFIX" --arg acc "$ACCESSIONS" \
  --argjson ds "$DS_JSON" --argjson payer "$PAYER_JSON" --arg created "$(now)" '{
    gate:$gate, run_id:$run, task_id:$task, spec:$spec, spec_sha256:$spec_sha,
    commit:$sha, tree_dirty:$dirty, upstream:{repo:$urepo, pin:$upin},
    tools:{spawn:$spawn_v, truffle:$truffle_v},
    region:$region, ttl:$ttl, cost_limit_usd:$cost, s3_prefix:$prefix,
    sample_accessions:($acc|split(" ")|map(select(.!=""))),
    datasets:$ds, bucket_payer:$payer, manifest_created_at:$created
  }' > "$M" || die "could not write $M"
mset() { local tmp; tmp=$(mktemp) && jq "$@" "$M" > "$tmp" && mv "$tmp" "$M"; }

# ---- plan, then launch ----
spawn task run --spec "$RESOLVED" --region "$REGION" --dry-run > "$RUN_DIR/spawn-plan.txt" 2>&1 ||
  { cat "$RUN_DIR/spawn-plan.txt" >&2; die "spawn dry-run failed"; }
say "plan: $(grep -E 'Instance|Max cost' "$RUN_DIR/spawn-plan.txt" | tr -s ' ' | paste -sd ';' -)"
# Pin the planned type for the real launch: spawn's sizing takes minutes per call (truffle
# search + live price per candidate), and the launch must be the box the plan priced.
PLANNED=$(awk '/^Instance:/{print $2; exit}' "$RUN_DIR/spawn-plan.txt")
[ -n "$PLANNED" ] || die "could not read the planned instance type from spawn-plan.txt"
TMP_SPEC=$(mktemp) && jq --arg t "$PLANNED" '.resources.instance_type = $t' "$RESOLVED" > "$TMP_SPEC" &&
  mv "$TMP_SPEC" "$RESOLVED" || die "could not pin instance type"
if [ "${DRY_RUN:-}" = 1 ]; then
  say "DRY_RUN=1: stopping before launch; removing $RUN_DIR"
  cat "$RUN_DIR/spawn-plan.txt" >&2
  rm -rf "$RUN_DIR"
  exit 0
fi
LAUNCH_AT=$(now)
spawn task run --spec "$RESOLVED" --region "$REGION" -o json > "$RUN_DIR/launch.json" 2> "$RUN_DIR/launch.err"
LRC=$?
if [ $LRC -ne 0 ] || ! jq -e .instance_id "$RUN_DIR/launch.json" >/dev/null 2>&1; then
  cat "$RUN_DIR/launch.err" >&2
  mset --arg t "$LAUNCH_AT" '.launch = {at:$t, error:"spawn task run failed"}'
  scripts/orphans.sh
  die "launch failed (rc=$LRC)"
fi
IID=$(jq -r .instance_id "$RUN_DIR/launch.json")
ITYPE=$(jq -r .instance_type "$RUN_DIR/launch.json")
LREGION=$(jq -r .region "$RUN_DIR/launch.json")
say "launched $IID ($ITYPE) in $LREGION"
[ "$LREGION" = "$REGION" ] || say "WARNING: spawn reports region $LREGION, expected $REGION (the preamble will abort)"
aws ec2 create-tags --region "$LREGION" --resources "$IID" --tags \
  "Key=ak2:project,Value=$AK2_TAG_PROJECT" "Key=ak2:gate,Value=$GATE" "Key=ak2:run-id,Value=$RUN_ID" ||
  say "WARNING: create-tags failed; orphans still finds it by spawn:task-id=$TASK_ID"

DESC=$(aws ec2 describe-instances --region "$LREGION" --instance-ids "$IID" --query 'Reservations[0].Instances[0]' --output json)
PRICE_ERR=$(mktemp)
PRICE=$(truffle find "$ITYPE" --regions "$LREGION" --show-price --skip-azs -o json 2> "$PRICE_ERR" | jq '.[0].on_demand_price // null')
mset --arg t "$LAUNCH_AT" --arg iid "$IID" --arg type "$ITYPE" --arg lr "$LREGION" \
  --argjson price "${PRICE:-null}" --arg perr "$(cat "$PRICE_ERR")" --argjson d "$DESC" '
  .launch = {requested_at:$t, instance_id:$iid, region:$lr}
  | .instance = {type:$type, count:1, ami:$d.ImageId, az:$d.Placement.AvailabilityZone,
                 launch_time:$d.LaunchTime, architecture:$d.Architecture,
                 lifecycle:($d.InstanceLifecycle // "on-demand")}
  | .truffle_price_usd_per_hour = $price | .truffle_price_note = $perr'
rm -f "$PRICE_ERR"

# ---- wait: tail the streamed log until the completion record lands or TTL+3m passes ----
ttl_s() { local t=$1 s=0 n; while [[ $t =~ ^([0-9]+)([hms])(.*)$ ]]; do n=${BASH_REMATCH[1]}
  case ${BASH_REMATCH[2]} in h) s=$((s+n*3600));; m) s=$((s+n*60));; s) s=$((s+n));; esac; t=${BASH_REMATCH[3]}; done; echo $s; }
DEADLINE=$(( $(date +%s) + $(ttl_s "$TTL") + 180 ))
COMPLETION="$PREFIX/spawn/$TASK_ID/completion.json"
mkdir -p "$RUN_DIR/log"
SHOWN=0
while :; do
  if aws s3 cp --only-show-errors "$PREFIX/log/run.log" "$RUN_DIR/log/run.log" 2>/dev/null; then
    LINES=$(wc -l < "$RUN_DIR/log/run.log")
    [ "$LINES" -gt "$SHOWN" ] && sed -n "$((SHOWN+1)),${LINES}p" "$RUN_DIR/log/run.log" | sed 's/^/  | /' >&2
    SHOWN=$LINES
  fi
  aws s3 cp --only-show-errors "$COMPLETION" "$RUN_DIR/completion.json" 2>/dev/null && break
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then say "no completion record by TTL+3m"; break; fi
  STATE=$(aws ec2 describe-instances --region "$LREGION" --instance-ids "$IID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
  case "$STATE" in shutting-down|terminated) sleep 10
    aws s3 cp --only-show-errors "$COMPLETION" "$RUN_DIR/completion.json" 2>/dev/null
    say "instance is $STATE"; break ;; esac
  sleep 15
done

# ---- wait for termination, fetch everything, finalise the manifest ----
for _ in $(seq 1 40); do
  STATE=$(aws ec2 describe-instances --region "$LREGION" --instance-ids "$IID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
  [ "$STATE" = terminated ] && break
  sleep 15
done
aws s3 cp --only-show-errors --recursive "$PREFIX/" "$RUN_DIR/" || say "WARNING: fetch of $PREFIX failed"
DESC=$(aws ec2 describe-instances --region "$LREGION" --instance-ids "$IID" --query 'Reservations[0].Instances[0]' --output json)
# StateTransitionReason carries the termination time: "User initiated (2026-10-05 18:40:12 GMT)".
END_AT=$(echo "$DESC" | jq -r '.StateTransitionReason' | sed -n 's/.*(\([0-9-]* [0-9:]*\) GMT).*/\1/p')
END_ISO=""; [ -n "$END_AT" ] && END_ISO="${END_AT/ /T}Z"
REC='null'; [ -s "$RUN_DIR/completion.json" ] && REC=$(cat "$RUN_DIR/completion.json")
PRE='null'; [ -s "$RUN_DIR/preflight.json" ] && PRE=$(cat "$RUN_DIR/preflight.json")
mset --arg state "$STATE" --arg end "$END_ISO" --argjson rec "$REC" --argjson pre "$PRE" --arg fin "$(now)" '
  .instance.final_state = $state
  | .instance.terminated_at = (if $end == "" then null else $end end)
  | .task = $rec | .preflight = $pre
  | .start = (.instance.launch_time) | .stop = .instance.terminated_at
  | .billed_seconds = (if .stop then ((.stop|sub("\\+00:00$";"Z")|fromdateiso8601) - (.start|sub("\\.[0-9]+";"")|sub("\\+00:00$";"Z")|fromdateiso8601)) else null end)
  | .cost_usd = (if .billed_seconds and .truffle_price_usd_per_hour then
       ((([.billed_seconds, 60]|max) * .truffle_price_usd_per_hour / 3600) * 1e6 | round / 1e6) else null end)
  | .cost_basis = "on-demand truffle price x (terminated_at - launch_time), 60 s minimum; compute only, excludes EBS and S3 requests"
  | .manifest_finalised_at = $fin'
EXIT=$(jq -r '.task.exit_code // 99' "$M")

# ---- gate-specific local post-processing, if checked in alongside the spec ----
POST="${SPEC%.json}.post.sh"
if [ -f "$POST" ]; then
  say "post: $POST $RUN_DIR"
  bash "$POST" "$RUN_DIR" || { say "post-processing failed"; [ "$EXIT" = 0 ] && EXIT=98; }
fi

say "run dir: $RUN_DIR  (task exit $EXIT, state $STATE, cost \$$(jq -r .cost_usd "$M"))"
scripts/orphans.sh; ORC=$?
[ "$ORC" -eq 0 ] || { say "ORPHANS FOUND"; exit 3; }
exit "$EXIT"
