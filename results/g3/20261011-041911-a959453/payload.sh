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
#     TERM/HUP/INT/PIPE. Do not replace the EXIT or signal traps. The utilisation sampler's
#     $AK2_UTIL (1 Hz, tagged with the current phase) goes to log/util.tsv every 30 s and at exit.
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
AK2_UTIL=/tmp/ak2-util.tsv      # the utilisation sampler's record (scripts/util-sampler.sh, started by the stub)
AK2_PUSH_EVERY=5
AK2_UTIL_PUSH_EVERY=30          # util.tsv grows by a line a second: re-uploaded every 30 s (and at exit)
AK2_MAIN_PID=$BASHPID
readonly AK2_EXPECT_REGION AK2_BUCKETS AK2_ALLOWED_BUCKETS AK2_S3_PREFIX AK2_RUN_ID AK2_GATE \
  AK2_PUSH_EVERY AK2_UTIL_PUSH_EVERY AK2_LOG AK2_REQS AK2_FIFO AK2_BIN AK2_STATE AK2_UTIL AK2_MAIN_PID AK2_INHERITED_FLAGS
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
  [ -s "$AK2_UTIL" ] && "$AK2_REAL_AWS" s3 cp --only-show-errors "$AK2_UTIL" "$AK2_S3_PREFIX/log/util.tsv" >/dev/null 2>&1
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
  # A utilisation tick at the boundary: the interval up to it is the previous phase's.
  [ -s /tmp/ak2-util.sh ] && bash /tmp/ak2-util.sh once phase
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
# The utilisation sampler (docs/run.md, "Utilisation"): the stub started it; start it here only if
# the stub could not (its record then begins late, and util.py measures from its first tick).
AK2_UPID=$(cat "${AK2_UTIL%.tsv}.pid" 2>/dev/null)
if [ -n "$AK2_UPID" ] && kill -0 "$AK2_UPID" 2>/dev/null; then
  ak2_say "util sampler running (pid $AK2_UPID, $(grep -c '^S' "$AK2_UTIL") ticks so far) -> log/util.tsv"
elif [ -s /tmp/ak2-util.sh ]; then
  ( bash /tmp/ak2-util.sh loop "$$" < /dev/null > /dev/null 2>&1 & )
  ak2_say "WARN: util sampler was not running; started it from the preamble"
else
  ak2_say "WARN: no util sampler (/tmp/ak2-util.sh missing): this run records no utilisation"
fi
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
  # The sampler's last tick: stop the loop (it exits between ticks), one `final` sample with the
  # end-of-run ethtool counters, then the push below.
  local up i; up=$(cat "${AK2_UTIL%.tsv}.pid" 2>/dev/null)
  if [ -n "$up" ] && kill "$up" 2>/dev/null; then
    for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$up" 2>/dev/null || break; sleep 0.1; done
  fi
  [ -s /tmp/ak2-util.sh ] && bash /tmp/ak2-util.sh once final
  [ -s "$AK2_UTIL" ] && ak2_put "$AK2_UTIL" log/util.tsv
  ak2_put "$AK2_REQS" out/requests.tsv
  [ -s "$AK2_STATE/errors" ] && ak2_put "$AK2_STATE/errors" out/helper-errors.tsv
  for i in 1 2 3 4; do kill -0 "$AK2_TEE_PID" 2>/dev/null || break; sleep 0.5; done
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
( AK2_N=0; while sleep "$AK2_PUSH_EVERY"; do ak2_put "$AK2_LOG" log/run.log; ak2_put "$AK2_REQS" out/requests.tsv
    AK2_N=$((AK2_N + 1)); [ $((AK2_N * AK2_PUSH_EVERY % AK2_UTIL_PUSH_EVERY)) = 0 ] && [ -s "$AK2_UTIL" ] && ak2_put "$AK2_UTIL" log/util.tsv; done ) >/dev/null 2>&1 &
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

# G3 pre-launch probe (#53 review, before the #25 ladder): the rate of RODA v205's hash.k2d
# (1.19 TB) staged by the AMI's aws CLI as shipped (awscp-default: the classic transfer client on
# r8gd.48xlarge, lever.sh's auto rule), onto the type's single NVMe device, exactly as S0-T1 and
# S0-Tv's fetch-db stage it: lv_nvme single, then lever.sh's lv_stage_db awscp-default command line
# (its client, its signed-then-anonymous head-object, `aws s3 cp --only-show-errors`). That rate has
# never been measured, so their 360 min TTL is a guess.
# It stages a prefix of the object: the copy runs until 20 min or 300 GiB received, whichever
# comes first (or the object is complete), and is then stopped; the partial file is removed.
# Every 10 s a progress line streams as "probe-awscp {json}" and into out/awscp.jsonl:
#   bytes (received on the NIC since the copy started; the allocated bytes on the NVMe beside it),
#   s, gbps (gigabits/s, cumulative) and interval_gbps (since the last line), gb_per_s (GB/s).
# The resolved client is recorded (kind client, from lever.sh's aws-client record), and the done
# line estimates the whole object's staging time at the measured rate.
# make rehearse seams (AK2_REHEARSE_*, which run.sh refuses in a spec's env): lever.sh's NVME, and
# AWSCP_S, AWSCP_BYTES and AWSCP_EVERY (the limits and the sampling period).
W=$HOME/ak2; mkdir -p "$W"
SHA=${AK2_RUN_ID##*-}
RB=kraken2-ncbi-refseq-complete-v205; RP=Kraken2_RefSeqCompleteV205
LIMIT_S=${AK2_REHEARSE_AWSCP_S:-1200}; LIMIT_B=${AK2_REHEARSE_AWSCP_BYTES:-322122547200}; EVERY=${AK2_REHEARSE_AWSCP_EVERY:-10}
fail() { ak2_say "ERROR: $*"; exit 1; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
J="$W/awscp.jsonl"; : > "$J"
emit() { printf '%s\n' "$1" >> "$J"; printf 'probe-awscp %s\n' "$1"; }
# rx: bytes received on the default-route interface (/proc/net/dev); "" where there is none.
rx() {
  local i; i=$(awk '$2 == "00000000" {print $1; exit}' /proc/net/route 2> /dev/null)
  [ -n "$i" ] && awk -v i="$i:" '$1 == i {print $2}' /proc/net/dev 2> /dev/null
}
# alloc DIR: the bytes allocated to the files under DIR (what the copy has written so far).
alloc() { python3 -c 'import os, sys; print(sum(os.lstat(os.path.join(d, f)).st_blocks * 512 for d, _, fs in os.walk(sys.argv[1]) for f in fs))' "$1"; }

ak2_phase setup
sudo -n dnf install -y -q git jq perl python3 tar util-linux > "$W/dnf.log" 2>&1 || { tail -5 "$W/dnf.log"; fail "dnf install failed"; }
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "no repo"
. scripts/g3/lever.sh || fail "lever.sh did not load"
# S0's storage: the first instance-store device, one xfs (lv_nvme single, as ladder.body.sh).
lv_nvme single /mnt/nvme || fail "lv_nvme failed"
DEST="$LV_NVME/db"; mkdir -p "$DEST" || fail "mkdir $DEST"
# S0's client: the AMI's aws CLI with no config override, recorded once (lever.sh's aws-client line).
lv__client default || fail "aws client default"
CL=$(grep '"kind":"aws-client"' "$LV_REC" | grep '"client":"default"' | tail -1)
emit "$(jq -c '{kind:"client", client, cli_version, resolved, how, estimate, configure_get, instance_type, optimized_platforms, ladder_types,
  home_aws_config, etc_aws}' <<< "$CL")"
# lv_stage_db's head-object: signed first, then anonymous; the copy is signed the same way.
lv__head "$RB" "$RP/hash.k2d" || fail "head-object of hash.k2d failed (signed and anonymous)"
OBJ=$LV_H_SIZE
CMD=("${LV_AWS[@]}" s3 cp --only-show-errors $LV_H_SIGN "s3://$RB/$RP/hash.k2d" "$DEST/hash.k2d")
emit "$(jq -nc --arg type "${AK2_INSTANCE_TYPE:-}" --argjson obj "$OBJ" --arg etag "$LV_H_ETAG" --arg sign "${LV_H_SIGN:-signed}" \
  --argjson ls "$LIMIT_S" --argjson lb "$LIMIT_B" --argjson every "$EVERY" --arg dest "$DEST" --arg fs "$(stat -f -c %T "$DEST" 2> /dev/null)" \
  --argjson nproc "$(nproc)" --arg cmd "${CMD[*]}" --arg aws "$(aws --version 2>&1 | head -1)" \
  '{kind:"config", instance_type:$type, object_bytes:$obj, etag:$etag, signing:$sign, limit_s:$ls, limit_bytes:$lb, every_s:$every,
    dest:$dest, fstype:$fs, nproc:$nproc, aws_version:$aws, command:$cmd}')"
ak2_push "$J" awscp.jsonl > /dev/null

# Cold, as S0's fetch-db (nothing of the object is cached; the copy goes network -> NVMe).
ak2_drop_caches
ak2_phase stage
R0=$(rx); T0=$(now)
"${CMD[@]}" > "$W/cp.out" 2>&1 &
CP=$!
STOP=""; LB=0; LS=0; LASTPUSH=$SECONDS; S60=""
while :; do
  for _ in $(seq "$EVERY"); do kill -0 "$CP" 2> /dev/null || break; sleep 1; done
  t=$(now); s=$(awk -v a="$T0" -v b="$t" 'BEGIN{printf "%.3f", b - a}')
  r=$(rx); al=$(alloc "$DEST")
  # Dirty and Writeback (kB): page cache waiting for, or being written to, the NVMe. Growing, they
  # say the disk, not the network, limits the rate. "" where there is no /proc/meminfo.
  read -r dk wk < <(awk '/^Dirty:/ {d = $2} /^Writeback:/ {w = $2} END {print d, w}' /proc/meminfo 2> /dev/null)
  if [ -n "$R0" ] && [ -n "$r" ]; then b=$((r - R0)); basis=nic_rx; else b=$al; basis=allocated; fi
  emit "$(jq -nc --argjson b "$b" --argjson al "${al:-0}" --arg basis "$basis" --argjson s "$s" --argjson lb "$LB" --argjson ls "$LS" \
    --arg dk "${dk:-}" --arg wk "${wk:-}" '
    def r3: . * 1000 | round / 1000;
    {kind:"progress", bytes:$b, bytes_basis:$basis, allocated_bytes:$al, s:$s,
     dirty_kb:(if $dk == "" then null else ($dk | tonumber) end), writeback_kb:(if $wk == "" then null else ($wk | tonumber) end),
     gbps:(if $s > 0 then ($b * 8 / $s / 1e9 | r3) else null end),
     gb_per_s:(if $s > 0 then ($b / $s / 1e9 | r3) else null end),
     interval_gbps:(if $s > $ls then (($b - $lb) * 8 / ($s - $ls) / 1e9 | r3) else null end)}')"
  LB=$b; LS=$s
  [ -z "$S60" ] && awk -v s="$s" 'BEGIN{exit !(s >= 60)}' && S60="$s $b"   # the steady rate is taken from the first line past 60 s
  if ! kill -0 "$CP" 2> /dev/null; then STOP=ended; break; fi
  if awk -v s="$s" -v l="$LIMIT_S" 'BEGIN{exit !(s >= l)}'; then STOP=time; break; fi
  if [ "$b" -ge "$LIMIT_B" ]; then STOP=bytes; break; fi
  if [ $((SECONDS - LASTPUSH)) -ge 30 ]; then ak2_push "$J" awscp.jsonl > /dev/null; LASTPUSH=$SECONDS; fi
done
# Stop the copy: TERM, then KILL if it has not exited within 30 s, so the wait below cannot hang
# until the TTL.
HARD=false
if [ "$STOP" != ended ]; then
  kill "$CP" 2> /dev/null
  for _ in $(seq 30); do kill -0 "$CP" 2> /dev/null || break; sleep 1; done
  if kill -0 "$CP" 2> /dev/null; then kill -KILL "$CP" 2> /dev/null; HARD=true; ak2_say "probe-awscp: the copy ignored TERM for 30 s; KILL"; fi
fi
wait "$CP"; CPRC=$?
[ "$STOP" = ended ] && { [ "$CPRC" = 0 ] && STOP=complete || STOP=failed; }
T1=$(now); sync
FB=$(alloc "$DEST"); FR=$(rx)
B=$LB; [ -n "$R0" ] && [ -n "$FR" ] && B=$((FR - R0))
[ "$STOP" = complete ] && B=$OBJ
# Requests (derived, as lever.sh counts them): head-object made by lv__head; the copy's GETs at
# the classic client's 8 MiB parts, as -estimate unless the client resolved to classic.
SFX=""; [ "${LV_CLIENT_EST[default]:-1}" = 1 ] && SFX=-estimate
ak2_req "GetObject$SFX" $(( (B + 8388607) / 8388608 )) "$RB"
emit "$(jq -nc --arg stop "$STOP" --argjson rc "$CPRC" --argjson b "$B" --argjson fb "${FB:-0}" --argjson obj "$OBJ" \
  --arg t0 "$T0" --arg t1 "$T1" --arg s60 "${S60:-}" --argjson hard "$HARD" --arg out "$(tail -c 600 "$W/cp.out")" '
  def r3: . * 1000 | round / 1000;
  (($t1|tonumber) - ($t0|tonumber)) as $s
  | (if $s60 == "" then null else ($s60 | split(" ") | map(tonumber)) end) as $p
  | (if $p == null or $s <= $p[0] then null else (($b - $p[1]) / ($s - $p[0])) end) as $steady
  | {kind:"done", stopped_by:$stop, cp_rc:$rc, killed_hard:$hard, bytes:$b, allocated_bytes_after_stop:$fb, object_bytes:$obj, s:($s | r3),
     gbps:(if $s > 0 then ($b * 8 / $s / 1e9 | r3) else null end), gb_per_s:(if $s > 0 then ($b / $s / 1e9 | r3) else null end),
     steady_gbps:(if $steady == null then null else ($steady * 8 / 1e9 | r3) end),
     est_object_s:(if $s > 0 and $b > 0 then ($obj / ($b / $s) | round) else null end),
     est_object_s_steady:(if $steady == null or $steady <= 0 then null else ($obj / $steady | round) end),
     cp_output_tail:$out}')"
rm -rf "$DEST"
ak2_push "$J" awscp.jsonl > /dev/null || fail "push of awscp.jsonl failed"
ak2_say "probe-awscp: stopped by $STOP after $(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.0f", b - a}') s, $B bytes"
case $STOP in time|bytes|complete) exit 0 ;; *) fail "the copy failed (rc $CPRC): $(tail -3 "$W/cp.out" | tr '\n' ' ')" ;; esac

