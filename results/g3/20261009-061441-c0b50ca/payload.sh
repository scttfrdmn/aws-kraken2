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

# G3 probe (a) (#25, Scott approved the three cheap probes 2026-10-08): best-practice staging of
# RODA v205's hash.k2d (1.19 TB) onto a tmpfs on one x8g.24xlarge (40 Gb/s, 1536 GiB), as an
# upstream user at their best would stage it, with nothing else running (U1 staged with aws s3 cp
# while the upstream build ran, and its 647 s fetch-db included a 31.4 s ETag check).
# Cheapest first: (1) a 30 s discard sweep of our ranged-GET reader (k2probe rget, the loader's
# approach: parallel ranged GETs pinned to the ETag) at 32, 64 and 128 workers; (2) the whole
# object onto the tmpfs with rget at the sweep's best, then the ETag check timed on its own;
# (3) the whole object with s5cmd (a released, checksummed binary), its ETag check timed; (4) aws
# s3 cp (CRT, 40 Gb/s target, as U1) for 150 s, rate only. The file is removed between tools.
# Network transfers, not storage reads, so drop_caches does not apply (the tmpfs is RAM).
# Every progress line streams as "probe-stage {json}" and into out/stage.jsonl, pushed per step.
W=$HOME/ak2; mkdir -p "$W"
SHA=${AK2_RUN_ID##*-}
RB=kraken2-ncbi-refseq-complete-v205; RP=Kraken2_RefSeqCompleteV205
URL=${AK2_REHEARSE_HASH_URL:-https://$RB.s3.us-west-2.amazonaws.com/$RP/hash.k2d}
SWEEP_S=${AK2_REHEARSE_SWEEP_S:-30}; CRT_S=${AK2_REHEARSE_CRT_S:-150}
S5V=2.3.0
fail() { ak2_say "ERROR: $*"; exit 1; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
J="$W/stage.jsonl"; : > "$J"
emit() { echo "$1" >> "$J"; echo "probe-stage $1"; }

ak2_phase setup
sudo -n dnf install -y -q git jq perl tar > "$W/dnf.log" 2>&1 || { tail -5 "$W/dnf.log"; fail "dnf failed"; }
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "no repo"
GOV=$(awk '$1=="go"{print $2}' go.mod)
case "$(uname -s)-$(uname -m)" in Linux-aarch64) GOOS=linux; GOA=arm64 ;; Darwin-arm64) GOOS=darwin; GOA=arm64 ;; *) fail "unsupported host" ;; esac
if [ -z "${AK2_REHEARSE_GO:-}" ]; then
  curl -fsSL --retry 5 "https://go.dev/dl/go$GOV.$GOOS-$GOA.tar.gz" -o "$W/go.tgz" || fail "Go download failed"
  tar -xzf "$W/go.tgz" -C "$W" || fail "Go unpack failed"
  export PATH="$W/go/bin:$PATH"
fi
CGO_ENABLED=0 go build -o "$W/k2probe" ./cmd/k2probe || fail "k2probe build failed"
if [ -n "${AK2_REHEARSE_S5CMD:-}" ]; then S5=$AK2_REHEARSE_S5CMD; else
  T=s5cmd_${S5V}_Linux-arm64.tar.gz
  curl -fsSL --retry 5 "https://github.com/peak/s5cmd/releases/download/v$S5V/$T" -o "$W/$T" || fail "s5cmd download failed"
  curl -fsSL --retry 5 "https://github.com/peak/s5cmd/releases/download/v$S5V/s5cmd_checksums.txt" -o "$W/s5sums" || fail "s5cmd checksums failed"
  ( cd "$W" && grep " $T\$" s5sums | sha256sum -c - ) || fail "s5cmd checksum mismatch"
  tar -xzf "$W/$T" -C "$W" s5cmd || fail "s5cmd unpack failed"
  S5=$W/s5cmd
fi
ak2_say "tools: $("$W/k2probe" 2>&1 | grep -c rget) rget; s5cmd $("$S5" version 2>&1 | head -1); $(aws --version 2>&1)"
ET=$(aws s3api head-object --no-sign-request --bucket "$RB" --key "$RP/hash.k2d" --query ETag --output text | tr -d '"')
SZ=$(aws s3api head-object --no-sign-request --bucket "$RB" --key "$RP/hash.k2d" --query ContentLength --output text)
ak2_req HeadObject 2 "$RB"
[[ "$SZ" =~ ^[0-9]+$ ]] && [ -n "$ET" ] || fail "head-object of hash.k2d failed"
ak2_say "hash.k2d etag=$ET size=$SZ"
RAMDB=$(scripts/upstream-cohort.sh mount roda 1150g) || fail "tmpfs failed"
ak2_say "tmpfs $RAMDB; nproc $(nproc); $(grep MemTotal /proc/meminfo 2>/dev/null)"

# rget_run LABEL OUT SECONDS WORKERS: our ranged-GET reader; its JSON lines streamed.
rget_run() {
  local line rc
  "$W/k2probe" rget -url "$URL" -etag "$ET" -size "$SZ" -out "$2" -seconds "$3" -workers "$4" -chunk-mib 64 -every 5 -label "$1" \
    > "$W/rget.out" 2> "$W/rget.err" &
  local p=$!
  # Stream as it goes (a TTL kill must not lose the lines).
  local seen=0
  while kill -0 "$p" 2>/dev/null; do
    sleep 5
    n=$(wc -l < "$W/rget.out"); [ "$n" -gt "$seen" ] && { sed -n "$((seen + 1)),${n}p" "$W/rget.out" | while read -r line; do emit "$line"; done; seen=$n; }
  done
  wait "$p"; rc=$?
  n=$(wc -l < "$W/rget.out"); [ "$n" -gt "$seen" ] && sed -n "$((seen + 1)),${n}p" "$W/rget.out" | while read -r line; do emit "$line"; done
  [ "$rc" = 0 ] || { tail -3 "$W/rget.err"; ak2_say "rget $1 rc=$rc"; }
  return "$rc"
}
# etag_run LABEL: the ETag check of the staged file, on its own.
etag_run() {
  local t0 t1 j rc
  t0=$(now); j=$(python3 scripts/lib/etagcheck.py "$RAMDB/hash.k2d" "$ET"); rc=$?; t1=$(now)
  emit "$(jq -nc --arg l "$1" --arg t0 "$t0" --arg t1 "$t1" --argjson rc "$rc" --arg j "$j" \
    '{kind:"etag", label:$l, seconds:(($t1|tonumber)-($t0|tonumber)), ok:($rc == 0), check:$j}')"
  return "$rc"
}
# sampled_run LABEL SECONDS CMD...: a tool writing $RAMDB/hash.k2d, its file size sampled every 5 s.
sampled_run() {
  local l=$1 lim=$2 t0 t1 rc b; shift 2
  t0=$(now)
  if [ "$lim" -gt 0 ]; then timeout "$lim" "$@" > "$W/tool.out" 2>&1 & else "$@" > "$W/tool.out" 2>&1 & fi
  local p=$!
  while kill -0 "$p" 2>/dev/null; do
    sleep 5
    b=$(stat -c%s "$RAMDB/hash.k2d" 2>/dev/null || echo 0)
    emit "$(jq -nc --arg l "$l" --arg t0 "$t0" --arg t1 "$(now)" --argjson b "$b" \
      '{kind:"progress", label:$l, elapsed_s:(($t1|tonumber)-($t0|tonumber)), file_bytes:$b}')"
  done
  wait "$p"; rc=$?; t1=$(now)
  # The bytes actually present: for a time-limited sparse write, the allocated size, not the length.
  b=$(du -k "$RAMDB/hash.k2d" 2>/dev/null | cut -f1); b=$(( ${b:-0} * 1024 ))
  emit "$(jq -nc --arg l "$l" --arg t0 "$t0" --arg t1 "$t1" --argjson b "$b" --argjson rc "$rc" --argjson sz "$SZ" --argjson lim "$lim" \
    '{kind:"done", label:$l, seconds:(($t1|tonumber)-($t0|tonumber)), bytes_allocated:$b, object_bytes:$sz, exit:$rc,
      complete:($rc == 0 and $lim == 0), gbps:($b / (($t1|tonumber)-($t0|tonumber)) / 1e9)}')"
  tail -2 "$W/tool.out"
  return "$rc"
}

FAIL=0
ak2_phase sweep
BEST=64; BR=0
for wk in 32 64 128; do
  rget_run "sweep-w$wk" "" "$SWEEP_S" "$wk" || FAIL=1
  r=$(grep '"kind":"done"' "$W/rget.out" | jq -r '.gbps_cum')
  awk -v a="$r" -v b="$BR" 'BEGIN{exit !(a > b)}' && { BEST=$wk; BR=$r; }
  ak2_req GetObject "$(grep '"kind":"done"' "$W/rget.out" | jq -r '.requests')" "$RB"
done
ak2_say "sweep best: $BEST workers at $BR GB/s"
ak2_push "$J" stage.jsonl > /dev/null

ak2_phase rget-full
rget_run "full-rget-w$BEST" "$RAMDB/hash.k2d" 0 "$BEST" || FAIL=1
ak2_req GetObject "$(grep '"kind":"done"' "$W/rget.out" | jq -r '.requests')" "$RB"
ak2_phase etag-rget
etag_run "etag-after-rget" || FAIL=1
rm -f "$RAMDB/hash.k2d"
ak2_push "$J" stage.jsonl > /dev/null

ak2_phase s5cmd-full
sampled_run "full-s5cmd" 0 "$S5" --no-sign-request --numworkers 256 cp --concurrency 128 --part-size 64 "s3://$RB/$RP/hash.k2d" "$RAMDB/hash.k2d" || FAIL=1
ak2_req GetObject $(( (SZ + 67108863) / 67108864 )) "$RB"
ak2_phase etag-s5cmd
etag_run "etag-after-s5cmd" || FAIL=1
rm -f "$RAMDB/hash.k2d"
ak2_push "$J" stage.jsonl > /dev/null

ak2_phase awscrt-sample
printf '[default]\ns3 =\n  preferred_transfer_client = crt\n  target_bandwidth = 40Gb/s\n  multipart_chunksize = 64MB\n' > "$W/aws-config"
AWS_CONFIG_FILE="$W/aws-config" sampled_run "awscrt-${CRT_S}s" "$CRT_S" aws s3 cp --only-show-errors --no-sign-request "s3://$RB/$RP/hash.k2d" "$RAMDB/hash.k2d"
rc=$?
[ "$rc" = 0 ] || [ "$rc" = 124 ] || FAIL=1   # 124: stopped by its time limit, as planned
ak2_req GetObject "$(awk -v b="$(grep '"label":"awscrt' "$J" | tail -1 | jq -r '.bytes_allocated')" 'BEGIN{print int((b + 67108863) / 67108864)}')" "$RB"
rm -f "$RAMDB/hash.k2d"
scripts/upstream-cohort.sh umount roda
ak2_phase push
ak2_push "$J" stage.jsonl || FAIL=1
ak2_say "stage probe done FAIL=$FAIL"
exit "$FAIL"

