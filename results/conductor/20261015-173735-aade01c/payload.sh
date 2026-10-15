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

# The conductor (#77; runbook docs/conductor.md): make ladder-campaign off the laptop, on a small
# Graviton instance launched by make run GATE=conductor SPEC=runs/conductor*.json. Generated by
# scripts/mkspec-conductor.sh; the campaign's arguments are the parameter block below (in the
# payload, never in env, so user data stays small). Runs after scripts/preamble.sh: set +e, the log
# streams to the run prefix, the aws shim allows only the declared buckets.
#   setup     wait for the ak2-conductor instance role (run.sh swaps it in after launch), packages,
#             clone at the run's commit (and upstream at the pin, for run.sh's pin identity), the
#             pinned tools of scripts/conductor.tools.tsv by sha256, the drain poller and the stager
#   probe     (DRY_MAKE_RUN=1) DRY_RUN=1 make run of the cheapest planned rung: spawn's sizing,
#             cost and quota checks and user-data measure under the instance role; launches nothing
#   campaign  make ladder-campaign COHORT=... (DRY_RUN=1: the plan only)
#   stage     the last staging pass; conductor.json says ended
# Staging (s3://<results bucket>/<root>/results-staging/<this run id>/, make harvest's input):
# tree/<path> for every file the campaign added to the clone (git status: untracked). A run or
# cohort dir (results/<gate>/<yyyymmdd-hhmmss>-...) is staged only once it is finalised (its
# manifest has manifest_finalised_at, or it has cohort.json): run.sh and run-multi.sh delete the
# dirs of refused or DRY_RUN launches, and those must never reach the stage. Each staged dir is
# synced with --delete, so a file removed after finalisation leaves the stage too. tracked.patch
# (with tracked.patch.sha256) for scripts/lib/g3_defects.tsv, the one tracked file the campaign may
# change; any other tracked change is listed in conductor.json (unexpected_tracked), and make
# harvest refuses it. changes.tsv (sha256, bytes, path of each staged file), campaign.log
# (streamed), conductor.json (state). Re-staged every STAGE_EVERY s and after the campaign. DRAIN there (make ladder-campaign-drain CAMPAIGN=<this run id>) is copied
# to the campaign's local flag within DRAIN_POLL_S s; the campaign then launches nothing more and
# exits 4 once its runs in flight are recorded. The body exits 0 when the campaign exits 0 or 4.
# make rehearse-conductor seams (AK2C_*; run.sh refuses them in a spec's env, so on AWS they are
# unset): AK2C_REHEARSE=1 (no dnf, no tool downloads: stubs in AK2C_TOOLS_BIN), AK2C_REPO_URL, AK2C_UPSTREAM_URL,
# AK2C_STAGE_UNFILTERED=1 (stage every untracked dir, unfinalised included: the rehearsal's B1 control),
# AK2C_ROLE_WAIT (tries, 5 s apart; 120), and DRAIN_POLL_S (30), STAGE_EVERY (60), DEADLINE_MARGIN_S (900).
# Conductor parameters (scripts/mkspec-conductor.sh; TTL 1440m and cost_limit $2.16 at $0.08976/h for m8g.large: runaway backstops):
COHORT=10; RUNGS=""; REPS=2; CONCURRENCY=1; FAMILY_LIMITS=""; DRY_RUN=; DRY_MAKE_RUN=1; TTL_S=86400
W=$HOME/ak2c; mkdir -p "$W"
ak2_phase setup
SHA7=$(echo "$AK2_RUN_ID" | cut -d- -f3)
STAGE="${AK2_S3_PREFIX%/*/*}/results-staging/$AK2_RUN_ID"
CRC=""; STATE=setup; FULL=""; TOOLS='{}'; CAMPAIGN_TS=""; BG=()
status() {  # status STATE [ended]: conductor.json, here and in the staging prefix
  STATE=$1
  jq -n --arg run "$AK2_RUN_ID" --arg sha "$FULL" --arg state "$STATE" --arg stage "$STAGE" --arg ts "$CAMPAIGN_TS" \
    --arg crc "$CRC" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson tools "$TOOLS" --arg ended "${2:-}" \
    --arg iid "${AK2_INSTANCE_ID:-}" --arg deadline "${AK2_CAMPAIGN_DEADLINE:-}" --arg drained "$([ -e "$W/DRAIN" ] && head -1 "$W/DRAIN")" \
    --arg unexp "$(cat "$W/unexpected.txt" 2> /dev/null)" --arg cohort "$COHORT" \
    --arg p "COHORT=$COHORT; RUNGS=$RUNGS; REPS=$REPS; CONCURRENCY=$CONCURRENCY; FAMILY_LIMITS=$FAMILY_LIMITS; DRY_RUN=$DRY_RUN; DRY_MAKE_RUN=$DRY_MAKE_RUN" '{
      conductor_run_id:$run, commit:$sha, instance_id:$iid, state:$state, ended:($ended == "ended"), params:$p,
      cohort:($cohort|tonumber? // null), unexpected_tracked:($unexp | split("\n") | map(select(. != ""))),
      staging:$stage, campaign_ts:$ts, campaign_rc:(if $crc == "" then null else ($crc|tonumber) end),
      drain:(if $drained == "" then null else $drained end), deadline_epoch:(if $deadline == "" then null else ($deadline|tonumber) end),
      tools:$tools, updated_at:$at}' > "$W/conductor.json"
  aws s3 cp --only-show-errors "$W/conductor.json" "$STAGE/conductor.json" || ak2_say "WARN: could not stage conductor.json"
}
# stage_now: what the campaign added (finalised run dirs, the campaign's own files) and its
# g3_defects.tsv rows, to the staging prefix.
RUNDIR_RE='^results/[^/]+/[0-9]{8}-[0-9]{6}-[^/]+'
stage_ready() {  # a run or cohort dir is staged only once finalised
  [ "${AK2C_STAGE_UNFILTERED:-}" = 1 ] && return 0
  [ -f "$1/cohort.json" ] && return 0
  [ -f "$1/manifest.json" ] && [ -n "$(jq -r '.manifest_finalised_at // empty' "$1/manifest.json" 2> /dev/null)" ]
}
stage_now() {
  [ -d "$W/repo/.git" ] || return 0
  ( cd "$W/repo" || exit 1
    : > "$W/units.txt"; : > "$W/unexpected.txt"
    # Units: a run/cohort dir (when finalised), a campaign dir results/g3/ladder-campaign/<ts>, else the file.
    git ls-files --others --exclude-standard > "$W/untracked.txt" || exit 1
    while IFS= read -r f; do
      if [[ "$f" =~ $RUNDIR_RE ]]; then u=${BASH_REMATCH[0]}; stage_ready "$u" || continue
      elif [[ "$f" =~ ^results/g3/ladder-campaign/[0-9]{8}-[0-9]{6}/ ]]; then u=${BASH_REMATCH[0]%/}
      else u=$f; fi
      echo "$u"
    done < "$W/untracked.txt" | sort -u > "$W/units.txt"
    : > "$W/changes.tsv"
    while IFS= read -r u; do
      if [ -d "$u" ]; then
        if [ "${AK2C_STAGE_UNFILTERED:-}" = 1 ]; then aws s3 sync --only-show-errors --no-progress "$u" "$STAGE/tree/$u" || exit 1
        else aws s3 sync --only-show-errors --no-progress --delete "$u" "$STAGE/tree/$u" || exit 1; fi
        find "$u" -type f | sort
      else
        aws s3 cp --only-show-errors "$u" "$STAGE/tree/$u" || exit 1
        echo "$u"
      fi
    done < "$W/units.txt" | while IFS= read -r f; do
      printf '%s\t%s\t%s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c %s "$f")" "$f"; done > "$W/changes.tsv" || exit 1
    # Tracked changes: only scripts/lib/g3_defects.tsv goes into the patch.
    git diff --name-only HEAD | grep -vx 'scripts/lib/g3_defects.tsv' > "$W/unexpected.txt"
    git diff --binary HEAD -- scripts/lib/g3_defects.tsv > "$W/tracked.patch" || exit 1
    sha256sum "$W/tracked.patch" | cut -d' ' -f1 > "$W/tracked.patch.sha256"
    aws s3 cp --only-show-errors "$W/tracked.patch" "$STAGE/tracked.patch" || exit 1
    aws s3 cp --only-show-errors "$W/tracked.patch.sha256" "$STAGE/tracked.patch.sha256" || exit 1
    aws s3 cp --only-show-errors "$W/changes.tsv" "$STAGE/changes.tsv" || exit 1 ) ||
    { ak2_say "WARN: staging pass failed"; return 1; }
  [ -s "$W/unexpected.txt" ] && ak2_say "WARN: tracked files changed outside g3_defects.tsv (not staged; make harvest will refuse): $(tr '\n' ' ' < "$W/unexpected.txt")"
  [ -s "$W/campaign.log" ] && aws s3 cp --only-show-errors "$W/campaign.log" "$STAGE/campaign.log"
  return 0
}
finish() {  # finish RC: the last staging pass, conductor.json ended, background loops stopped
  local rc=$1 b
  # Stop the drain poller and the stager, each with its process group (an in-flight staging pass and
  # its aws children included), and wait until they are gone: the final pass must run alone.
  for b in "${BG[@]}"; do kill -TERM -- "-$b" 2> /dev/null; done
  for b in "${BG[@]}"; do
    for _ in $(seq 1 60); do kill -0 -- "-$b" 2> /dev/null || break; sleep 0.5; done
    kill -0 -- "-$b" 2> /dev/null && { ak2_say "WARN: background group $b still alive after TERM; KILL"; kill -KILL -- "-$b" 2> /dev/null; }
    wait "$b" 2> /dev/null
  done
  ak2_phase stage
  stage_now; status "${STATE}" ended
  ak2_say "conductor: exit $rc (campaign rc ${CRC:-none}); staged under $STAGE/"
  exit "$rc"
}
fail() { ak2_say "ERROR: $*"; STATE="failed: $*"; finish 1; }
[[ "$COHORT" =~ ^[1-9][0-9]*$ ]] && [[ "$REPS" =~ ^[1-9][0-9]*$ ]] && [[ "$CONCURRENCY" =~ ^[1-9][0-9]*$ ]] &&
  [[ "$DRY_RUN" =~ ^[01]?$ ]] && [[ "$DRY_MAKE_RUN" =~ ^[01]$ ]] && [[ "$TTL_S" =~ ^[1-9][0-9]*$ ]] || fail "bad parameter block"
[[ "$SHA7" =~ ^[0-9a-f]{7}$ ]] || fail "no commit in the run id $AK2_RUN_ID"
ak2_say "conductor $AK2_RUN_ID: commit $SHA7, cohort $COHORT, rungs '${RUNGS:-all}', reps $REPS, concurrency $CONCURRENCY, DRY_RUN=${DRY_RUN:-0}, DRY_MAKE_RUN=$DRY_MAKE_RUN; staging $STAGE/"
status starting

# ---- the instance role: run.sh replaces spawn's profile with ak2-conductor just after launch ----
ROLE_OK=0
for i in $(seq 1 "${AK2C_ROLE_WAIT:-120}"); do
  TOK=$(curl -sf -X PUT -m 5 http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
  IP=$(curl -sf -m 5 -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/iam/info | jq -r '.InstanceProfileArn // empty')
  WHO=$(aws sts get-caller-identity --query Arn --output text 2> /dev/null)
  if [[ "$IP" == */ak2-conductor ]] && [[ "$WHO" == *":assumed-role/ak2-conductor/"* ]]; then ROLE_OK=1; break; fi
  [ $((i % 6)) = 1 ] && ak2_say "waiting for the ak2-conductor role (profile '${IP:-none}', caller '${WHO:-none}')"
  sleep 5
done
[ "$ROLE_OK" = 1 ] || fail "the instance never got the ak2-conductor role (make conductor-iam; run.sh replaces the profile after launch)"
ak2_say "role: $WHO (profile $IP)"
aws s3 cp --only-show-errors "$STAGE/DRAIN" "$W/DRAIN" 2> /dev/null && { ak2_say "drain flag already set in $STAGE/DRAIN: nothing to do"; STATE=drained-before-start; finish 0; }

# ---- packages, the clone, the pinned tools ----
if [ "${AK2C_REHEARSE:-}" != 1 ]; then
  sudo -n dnf install -y -q git jq make tar gzip unzip findutils perl-Digest-SHA python3 > "$W/dnf.log" 2>&1 ||
    { tail -5 "$W/dnf.log"; fail "dnf install failed"; }
fi
git clone -q "${AK2C_REPO_URL:-https://github.com/scttfrdmn/aws-kraken2.git}" "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA7" || fail "checkout $SHA7 failed (is it pushed?)"
FULL=$(git -C "$W/repo" rev-parse HEAD)
[ "${FULL:0:7}" = "$SHA7" ] || fail "checked out $FULL, not $SHA7"
cd "$W/repo" || fail "no repo"
. scripts/pin.env
. scripts/paths.sh
# pin.env's UPSTREAM_REPO is the full clone URL (as oracle-build.sh uses it); the rehearsal overrides
# it, so the default is logged and the rehearsal checks it against pin.env.
ak2_say "upstream: default $UPSTREAM_REPO at $UPSTREAM_PIN"
git clone -q "${AK2C_UPSTREAM_URL:-$UPSTREAM_REPO}" "$ORACLE_SRC" || fail "upstream clone failed"
# The pinned tools (make tools, with Go): run.sh and run-multi.sh take spawn and truffle from
# AK2_TOOLS_BIN only (scripts/lib/tools_pin.sh).
GOV=$(awk -F'\t' '$1 == "go" {print $2; exit}' scripts/conductor.tools.tsv)
if [ "${AK2C_REHEARSE:-}" != 1 ]; then
  export AK2_TOOLS_BIN="$W/repo/bin"
  scripts/tools.sh --go || fail "make tools (spawn, truffle, go by sha256) failed"
else
  export AK2_TOOLS_BIN="${AK2C_TOOLS_BIN:?the rehearsal sets AK2C_TOOLS_BIN}"
fi
export PATH="$AK2_BIN:$AK2_TOOLS_BIN:$W/repo/.cache/tools/go-$GOV/go/bin:$PATH" GOPATH="$W/gopath" GOMODCACHE="$W/gopath/pkg/mod" GOCACHE="$W/gocache"
hash -r
[ "$(command -v aws)" = "$AK2_BIN/aws" ] || fail "the aws shim is not first on PATH"
v() { "$@" 2>&1 | head -1 | tr -d '\r'; }
TOOLS=$(jq -n --arg spawn "$("$AK2_TOOLS_BIN/spawn" version 2> /dev/null | awk '/Version:/{print $2}')" \
  --arg truffle "$("$AK2_TOOLS_BIN/truffle" version 2> /dev/null | awk '/Version:/{print $2}')" --arg go "$(v go version)" \
  --arg aws "$(v "$AK2_REAL_AWS" --version)" --arg git "$(v git --version)" --arg jq "$(v jq --version)" \
  --arg python "$(v python3 --version)" --arg make "$(v make --version)" --arg kernel "$(uname -r)" \
  '{spawn:$spawn, truffle:$truffle, go:$go, aws:$aws, git:$git, jq:$jq, python:$python, make:$make, kernel:$kernel}')
ak2_say "tools: $(echo "$TOOLS" | jq -c .)"
while IFS=$'\t' read -r tool ver _; do
  case "$tool" in spawn|truffle) [ "$(echo "$TOOLS" | jq -r ".$tool")" = "$ver" ] || fail "$tool is $(echo "$TOOLS" | jq -r ".$tool"), want $ver" ;; esac
done < scripts/conductor.tools.tsv
. scripts/lib/tools_pin.sh
ak2_pin_tools "$W/repo" || fail "the pinned tools do not check (above)"
for t in spawn truffle go aws git jq python3 make shasum curl; do command -v "$t" > /dev/null || fail "$t not on PATH"; done
# scripts/udsize links spawn's whole dependency tree. run.sh builds it on every launch; built here once,
# one package at a time (GOFLAGS=-p=1, kept for the nested builds, which then hit GOCACHE), so it fails
# in setup and not inside the probe. On m8g.medium (3.7 GiB, no swap) the probe's parallel build froze
# the instance until its TTL (results/conductor/20261015-003557-bb04dfb).
export GOFLAGS=-p=1
UDT0=$(date +%s)
go build -C scripts/udsize -o "$W/repo/bin/udsize" . || fail "go build of scripts/udsize failed"
[ "${AK2C_REHEARSE:-}" = 1 ] || [ -x "$W/repo/bin/udsize" ] || fail "go build of scripts/udsize left no binary"
ak2_say "udsize: built in $(( $(date +%s) - UDT0 )) s (GOFLAGS=$GOFLAGS)"

# ---- the campaign's environment: the instance role, who finalises, the drain flag, the deadline ----
# The conductor's own launch passed its payload mode (url, from the laptop) in env; left set, the
# nested run.sh would take it as a choice and presign under this role (session token in user data;
# results/conductor/20261015-043304-ccbf8b1's probe: url, 15279 B).
ak2_say "payload: inherited AK2_PAYLOAD_GET=${AK2_PAYLOAD_GET:-unset}, unset (run.sh picks role under AK2_INSTANCE_ROLE=1)"
unset AK2_PAYLOAD_GET AK2_PAYLOAD_URL
export AK2_INSTANCE_ROLE=1 AK2_FINALISED_BY=conductor AK2_CONDUCTOR_RUN_ID="$AK2_RUN_ID" AK2_CAMPAIGN_DRAIN="$W/DRAIN"
DL=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$AK2_INSTANCE_ID" Name=key,Values=spawn:ttl-deadline \
  --query 'Tags[0].Value' --output text 2> /dev/null)
DLE=$(date -u -d "$DL" +%s 2> /dev/null)
[ -n "$DLE" ] || { DLE=$(( $(date +%s) + TTL_S )); ak2_say "WARN: no spawn:ttl-deadline tag ('$DL'); deadline from TTL_S"; }
# The conductor's own end: its last launch must be finalised, staged and the body done before it.
export AK2_CAMPAIGN_DEADLINE=$(( DLE - ${DEADLINE_MARGIN_S:-900} ))
ak2_say "deadline: TTL ends $(date -u -d "@$DLE" +%Y-%m-%dT%H:%M:%SZ); no launch whose TTL + finalisation ends after $(date -u -d "@$AK2_CAMPAIGN_DEADLINE" +%Y-%m-%dT%H:%M:%SZ)"
# Each loop in a process group of its own (job control on while they start), so finish() can stop
# the loop and whatever it is running (an aws s3 sync of a staging pass) before the final pass.
set -m
( while sleep "${DRAIN_POLL_S:-30}"; do
    [ -e "$W/DRAIN" ] && continue
    if aws s3 cp --only-show-errors "$STAGE/DRAIN" "$W/DRAIN.tmp" 2> /dev/null; then
      mv "$W/DRAIN.tmp" "$W/DRAIN"; ak2_say "drain: $STAGE/DRAIN found ($(head -1 "$W/DRAIN")); the campaign launches nothing more"
    fi
  done ) &
BG+=($!)
( while sleep "${STAGE_EVERY:-60}"; do stage_now; done ) > /dev/null 2>&1 &
BG+=($!)
set +m
status ready

# ---- the probe: run.sh's whole pre-launch path under the instance role, launching nothing ----
if [ "$DRY_MAKE_RUN" = 1 ]; then
  ak2_phase probe
  PROBE=$(for f in runs/g3-l-*-c"$COHORT".json; do
      [ -f "$f" ] || continue
      jq -r --arg f "$f" '"\(.lifecycle.cost_limit)\t\($f)"' "$f"; done | sort -g | head -1 | cut -f2)
  [ -n "$PROBE" ] || fail "no committed runs/g3-l-*-c$COHORT.json to probe"
  NP=$(python3 scripts/lib/ladder_levers.py spec-params "$PROBE" | jq -r .want_n)
  # In a clone of its own: run.sh and run-multi.sh create run dirs and remove them on DRY_RUN, and
  # nothing of that may touch the campaign's clone (or its stage).
  git clone -q --shared "$W/repo" "$W/probe" && git -C "$W/probe" checkout -q "$FULL" || fail "probe clone failed"
  ak2_say "probe: DRY_RUN=1 make run GATE=g3 SPEC=$PROBE NODES=$NP (in $W/probe)"
  ( cd "$W/probe" && K2_SHARED_ROOT="$W/repo" DRY_RUN=1 make run GATE=g3 SPEC="$PROBE" NODES="$NP" ) 2>&1 | tee "$W/probe.log"
  PRC=${PIPESTATUS[0]}
  ak2_say "probe: rc $PRC"
  [ "$PRC" = 0 ] || fail "the probe (DRY_RUN=1 make run of $PROBE) failed: rc $PRC ($W/probe.log, in the run log above)"
  grep 'payload: GET by role' "$W/probe.log" > /dev/null || fail "the probe's run.sh did not choose AK2_PAYLOAD_GET=role ($W/probe.log)"
fi

# ---- the campaign ----
ak2_phase campaign
status campaign
ARGS=(COHORT="$COHORT" REPS="$REPS" CONCURRENCY="$CONCURRENCY")
[ -n "$RUNGS" ] && ARGS+=(RUNGS="$RUNGS")
[ -n "$FAMILY_LIMITS" ] && ARGS+=(FAMILY_LIMITS="$FAMILY_LIMITS")
[ "$DRY_RUN" = 1 ] && ARGS+=(DRY_RUN=1)
ak2_say "campaign: make ladder-campaign ${ARGS[*]}"
make ladder-campaign "${ARGS[@]}" 2>&1 | tee "$W/campaign.log"
MRC=${PIPESTATUS[0]}
# make reports any failing recipe as 2; the campaign's own exit is its last line.
CRC=$(sed -n 's/^ladder-campaign: exit \([0-9][0-9]*\)$/\1/p' "$W/campaign.log" | tail -1)
CAMPAIGN_TS=$(sed -n 's/^ladder-campaign: campaign \([0-9]\{8\}-[0-9]\{6\}\): .*/\1/p' "$W/campaign.log" | head -1)
ak2_say "campaign: make rc $MRC, campaign exit ${CRC:-unknown}${CAMPAIGN_TS:+ (campaign $CAMPAIGN_TS)}"
[ -n "$CRC" ] || { CRC=$MRC; STATE="campaign ended without its exit line"; finish "${MRC:-1}"; }
case "$CRC" in
  0) STATE="campaign done" ;;
  4) STATE="campaign drained" ;;
  *) STATE="campaign exit $CRC" ;;
esac
case "$CRC" in 0|4) finish 0 ;; *) finish "$CRC" ;; esac
