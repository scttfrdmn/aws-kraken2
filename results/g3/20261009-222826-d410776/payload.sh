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

# G3 tune-selection probe (#41; #25 WP-5, ladder 1 rung S3): which host-tune set, if any, S3 uses.
# One x8g.24xlarge (96 vCPU, 1536 GiB, kernel 6.18, THP enabled=madvise defrag=madvise at boot).
# Regimes (one table load each, cold, end to end):
#   a  upstream at the pin, -M on a huge=always tmpfs (S2b's context, which S3 inherits): RODA v205's
#      hash.k2d staged onto the tmpfs by s5cmd (S1's stager); load_s = that staging. Then
#      kraken2 --memory-mapping --paired --threads $(nproc) on the fixed sample; the tmpfs unmounted.
#   b  ours, engine N = 1: the shard read by 48 parallel ranged GETs (If-Match, K2_DB_READ_THREADS
#      = 48 as E2's x8g.24xlarge N = 1 point) into MADV_HUGEPAGE anonymous memory; load_s = the
#      shard-load-0 phase. Then the same classify, in the same process.
# Sets (scripts/g3/hosttune.sh; rationale in docs/probes.md): none, precompact, proactive, defer,
# defermadv, always. For (b), always and defermadv give the same allocation flags as none (v6.18
# vma_thp_gfp_mask, madvised faults): null controls, so a "win" among them reads as noise.
# SCHEDULE (registered here; scripts/lib/tune_tables.py --self-test checks it): first a warm-up
# pair, none a then none b (rep 0, "warmup": streamed and recorded, never in a cell), so that no
# cell carries the fresh-boot trial alone. Then 3 reps, each complete (all 12 cells) before the
# next starts; within a rep the 12 cells run in the fixed order SCHED[rep] below (a searched
# design, not a rotation): every set's a-before-b order flips from rep to rep; every cell's 3
# trials follow 3 different predecessors, of both regimes; every cell, in both regimes, has
# exactly 2 of its 3 trials right after a trial of the other regime (equal cross-regime
# carry-over for every set); the sets' mean positions differ by at most 1 trial (0.83) and the
# cells' by at most 3; no regime runs 3 times in a row. 38 trials. Before
# every trial: ht_restore (the boot values), drop_caches (Law 4; a cold rung), ht_apply SET (its
# knobs, then its timed pre-compaction step), ht_record. After: an ht_record. Between load and
# classify (a), an ht_record; during both, a 2 s sampler of meminfo's AnonHugePages and
# ShmemPmdMapped (huge-page coverage). Fragmentation is not reset between trials: trial position
# is recorded, so the state after successive loads is in the record. teardown_s, outside
# total_s: (a) the tmpfs unmount; (b) the process's close, report, unmap and exit after classify.
# Fixed sample: SRR5935740 (rank 1 of results/cohort/PRJNA398089/runs.tsv, U1's drift reference),
# gunzipped once onto a tmpfs before any trial (not timed), so classify is table-bound.
# Network ceiling: a 30 s ranged-GET discard read at 64 workers (probe (a)'s fastest), before and after;
# hash bytes / that rate is the load floor, so median(load none) - floor bounds a load-side gain.
#
# SELECTION RULE (registered here before any run; scripts/lib/tune_tables.py applies it):
#   Per regime, separately. A trial is valid if its load and classify exit 0, ht_apply returned 0
#   (the set read back as wanted), and its --output and --report sha256 equal the run's modal
#   ones. Warm-up trials are excluded, and so is every trial of a rep that did not record all 12
#   of its trials (a TTL kill then leaves whole reps only, so it cannot favour the sets that ran
#   early in the last rep). Per trial total_s = precompact_s (0 without the step) + load_s +
#   classify_s. A cell (regime, set) needs >= 3 valid trials. range(cell) = max - min of total_s; crange(cell) the same of classify_s.
#   A set S != none qualifies iff
#     gain = median total(none) - median total(S) > 2 x max(range(none), range(S)), and
#     median classify(S) <= median classify(none) + 2 x max(crange(none), crange(S))
#       (no classify regression the probe can resolve: it would scale with a cohort).
#   Pick the qualifying set with the lowest median total_s; else none.
#   S3's set is regime a's pick. Regime b's pick is recorded for ours (O0b); it does not change S3.
# RESOLUTION (computed by the post before any verdict): the smallest gain the rule can accept is
#   2 x range(none); with the load ceiling (median load none - floor) it is printed per regime.
#   If the ceiling is below the resolution, a "none" verdict is not evidence that no set helps.
# Every result line streams as "probe-tune {json}" and into out/tune.jsonl (pushed after every
# trial); every ht_record line as "ht-record {json}" into out/hosttune.{txt,jsonl}, pushed per call.
W=$HOME/ak2; mkdir -p "$W"
SHA=${AK2_RUN_ID##*-}
HT_ROOT=${AK2_REHEARSE_HT_ROOT:-}
# The host's state before this body does anything (the stub and the preamble ran before it).
{ echo "== boot-raw $(date -u +%FT%TZ)"; cat "$HT_ROOT/proc/buddyinfo"; grep -E '^(compact_|thp_)' "$HT_ROOT/proc/vmstat"; } > "$W/boot-raw.txt" 2>&1
ak2_push "$W/boot-raw.txt" boot-raw.txt > /dev/null
RB=kraken2-ncbi-refseq-complete-v205; RP=Kraken2_RefSeqCompleteV205
B=aws-kraken2-942542972736-us-west-2; CK=aws-kraken2/data/cohort
S1=SRR5935740
SETS=(none precompact proactive defer defermadv always)
SCHED=(
  "defermadv:a always:a precompact:b defermadv:b defer:a proactive:b always:b none:a none:b defer:b precompact:a proactive:a"
  "none:b proactive:a defer:b none:a precompact:a defermadv:b defermadv:a proactive:b precompact:b defer:a always:b always:a"
  "defer:a precompact:b proactive:b always:a always:b precompact:a none:a defer:b proactive:a defermadv:a defermadv:b none:b"
)
NET_S=${AK2_REHEARSE_NET_S:-30}
RW=48; NW=64
S5V=2.3.0
fail() { ak2_say "ERROR: $*"; exit 1; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
J="$W/tune.jsonl"; : > "$J"
emit() { echo "$1" >> "$J"; echo "probe-tune $1"; }

ak2_phase setup
sudo -n dnf install -y -q git gcc-c++ make zlib-devel perl jq gzip tar findutils python3 pigz > "$W/dnf.log" 2>&1 ||
  { tail -5 "$W/dnf.log"; fail "dnf failed"; }
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "no repo"
HT_DIR="$W/hosttune"
. scripts/g3/hosttune.sh
ht_init || fail "ht_init failed"
ht_record setup
( scripts/oracle-build.sh > "$W/build.out" 2>&1 ) &
BUILD_PID=$!
GOV=$(awk '$1=="go"{print $2}' go.mod)
if [ -z "${AK2_REHEARSE_GO:-}" ]; then
  curl -fsSL --retry 5 "https://go.dev/dl/go$GOV.linux-arm64.tar.gz" -o "$W/go.tgz" || fail "Go download failed"
  tar -xzf "$W/go.tgz" -C "$W" || fail "Go unpack failed"
  export PATH="$W/go/bin:$PATH"
fi
make build > "$W/make-build.out" 2>&1 || { tail -20 "$W/make-build.out"; fail "make build failed"; }
OURS="$W/repo/bin/aws-kraken2"; K2P="$W/repo/bin/k2probe"
if [ -n "${AK2_REHEARSE_S5CMD:-}" ]; then S5=$AK2_REHEARSE_S5CMD; else
  T5=s5cmd_${S5V}_Linux-arm64.tar.gz
  curl -fsSL --retry 5 "https://github.com/peak/s5cmd/releases/download/v$S5V/$T5" -o "$W/$T5" || fail "s5cmd download failed"
  curl -fsSL --retry 5 "https://github.com/peak/s5cmd/releases/download/v$S5V/s5cmd_checksums.txt" -o "$W/s5sums" || fail "s5cmd checksums failed"
  ( cd "$W" && grep " $T5\$" s5sums | sha256sum -c - ) || fail "s5cmd checksum mismatch"
  tar -xzf "$W/$T5" -C "$W" s5cmd || fail "s5cmd unpack failed"
  S5=$W/s5cmd
fi
wait "$BUILD_PID" || { cat "$W/build.out"; fail "upstream build failed"; }
K2DIR=$(scripts/oracle-build.sh 2>/dev/null) || fail "upstream build not found"
K2="$K2DIR/kraken2"
T=$(nproc)
ak2_say "upstream $(tr '\n' ';' < "$K2DIR/BUILD"); ours $(git rev-parse HEAD); s5cmd $("$S5" version 2>&1 | head -1); threads $T; ranged-GET workers $RW"

ak2_phase fetch-inputs
DB="$W/db"; mkdir -p "$DB"
for f in opts.k2d taxo.k2d; do
  ak2_stage "s3://$RB/$RP/$f" "$DB/$f" || fail "stage of RODA $f failed"
  ak2_req GetObject 1 "$RB"
done
ET=$(aws s3api head-object --no-sign-request --bucket "$RB" --key "$RP/hash.k2d" --query ETag --output text | tr -d '"')
SZ=$(aws s3api head-object --no-sign-request --bucket "$RB" --key "$RP/hash.k2d" --query ContentLength --output text)
ak2_req HeadObject 2 "$RB"
[[ "$SZ" =~ ^[0-9]+$ ]] && [ -n "$ET" ] || fail "head-object of hash.k2d failed"
URL=${AK2_REHEARSE_HASH_URL:-https://$RB.s3.us-west-2.amazonaws.com/$RP/hash.k2d}
ak2_say "hash.k2d etag=$ET size=$SZ"
IN=$(scripts/upstream-cohort.sh mount inputs 24g) || fail "tmpfs for inputs failed"
"$W/repo/scripts/g3/fetch.sh" "$B" "$CK" "$IN" 2 "${S1}_1.fastq.gz" "${S1}_2.fastq.gz" > "$W/fetched.txt" 2>&1
FERR=$?
cat "$W/fetched.txt"
[ "$FERR" = 0 ] && [ "$(grep -vc ERROR "$W/fetched.txt")" = 2 ] || fail "input fetch failed"
ak2_req GetObject "$(awk '!/ERROR/{n += int(($2 + 8388607) / 8388608)} END{print n+0}' "$W/fetched.txt")" "$B"
ak2_req HeadObject 2 "$B"
t0=$(now)
for m in 1 2; do pigz -dc -p 16 "$IN/${S1}_$m.fastq.gz" > "$IN/${S1}_$m.fq" || fail "gunzip of mate $m failed"; done
t1=$(now)
FQ1="$IN/${S1}_1.fq"; FQ2="$IN/${S1}_2.fq"
emit "$(jq -nc --arg s "$S1" --arg t0 "$t0" --arg t1 "$t1" --argjson b "$(( $(stat -c%s "$FQ1") + $(stat -c%s "$FQ2") ))" \
  '{kind:"prep", sample:$s, tool:"pigz -dc -p 16", seconds:(($t1|tonumber)-($t0|tonumber)), fq_bytes:$b}')"

# net LABEL: the network ceiling, a NET_S-second ranged-GET discard read at NW workers.
net() {
  "$K2P" rget -url "$URL" -etag "$ET" -size "$SZ" -out "" -seconds "$NET_S" -workers "$NW" -chunk-mib 64 -every 5 -label "$1" \
    > "$W/net.out" 2> "$W/net.err"
  local rc=$? d
  d=$(grep '"kind":"done"' "$W/net.out" | tail -1)
  [ -n "$d" ] || d='{}'
  emit "$(jq -nc --arg l "$1" --argjson rc "$rc" --argjson d "$d" --argjson sz "$SZ" --argjson w "$NW" \
    '{kind:"net", label:$l, exit:$rc, workers:$w, gbps:$d.gbps_cum, requests:$d.requests, object_bytes:$sz,
      load_floor_s:(if ($d.gbps_cum // 0) > 0 then $sz / ($d.gbps_cum * 1e9) else null end)}')"
  ak2_req GetObject "$(jq -r '.requests // 0' <<< "$d")" "$RB"
  [ "$rc" = 0 ]
}
# hugewatch FILE: every 2 s, meminfo's AnonHugePages and ShmemPmdMapped (kB), until killed.
hugewatch() {
  while :; do
    awk -v t="$(date +%s)" '/^AnonHugePages:/{a=$2} /^ShmemPmdMapped:/{s=$2} END{print t, a+0, s+0}' "$HT_ROOT/proc/meminfo" >> "$1" 2>/dev/null
    sleep 2
  done
}
peak() { awk -v c="$2" 'BEGIN{m=0} $c > m {m = $c} END{print m+0}' "$1" 2>/dev/null || echo 0; }
sec() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b - a}'; }

# trial POS REP SET REGIME: one cold load and classify; one "trial" line.
FAIL=0
trial() {
  local pos=$1 rep=$2 set=$3 reg=$4 warm=${5:-false} tag="t$1-$4-$3" d arc pre mid=null post t0 t1 tl0 tl1 tc0 tc1 td0 td1 lrc=1 crc=1 cs ls hw
  local RAMDB req=0 osha=- rsha=- applied
  ak2_phase "$tag"
  ht_restore || ak2_say "ht_restore before $tag did not restore every knob"
  ak2_drop_caches
  ht_apply "$set"; arc=$?
  applied=$HT_APPLIED
  local writes=$HT_WRITES pcs=${HT_PRECOMPACT_S:-}
  ht_record "pre-$tag"; pre=$HT_LAST_JSON
  d="$IN/out/$tag"; mkdir -p "$d"
  hugewatch "$d/huge.txt" & hw=$!
  t0=$(now)
  if [ "$reg" = a ]; then
    RAMDB=$(scripts/upstream-cohort.sh mount roda 1150g)
    if [ -n "$RAMDB" ] && cp "$DB/opts.k2d" "$DB/taxo.k2d" "$RAMDB/"; then
      tl0=$(now)
      "$S5" --no-sign-request --numworkers 256 cp --concurrency 128 --part-size 64 "s3://$RB/$RP/hash.k2d" "$RAMDB/hash.k2d" > "$d/load.log" 2>&1
      lrc=$?; tl1=$(now)
      req=$(( (SZ + 67108863) / 67108864 ))
      if [ "$lrc" = 0 ] && [ "$(stat -c%s "$RAMDB/hash.k2d" 2>/dev/null)" != "$SZ" ]; then lrc=1; fi
      [ "$lrc" = 0 ] || tail -3 "$d/load.log"
      ls=$(sec "$tl0" "$tl1")
      ht_record "load-$tag"; mid=$HT_LAST_JSON
      if [ "$lrc" = 0 ]; then
        tc0=$(now)
        "$K2" --db "$RAMDB" --memory-mapping --paired --threads "$T" --output "$d/output" --report "$d/report" "$FQ1" "$FQ2" \
          > /dev/null 2> "$d/stderr"
        crc=$?; tc1=$(now)
      fi
    else
      ak2_say "tmpfs for $tag failed"
    fi
    td0=$(now)
    scripts/upstream-cohort.sh umount roda || { kill "$hw" 2>/dev/null; fail "umount of the RODA tmpfs after $tag failed (the next trial would not fit)"; }
    td1=$(now)
  else
    mkdir -p "$W/rv/$tag"
    tc0=$(now)
    env AK2_ENGINE_N=1 AK2_ENGINE_RANK=0 AK2_ENGINE_RENDEZVOUS="$W/rv/$tag" AK2_ENGINE_LISTEN=127.0.0.1 AK2_ENGINE_TIMEOUT=30m \
      AK2_ENGINE_HASH_URL="$URL" AK2_ENGINE_HASH_ETAG="$ET" AK2_ENGINE_HASH_SIZE="$SZ" AK2_TIMINGS=1 K2_DB_READ_THREADS="$RW" \
      "$OURS" --db "$DB" --paired --threads "$T" --output "$d/output" --report "$d/report" "$FQ1" "$FQ2" \
      2> >(tee "$d/stderr" | grep --line-buffered -E '^ak2-(timing|engine)' | sed -u "s/^/[$tag] /") > /dev/null
    crc=$?; tc1=$(now)
    sleep 1 # let the tee drain
    ls=$(awk -F'\t' '$1 == "ak2-timing" && $2 == "shard-load-0" {print $4}' "$d/stderr" | tail -1)
    [ -n "$ls" ] && lrc=0
    req=$(awk -F'\t' '$1 == "ak2-engine" && $2 == "load" {print $6}' "$d/stderr" | tail -1)
    # Teardown: from the classify phase's end (its start + seconds after process start, ~ tc0)
    # to the process's exit; classify_wall_s is the classify phase itself.
    local ce cw
    ce=$(awk -F'\t' '$1 == "ak2-timing" && $2 == "classify" {e = $3 + $4} END {if (e != "") print e}' "$d/stderr")
    cw=$(awk -F'\t' '$1 == "ak2-timing" && $2 == "classify" {print $4}' "$d/stderr" | tail -1)
    if [ -n "$ce" ]; then td0=$(awk -v a="$tc0" -v e="$ce" 'BEGIN{printf "%.3f", a + e}'); td1=$tc1; else td0=; td1=; fi
    [ -n "$cw" ] && tc1=$(awk -v a="$tc0" -v w="$cw" 'BEGIN{printf "%.3f", a + w}') || { tc0=; tc1=; }
  fi
  t1=$(now)
  kill "$hw" 2>/dev/null; wait "$hw" 2>/dev/null
  ak2_req GetObject "${req:-0}" "$RB"
  cs=$(sed -nE 's/.*processed in ([0-9.]+)s.*/\1/p' "$d/stderr" 2>/dev/null | tail -1)
  [ -s "$d/output" ] && osha=$(sha256sum "$d/output" | cut -d' ' -f1)
  [ -s "$d/report" ] && rsha=$(sha256sum "$d/report" | cut -d' ' -f1)
  ht_record "post-$tag"; post=$HT_LAST_JSON
  emit "$(jq -nc --argjson pos "$pos" --argjson rep "$rep" --argjson warm "$warm" --arg set "$set" --arg reg "$reg" --argjson arc "$arc" --arg applied "$applied" \
    --argjson writes "$writes" --arg pcs "$pcs" --arg ls "${ls:-}" --arg cs "${cs:-}" --argjson lrc "$lrc" --argjson crc "$crc" \
    --arg t0 "$t0" --arg t1 "$t1" --arg tc0 "${tc0:-}" --arg tc1 "${tc1:-}" --arg td0 "${td0:-}" --arg td1 "${td1:-}" \
    --arg osha "$osha" --arg rsha "$rsha" --argjson pre "$pre" --argjson mid "$mid" --argjson post "$post" \
    --argjson ha "$(peak "$d/huge.txt" 2)" --argjson hs "$(peak "$d/huge.txt" 3)" --arg tail "$(tail -2 "$d/stderr" 2>/dev/null | tr '\n' ' ' | cut -c1-200)" '
    def n($s): if $s == "" then null else ($s | tonumber) end;
    def delta($k): if ($pre.vmstat[$k] != null and $post.vmstat[$k] != null) then $post.vmstat[$k] - $pre.vmstat[$k] else null end;
    {kind:"trial", pos:$pos, rep:$rep, warmup:$warm, set:$set, regime:$reg, applied:($applied == "true" and $arc == 0), ht_apply_rc:$arc,
     ht_writes:$writes, precompact_s:n($pcs), load_s:n($ls), classify_s:n($cs), load_exit:$lrc, classify_exit:$crc,
     classify_wall_s:(if $tc0 == "" or $tc1 == "" then null else n($tc1) - n($tc0) end),
     teardown_s:(if $td0 == "" then null else n($td1) - n($td0) end),
     wall_s:(n($t1) - n($t0)),
     total_s:(if $ls == "" or $cs == "" then null else (n($pcs) // 0) + n($ls) + n($cs) end),
     output_sha256:$osha, report_sha256:$rsha,
     pre_free_huge_frac:$pre.free_huge_frac, pre_free_bytes:$pre.free_bytes, pre_buddy:$pre.buddy,
     thp:{enabled:$pre.enabled, defrag:$pre.defrag, proactiveness:$pre.proactiveness},
     vmstat_delta:([ "compact_stall", "compact_success", "compact_fail", "compact_migrate_scanned", "compact_free_scanned",
       "compact_daemon_wake", "thp_fault_alloc", "thp_fault_fallback", "thp_file_alloc", "thp_file_fallback" ]
       | map({(.): delta(.)}) | add),
     shmem_huge_kb_after_load:(if $mid == null then null else $mid.meminfo_kb.ShmemHugePages end),
     anon_huge_kb_peak:$ha, shmem_pmd_mapped_kb_peak:$hs, stderr_tail:$tail}')"
  ak2_push "$J" tune.jsonl > /dev/null
  rm -rf "$d"
  [ "$lrc" = 0 ] && [ "$crc" = 0 ] && [ "$arc" = 0 ]
}

ak2_phase net-0
net net-0 || FAIL=1
POS=0
for reg in a b; do
  POS=$((POS + 1))
  trial "$POS" 0 none "$reg" true || { FAIL=1; ak2_say "warm-up $POS ($reg) failed"; }
done
for ((rep = 1; rep <= ${#SCHED[@]}; rep++)); do
  for c in ${SCHED[$((rep - 1))]}; do
    POS=$((POS + 1))
    trial "$POS" "$rep" "${c%%:*}" "${c#*:}" || { FAIL=1; ak2_say "trial $POS (${c#*:}, ${c%%:*}) failed"; }
  done
done
ak2_phase net-1
net net-1 || FAIL=1

ak2_phase push
ht_restore || FAIL=1
ht_record end
scripts/upstream-cohort.sh umount inputs || ak2_say "umount inputs failed"
ak2_push "$J" tune.jsonl || FAIL=1
ak2_say "tune probe done: $POS trials, FAIL=$FAIL"
exit "$FAIL"

