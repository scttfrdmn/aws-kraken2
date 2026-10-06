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
. scripts/pin-identity.sh
# shellcheck source=/dev/null
. scripts/ak2.env
# shellcheck source=/dev/null
. scripts/lib/tags.sh
export AWS_PROFILE

GATE=${1:-}
SPEC=${2:-}
die() { echo "make run: $*" >&2; exit 2; }
say() { echo "make run: $*" >&2; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

for t in jq spawn truffle aws curl git python3; do command -v "$t" >/dev/null || die "$t not on PATH"; done
pin_identity || die "cannot establish the upstream pin identity (scripts/pin-identity.sh)"
[[ "$GATE" =~ ^[a-z0-9]+$ ]] || die "usage: make run GATE=<gate, e.g. g0a> SPEC=runs/<file>.json"
case "$SPEC" in runs/*.json) ;; *) die "SPEC must be a checked-in runs/*.json (got '$SPEC')" ;; esac
[ -f "$SPEC" ] || die "$SPEC: no such file"
git ls-files --error-unmatch "$SPEC" >/dev/null 2>&1 || die "$SPEC is not committed; commit it first"
# The manifest cites one commit for the harness, the spec and the decoders; they must be it.
DIRTY_PATHS=$(git status --porcelain -- scripts runs cmd internal upstream go.mod go.sum Makefile)
[ -z "$DIRTY_PATHS" ] || die "uncommitted changes in scripts/ runs/ cmd/ internal/ upstream/ go.mod go.sum Makefile; commit first:
$DIRTY_PATHS"
jq -e . "$SPEC" >/dev/null || die "$SPEC is not valid JSON"

q() { jq -r "$1" "$SPEC"; }
ttl_s() { local t=$1 s=0 n; while [[ $t =~ ^([0-9]+)([hms])(.*)$ ]]; do n=${BASH_REMATCH[1]}
  case ${BASH_REMATCH[2]} in h) s=$((s+n*3600));; m) s=$((s+n*60));; s) s=$((s+n));; esac; t=${BASH_REMATCH[3]}; done; echo $s; }

# ---- refuse specs that skip hygiene ----
TTL=$(q '.lifecycle.ttl // empty')
COST=$(q '.lifecycle.cost_limit // 0')
[ -n "$TTL" ] || die "spec has no lifecycle.ttl"
[[ "$TTL" =~ ^([0-9]+[hms])+$ ]] || die "lifecycle.ttl '$TTL' must match ^([0-9]+[hms])+\$ (e.g. 15m, 1h30m)"
TTL_S=$(ttl_s "$TTL")
[ "$TTL_S" -gt 0 ] || die "lifecycle.ttl '$TTL' is zero"
[ "$TTL_S" -le "$AK2_MAX_TTL_S" ] || die "lifecycle.ttl $TTL (${TTL_S}s) exceeds AK2_MAX_TTL_S=$AK2_MAX_TTL_S"
awk -v c="$COST" 'BEGIN{exit !(c+0 > 0)}' || die "spec has no positive lifecycle.cost_limit"
awk -v c="$COST" -v m="$AK2_MAX_COST_USD" 'BEGIN{exit !(c+0 <= m+0)}' ||
  die "lifecycle.cost_limit \$$COST exceeds AK2_MAX_COST_USD=\$$AK2_MAX_COST_USD"
OC=$(q '.lifecycle.on_complete // "terminate"')
[ "$OC" = terminate ] || die "lifecycle.on_complete must be terminate (got $OC)"
[ -z "$(q '.container // empty')" ] ||
  die "spec.container is not supported: the preamble must run on the host. Run docker from the bash -c script."
[ "$(q '.inputs // [] | length')" = 0 ] ||
  die "spec.inputs[] is not supported: spawn stages it before the preamble's region assert. Use ak2_stage in the script."
[ -z "$(q '.results_prefix // empty')" ] || die "results_prefix is set by the harness; remove it from the spec"
for k in ami volumes fsx_lustre_id efs_id efs_mount_point fsx_mount_point; do
  jq -e --arg k "$k" '.placement // {} | has($k)' "$SPEC" >/dev/null &&
    die "placement.$k is not supported: the AMI comes from spawn's auto-selection (recorded in the manifest), and data comes through ak2_stage"
done
case "$(q '.resources.purchase // "on_demand"')" in
  on_demand) ;;
  *) die "resources.purchase must be on_demand: spot is a later lever, and cost_usd assumes the on-demand price" ;;
esac
[ -z "$(q '.resources.fallback // empty')" ] || die "resources.fallback is only meaningful with spot; remove it"
jq -e '[.outputs[]?.destination | startswith("${AK2_OUT}/")] | all' "$SPEC" >/dev/null ||
  die 'every outputs[].destination must start with ${AK2_OUT}/'
jq -e '(.command|length)==3 and .command[0]=="bash" and .command[1]=="-c"' "$SPEC" >/dev/null ||
  die 'command must be ["bash","-c","<script>"] so the preamble can be prepended'

# env: an allow-list of keys. Anything else a spec needs is set in its script.
ALLOWED_ENV="AK2_REGION AK2_ACCESSIONS AK2_DATASETS AK2_ALLOW_NO_BUCKETS AK2_ALLOW_REQUESTER_PAYS BUCKET_REGION"
for k in $(q '.env // {} | keys[]'); do
  case " $ALLOWED_ENV " in *" $k "*) ;; *) die "spec env may not set $k (allowed keys: $ALLOWED_ENV)" ;; esac
done
for k in AK2_ALLOW_NO_BUCKETS AK2_ALLOW_REQUESTER_PAYS; do
  v=$(q ".env.$k // empty"); [ -z "$v" ] || [ "$v" = 1 ] || die "env.$k must be \"1\" or absent"
done
REGION=$(q '.env.AK2_REGION // empty')
[ -n "$REGION" ] || die "spec must declare env.AK2_REGION (the region to launch in)"
jq -e '.env | has("AK2_ACCESSIONS")' "$SPEC" >/dev/null ||
  die 'spec must declare env.AK2_ACCESSIONS (space-separated sample accessions; "" if none)'
ACCESSIONS=$(q '.env.AK2_ACCESSIONS')
DATASETS=$(q '.env.AK2_DATASETS // ""')
ALLOW_NO_BUCKETS=$(q '.env.AK2_ALLOW_NO_BUCKETS // empty')
ALLOW_RP=$(q '.env.AK2_ALLOW_REQUESTER_PAYS // empty')

# ---- the bucket allow-list: AK2_DATASETS declares every bucket the spec may touch ----
bucket_of() { local u=${1#s3://}; echo "${u%%/*}"; }
bucket_region() {
  curl -sI -m 10 "https://$1.s3.amazonaws.com/" | tr -d '\r' |
    awk -F': ' 'tolower($1)=="x-amz-bucket-region"{print $2}'
}
for d in $DATASETS; do [[ "$d" =~ ^s3://[a-z0-9][a-z0-9.-]*[a-z0-9](/.*)?$ ]] || die "AK2_DATASETS entry '$d' is not an s3:// URI"; done
BUCKETS=$(for d in $DATASETS; do bucket_of "$d"; done | sort -u | tr '\n' ' ')
BUCKETS=${BUCKETS% }
if [ -z "$BUCKETS" ] && [ "$ALLOW_NO_BUCKETS" != 1 ]; then
  die "spec declares no buckets (env.AK2_DATASETS); set env.AK2_ALLOW_NO_BUCKETS=\"1\" if it truly touches none"
fi
for u in $(q '.resources.s3_read_write // [] | .[]'); do
  b=$(bucket_of "$u"); case " $BUCKETS " in *" $b "*) ;; *) die "resources.s3_read_write bucket $b is not declared in AK2_DATASETS" ;; esac
done
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
ALLOWED_BUCKETS=$(printf '%s\n' $BUCKETS "$RESULTS_BUCKET" | sort -u | tr '\n' ' '); ALLOWED_BUCKETS=${ALLOWED_BUCKETS% }

# Static check of the script: every literal bucket must be allowed. Variables ($B) can't be
# resolved here; the preamble's aws PATH shim checks them at run time.
BODY=$(q '.command[2]')
LITERALS=$( { printf '%s\n' "$BODY" | grep -oE 's3://[A-Za-z0-9._-]+' | sed 's|^s3://||'
              printf '%s\n' "$BODY" | grep -oE -- "--(bucket|copy-source)[= ]+[\"']?/?[A-Za-z0-9._-]+" |
                sed -E "s/^--(bucket|copy-source)[= ]+[\"']?\/?//"; } | sort -u)
for b in $LITERALS; do
  case " $ALLOWED_BUCKETS " in *" $b "*) ;; *) die "the script names bucket '$b', which is not declared in AK2_DATASETS" ;; esac
done
# Law 4: `set +e`. Refuse anything in the body that turns errexit back on. A shell-aware
# tokeniser parses each set/shopt/eval/bash invocation (scripts/lib/errexit_check.py); the
# preamble's runtime check of $- is the backstop for what static parsing cannot see.
ERREXIT=$(printf '%s\n' "$BODY" | python3 scripts/lib/errexit_check.py)
case $? in
  0) ;;
  1) die "the script turns on errexit (Law 4 requires set +e):
$ERREXIT" ;;
  *) die "errexit check crashed (scripts/lib/errexit_check.py); fix the checker, the spec was not judged:
$ERREXIT" ;;
esac

# ---- Payer: refuse UNKNOWN; refuse Requester unless the spec opts in ----
PAYER_JSON=$(for b in $BUCKETS; do
  p=$(aws s3api get-bucket-request-payment --bucket "$b" --query Payer --output text 2>/dev/null ||
      aws s3api get-bucket-request-payment --no-sign-request --bucket "$b" --query Payer --output text 2>/dev/null ||
      echo UNKNOWN)
  jq -n --arg b "$b" --arg p "$p" '{bucket:$b, payer:$p}'
done | jq -s .)
for row in $(echo "$PAYER_JSON" | jq -r '.[] | "\(.bucket)=\(.payer)"'); do
  case "${row#*=}" in
    BucketOwner) ;;
    Requester) [ "$ALLOW_RP" = 1 ] || die "bucket ${row%%=*} is Requester-pays; set env.AK2_ALLOW_REQUESTER_PAYS=\"1\" to accept the charges" ;;
    *) die "cannot read the Payer of bucket ${row%%=*} (got '${row#*=}')" ;;
  esac
done

# ---- datasets: ETag and version, recorded at launch (prefix declarations end in /) ----
head_obj() {
  local u=${1#s3://} b k out
  b=${u%%/*}; k=${u#*/}
  [ "$k" = "$u" ] && k=""
  if [ -z "$k" ] || [[ "$k" == */ ]]; then
    jq -n --arg uri "$1" '{uri:$uri, kind:"prefix"}'; return 0
  fi
  out=$(aws s3api head-object --region "$REGION" --bucket "$b" --key "$k" 2>/dev/null ||
        aws s3api head-object --region "$REGION" --no-sign-request --bucket "$b" --key "$k" 2>/dev/null) || return 1
  echo "$out" | jq --arg uri "$1" '{uri:$uri, kind:"object", etag:(.ETag|gsub("\"";"")), version_id:(.VersionId // null),
    size:.ContentLength, last_modified:.LastModified}'
}
DS_JSON=$(for u in $DATASETS; do head_obj "$u" || { echo "HEADFAIL $u"; }; done)
if echo "$DS_JSON" | grep -q '^HEADFAIL'; then die "head-object failed: $(echo "$DS_JSON" | grep '^HEADFAIL' | cut -d' ' -f2 | tr '\n' ' ')"; fi
DS_JSON=$(echo "$DS_JSON" | jq -s .)

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
# The payload (preamble + spec body, exactly what used to be inlined) goes to the run prefix;
# command[2] becomes scripts/stub.sh, which asserts the region, fetches the payload, checks its
# sha256 and execs it. EC2's 16384-byte user-data cap cannot hold the payload inline.
RESOLVED="$RUN_DIR/spec.resolved.json"
# The spec spawn reads carries the presigned URL, so it lives outside results/ and is removed on
# any exit; $RESOLVED under results/ is only ever written redacted (by write_resolved).
LIVE_SPEC=$(mktemp "${TMPDIR:-/tmp}/ak2-spec.XXXXXX") || die "mktemp failed"
trap 'rm -f "$LIVE_SPEC"' EXIT
write_resolved() {
  jq '.env.AK2_PAYLOAD_URL = "<presigned GET of env.AK2_PAYLOAD_URI; redacted>"' "$LIVE_SPEC" > "$RESOLVED"
}
PAYLOAD="$RUN_DIR/payload.sh"
{ cat scripts/preamble.sh; printf '\n'; q '.command[2]'; } > "$PAYLOAD" || die "could not write $PAYLOAD"
PAYLOAD_BYTES=$(wc -c < "$PAYLOAD" | tr -d ' ')
# The stub execs it as one `bash -c` argument; Linux caps a single argument at 128 KiB.
[ "$PAYLOAD_BYTES" -lt 122880 ] || { rm -rf "$RUN_DIR"; die "payload is $PAYLOAD_BYTES bytes; the limit is 120 KiB (one bash -c argument)"; }
PAYLOAD_SHA=$(shasum -a 256 "$PAYLOAD" | cut -d' ' -f1)
PAYLOAD_URI="$PREFIX/payload.sh"
# A presigned GET for this one object, so the instance needs no extra IAM grant on the (shared)
# results bucket. Signing is local; the object is uploaded just before launch.
PAYLOAD_URL=$(aws s3 presign "$PAYLOAD_URI" --region "$REGION" --expires-in $((TTL_S + 3600))) ||
  die "could not presign $PAYLOAD_URI"
jq --rawfile stub scripts/stub.sh --arg tid "$TASK_ID" --arg prefix "$PREFIX" \
   --arg expect "$EXPECT" --arg buckets "$BUCKETS" --arg allowed "$ALLOWED_BUCKETS" \
   --arg run "$RUN_ID" --arg gate "$GATE" --arg puri "$PAYLOAD_URI" --arg psha "$PAYLOAD_SHA" \
   --arg purl "$PAYLOAD_URL" '
  .task_id = $tid
  | .results_prefix = ($prefix + "/spawn")
  | .lifecycle.on_complete = "terminate"
  | .command[2] = $stub
  | .env += {AK2_EXPECT_REGION: $expect, AK2_BUCKETS: $buckets, AK2_ALLOWED_BUCKETS: $allowed,
             AK2_S3_PREFIX: $prefix, AK2_RUN_ID: $run, AK2_GATE: $gate,
             AK2_PAYLOAD_URI: $puri, AK2_PAYLOAD_URL: $purl, AK2_PAYLOAD_SHA256: $psha}
  | if .outputs then .outputs |= map(.destination |= gsub("\\$\\{AK2_OUT\\}"; $prefix + "/out")) else . end
' "$SPEC" > "$LIVE_SPEC" && write_resolved || die "could not resolve spec"
cp "$SPEC" "$RUN_DIR/spec.json"

# ---- user-data size, measured with the pinned spawn version's own builders (scripts/udsize) ----
UDSIZE_BIN="$ROOT/bin/udsize"
SPAWN_V=$(spawn version 2>/dev/null | awk '/Version:/{print $2}')
UDSIZE_V=$(awk '$1=="require" && $2=="github.com/spore-host/spawn"{sub(/^v/,"",$3); print $3}' scripts/udsize/go.mod)
if [ -z "$SPAWN_V" ] || [ "$SPAWN_V" != "$UDSIZE_V" ]; then
  rm -rf "$RUN_DIR"
  die "spawn on PATH is ${SPAWN_V:-unknown} but scripts/udsize measures user data with spawn $UDSIZE_V.
Bump github.com/spore-host/spawn in scripts/udsize/go.mod to v$SPAWN_V (then go mod tidy there) so the size check models the spawn that launches."
fi
go build -C scripts/udsize -o "$UDSIZE_BIN" . || { rm -rf "$RUN_DIR"; die "could not build scripts/udsize"; }
UD=$("$UDSIZE_BIN" -region "$REGION" -account "$AK2_ACCOUNT" "$LIVE_SPEC") || { rm -rf "$RUN_DIR"; die "udsize failed on the resolved spec"; }
UD_GZ=$(echo "$UD" | jq -r .gzip_bytes)
UD_MAX=$((16384 - AK2_USERDATA_MARGIN))
say "user data: $UD_GZ of 16384 bytes after base64 decoding (refuse above $UD_MAX)"
if [ "$UD_GZ" -gt "$UD_MAX" ]; then
  rm -rf "$RUN_DIR"
  die "user data would be $UD_GZ bytes; EC2's cap is 16384 and the harness keeps a $AK2_USERDATA_MARGIN-byte margin"
fi

jq -n --arg gate "$GATE" --arg run "$RUN_ID" --arg task "$TASK_ID" --arg spec "$SPEC" \
  --arg spec_sha "$(shasum -a 256 "$SPEC" | cut -d' ' -f1)" --arg sha "$SHA" --argjson dirty "$DIRTY" \
  --arg urepo "$UPSTREAM_REPO" --arg upin "$UPSTREAM_SHA" --arg udesc "$UPSTREAM_DESCRIBE" --arg region "$REGION" \
  --arg spawn_v "$(spawn version 2>/dev/null | awk '/Version:/{print $2}')" \
  --arg truffle_v "$(truffle version 2>/dev/null | awk '/Version:/{print $2}')" \
  --arg ttl "$TTL" --argjson cost "$COST" --arg prefix "$PREFIX" --arg acc "$ACCESSIONS" \
  --arg allowed "$ALLOWED_BUCKETS" --arg puri "$PAYLOAD_URI" --arg psha "$PAYLOAD_SHA" \
  --arg pbytes "$(wc -c < "$PAYLOAD" | tr -d ' ')" --argjson ud "$UD" \
  --argjson ds "$DS_JSON" --argjson payer "$PAYER_JSON" --arg created "$(now)" '{
    gate:$gate, run_id:$run, task_id:$task, spec:$spec, spec_sha256:$spec_sha,
    commit:$sha, tree_dirty:$dirty, upstream:{repo:$urepo, pin:$upin, sha:$upin, describe:$udesc},
    tools:{spawn:$spawn_v, truffle:$truffle_v},
    region:$region, ttl:$ttl, cost_limit_usd:$cost, s3_prefix:$prefix,
    sample_accessions:($acc|split(" ")|map(select(.!=""))),
    allowed_buckets:($allowed|split(" ")),
    payload:{uri:$puri, sha256:$psha, bytes:($pbytes|tonumber)}, user_data:$ud,
    datasets:$ds, bucket_payer:$payer, manifest_created_at:$created
  }' > "$M" || die "could not write $M"
# After launch a manifest write failure must not abandon the instance: record it, carry on,
# and exit non-zero at the end.
LATE_FAIL=0
mset() {
  local tmp
  if tmp=$(mktemp) && jq "$@" "$M" > "$tmp" && mv "$tmp" "$M"; then return 0; fi
  say "ERROR: manifest update failed: jq $*"; LATE_FAIL=1; return 1
}

# ---- plan, then launch ----
spawn task run --spec "$LIVE_SPEC" --region "$REGION" --dry-run > "$RUN_DIR/spawn-plan.txt" 2>&1 ||
  { cat "$RUN_DIR/spawn-plan.txt" >&2; die "spawn dry-run failed"; }
say "plan: $(grep -E 'Instance|Max cost' "$RUN_DIR/spawn-plan.txt" | tr -s ' ' | paste -sd ';' -)"
# Pin the planned type for the real launch: spawn's sizing takes minutes per call (truffle
# search + live price per candidate), and the launch must be the box the plan priced.
PLANNED=$(awk '/^Instance:/{print $2; exit}' "$RUN_DIR/spawn-plan.txt")
[ -n "$PLANNED" ] || die "could not read the planned instance type from spawn-plan.txt"
TMP_SPEC=$(mktemp) && jq --arg t "$PLANNED" '.resources.instance_type = $t' "$LIVE_SPEC" > "$TMP_SPEC" &&
  mv "$TMP_SPEC" "$LIVE_SPEC" && write_resolved || die "could not pin instance type"
if [ "${DRY_RUN:-}" = 1 ]; then
  say "DRY_RUN=1: stopping before launch; removing $RUN_DIR"
  cat "$RUN_DIR/spawn-plan.txt" >&2
  rm -rf "$RUN_DIR"
  exit 0
fi
aws s3 cp --only-show-errors --region "$REGION" "$PAYLOAD" "$PAYLOAD_URI" || die "could not upload the payload to $PAYLOAD_URI"
GOT=$(aws s3 cp --only-show-errors --region "$REGION" "$PAYLOAD_URI" - | shasum -a 256 | cut -d' ' -f1)
[ "$GOT" = "$PAYLOAD_SHA" ] || die "uploaded payload sha256 $GOT != $PAYLOAD_SHA"
ak2_tag_object "$RESULTS_BUCKET" "${PAYLOAD_URI#s3://$RESULTS_BUCKET/}" payload >/dev/null ||
  die "could not tag the payload object"
LAUNCH_AT=$(now)
spawn task run --spec "$LIVE_SPEC" --region "$REGION" -o json > "$RUN_DIR/launch.json" 2> "$RUN_DIR/launch.err"
LRC=$?
rm -f "$LIVE_SPEC"
if [ $LRC -ne 0 ] || ! jq -e .instance_id "$RUN_DIR/launch.json" >/dev/null 2>&1; then
  cat "$RUN_DIR/launch.err" >&2
  mset --arg t "$LAUNCH_AT" '.launch = {at:$t, error:"spawn task run failed"}'
  scripts/orphans.sh --own "$TASK_ID"
  die "launch failed (rc=$LRC)"
fi
IID=$(jq -r .instance_id "$RUN_DIR/launch.json")
ITYPE=$(jq -r .instance_type "$RUN_DIR/launch.json")
LREGION=$(jq -r .region "$RUN_DIR/launch.json")
say "launched $IID ($ITYPE) in $LREGION"
aws ec2 create-tags --region "$LREGION" --resources "$IID" --tags \
  "Key=ak2:project,Value=$AK2_TAG_PROJECT" "Key=ak2:gate,Value=$GATE" "Key=ak2:run-id,Value=$RUN_ID" ||
  say "WARNING: create-tags failed; orphans still finds it by spawn:task-id=$TASK_ID"
if [ "$LREGION" != "$REGION" ]; then
  say "spawn launched in $LREGION, not the requested $REGION: terminating $IID"
  aws ec2 terminate-instances --region "$LREGION" --instance-ids "$IID" >/dev/null
  aws ec2 wait instance-terminated --region "$LREGION" --instance-ids "$IID"
  mset --arg t "$LAUNCH_AT" --arg iid "$IID" --arg lr "$LREGION" \
    '.launch = {requested_at:$t, instance_id:$iid, region:$lr, error:"launched in the wrong region; terminated by run.sh"}'
  scripts/orphans.sh --own "$TASK_ID" "$IID"
  die "launch region $LREGION != $REGION"
fi

DESC=$(aws ec2 describe-instances --region "$LREGION" --instance-ids "$IID" --query 'Reservations[0].Instances[0]' --output json)
PRICE_ERR=$(mktemp)
PRICE=$(truffle find "$ITYPE" --regions "$LREGION" --show-price --skip-azs -o json 2> "$PRICE_ERR" | jq '.[0].on_demand_price // null')
mset --arg t "$LAUNCH_AT" --arg iid "$IID" --arg type "$ITYPE" --arg lr "$LREGION" \
  --argjson price "${PRICE:-null}" --arg perr "$(cat "$PRICE_ERR")" --argjson d "${DESC:-null}" '
  .launch = {requested_at:$t, instance_id:$iid, region:$lr}
  | .instance = {type:$type, count:1, ami:$d.ImageId, az:$d.Placement.AvailabilityZone,
                 launch_time:$d.LaunchTime, architecture:$d.Architecture,
                 lifecycle:($d.InstanceLifecycle // "on-demand")}
  | .truffle_price_usd_per_hour = $price | .truffle_price_note = $perr'
rm -f "$PRICE_ERR"

# ---- wait: tail the streamed log until the completion record lands or TTL+3m passes ----
DEADLINE=$(( $(date +%s) + TTL_S + 180 ))
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
# The instance role has PutObject but not PutObjectTagging, so what the preamble and spawn wrote
# under the run prefix is tagged here, after the run.
TAGLINE=$(scripts/tag-objects.sh "$PREFIX/" 2>&1); TAG_OK=$?
if [ "$TAG_OK" = 0 ]; then say "$TAGLINE"; else say "WARNING: object tagging failed: $TAGLINE"; fi
DESC=$(aws ec2 describe-instances --region "$LREGION" --instance-ids "$IID" --query 'Reservations[0].Instances[0]' --output json)
# StateTransitionReason carries the termination time: "User initiated (2026-10-05 18:40:12 GMT)".
END_AT=$(echo "$DESC" | jq -r '.StateTransitionReason' | sed -n 's/.*(\([0-9-]* [0-9:]*\) GMT).*/\1/p')
END_ISO=""; [ -n "$END_AT" ] && END_ISO="${END_AT/ /T}Z"
REC='null'; [ -s "$RUN_DIR/completion.json" ] && REC=$(cat "$RUN_DIR/completion.json")
PRE='null'; [ -s "$RUN_DIR/preflight.json" ] && PRE=$(cat "$RUN_DIR/preflight.json")

# Per-phase timings from the ak2_phase markers in the streamed log.
mkdir -p "$RUN_DIR/tables"
PHASES='[]'
if [ -s "$RUN_DIR/log/run.log" ]; then
  # The last phase has no successor if the run was killed hard: emit it with empty seconds.
  awk -F'\t' 'BEGIN{print "phase\tstart\tseconds\tcold"}
    $1=="ak2-phase"{n++; name[n]=$4; at[n]=$2; ep[n]=$3; cold[n]=($5==""?"no":$5)}
    END{for(i=1;i<=n;i++){ if(name[i]=="end") continue
          if(i<n) printf "%s\t%s\t%d\t%s\n", name[i], at[i], ep[i+1]-ep[i], cold[i]
          else printf "%s\t%s\t\t%s\n", name[i], at[i], cold[i] }}' "$RUN_DIR/log/run.log" > "$RUN_DIR/tables/phases.tsv"
  PHASES=$(awk -F'\t' 'NR>1' "$RUN_DIR/tables/phases.tsv" | jq -R -s 'split("\n") | map(select(. != "") | split("\t")
    | {phase:.[0], start:.[1], seconds:(.[2] | tonumber? // null), cold:(.[3] == "yes")})') || PHASES='null'
fi
# Request counts the spec recorded with ak2_req (out/requests.tsv).
REQS='null'
if [ -s "$RUN_DIR/out/requests.tsv" ]; then
  cp "$RUN_DIR/out/requests.tsv" "$RUN_DIR/tables/requests.tsv"
  REQS=$(awk -F'\t' 'NR>1' "$RUN_DIR/out/requests.tsv" | jq -R -s 'split("\n") | map(select(. != "") | split("\t")
      | {phase:.[0], op:.[1], count:(.[2] | tonumber? // null), bucket:.[3]})
    | {total:(map(.count // 0)|add // 0), unparsed_rows:(map(select(.count == null))|length),
       by_op:(group_by(.op) | map({key:.[0].op, value:(map(.count // 0)|add)}) | from_entries), rows:.}') || REQS='null'
fi

mset --argjson ok "$([ "$TAG_OK" = 0 ] && echo true || echo false)" --arg line "$TAGLINE" \
  '.object_tags = {ok: $ok, line: $line}' || say "WARNING: could not record object tags in the manifest"
# Derived tables first and separately: a bad table must never block finalisation below.
mset --argjson phases "${PHASES:-null}" --argjson reqs "${REQS:-null}" '.phases = $phases | .requests = $reqs' ||
  say "WARNING: could not record phases/requests in the manifest"
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
EXIT=$(jq -r '.task.exit_code // 99' "$M" 2>/dev/null || echo 99)
[ "$REQS" = null ] && say "WARNING: the spec recorded no request counts (ak2_req)"

# ---- spec-specific local post-processing: scripts/post/<spec name>.sh, if it exists ----
POST="scripts/post/$(basename "$SPEC" .json).sh"
if [ -f "$POST" ]; then
  say "post: $POST $RUN_DIR"
  bash "$POST" "$RUN_DIR" || { say "post-processing failed"; [ "$EXIT" = 0 ] && EXIT=98; }
fi
[ "$LATE_FAIL" = 0 ] || { say "manifest updates failed (see above)"; [ "$EXIT" = 0 ] && EXIT=4; }

say "run dir: $RUN_DIR  (task exit $EXIT, state $STATE, cost \$$(jq -r .cost_usd "$M"))"
# Scoped to this run: concurrent runs' instances are listed, not counted (make orphans is the
# global, strict check, for when nothing is in flight).
AK2_ORPHANS_JSON="$RUN_DIR/orphan_check.json" scripts/orphans.sh --own "$TASK_ID" "$IID" 2>&1 | tee "$RUN_DIR/orphans.txt"
ORC=${PIPESTATUS[0]}
# orphans.sh's exit code is authoritative: the summary can only confirm own_gone, never assert it.
if [ -s "$RUN_DIR/orphan_check.json" ] &&
   OC=$(jq -e -c --argjson rc "$ORC" 'if type == "object" and .mode == "own" then . + {rc: $rc, own_gone: (.own_gone == true and $rc == 0)} else null end' "$RUN_DIR/orphan_check.json" 2>/dev/null); then
  :
else
  OC=$(jq -n -c --argjson rc "$ORC" '{mode:"own", rc:$rc, own_gone:false, error:"orphans.sh wrote no usable summary"}')
fi
rm -f "$RUN_DIR/orphan_check.json"
mset --argjson oc "$OC" '.orphan_check = $oc' || say "WARNING: could not record the orphan check in the manifest"
[ "$ORC" -eq 0 ] || { say "THIS RUN'S INSTANCE IS STILL ALIVE (or a region could not be checked)"; exit 3; }
exit "$EXIT"
