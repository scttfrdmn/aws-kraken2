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

# G3 campaign point (#25; Scott approved the campaign 2026-10-08): the multi-node engine on RODA
# v205, N nodes, one cohort-mode invocation over the first COHORT samples of the recorded cohort
# (results/cohort/PRJNA398089/runs.tsv), the shard loaded once. Generated by scripts/g3/mkspec.sh
# from scripts/g3/campaign.body.sh; the parameters are the block below.
# Batches of the one invocation c<COHORT> (defaults: SDK emitter, sample-parallel, T16, LPT):
#   0  parallel:lpt, every sample, INFLIGHT per node (weight = pairs, runs.tsv read_count)
#   1  parallel:mod, the same samples (the placement control, j mod N; CONTROL_MOD=1, N > 1)
#   2  parallel:lpt again (the within-run spread; REPEAT_LPT=1)
#   3… sample 1 block-striped across the N nodes, C1_REPS times (N > 1), then sample 1 on its
#      home node alone, C1_REPS times (the single-sample points on the same load)
# Each node fetches only the inputs it reads (its home samples in batches 0-2 and sample 1), each
# checked against its sha256 metadata; inputs are page-cache warm when classified (staged just
# before, as upstream's are in U1/U2). Every output is an s3:// object under
# <cohort prefix>/out/c<COHORT>/<batch>-<sample>/{output,report}. No upstream arm here: Law 1 for
# these paths rests on make oracle-cohort (LPT included) and on the cross-check of the cohort's
# outputs with U1's (equal ETags, the same 8 MiB part layout). The cohort post
# (scripts/post/<spec>.cohort.sh) derives every table offline from the pushed stderr and
# outputs.tsv. Streaming: every engine ak2 line goes into the run log as written.
# Parameters (scripts/g3/mkspec.sh):
EXP=e2; WANT_N=1; COHORT=100; THREADS=16; INFLIGHT=auto; CONTROL_MOD=1; REPEAT_LPT=1; C1_REPS=3
W=$HOME/ak2; mkdir -p "$W"
SHA=$(echo "$AK2_COHORT_ID" | cut -d- -f3)
RANK=$AK2_ENGINE_RANK; N=$AK2_ENGINE_N
set -- $AK2_DATASETS
U=${1#s3://}; RB=${U%%/*}; HK=${U#*/}; RP=${HK%/*}
U=${4#s3://}; B=${U%%/*}; CK=${U#*/}; CK=${CK%/}
fail() { ak2_say "ERROR: $*"; exit 1; }
hex64() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
# AK2_REHEARSE_* are make rehearse's seams (scripts/lib/cohort_rehearse.sh): run.sh refuses them in
# a spec's env and never sets them, so on AWS they are always unset.
[ -n "$AK2_COHORT_ID" ] && [ -n "$RANK" ] && [ "$N" = "${AK2_REHEARSE_N:-$WANT_N}" ] ||
  fail "not a member of a ${AK2_REHEARSE_N:-$WANT_N}-node cohort (make run ... NODES=$WANT_N)"
ak2_say "$EXP cohort $AK2_COHORT_ID rank $RANK of $N, commit $SHA; RODA $RB/$RP; samples $B/$CK; cohort $COHORT"

ak2_phase setup
sudo -n dnf install -y -q git gcc make jq gzip tar findutils python3 > "$W/dnf.log" 2>&1 || { tail -20 "$W/dnf.log"; fail "dnf install failed"; }
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
GOV=$(awk '$1=="go"{print $2}' "$W/repo/go.mod")
curl -fsSL --retry 5 --retry-delay 5 "https://go.dev/dl/go$GOV.linux-arm64.tar.gz" -o "$W/go.tgz" || fail "Go download failed"
tar -xzf "$W/go.tgz" -C "$W" || fail "Go unpack failed"
export PATH="$W/go/bin:$PATH"
(cd "$W/repo" && make build) > "$W/make-build.out" 2>&1 || { tail -30 "$W/make-build.out"; fail "make build failed"; }
OURS="$W/repo/bin/aws-kraken2"
TOKEN=$(curl -sf -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 300" http://169.254.169.254/latest/api/token)
IP=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
[ -n "$IP" ] || fail "no private IP from IMDS"
NPROC=$(nproc)
[ "$INFLIGHT" = auto ] && INFLIGHT=$(( NPROC / 8 > 0 ? NPROC / 8 : 1 ))
ak2_say "built $(git -C "$W/repo" rev-parse HEAD); $(go version); ip $IP; nproc $NPROC; $(free -g | awk '/Mem:/{print "mem_gib " $2}'); threads $THREADS, inflight $INFLIGHT"

ak2_phase manifest
DB="$W/db/roda"; mkdir -p "$DB"
for f in opts.k2d taxo.k2d; do
  ak2_stage "s3://$RB/$RP/$f" "$DB/$f" || fail "stage of RODA $f failed"
  ak2_req GetObject 1 "$RB"
done
aws s3api head-object --no-sign-request --bucket "$RB" --key "$RP/hash.k2d" > "$W/head-hash.json" || fail "head-object hash.k2d failed"
ak2_req HeadObject 1 "$RB"
ETAG=$(jq -r '.ETag | gsub("\"";"")' "$W/head-hash.json"); SIZE=$(jq -r .ContentLength "$W/head-hash.json")
URL=${AK2_REHEARSE_HASH_URL:-"https://$RB.s3.$AK2_REGION.amazonaws.com/$RP/hash.k2d"}
ak2_say "RODA hash.k2d etag=$ETAG size=$SIZE"
# The first COHORT runs of the recorded cohort (rank order) and their pairs (the LPT weight).
RUNS="$W/repo/results/cohort/PRJNA398089/runs.tsv"
mapfile -t SAMPLES < <(awk -F'\t' -v c="$COHORT" 'NR>1 && $1<=c {print $2}' "$RUNS")
mapfile -t WEIGHTS < <(awk -F'\t' -v c="$COHORT" 'NR>1 && $1<=c {print $4}' "$RUNS")
if [ -n "${AK2_REHEARSE_SAMPLES:-}" ]; then
  read -r -a SAMPLES <<< "$AK2_REHEARSE_SAMPLES"; read -r -a WEIGHTS <<< "$AK2_REHEARSE_WEIGHTS"
  COHORT=${#SAMPLES[@]}
fi
[ "${#SAMPLES[@]}" = "$COHORT" ] && [ "${#WEIGHTS[@]}" = "$COHORT" ] || fail "want $COHORT cohort runs and weights, got ${#SAMPLES[@]} and ${#WEIGHTS[@]}"
CD="$W/cohort"; mkdir -p "$CD"
OUT="$AK2_COHORT_PREFIX/out"
INV="c$COHORT"
M="$W/$INV.tsv"; : > "$M"
inputs() { echo "$CD/${1}_1.fastq.gz"; echo "$CD/${1}_2.fastq.gz"; }
line() {  # batch mode name weight sample
  local b=$1 mode=$2 s=$5 w=()
  [ "$4" != - ] && w=("weight=$4")
  local inf=$INFLIGHT; [ "$mode" = striped ] && inf=1
  printf '%s\t%s\t%s\tsdk\t%s' "$b" "$inf" "$mode" "$3"
  [ "${#w[@]}" -gt 0 ] && printf '\t%s' "${w[@]}"
  printf '\t--threads\t%s\t--output\t%s\t--report\t%s\t%s\t%s\n' "$THREADS" "$OUT/$INV/$3/output" "$OUT/$INV/$3/report" \
    "$CD/${s}_1.fastq.gz" "$CD/${s}_2.fastq.gz"
}
b=0
for ((j = 0; j < COHORT; j++)); do line "$b" parallel:lpt "$b-${SAMPLES[$j]}" "${WEIGHTS[$j]}" "${SAMPLES[$j]}" >> "$M"; done
b=$((b + 1))
if [ "$CONTROL_MOD" = 1 ] && [ "$N" -gt 1 ]; then
  for ((j = 0; j < COHORT; j++)); do line "$b" parallel:mod "$b-${SAMPLES[$j]}" "${WEIGHTS[$j]}" "${SAMPLES[$j]}" >> "$M"; done
  b=$((b + 1))
fi
if [ "$REPEAT_LPT" = 1 ]; then
  for ((j = 0; j < COHORT; j++)); do line "$b" parallel:lpt "$b-${SAMPLES[$j]}" "${WEIGHTS[$j]}" "${SAMPLES[$j]}" >> "$M"; done
  b=$((b + 1))
fi
S1=${SAMPLES[0]}
for ((k = 0; k < C1_REPS; k++)); do
  [ "$N" -gt 1 ] || break
  line "$b" striped "$b-$S1" - "$S1" >> "$M"; b=$((b + 1))
done
for ((k = 0; k < C1_REPS; k++)); do line "$b" parallel:lpt "$b-$S1" "${WEIGHTS[0]}" "$S1" >> "$M"; b=$((b + 1)); done
ak2_push "$M" "rank$RANK/$INV.tsv"
python3 "$W/repo/scripts/lib/cohort_place.py" table "$N" "$M" > "$W/placement.tsv" || fail "placement table failed"
ak2_push "$W/placement.tsv" "rank$RANK/placement.tsv"
mapfile -t NEED < <(python3 "$W/repo/scripts/lib/cohort_place.py" needs "$N" "$RANK" "$M")
ak2_say "manifest $INV: $(grep -c . "$M") lines in $b batches; rank $RANK reads ${#NEED[@]} samples"

ak2_phase fetch
# Each needed mate: GET, then sha256 against its metadata; 8 at once.
fetch_one() {
  local f=$1 want got
  ak2_stage "s3://$B/$CK/$f" "$CD/$f" > "$W/fetch-$f.log" 2>&1 || { cat "$W/fetch-$f.log"; return 1; }
  want=$(aws s3api head-object --bucket "$B" --key "$CK/$f" --query Metadata.sha256 --output text)
  got=$(sha256sum "$CD/$f" | cut -d' ' -f1)
  hex64 "$want" && [ "$got" = "$want" ] || { echo "ERROR: $f sha256 $got != metadata $want"; return 1; }
  echo "$f $(stat -c%s "$CD/$f")"
}
: > "$W/fetched.txt"
FERR=0; RUNNING=0
for s in "${NEED[@]}"; do
  for m in 1 2; do
    fetch_one "${s}_$m.fastq.gz" >> "$W/fetched.txt" 2>&1 &
    RUNNING=$((RUNNING + 1))
    if [ "$RUNNING" -ge 8 ]; then wait -n || FERR=1; RUNNING=$((RUNNING - 1)); fi
  done
done
while [ "$RUNNING" -gt 0 ]; do wait -n || FERR=1; RUNNING=$((RUNNING - 1)); done
grep ERROR "$W/fetched.txt" | head -5
[ "$FERR" = 0 ] || fail "input fetch failed"
NF=$(grep -vc ERROR "$W/fetched.txt")
[ "$NF" = $(( 2 * ${#NEED[@]} )) ] || fail "fetched $NF files, want $(( 2 * ${#NEED[@]} ))"
ak2_req GetObject "$(awk '!/ERROR/{n += int(($2 + 8388607) / 8388608)} END{print n+0}' "$W/fetched.txt")" "$B"
ak2_req HeadObject "$NF" "$B"
ak2_say "inputs staged and verified: $NF files, $(awk '!/ERROR/{s+=$2} END{printf "%.2f GB", s/1e9}' "$W/fetched.txt")"

ENGINE_ENV=(AK2_ENGINE_LISTEN="$IP" AK2_ENGINE_TIMEOUT=30m AK2_ENGINE_HASH_URL="$URL" AK2_ENGINE_HASH_ETAG="$ETAG"
  AK2_ENGINE_HASH_SIZE="$SIZE" AK2_TIMINGS=1 K2_DB_READ_THREADS=48)
COMMON=(--db "$DB" --paired)
env "${ENGINE_ENV[@]}" AK2_COHORT="$M" AK2_COHORT_CHECK=1 "$OURS" "${COMMON[@]}" > /dev/null 2> "$W/check.err" ||
  { cat "$W/check.err"; fail "cohort manifest $M does not check"; }
ak2_say "manifest $INV: $(grep "^cohort:" "$W/check.err" | tail -1)"

ak2_phase "inv-$INV"
# The engine's stderr to a file and, line by line as written, its ak2 lines into the run log.
# Order matters: the 2> process substitution forks with the stdout in effect at that point, so
# it comes before > /dev/null.
env "${ENGINE_ENV[@]}" AK2_ENGINE_RENDEZVOUS="$AK2_ENGINE_RENDEZVOUS/$INV" AK2_COHORT="$M" "$OURS" "${COMMON[@]}" \
  2> >(tee "$W/eng-$INV.stderr" | grep --line-buffered -E '^ak2-(sample|timing|engine)' | sed -u "s/^/[$INV] /") \
  > /dev/null
RC=$?
sleep 1 # let the tee drain
ak2_say "inv $INV rank $RANK exit $RC"
grep -vE '^ak2-(timing|engine|sample)' "$W/eng-$INV.stderr" | grep -v ' sequences ' | tail -5 | sed "s/^/[$INV stderr] /"
# Requests: the shard load's ranged GETs (RODA, anonymous); every S3 request of the process by
# operation (outputs and rendezvous, both clients); the rendezvous's own puts and gets.
F="$W/eng-$INV.stderr"
v=$(awk -F'\t' '$1=="ak2-engine" && $2=="load" {print $6}' "$F" | tail -1)
[ -n "$v" ] && ak2_req GetObject-range "$v" "$RB"
for op in put:PutObject get:GetObject create_multipart:CreateMultipartUpload upload_part:UploadPart \
          complete_multipart:CompleteMultipartUpload abort_multipart:AbortMultipartUpload; do
  v=$(awk -F'\t' -v k="${op%%:*}" '$1=="ak2-engine" && $2=="s3" { for (i = 3; i < NF; i++) if ($i == k) s += $(i+1) } END { print s+0 }' "$F")
  [ "$v" -gt 0 ] && ak2_req "${op#*:}" "$v" "$B"
done
v=$(awk -F'\t' '$1=="ak2-engine" && $2=="rendezvous" {print $4}' "$F" | tail -1); [ -n "$v" ] && ak2_req Rendezvous-PutObject "$v" "$B"
v=$(awk -F'\t' '$1=="ak2-engine" && $2=="rendezvous" {print $6}' "$F" | tail -1); [ -n "$v" ] && ak2_req Rendezvous-GetObject "$v" "$B"
ak2_push "$F" "rank$RANK/eng-$INV.stderr"
ak2_say "rank $RANK done (rc=$RC)"
exit "$RC"
