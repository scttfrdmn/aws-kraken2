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
  # Three tries: one timed out on O3-n16 at c10, rank 14 ('unknown' after 11 s, exit 97;
  # results/g3/20261015-181714-aade01c-2d27-n16-r14). An answer is still asserted below.
  for AK2_T3 in 1 2 3; do
    AK2_BR=$(curl -sI -m 10 "https://$AK2_B.s3.amazonaws.com/" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-amz-bucket-region"{print $2}')
    ak2_req HeadBucket-anon 1 "$AK2_B"
    [ -n "$AK2_BR" ] && break
    ak2_say "WARN: no region for bucket $AK2_B (try $AK2_T3 of 3)"; [ "$AK2_T3" = 3 ] || sleep 2
  done
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

# shellcheck disable=SC2015,SC2016,SC2024  # A && B || C is meant; the gdb and sh -c text is literal; the logs are ours
# G3 probe (h): two candidate fixes for rapidgzip's SIGSEGV on Graviton4 (Scott approved
# 2026-10-18; docs/probes.md, "The rapidgzip fix probe"). Probe (g)
# (results/g3/20261018-184334-cc920a8) reproduced it: 9 SIGSEGV in 3588 lad_identity jobs of
# rapidgzip 0.14.5 on r8g.16xlarge, every one with a wrong sha256; 6 cores in rpmalloc's
# _rpmalloc_deallocate_small_or_medium (freeing ChunkData via Cache::clear on the main thread), 3 in
# __aarch64_cas4_acq: a race in 0.14.5's bundled rpmalloc on aarch64.
# Same conditions as probe (g): lad_identity exactly (IDL = nproc/(P+2) = 6 lanes, P = 8, lane l
# taking jobs n = l + 6k, each GNU gzip -dc FILE | sha256sum then rapidgzip -d -c -P 8 FILE |
# sha256sum on the same c10 file on /dev/shm), cores to /dev/shm, gdb on failure, pushed as it
# goes, the same stop rule, TTL 150 min. The rapidgzip of a job alternates between two variants:
#   a  0.14.5-norpmalloc: 0.14.5 built from its sdist with rpmalloc off (scripts/g3/rg-build.sh;
#      ISA-L stays off as in the PyPI aarch64 wheel: 0.14.5 cannot build it on aarch64). Against
#      the crashing wheel it differs by rpmalloc off and a different toolchain (gcc 11.5, AL2023,
#      the system python; the wheel: the manylinux toolchain), not a single-lever change. Cached by recipe sha256 in
#      the results bucket's aws-kraken2/data/rg-build/ (the input-path sweep, #90, reuses the same wheel).
#   b  0.16.0: the PyPI cp39 manylinux aarch64 wheel, --require-hashes (rpmalloc on, ISA-L on).
# If a's build fails, every job runs b and a is reported build-failed (its build log streamed).
# Resolution: at probe (g)'s rate, 9/3588, n jobs of a variant see no crash with probability
# exp(-(9/3588) x n); the plan line streams the expected n per variant (from probe (g)'s measured
# 12.3 s per step and the loop time left after the build), progress lines re-project it from this
# run's steps, and each variant's summary says whether its null resolves (<= 0.05).
# make rehearse seams (AK2_REHEARSE_*, refused by run.sh in a spec's env): LOOP_S, LANES, SHM,
# MAXCORES, PUSH_N, PROGRESS_S (as probe (g)), and rg-build.sh's RGBUILD_SDIST_SHA256.
W=$HOME/ak2; mkdir -p "$W"
T_START=$(date +%s)
SHA=${AK2_RUN_ID##*-}
B=aws-kraken2-942542972736-us-west-2; CK=aws-kraken2/data/cohort
RGCACHE=s3://$B/aws-kraken2/data/rg-build
P=8; JOB_TIMEOUT=300; KILL_GRACE=30
TTL_S=9000; MARGIN_S=900; WRAP_S=120; LAUNCH_LEAD_S=120   # the spec's TTL (150m); >= 15 min left at the end
PRIOR_JOB_S=12.3; RATE_N=9; RATE_D=3588   # probe (g)'s measured mean step and crash rate (results/g3/20261018-184334-cc920a8)
RG16_VERSION=0.16.0
# sha256 of rapidgzip-0.16.0-cp39-cp39-manylinux_2_26_aarch64.manylinux_2_28_aarch64.whl (PyPI's
# JSON API, checked on 2026-10-18 by hashing the downloaded wheel): pip --require-hashes accepts only it.
RG16_HASH=2c3d75cb314b6dc28cf8fa238ff56f5ffae142af581f531fc674229184386f1d
MAXCORES=${AK2_REHEARSE_MAXCORES:-6}; PUSH_N=${AK2_REHEARSE_PUSH_N:-100}; PROGRESS_S=${AK2_REHEARSE_PROGRESS_S:-300}
NPROC=$(nproc)
LANES=$(( NPROC / (P + 2) )); [ "$LANES" -lt 1 ] && LANES=1
[ -n "${AK2_REHEARSE_LANES:-}" ] && LANES=$AK2_REHEARSE_LANES
J="$W/rgfix.jsonl"; : > "$J"
emit() { printf '%s\n' "$1" >> "$J"; printf 'probe-rgfix %s\n' "$1"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
CORE_DIR=/dev/shm/cores; PREV_CP=""
restore_cp() {
  [ -n "$PREV_CP" ] || return 0
  sudo -n sysctl -q -w "kernel.core_pattern=$PREV_CP" > /dev/null 2>&1
  local now_cp; now_cp=$(cat /proc/sys/kernel/core_pattern)
  emit "$(jq -nc --arg prev "$PREV_CP" --arg now "$now_cp" '{kind:"restore", core_pattern_prev:$prev, core_pattern_now:$now, restored:($prev == $now)}')"
  PREV_CP=""
}
fail() { ak2_say "ERROR: $*"; restore_cp; ak2_push "$J" rgfix.jsonl > /dev/null; exit 1; }
meminfo() {
  emit "$(awk -v l="$1" '/^(MemTotal|MemFree|MemAvailable|Cached|Shmem|Dirty|Writeback):/ {gsub(":", "", $1); kv = kv sprintf(",\"%s_kb\":%s", $1, $2)} END {printf "{\"kind\":\"meminfo\",\"at\":\"%s\"%s}", l, kv}' /proc/meminfo)"
}
ak2_say "shell flags $- (body start)"
# lad_identity's lane count on the crashing type: a different count is a different load.
[ "${AK2_INSTANCE_TYPE:-}" != r8g.16xlarge ] || [ "$LANES" = 6 ] || fail "r8g.16xlarge with nproc $NPROC gives $LANES lanes, want lad_identity's 6"

ak2_phase setup
sudo -n dnf install -y -q git gzip python3-pip perl jq gdb zstd tar findutils procps-ng util-linux file > "$W/dnf.log" 2>&1 || { tail -5 "$W/dnf.log"; fail "dnf failed"; }
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "cd repo"
declare -A RGV RGN WHL WSHA SO PYX OK
RGN[a]=0.14.5-norpmalloc; RGN[b]=$RG16_VERSION
# b: the 0.16.0 wheel, lever.sh's way: pip download --require-hashes, then install from it.
V16=$W/rg16-venv; WD16=$W/rg16-wheels; REQ16=$W/rg16-requirements.txt
printf 'rapidgzip==%s \\\n    --hash=sha256:%s\n' "$RG16_VERSION" "$RG16_HASH" > "$REQ16"
python3 -m venv "$V16" > /dev/null 2>&1 || fail "venv for rapidgzip $RG16_VERSION failed"
"$V16/bin/pip" download -q --no-deps --only-binary=:all: --require-hashes -r "$REQ16" -d "$WD16" > "$W/rg16-pip.log" 2>&1 &&
  "$V16/bin/pip" install -q --no-deps --no-index --only-binary=:all: --require-hashes --find-links "$WD16" -r "$REQ16" >> "$W/rg16-pip.log" 2>&1 ||
  { tail -5 "$W/rg16-pip.log"; fail "pip install --require-hashes rapidgzip==$RG16_VERSION failed"; }
RGV[b]=$V16/bin/rapidgzip; WHL[b]=$(find "$WD16" -name 'rapidgzip-*.whl' | head -1); OK[b]=1
# a: 0.14.5 without rpmalloc, from scripts/g3/rg-build.sh (cached by recipe sha256). Its time
# counts against the TTL: measured, and in the plan line.
ak2_phase build
TB0=$(date +%s)
scripts/g3/rg-build.sh "$W/rgbuild" "$RGCACHE" > "$W/rgbuild.out" 2> "$W/rgbuild.err"; BRC=$?
BUILD_S=$(( $(date +%s) - TB0 ))
BREC=$(sed -n 's/^rg-build //p' "$W/rgbuild.out" | tail -1)
[ -n "$BREC" ] || BREC=$(jq -nc --arg e "$(tail -c 600 "$W/rgbuild.err")" '{kind:"rg-build", status:"failed", note:("no record: " + $e)}')
emit "$(jq -c --argjson rc "$BRC" --argjson s "$BUILD_S" '. + {exit:$rc, wall_seconds:$s}' <<< "$BREC")"
# rg-build.sh's cache requests: a hit is 2 GETs (build.json, wheel); a miss is 1 GET (404), and 2 PUTs once stored.
case $(jq -r '.cache // "none"' <<< "$BREC") in
  hit) ak2_req GetObject 2 "$B" ;;
  stored) ak2_req GetObject 1 "$B"; ak2_req PutObject 2 "$B" ;;
  "store failed") ak2_req GetObject 1 "$B"; ak2_req PutObject "$(jq -r '.cache_puts // 1' <<< "$BREC")" "$B" ;;
  *) ak2_req GetObject 1 "$B" ;;
esac
[ -s "$W/rgbuild/build.log" ] && ak2_push "$W/rgbuild/build.log" rg-build.log > /dev/null
if [ "$BRC" = 0 ] && [ "$(jq -r .status <<< "$BREC")" = ok ]; then
  WHL[a]=$(find "$W/rgbuild" -maxdepth 1 -name 'rapidgzip-0.14.5-*.whl' | head -1)
  VA=$W/rga-venv
  python3 -m venv "$VA" > /dev/null 2>&1 && "$VA/bin/pip" install -q --no-deps --no-index "${WHL[a]}" > "$W/rga-pip.log" 2>&1 &&
    RGV[a]=$VA/bin/rapidgzip && OK[a]=1 || OK[a]=0
  [ "${OK[a]}" = 1 ] && ak2_push "${WHL[a]}" "$(basename "${WHL[a]}")" > /dev/null
else
  OK[a]=0
fi
if [ "${OK[a]}" != 1 ]; then
  ak2_say "WARN: variant a (${RGN[a]}) build failed (exit $BRC); every job runs b. The build log follows."
  { tail -60 "$W/rgbuild/build.log" 2> /dev/null; cat "$W/rgbuild.err"; } | sed 's/^/rg-build-log | /'
fi
VARS=(); for v in a b; do [ "${OK[$v]}" = 1 ] && VARS+=("$v"); done
for v in "${VARS[@]}"; do
  vv=$("${RGV[$v]}" --version 2>&1 | head -1)
  SO[$v]=$(find "$(dirname "$(dirname "${RGV[$v]}")")" -name 'rapidgzip*.so' | head -1)
  PYX[$v]=$(readlink -f "$(dirname "${RGV[$v]}")/python")
  WSHA[$v]=$(sha256sum "${WHL[$v]}" | cut -d' ' -f1)
  emit "$(jq -nc --arg var "$v" --arg v "${RGN[$v]}" --arg rv "$vv" --arg path "${RGV[$v]}" --arg whl "$(basename "${WHL[$v]}")" --arg wsha "${WSHA[$v]}" \
    --arg so "${SO[$v]}" --arg sosha "$(sha256sum "${SO[$v]}" | cut -d' ' -f1)" --arg py "${PYX[$v]}" \
    --arg rpm "$(nm -D --defined-only "${SO[$v]}" 2> /dev/null | awk '{print $NF}' | grep -c -E '^(_?rpmalloc|rpfree|rprealloc|rpcalloc|rpaligned|rpmemalign|rpposix)')" \
    --arg isal "$(nm -D "${SO[$v]}" 2> /dev/null | grep -c -E 'isal_inflate|isal_deflate')" \
    --arg oss "$("${RGV[$v]}" --oss-attributions 2>&1 | grep -E '^# ' | tr '\n' ' ')" \
    '{kind:"tool", variant:$var, version:$v, reports:$rv, path:$path, wheel:$whl, wheel_sha256:$wsha, extension:$so, extension_sha256:$sosha,
      python:$py, rpmalloc_functions:($rpm|tonumber), isal_symbols:($isal|tonumber), oss_attributions:$oss}')"
done
DI=skipped
timeout 900 sudo -n dnf debuginfo-install -y -q python3 python3-libs glibc libstdc++ > "$W/debuginfo.log" 2>&1 && DI=ok || DI="failed rc $?"
emit "$(jq -nc --arg gdb "$(gdb --version 2> /dev/null | head -1)" --arg di "$DI" --arg ditail "$(tail -3 "$W/debuginfo.log" | tr '\n' ' ' | cut -c1-400)" \
  --arg kernel "$(uname -r)" --arg cpu "$(lscpu 2> /dev/null | awk -F: '/Model name/ {gsub(/^ +/, "", $2); print $2; exit}')" \
  --argjson nproc "$NPROC" --argjson lanes "$LANES" --argjson p "$P" --arg glibc "$(ldd --version 2> /dev/null | head -1)" --arg itype "${AK2_INSTANCE_TYPE:-}" \
  --arg vars "${VARS[*]}" \
  '{kind:"host", gdb:$gdb, debuginfo_install:$di, debuginfo_tail:$ditail, kernel:$kernel, cpu:$cpu, nproc:$nproc, lanes:$lanes, P:$p,
    lanes_rule:"lad_identity: IDL = nproc / (P + 2)", glibc:$glibc, instance_type:$itype, variants:($vars | split(" "))}')"
# Analysis bundles (each variant's .so, its python, libpython): pushed now.
for v in "${VARS[@]}"; do
  lp=$(ldd "${PYX[$v]}" 2> /dev/null | awk '/libpython/ {print $3; exit}')
  tar -cf - --dereference "${SO[$v]}" "${PYX[$v]}" ${lp:+"$lp"} 2> /dev/null | zstd -q -T0 -3 -o "$W/bundle-${RGN[$v]}.tar.zst" -f &&
    ak2_push "$W/bundle-${RGN[$v]}.tar.zst" "bundle-${RGN[$v]}.tar.zst" > /dev/null || ak2_say "WARN: bundle ${RGN[$v]} not pushed"
done

# ---- core capture: ulimit, core_pattern to tmpfs, and a positive control ----
ulimit -c unlimited 2> /dev/null || sudo -n prlimit --pid $$ --core=unlimited:unlimited
mkdir -p "$CORE_DIR" && chmod 1777 "$CORE_DIR" || fail "mkdir $CORE_DIR"
PREV_CP0=$(cat /proc/sys/kernel/core_pattern)
sudo -n sysctl -q -w "kernel.core_pattern=$CORE_DIR/core.%p.%e.%t" > /dev/null || fail "cannot set kernel.core_pattern"
PREV_CP=$PREV_CP0
CP=$(cat /proc/sys/kernel/core_pattern)
# The control: the python rapidgzip runs under SIGSEGVs itself and must leave a core gdb can open.
"${PYX[b]}" -c 'import os, signal; os.kill(os.getpid(), signal.SIGSEGV)' 2> /dev/null; src=$?
sleep 1
sc=$(find "$CORE_DIR" -name 'core.*' | head -1)
sg=""; [ -n "$sc" ] && sg=$(gdb -batch -nx -ex 'set pagination off' -ex bt "${PYX[b]}" "$sc" 2>&1 | grep -c '^#')
emit "$(jq -nc --arg prev "$PREV_CP0" --arg cp "$CP" --arg ulc "$(ulimit -c)" --arg ulh "$(ulimit -Hc)" --argjson rc "$src" \
  --arg core "$sc" --arg sz "$([ -n "$sc" ] && stat -c%s "$sc")" --arg frames "${sg:-0}" \
  --arg cd "$(systemctl is-active systemd-coredump.socket 2> /dev/null)" --arg pipe "$(cat /proc/sys/kernel/core_pipe_limit 2> /dev/null)" \
  '{kind:"core-control", core_pattern_prev:$prev, core_pattern:$cp, ulimit_c:$ulc, ulimit_hc:$ulh, systemd_coredump_socket:$cd,
    core_pipe_limit:$pipe, control_exit:$rc, control_core:$core, control_core_bytes:($sz|tonumber? // 0), gdb_frames:($frames|tonumber),
    ok:($rc == 139 and $core != "" and ($frames|tonumber) > 0)}')"
[ "$src" = 139 ] && [ -n "$sc" ] && [ "${sg:-0}" -gt 0 ] || fail "core capture control failed (exit $src, core '${sc}', gdb frames ${sg:-0})"
rm -f "$CORE_DIR"/core.*

ak2_phase fetch-inputs
IN=/dev/shm/ak2-in; [ -n "${AK2_REHEARSE_SHM:-}" ] && IN=$AK2_REHEARSE_SHM
mkdir -p "$IN" || fail "mkdir $IN"
mapfile -t FILES < <(awk -F'\t' 'NR > 1 && $1 >= 1 && $1 <= 10 {print $2 "_1.fastq.gz"; print $2 "_2.fastq.gz"}' results/cohort/PRJNA398089/runs.tsv)
[ "${#FILES[@]}" = 20 ] || fail "want 20 c10 files from runs.tsv, got ${#FILES[@]}"
scripts/g3/fetch.sh "$B" "$CK" "$IN" 8 "${FILES[@]}" > "$W/fetched.txt" 2>&1
FERR=$?
cat "$W/fetched.txt"
[ "$FERR" = 0 ] && [ "$(grep -vc ERROR "$W/fetched.txt")" = 20 ] || fail "input fetch failed"
ak2_req GetObject "$(awk '!/ERROR/{n += int(($2 + 8388607) / 8388608)} END{print n+0}' "$W/fetched.txt")" "$B"
ak2_req HeadObject 20 "$B"
ak2_say "inputs staged and verified: 20 files, $(awk '{s+=$2} END{printf "%.3f GB", s/1e9}' "$W/fetched.txt")"
meminfo after-fetch

ak2_phase reference
mkdir -p "$W/ref"; RPIDS=()
for ((l = 0; l < LANES; l++)); do
  (
    for ((i = l; i < ${#FILES[@]}; i += LANES)); do
      f=${FILES[$i]}; t0=$(now)
      g=$(gzip -dc "$IN/$f" | sha256sum | cut -d' ' -f1; exit "${PIPESTATUS[0]}"); gr=$?
      printf '%s\t%s\t%s\t%s\n' "$g" "$gr" "$t0" "$(now)" > "$W/ref/$f"
    done
  ) &
  RPIDS+=($!)
done
for p in "${RPIDS[@]}"; do wait "$p"; done   # by PID: a bare wait would also wait for the harness's children
declare -A REF
GZ_MAX=0
for f in "${FILES[@]}"; do
  IFS=$'\t' read -r g gr t0 t1 < "$W/ref/$f" || { g=missing; gr=-1; t0=0; t1=0; }
  REF[$f]=$g
  GZ_MAX=$(awk -v a="$GZ_MAX" -v b="$t0" -v c="$t1" 'BEGIN {d = c - b; printf "%d", (d > a ? d + 1 : a)}')
  emit "$(jq -nc --arg f "$f" --arg g "$g" --argjson gr "$gr" --arg t0 "$t0" --arg t1 "$t1" \
    '{kind:"reference", file:$f, tool:"gzip -dc", sha256:$g, exit:$gr, seconds:(($t1|tonumber)-($t0|tonumber))}')"
  [[ $g =~ ^[0-9a-f]{64}$ ]] && [[ $gr =~ ^(0|2)$ ]] || fail "GNU gzip reference failed on $f (exit $gr)"
done
ak2_push "$J" rgfix.jsonl > /dev/null

# ---- the loop's end, and the resolution it can reach (probe (g)'s rule) ----
T0_LOOP=$(date +%s)
BOOT=$(( T0_LOOP - $(cut -d. -f1 /proc/uptime) ))
TTL_END=$(( BOOT - LAUNCH_LEAD_S + TTL_S ))
LAST_START=$(( TTL_END - MARGIN_S - WRAP_S - JOB_TIMEOUT - KILL_GRACE - GZ_MAX ))
T_END=$LAST_START; END_BASIS="ttl"
[ -n "${AK2_REHEARSE_LOOP_S:-}" ] && { T_END=$(( T0_LOOP + AK2_REHEARSE_LOOP_S )); END_BASIS="rehearsal"; }
[ "$T_END" -gt "$T0_LOOP" ] || fail "no loop time left (last start $T_END, now $T0_LOOP)"
emit "$(jq -nc --argjson lanes "$LANES" --argjson t0 "$T0_LOOP" --argjson tend "$T_END" --argjson ttl_end "$TTL_END" --argjson tstart "$T_START" \
  --argjson boot "$BOOT" --argjson gzmax "$GZ_MAX" --argjson prior "$PRIOR_JOB_S" --argjson rn "$RATE_N" --argjson rd "$RATE_D" \
  --argjson margin "$MARGIN_S" --argjson wrap "$WRAP_S" --argjson to "$JOB_TIMEOUT" --argjson kg "$KILL_GRACE" --arg basis "$END_BASIS" \
  --argjson ls "$LAST_START" --argjson build_s "$BUILD_S" --arg vars "${VARS[*]}" --arg na "${RGN[a]}" --arg nb "${RGN[b]}" \
  '($rn / $rd) as $rate | (($tend - $t0) * $lanes / $prior | floor) as $e | ($vars | split(" ")) as $vs
   | {kind:"plan", lanes:$lanes, variants:$vs, loop_start:$t0, last_start:$tend, end_basis:$basis, loop_s:($tend - $t0),
      ttl_rule_last_start:$ls, margin_s:$margin, wrap_s:$wrap, job_timeout_s:$to, kill_grace_s:$kg, ttl_end_est:$ttl_end, boot:$boot,
      worst_end_before_ttl_s:($ttl_end - ($tend + $gzmax + $to + $kg + $wrap)), gzip_max_s:$gzmax,
      build_s:$build_s, setup_s:($t0 - $tstart), prior_job_s:$prior, reference_rate:$rate, reference_rate_basis:"probe (g) 9/3588, results/g3/20261018-184334-cc920a8",
      expected_jobs:$e,
      per_variant:[ $vs[] as $v | (($e / ($vs | length)) | floor) as $n
        | {variant:$v, version:(if $v == "a" then $na else $nb end), expected_jobs:$n, p_no_crash_expected:((-$rate * $n) | exp),
           resolves_expected:(((-$rate * $n) | exp) <= 0.05)} ]}')"
ak2_say "loop: $LANES lanes (lad_identity: gzip -dc then rapidgzip -P $P on the same file), variants ${VARS[*]} alternating, last start $(date -u -d "@$T_END" +%FT%TZ 2> /dev/null || echo "$T_END") ($END_BASIS), cores to $CP"

# on_fail N VAR FILE PID: stream the failure's evidence: stderr, dmesg, and gdb on its core if any.
on_fail() {
  local n=$1 v=$2 f=$3 pid=$4 core k slot="" zc="" frames=0 dm
  core=$(find "$CORE_DIR" -maxdepth 1 -name "core.$pid.*" 2> /dev/null | head -1)
  dm=$(sudo -n dmesg 2> /dev/null | grep -E "\[$pid\]|rapidgzip|python" | tail -5)
  if [ -n "$core" ]; then
    mkdir -p "$W/gdb"
    gdb -batch -nx -ex 'set pagination off' -ex 'set print thread-events off' -ex 'info sharedlibrary' -ex 'p $_siginfo' \
      -ex 'echo ---- bt\n' -ex bt -ex 'echo ---- thread apply all bt\n' -ex 'thread apply all bt' -ex 'echo ---- info registers\n' \
      -ex 'info registers' -ex 'echo ---- x/16i $pc\n' -ex 'x/16i $pc' "${PYX[$v]}" "$core" > "$W/gdb/$n.txt" 2>&1
    frames=$(grep -c '^#' "$W/gdb/$n.txt")
    sed "s/^/rgfix-gdb $n | /" "$W/gdb/$n.txt"
    ak2_push "$W/gdb/$n.txt" "gdb/$n.txt" > /dev/null
    for ((k = 1; k <= MAXCORES; k++)); do mkdir "$W/coreslot.$k" 2> /dev/null && { slot=$k; break; }; done
    if [ -n "$slot" ]; then
      zc=cores/$(basename "$core")-job$n-${RGN[$v]}.zst
      zstd -q -T0 -3 "$core" -o "$core.zst" && ak2_push "$core.zst" "$zc" > /dev/null || zc="push failed"
      rm -f "$core.zst"
    fi
  fi
  emit "$(jq -nc --argjson n "$n" --arg var "$v" --arg v "${RGN[$v]}" --arg f "$f" --arg core "$core" --arg sz "$([ -n "$core" ] && stat -c%s "$core")" \
    --arg zc "$zc" --argjson frames "$frames" --arg err "$(head -c 2000 "$W/err/$n" 2> /dev/null)" --arg dm "$dm" \
    --arg sig "$(grep -m1 -oE 'si_addr = 0x[0-9a-f]+' "$W/gdb/$n.txt" 2> /dev/null)" \
    --arg top "$(grep -m1 '^#0 ' "$W/gdb/$n.txt" 2> /dev/null | cut -c1-300)" \
    '{kind:"failure", n:$n, variant:$var, version:$v, file:$f, core:(if $core == "" then null else $core end), core_bytes:($sz|tonumber? // 0),
      core_pushed:(if $zc == "" then null else $zc end), gdb_frames:$frames, frame0:(if $top == "" then null else $top end),
      fault:(if $sig == "" then null else $sig end), stderr:$err, dmesg:$dm}')"
  [ -n "$core" ] && rm -f "$core"
  return 0
}
# lane L: lad_identity's lane L, repeated: jobs n = L + LANES*k, file n mod 20; GNU gzip, then
# rapidgzip; the variant alternates job by job (half the lanes start on each).
lane() {
  local l=$1 k=0 n v f h rc t0 t1 pid ok sig g gr gt0 gok
  while [ "$(date +%s)" -lt "$T_END" ]; do
    n=$((l + LANES * k))
    v=${VARS[$(( (k + l) % ${#VARS[@]} ))]}
    f=${FILES[$((n % ${#FILES[@]}))]}
    gt0=$(now)
    g=$(gzip -dc "$IN/$f" | sha256sum | cut -d' ' -f1; exit "${PIPESTATUS[0]}"); gr=$?
    gok=false; [ "$g" = "${REF[$f]}" ] && gok=true
    t0=$(now)
    h=$(timeout -s ABRT -k "$KILL_GRACE" "$JOB_TIMEOUT" sh -c 'echo $$ > "$0"; exec "$@"' "$W/pid/$n" "${RGV[$v]}" -d -c -P "$P" "$IN/$f" 2> "$W/err/$n" |
      sha256sum | cut -d' ' -f1; exit "${PIPESTATUS[0]}"); rc=$?
    t1=$(now)
    pid=$(cat "$W/pid/$n" 2> /dev/null); rm -f "$W/pid/$n"
    ok=false; [ "$h" = "${REF[$f]}" ] && ok=true
    sig=null; [ "$rc" -gt 128 ] && [ "$rc" -lt 160 ] && sig=$((rc - 128))
    emit "$(jq -nc --argjson n "$n" --argjson lane "$l" --arg var "$v" --arg v "${RGN[$v]}" --arg f "$f" --argjson p "$P" --argjson rc "$rc" --argjson sig "$sig" \
      --arg h "$h" --argjson ok "$ok" --arg t0 "$t0" --arg t1 "$t1" --arg pid "$pid" --arg g "$g" --argjson gr "$gr" --argjson gok "$gok" --arg gt0 "$gt0" \
      '{kind:"job", n:$n, lane:$lane, mode:"identity", variant:$var, version:$v, file:$f, P:$p, exit:$rc, signal:$sig, timeout:($rc == 124), sha256:$h, match:$ok,
        seconds:(($t1|tonumber)-($t0|tonumber)), t0:($t0|tonumber), pid:($pid|tonumber? // null),
        gzip_sha256:$g, gzip_exit:$gr, gzip_match:$gok, gzip_seconds:(($t0|tonumber)-($gt0|tonumber)),
        step_seconds:(($t1|tonumber)-($gt0|tonumber))}')"
    if [ "$rc" != 0 ] || [ "$ok" != true ] || [ "$gok" != true ]; then
      ak2_say "FAILURE job $n: rapidgzip ${RGN[$v]} -P $P $f exit $rc, sha256 ${h:0:16} (match $ok; gzip match $gok)"
      on_fail "$n" "$v" "$f" "$pid"
      : > "$W/push-now"
    else
      rm -f "$W/err/$n"
    fi
    k=$((k + 1))
  done
}
tally() {
  jq -r 'select(.kind == "job") | [.variant, .version, .exit, .match, .gzip_match] | @tsv' "$J" | awk -F'\t' '
    {k = $1 "\t" $2; jobs[k]++; if ($3 != 0) nz[k]++; if ($3 > 128 && $3 < 160) cr[k]++; if ($3 == 124) to[k]++; if ($4 != "true") ws[k]++; if ($5 != "true") gm[k]++}
    END {print "variant\tversion\tjobs\tnonzero_exit\tcrashes\ttimeouts\twrong_sha\tgzip_mismatch"; for (k in jobs) printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\n", k, jobs[k], nz[k], cr[k], to[k], ws[k], gm[k]}' |
    { IFS= read -r h; echo "$h"; sort; } > "$W/rgfix-tally.tsv"
}
# progress: per variant, jobs so far, the measured mean step and the projection to LAST_START.
progress() {
  jq -c -s --argjson lanes "$LANES" --argjson now "$(date +%s)" --argjson tend "$T_END" --argjson rn "$RATE_N" --argjson rd "$RATE_D" --arg vars "${VARS[*]}" \
    '[.[] | select(.kind == "job")] as $j | ($rn / $rd) as $rate | ($vars | split(" ")) as $vs | ($j | length) as $c
     | (if $c > 0 then ($j | map(.step_seconds) | add / $c) else null end) as $m
     | (if $m then ((([$tend - $now, 0] | max) * $lanes / $m / ($vs | length)) | floor) else null end) as $more
     | {kind:"progress", jobs:$c, mean_step_s:$m,
        per_variant:[ $vs[] as $v | ($j | map(select(.variant == $v))) as $x | (if $more then (($x | length) + $more) else null end) as $proj
          | {variant:$v, jobs:($x | length), crashes:($x | map(select(.signal != null)) | length),
             failures:($x | map(select(.exit != 0 or (.match | not) or (.gzip_match | not))) | length),
             projected_jobs:$proj, p_no_crash_projected:(if $proj then ((-$rate * $proj) | exp) else null end),
             resolves_projected:(if $proj then (((-$rate * $proj) | exp) <= 0.05) else null end)} ]}' "$J"
}
ak2_phase loop
meminfo loop-start
mkdir -p "$W/pid" "$W/err"
LPIDS=()
for ((l = 0; l < LANES; l++)); do lane "$l" & LPIDS+=($!); done
last=0; lastp=$(date +%s)
alive() { local p; for p in "${LPIDS[@]}"; do kill -0 "$p" 2> /dev/null && return 0; done; return 1; }
while alive; do
  sleep 5
  c=$(grep -c '"kind":"job"' "$J")
  if [ "$c" -ge $((last + PUSH_N)) ] || [ -e "$W/push-now" ]; then
    rm -f "$W/push-now"; tally
    ak2_push "$W/rgfix-tally.tsv" rgfix-tally.tsv > /dev/null; ak2_push "$J" rgfix.jsonl > /dev/null
    last=$c
  fi
  if [ $(( $(date +%s) - lastp )) -ge "$PROGRESS_S" ]; then
    emit "$(progress)"; meminfo progress; lastp=$(date +%s)
  fi
done
for p in "${LPIDS[@]}"; do wait "$p"; done

ak2_phase summary
meminfo end
tally
# Per variant: failed (any job with a non-zero exit, a wrong sha256 or a gzip mismatch: a wrong
# output with exit 0 is a failure too), or a null that resolves (no failure, and P(no crash at
# probe (g)'s 9/3588 over its jobs) <= 0.05: the fix is supported at 5%), or a null that does not;
# a variant that did not run says why. (a)'s verdict names both of its differences from the wheel.
for v in a b; do
  jq -c -s --arg var "$v" --arg v "${RGN[$v]}" --arg ran "${OK[$v]:-0}" --argjson rn "$RATE_N" --argjson rd "$RATE_D" --argjson lanes "$LANES" \
    --arg bstatus "$(jq -r '.status // "failed"' <<< "$BREC")" \
    '[.[] | select(.kind == "job" and .variant == $var)] as $x | ($rn / $rd) as $rate | ($x | length) as $c
     | ((-$rate * $c) | exp) as $p0 | ($x | map(select(.signal != null)) | length) as $cr
     | ($x | map(select(.exit != 0 or (.match | not) or (.gzip_match | not))) | length) as $nf
     | (if $var == "a" then "rpmalloc off and a different toolchain (gcc 11.5, AL2023), not a single-lever change" else "0.16.0: release, rpmalloc version and ISA-L together" end) as $diff
     | {kind:"summary", variant:$var, version:$v, mode:"identity", lanes:$lanes, ran:($ran == "1"),
        build:(if $var == "a" then $bstatus else "pypi wheel" end), jobs:$c,
        differs_from_crashing_wheel_by:$diff, failures:$nf, crashes:$cr, sigsegv:($x | map(select(.signal == 11)) | length),
        timeouts:($x | map(select(.timeout)) | length), nonzero_exit:($x | map(select(.exit != 0)) | length),
        wrong_sha:($x | map(select(.match | not)) | length), wrong_sha_exit0:($x | map(select(.exit == 0 and (.match | not))) | length),
        gzip_mismatch:($x | map(select(.gzip_match | not)) | length),
        crash_rate:(if $c > 0 then $cr / $c else null end), mean_step_s:(if $c > 0 then ($x | map(.step_seconds) | add / $c) else null end),
        reference_rate:$rate, p_no_crash_at_reference_rate:(if $c > 0 then $p0 else null end), null_resolves:($c > 0 and $nf == 0 and $p0 <= 0.05),
        verdict:(if $ran != "1" then "not run: build failed (see the rg-build line and rg-build-log)"
                 elif $nf > 0 then "failed (\($cr) crashes, \($nf) failures incl. wrong output): not a fix"
                 elif $p0 <= 0.05 then "no failure; the null resolves (P(no crash at 9/3588) <= 0.05): the fix is supported (\($diff))"
                 else "no failure; the null does NOT resolve (P(no crash at 9/3588) > 0.05)" end)}' "$J" > "$W/summary-$v.json"
  emit "$(cat "$W/summary-$v.json")"
done
restore_cp
ak2_phase push
ak2_push "$W/rgfix-tally.tsv" rgfix-tally.tsv > /dev/null
ak2_push "$J" rgfix.jsonl || exit 1
for v in a b; do ak2_say "variant $v (${RGN[$v]}): $(jq -r '"\(.verdict); \(.jobs) jobs, \(.crashes) crashes"' "$W/summary-$v.json")"; done
ak2_say "rgfix probe done: $(grep -c '"kind":"failure"' "$J") failures, $(find "$W" -maxdepth 1 -name 'coreslot.*' | wc -l) cores pushed"
[ "$(grep -c '"kind":"summary"' "$J")" = 2 ] || exit 1
exit 0

