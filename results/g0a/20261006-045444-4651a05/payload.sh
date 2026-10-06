# aws-kraken2 hygiene preamble (Law 4). scripts/run.sh prepends this to every spec's script
# to form the payload, which scripts/stub.sh fetches (after its own region assert), verifies
# by sha256 and execs; a spec cannot opt out. It runs on the instance, as the instance user,
# before any line of the spec. run.sh injects (and refuses specs that set) AK2_EXPECT_REGION,
# AK2_BUCKETS, AK2_ALLOWED_BUCKETS, AK2_S3_PREFIX, AK2_RUN_ID, AK2_GATE.
#
# Contract for the spec body that follows (docs/run.md):
#   - `set +e` is in force (run.sh refuses a body that turns -e back on, and $- is checked at
#     body start and at exit); check statuses by hand.
#   - stdout/stderr go to $AK2_LOG, pushed to S3 every 5 s and once more on exit or on
#     TERM/HUP/INT/PIPE. Do not replace the EXIT or signal traps.
#   - `aws` on PATH is a shim that refuses s3/s3api calls naming a bucket outside
#     $AK2_ALLOWED_BUCKETS (declared buckets plus the results bucket), then execs the real CLI.
#     It covers anything that finds `aws` via PATH; not curl, SDKs, or `sudo aws`.
#   - ak2_stage SRC DST     stage an input (replaces spawn inputs[]; runs after the region assert)
#   - ak2_push FILE [NAME]  stream a result file to $AK2_S3_PREFIX/out/NAME now
#   - ak2_phase NAME        mark the start of a phase (run.sh derives phases.tsv)
#   - ak2_req OP N [BUCKET] record N S3 requests of OP in the current phase (requests.tsv)
#   - ak2_drop_caches       required before every cold rung; marks the next phase cold.
#                           Ends the run with 95 if caches cannot be dropped.
# Helper state (current phase, cold marker, errors, finish lock) lives in files under
# $AK2_STATE, so helpers called from subshells still count and the body cannot clobber it by
# assigning a variable.
AK2_INHERITED_FLAGS="$-"
set +e
AK2_LOG=/tmp/ak2-run.log
AK2_REQS=/tmp/ak2-requests.tsv
AK2_FIFO=/tmp/ak2-log.fifo
AK2_BIN=/tmp/ak2-bin
AK2_STATE=/tmp/ak2-state
AK2_PUSH_EVERY=5
AK2_MAIN_PID=$BASHPID
readonly AK2_EXPECT_REGION AK2_BUCKETS AK2_ALLOWED_BUCKETS AK2_S3_PREFIX AK2_RUN_ID AK2_GATE \
  AK2_PUSH_EVERY AK2_LOG AK2_REQS AK2_FIFO AK2_BIN AK2_STATE AK2_MAIN_PID AK2_INHERITED_FLAGS
AK2_REAL_AWS=$(command -v aws)
readonly AK2_REAL_AWS
: > "$AK2_LOG"
printf 'phase\top\tcount\tbucket\n' > "$AK2_REQS"
rm -rf "$AK2_STATE"; mkdir -p "$AK2_STATE"
: > "$AK2_STATE/errors"          # one line per helper error: <exit code>\t<message>
echo preamble > "$AK2_STATE/phase"

# ---- the log tee: a FIFO, not a process substitution (bash's bare `wait` waits for the last
# process substitution), immune to TERM/HUP so the final lines survive a process-group kill,
# and verified before anything relies on it ----
ak2_boot_fail() {
  local m; m=$(printf 'ak2: [%s] FATAL: %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*")
  echo "$m" >> "$AK2_LOG"; echo "$m" >&2
  "$AK2_REAL_AWS" s3 cp --only-show-errors "$AK2_LOG" "$AK2_S3_PREFIX/log/run.log" >/dev/null 2>&1
  exit 97
}
rm -f "$AK2_FIFO"
mkfifo "$AK2_FIFO" || ak2_boot_fail "mkfifo $AK2_FIFO failed"
( trap '' TERM HUP; exec tee -a "$AK2_LOG" ) < "$AK2_FIFO" &
AK2_TEE_PID=$!
readonly AK2_TEE_PID
disown "$AK2_TEE_PID"
exec 3<>"$AK2_FIFO" || ak2_boot_fail "cannot open $AK2_FIFO"
echo "ak2: log tee up" >&3
AK2_I=0
until grep -q '^ak2: log tee up$' "$AK2_LOG" 2>/dev/null; do
  AK2_I=$((AK2_I + 1))
  if [ "$AK2_I" -gt 50 ] || ! kill -0 "$AK2_TEE_PID" 2>/dev/null; then
    # A tee that is alive but stuck ignores TERM by design, so KILL it.
    kill -KILL "$AK2_TEE_PID" 2>/dev/null; exec 3>&-
    ak2_boot_fail "log tee did not start within 5 s"
  fi
  sleep 0.1
done
exec > "$AK2_FIFO" 2>&1 3>&-

ak2_say() { printf 'ak2: [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
# Record a helper error. Counted at exit even if the helper ran in a subshell.
ak2_err() {
  local m=${2//$'\t'/\\t}; m=${m//$'\n'/\\n}   # one error per line, whatever the caller passed
  printf '%s\t%s\n' "$1" "$m" >> "$AK2_STATE/errors"; ak2_say "ERROR: $m"
}
ak2_phase() {
  local name=${1:-} cold=no
  if [ -z "$name" ] || [[ "$name" == *[[:space:]]* ]]; then
    ak2_err 96 "ak2_phase '$name': name must be a non-empty word (the run will exit 96)"; return 2
  fi
  [ -e "$AK2_STATE/cold_next" ] && { cold=yes; rm -f "$AK2_STATE/cold_next"; }
  echo "$name" > "$AK2_STATE/phase"
  printf 'ak2-phase\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" "$name" "$cold"
}
ak2_req() {
  local op=${1:-} n=${2:-} b=${3:-}
  if [ -z "$op" ] || [[ "$op" == *[[:space:]]* ]] || ! [[ "$n" =~ ^[0-9]+$ ]] ||
     { [ -n "$b" ] && ! [[ "$b" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; }; then
    ak2_err 96 "ak2_req '$op' '$n' '$b': op must be a non-empty word, count a non-negative integer, bucket empty or a valid bucket name (the run will exit 96)"
    return 2
  fi
  printf '%s\t%s\t%s\t%s\n' "$(cat "$AK2_STATE/phase" 2>/dev/null)" "$op" "$n" "$b" >> "$AK2_REQS"
}
ak2_phase preamble
ak2_say "inherited \$-=$AK2_INHERITED_FLAGS (stub, as spawn started it: \$-=${AK2_STUB_FLAGS:-none})"
ak2_say "after set +e \$-=$-"
ak2_say "gate=$AK2_GATE run=$AK2_RUN_ID"

# ---- aws guard: a PATH shim, so env/xargs/timeout/sh/python subprocesses are covered too ----
[ -n "$AK2_REAL_AWS" ] || ak2_boot_fail "no aws CLI on PATH"
mkdir -p "$AK2_BIN" || ak2_boot_fail "cannot create $AK2_BIN"
AK2_SHIM=$(cat <<AK2SHIM
#!/bin/bash
# aws-kraken2 bucket allow-list shim (scripts/preamble.sh). Any call with an s3 or s3api
# argument may only name allowed buckets; everything else passes straight through.
ALLOWED=" $AK2_ALLOWED_BUCKETS "
s3=0
for a in "\$@"; do case "\$a" in s3|s3api) s3=1 ;; esac; done
if [ "\$s3" = 1 ]; then
  bad=""; prev=""
  for a in "\$@"; do
    b=""
    case "\$a" in
      s3://*) b=\${a#s3://}; b=\${b%%/*} ;;
      --bucket=*) b=\${a#--bucket=} ;;
      --copy-source=*) b=\${a#--copy-source=}; b=\${b#/}; b=\${b%%/*} ;;
    esac
    case "\$prev" in
      --bucket) b=\$a ;;
      --copy-source) b=\${a#/}; b=\${b%%/*} ;;
    esac
    prev=\$a
    if [ -n "\$b" ]; then case "\$ALLOWED" in *" \$b "*) ;; *) bad="\$bad \$b" ;; esac; fi
  done
  if [ -n "\$bad" ]; then
    echo "ak2: REFUSED aws \$* -- undeclared bucket(s):\$bad (declare them in env.AK2_DATASETS)" >&2
    exit 126
  fi
fi
exec "$AK2_REAL_AWS" "\$@"
AK2SHIM
)
printf '%s\n' "$AK2_SHIM" > "$AK2_BIN/aws" || ak2_boot_fail "cannot write the aws shim"
chmod 0555 "$AK2_BIN/aws" || ak2_boot_fail "cannot chmod the aws shim"
[ -s "$AK2_BIN/aws" ] && [ -x "$AK2_BIN/aws" ] || ak2_boot_fail "aws shim is empty or not executable"
[ "$(printf '%s\n' "$AK2_SHIM" | cksum)" = "$(cksum < "$AK2_BIN/aws")" ] || ak2_boot_fail "aws shim content does not match what was written"
export PATH="$AK2_BIN:$PATH"
hash -r
[ "$(command -v aws)" = "$AK2_BIN/aws" ] || ak2_boot_fail "aws shim is not first on PATH"
# Functional check: an undeclared bucket must be refused without reaching the real CLI.
# The endpoint is a closed local port, so even a broken shim could not reach AWS.
AWS_ENDPOINT_URL=http://127.0.0.1:9 aws s3 ls s3://ak2-guard-selftest-undeclared >/dev/null 2>&1
[ $? = 126 ] || ak2_boot_fail "aws shim did not refuse an undeclared bucket"
ak2_say "aws shim installed and self-tested ($AK2_BIN/aws -> $AK2_REAL_AWS)"

# ---- region assert: IMDSv2 region must equal every declared bucket's region, before any data I/O ----
AK2_TOK=$(curl -sf -X PUT -m 5 http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
ak2_md() { curl -sf -m 5 -H "X-aws-ec2-metadata-token: $AK2_TOK" "http://169.254.169.254/latest/meta-data/$1"; }
AK2_REGION=$(ak2_md placement/region)
AK2_AZ=$(ak2_md placement/availability-zone)
AK2_INSTANCE_ID=$(ak2_md instance-id)
AK2_INSTANCE_TYPE=$(ak2_md instance-type)
AK2_AMI=$(ak2_md ami-id)
ak2_say "imds region=$AK2_REGION az=$AK2_AZ instance=$AK2_INSTANCE_ID type=$AK2_INSTANCE_TYPE ami=$AK2_AMI"
export AWS_DEFAULT_REGION="$AK2_REGION" AWS_REGION="$AK2_REGION"

ak2_put() { aws s3 cp --only-show-errors "$1" "$AK2_S3_PREFIX/$2" >/dev/null 2>&1; }
AK2_PUSHER=""
# Runs on every exit path of the main shell: normal exit, `exit N`, and TERM/HUP/INT/PIPE (e.g. a
# process-group kill at shutdown). Its own output goes straight to the log file, so a dead tee
# cannot SIGPIPE it. The finish lock is a directory (mkdir is atomic) and only the main shell
# takes it, so neither a subshell nor a variable assignment can make the real finish skip.
ak2_finish() {
  local flags="$-"
  trap '' PIPE TERM HUP INT
  set +e +u
  local rc=$1 why=${2:-}
  if [ "$BASHPID" != "$AK2_MAIN_PID" ]; then exit "$rc"; fi
  # Recreate the state dir if the body deleted it; skip only if the lock itself already exists.
  mkdir -p "$AK2_STATE" 2>/dev/null
  if ! mkdir "$AK2_STATE/finishing" 2>/dev/null && [ -d "$AK2_STATE/finishing" ]; then exit "$rc"; fi
  trap - EXIT
  exec >>"$AK2_LOG" 2>&1
  if [[ "$flags" == *e* ]]; then
    printf '96\t%s\n' "errexit was on at exit (\$-=$flags); Law 4 requires set +e" >> "$AK2_STATE/errors"
    ak2_say "ERROR: errexit was on at exit (\$-=$flags)"
  fi
  if [ "$rc" = 0 ] && [ -s "$AK2_STATE/errors" ]; then
    rc=$(head -1 "$AK2_STATE/errors" | cut -f1)
    why="$(wc -l < "$AK2_STATE/errors" | tr -d ' ') helper error(s); first: $(head -1 "$AK2_STATE/errors" | cut -f2)"
  fi
  ak2_say "spec body exit rc=$rc${why:+ ($why)}"
  ak2_phase end
  [ -n "$AK2_PUSHER" ] && kill "$AK2_PUSHER" 2>/dev/null
  ak2_put "$AK2_REQS" out/requests.tsv
  [ -s "$AK2_STATE/errors" ] && ak2_put "$AK2_STATE/errors" out/helper-errors.tsv
  local i; for i in 1 2 3 4; do kill -0 "$AK2_TEE_PID" 2>/dev/null || break; sleep 0.5; done
  ak2_put "$AK2_LOG" log/run.log
  exit "$rc"
}
trap 'ak2_finish $?' EXIT
trap 'ak2_finish 143 SIGTERM' TERM
trap 'ak2_finish 129 SIGHUP' HUP
trap 'ak2_finish 130 SIGINT' INT
trap 'ak2_finish 141 SIGPIPE' PIPE
# Fatal: in the main shell this exits through ak2_finish; in a subshell the error file makes
# the main shell's exit status carry it too.
ak2_fatal() { ak2_err "${2:-97}" "FATAL: $1"; exit "${2:-97}"; }

[ -n "$AK2_REGION" ] || ak2_fatal "IMDSv2 returned no region"
[ "$AK2_REGION" = "$AK2_EXPECT_REGION" ] ||
  ak2_fatal "instance region $AK2_REGION != expected $AK2_EXPECT_REGION (cross-region placement)"

AK2_PAYERS=""
for AK2_B in $AK2_BUCKETS; do
  AK2_BR=$(curl -sI -m 10 "https://$AK2_B.s3.amazonaws.com/" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-amz-bucket-region"{print $2}')
  ak2_req HeadBucket-anon 1 "$AK2_B"
  ak2_say "bucket $AK2_B region=$AK2_BR"
  [ "$AK2_BR" = "$AK2_REGION" ] || ak2_fatal "bucket $AK2_B is in '${AK2_BR:-unknown}', instance in $AK2_REGION"
  AK2_P=$(aws s3api get-bucket-request-payment --bucket "$AK2_B" --query Payer --output text 2>/dev/null) ||
    { ak2_req GetBucketRequestPayment 1 "$AK2_B"
      AK2_P=$(aws s3api get-bucket-request-payment --no-sign-request --bucket "$AK2_B" --query Payer --output text 2>/dev/null); } ||
    AK2_P=UNKNOWN
  ak2_req GetBucketRequestPayment 1 "$AK2_B"
  ak2_say "bucket $AK2_B payer=$AK2_P"
  # The launch host already refused UNKNOWN (it has the credentials to read our own buckets;
  # the instance role does not), so UNKNOWN here is a warning. Requester is fatal unless opted in.
  if [ "$AK2_P" = Requester ] && [ "${AK2_ALLOW_REQUESTER_PAYS:-}" != 1 ]; then
    ak2_fatal "bucket $AK2_B is Requester-pays and the spec did not opt in"
  fi
  [ "$AK2_P" = UNKNOWN ] && ak2_say "WARN: could not read Payer of $AK2_B from the instance (launch host verified it)"
  AK2_PAYERS="$AK2_PAYERS{\"bucket\":\"$AK2_B\",\"region\":\"$AK2_BR\",\"payer\":\"$AK2_P\"},"
done
ak2_say "region assert passed"

# ---- drop_caches probe: a cold rung is only cold if this works ----
if sudo -n true 2>/dev/null && sudo -n test -w /proc/sys/vm/drop_caches; then AK2_DC_OK=true; else AK2_DC_OK=false; fi
readonly AK2_DC_OK
ak2_say "drop_caches_ok=$AK2_DC_OK"

printf '{"inherited_flags":"%s","payload_inherited_flags":"%s","flags_after_set":"%s","region":"%s","az":"%s","instance_id":"%s","instance_type":"%s","ami":"%s","drop_caches_ok":%s,"buckets":[%s],"allowed_buckets":"%s","aws_guard":"%s","preflight_at":"%s"}\n' \
  "${AK2_STUB_FLAGS:-$AK2_INHERITED_FLAGS}" "$AK2_INHERITED_FLAGS" "$-" "$AK2_REGION" "$AK2_AZ" "$AK2_INSTANCE_ID" "$AK2_INSTANCE_TYPE" "$AK2_AMI" \
  "$AK2_DC_OK" "${AK2_PAYERS%,}" "$AK2_ALLOWED_BUCKETS" "$AK2_BIN/aws" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /tmp/ak2-preflight.json
ak2_put /tmp/ak2-preflight.json preflight.json || ak2_say "WARN: preflight push failed"

# ---- log streaming ----
( while sleep "$AK2_PUSH_EVERY"; do ak2_put "$AK2_LOG" log/run.log; ak2_put "$AK2_REQS" out/requests.tsv; done ) >/dev/null 2>&1 &
AK2_PUSHER=$!
readonly AK2_PUSHER
disown "$AK2_PUSHER"

ak2_push() {
  local f=$1 n=${2:-$(basename "$1")}
  if aws s3 cp --only-show-errors "$f" "$AK2_S3_PREFIX/out/$n"; then ak2_say "pushed out/$n"; else ak2_say "WARN: push of $f failed"; return 1; fi
}
ak2_stage() {
  local src=$1 dst=$2 rec=""
  case "$src" in s3://*) ;; *) ak2_say "ak2_stage: source must be s3:// ($src)"; return 2 ;; esac
  case "$src" in */) rec=--recursive ;; esac
  # Signed first (needs resources.s3_read_write for a private bucket), then anonymous.
  if aws s3 cp --only-show-errors $rec "$src" "$dst" 2>/dev/null ||
     aws s3 cp --only-show-errors --no-sign-request $rec "$src" "$dst"; then
    ak2_say "staged $src -> $dst ($(du -sb "$dst" 2>/dev/null | cut -f1) bytes)"
  else
    ak2_say "ERROR: stage of $src failed"; return 1
  fi
}
ak2_drop_caches() {
  [ "$AK2_DC_OK" = true ] ||
    ak2_fatal "drop_caches is unavailable on this instance (preflight); the next rung cannot be cold" 95
  sync
  sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' ||
    ak2_fatal "DROP_CACHES FAILED: the next rung would not be cold" 95
  : > "$AK2_STATE/cold_next"
  ak2_say "drop_caches done; next phase is cold"
}
readonly -f ak2_say ak2_err ak2_phase ak2_req ak2_put ak2_finish ak2_fatal ak2_push ak2_stage \
  ak2_drop_caches ak2_md ak2_boot_fail
ak2_say "preamble done; spec body starts"
ak2_phase body
# Backstop for the static errexit check: nothing inherited or sourced may have turned -e on.
case "$-" in *e*) ak2_fatal "errexit is on at body start (\$-=$-); Law 4 requires set +e" 97 ;; esac
# ---- spec body follows ----

# G0a (#3): RODA kraken2 RefSeq Complete v205 -- hash.k2d header, opts.k2d, listing, Payer.
# The bucket and prefix come from the first AK2_DATASETS entry (the declared hash.k2d).
# Public bucket in another account: the instance role has no grant on it, so reads are
# anonymous (--no-sign-request). Every file is pushed as soon as it exists, and every S3
# request is counted with ak2_req (one CLI call below = one request unless noted).
set -- $AK2_DATASETS
U=${1#s3://}; B=${U%%/*}; K=${U#*/}; P=${K%/*}
O=/tmp/g0a; mkdir -p "$O"
s3a() { aws s3api --no-sign-request --region "$AK2_REGION" "$@"; }

ak2_phase hash-header
s3a get-object --bucket "$B" --key "$P/hash.k2d" --range bytes=0-31 "$O/hash.k2d.head32" > "$O/hash.k2d.head32.get.json"
ak2_say "ranged GET hash.k2d 0-31 rc=$? bytes=$(stat -c%s "$O/hash.k2d.head32" 2>/dev/null)"; ak2_req GetObject-range 1 "$B"
ak2_push "$O/hash.k2d.head32"; ak2_push "$O/hash.k2d.head32.get.json"

ak2_phase opts
s3a get-object --bucket "$B" --key "$P/opts.k2d" "$O/opts.k2d" > "$O/opts.k2d.get.json"
ak2_say "GET opts.k2d rc=$? bytes=$(stat -c%s "$O/opts.k2d" 2>/dev/null)"; ak2_req GetObject 1 "$B"
ak2_push "$O/opts.k2d"; ak2_push "$O/opts.k2d.get.json"

ak2_phase listing
s3a list-objects-v2 --bucket "$B" --output json > "$O/list-objects-v2.json"
N=$(grep -c '"Key"' "$O/list-objects-v2.json")
# The CLI pages at 1000 keys: one ListObjectsV2 request per page.
ak2_say "list-objects-v2 rc=$? objects=$N"; ak2_req ListObjectsV2 $(( N / 1000 + 1 )) "$B"
ak2_push "$O/list-objects-v2.json"
s3a list-object-versions --bucket "$B" --output json > "$O/list-object-versions.json" 2> "$O/list-object-versions.err"
ak2_say "list-object-versions rc=$?"; ak2_req ListObjectVersions $(( N / 1000 + 1 )) "$B"
ak2_push "$O/list-object-versions.json"; ak2_push "$O/list-object-versions.err"

ak2_phase head
for f in hash.k2d opts.k2d taxo.k2d; do
  s3a head-object --bucket "$B" --key "$P/$f" > "$O/head-$f.json"
  ak2_say "head-object $f rc=$?"; ak2_req HeadObject 1 "$B"
  ak2_push "$O/head-$f.json"
done

ak2_phase payer
s3a get-bucket-request-payment --bucket "$B" > "$O/request-payment.json"
ak2_say "get-bucket-request-payment rc=$? $(tr -d ' \n' < "$O/request-payment.json")"; ak2_req GetBucketRequestPayment 1 "$B"
ak2_push "$O/request-payment.json"
ak2_say "G0a probe done"

