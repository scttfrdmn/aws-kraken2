# aws-kraken2 hygiene preamble (Law 4). scripts/run.sh prepends this to every spec's
# `bash -c` script; a spec cannot opt out. It runs on the instance, as the instance user,
# before any line of the spec. Inputs arrive as exported env from the spec's `env` block,
# which run.sh fills in: AK2_EXPECT_REGION, AK2_BUCKETS, AK2_S3_PREFIX, AK2_RUN_ID, AK2_GATE.
#
# Contract for the spec body that follows:
#   - `set +e` is in force; check statuses by hand.
#   - stdout/stderr go to $AK2_LOG, which is pushed to S3 every $AK2_PUSH_EVERY seconds
#     and once more on exit. Do not replace the EXIT trap.
#   - ak2_push FILE [NAME] streams a result file to $AK2_S3_PREFIX/out/NAME now.
#   - ak2_drop_caches must precede every cold rung.
AK2_INHERITED_FLAGS="$-"
set +e
AK2_LOG=/tmp/ak2-run.log
AK2_PUSH_EVERY="${AK2_PUSH_EVERY:-5}"
: > "$AK2_LOG"
exec > >(tee -a "$AK2_LOG") 2>&1
AK2_TEE_PID=$!
ak2_say() { printf 'ak2: [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
ak2_say "inherited \$-=$AK2_INHERITED_FLAGS"
ak2_say "after set +e \$-=$-"
ak2_say "gate=$AK2_GATE run=$AK2_RUN_ID"

# ---- region assert: IMDSv2 region must equal every bucket's region, before any data I/O ----
AK2_TOK=$(curl -sf -X PUT -m 5 http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 3600')
ak2_md() { curl -sf -m 5 -H "X-aws-ec2-metadata-token: $AK2_TOK" "http://169.254.169.254/latest/meta-data/$1"; }
AK2_REGION=$(ak2_md placement/region)
AK2_AZ=$(ak2_md placement/availability-zone)
AK2_INSTANCE_ID=$(ak2_md instance-id)
AK2_INSTANCE_TYPE=$(ak2_md instance-type)
AK2_AMI=$(ak2_md ami-id)
ak2_say "imds region=$AK2_REGION az=$AK2_AZ instance=$AK2_INSTANCE_ID type=$AK2_INSTANCE_TYPE ami=$AK2_AMI"
export AWS_DEFAULT_REGION="$AK2_REGION" AWS_REGION="$AK2_REGION"

# Close our end of the tee pipe and give tee up to 10 s to drain (a background job left
# by the spec body can hold the pipe open, so never block on it).
ak2_close_log() {
  exec >&- 2>&-
  local i; for i in $(seq 1 20); do kill -0 "$AK2_TEE_PID" 2>/dev/null || break; sleep 0.5; done
}
ak2_put() { aws s3 cp --only-show-errors "$1" "$AK2_S3_PREFIX/$2" >/dev/null 2>&1; }
ak2_fatal() {
  ak2_say "FATAL: $*"
  ak2_close_log
  ak2_put "$AK2_LOG" log/run.log
  exit 97
}
[ -n "$AK2_REGION" ] || ak2_fatal "IMDSv2 returned no region"
[ "$AK2_REGION" = "$AK2_EXPECT_REGION" ] ||
  ak2_fatal "instance region $AK2_REGION != expected $AK2_EXPECT_REGION (cross-region placement)"

AK2_PAYERS=""
for AK2_B in $AK2_BUCKETS; do
  AK2_BR=$(curl -sI -m 10 "https://$AK2_B.s3.amazonaws.com/" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-amz-bucket-region"{print $2}')
  ak2_say "bucket $AK2_B region=$AK2_BR"
  [ "$AK2_BR" = "$AK2_REGION" ] || ak2_fatal "bucket $AK2_B is in '${AK2_BR:-unknown}', instance in $AK2_REGION"
  AK2_P=$(aws s3api get-bucket-request-payment --bucket "$AK2_B" --query Payer --output text 2>/dev/null ||
          aws s3api get-bucket-request-payment --no-sign-request --bucket "$AK2_B" --query Payer --output text 2>/dev/null)
  ak2_say "bucket $AK2_B payer=${AK2_P:-UNKNOWN}"
  AK2_PAYERS="$AK2_PAYERS{\"bucket\":\"$AK2_B\",\"region\":\"$AK2_BR\",\"payer\":\"${AK2_P:-UNKNOWN}\"},"
done
ak2_say "region assert passed"

printf '{"inherited_flags":"%s","flags_after_set":"%s","region":"%s","az":"%s","instance_id":"%s","instance_type":"%s","ami":"%s","buckets":[%s],"preflight_at":"%s"}\n' \
  "$AK2_INHERITED_FLAGS" "$-" "$AK2_REGION" "$AK2_AZ" "$AK2_INSTANCE_ID" "$AK2_INSTANCE_TYPE" "$AK2_AMI" \
  "${AK2_PAYERS%,}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /tmp/ak2-preflight.json
ak2_put /tmp/ak2-preflight.json preflight.json || ak2_say "WARN: preflight push failed"

# ---- log streaming ----
( while sleep "$AK2_PUSH_EVERY"; do ak2_put "$AK2_LOG" log/run.log; done ) >/dev/null 2>&1 &
AK2_PUSHER=$!
ak2_finish() {
  local rc=$1
  ak2_say "spec body exit rc=$rc"
  kill "$AK2_PUSHER" 2>/dev/null
  ak2_close_log
  ak2_put "$AK2_LOG" log/run.log
  exit "$rc"
}
trap 'ak2_finish $?' EXIT

ak2_push() {
  local f=$1 n=${2:-$(basename "$1")}
  if aws s3 cp --only-show-errors "$f" "$AK2_S3_PREFIX/out/$n"; then ak2_say "pushed out/$n"; else ak2_say "WARN: push of $f failed"; return 1; fi
}
ak2_drop_caches() { sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && ak2_say "drop_caches done"; }
ak2_say "preamble done; spec body starts"
# ---- spec body follows ----
