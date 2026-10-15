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

# G3 ladder rung (#25 WP-7, #51; runbook docs/ladder.md): one body for both arms of both ladders
# (S -> S*: upstream kraken2 at the pin; S* -> O*: ours). Generated by scripts/g3/mkspec-ladder.sh
# from scripts/g3/ladder.levers.tsv; the rung's lever choices are the parameter block below (in the
# payload, never in env). The scripts/g3/lever.sh contract is the API for every deployment lever.
#
# Every run is cold and end to end. Phases, the same on both arms (the engine's order differs where
# its ETag check needs the loaded table):
#   setup        packages, clone at the run's commit, the classifier built from source (upstream at
#                the pin by scripts/oracle-build.sh, ours at this commit by make build), host tunes
#                (hosttune.sh: HOST_TUNES), storage (lv_nvme single for nvme; huge=always tmpfs),
#                the gunzip shim (lv_gunzip_shim)
#   fetch-db     lv_stage_db DB_STAGE (ranged-get: opts.k2d and taxo.k2d by s5cmd, hash.k2d is
#                loaded by the engine)
#   etag-hash.k2d  upstream and ours-plain: lv_etag on the staged hash.k2d; the engine: its own
#                in-memory check (AK2_ENGINE_VERIFY_ETAG=1), from the shard-load line to connect
#   fetch-inputs lv_fetch_inputs IN_FETCH IN_CLIENT into IN_DEST
#   identity     (GUNZIP != gzip only) rapidgzip -P k vs gzip -dc sha256 on every input (S5)
#   load         drop_caches first (a cold phase); Cached/Dirty/Writeback recorded; the classifiers
#                start; ends when the first reports the table loaded ("Loading database
#                information... done.", or the engine's shard-load line)
#   classify     until every classifier exits; each sample streams one "lad-sample {json}" line
#                (sha256 of --output and --report computed on the node before upload; no
#                classified/unclassified outputs are written)
#   upload-drain lv_upload_drain (OUT_UPLOAD; serial uploads ran between samples)
#   push         records pushed, host tunes restored, tmpfs unmounted
# Placement: samples split over REPLICAS groups (fleet rank r is group r / SHARDS, shard r % SHARDS)
# by PLACEMENT (mod: j mod K; lpt: heaviest first to the least-loaded), then over PROCS lanes
# (per-sample classifiers) or homed by the engine (cohort mode, INFLIGHT in flight).
# make rehearse seams (AK2_REHEARSE_*; run.sh refuses them in a spec's env, so on AWS they are
# unset): lever.sh's (NVME, S5CMD, S5CMD_TGZ, RAPIDGZIP, WHEELS), upstream-cohort.sh's RAMDB_ROOT,
# and here GO (a Go already on PATH), HT_ROOT (hosttune's tree), HASH_URL, SAMPLES and WEIGHTS.
# TTL 40m and cost_limit $0.53: runaway backstops sized by estimate; TTL = max(30 min, 2.5 x the estimated wall 926 s), rounded up to 10 min (scripts/lib/ladder_ttl.py), from the c1 runs of O3-n32 (O3-cost-n32 at c1 has the configuration of O3-n32): 20261012-034539-e16fec4-5ad1-n32,20261012-035504-e16fec4-cd89-n32 (the larger estimate: 20261012-034539-e16fec4-5ad1-n32): fixed part 282 s + per-sample part 644 s (the busiest of 1 replica(s): 10 sample(s), 110.2 M pairs, 8 lane(s), thread slowdown 8.00).
# Parameters (scripts/g3/mkspec-ladder.sh O O3-cost-n32 10; manifest.params, by scripts/lib/ladder_levers.py spec-params):
RUNG=O3-cost-n32; ARM=O; COHORT=10; WANT_N=32; CLASSIFIER=ours-engine; THREADS=vcpus/6; PROCS=1; DB_STAGE=ranged-get; DB_PLACE=memory; DB_LOAD=resident; HOST_TUNES=none; GUNZIP=rapidgzip-Pauto; IN_FETCH=lanes16; IN_CLIENT=default; IN_DEST=tmpfs; OUT_UPLOAD=s5cmd-overlap; REPLICAS=1; SHARDS=32; PLACEMENT=mod; INFLIGHT=8; SETUP=overlap; ETAG_CHECK=on
W=$HOME/ak2; mkdir -p "$W"
fail() { ak2_say "ERROR: $*"; exit 1; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
J="$W/lad.jsonl"; : > "$J"; LS="$W/lad-samples.jsonl"; : > "$LS"
emit() { printf '%s\n' "$2" >> "$J"; printf 'lad-%s %s\n' "$1" "$2"; }
# A lad-sample line (#52's contract v1, docs/ladder.md): streamed, and in out/lad-samples.jsonl.
emit_sample() {
  [ -n "$1" ] || { FAIL=1; ak2_err 1 "ladder: an empty lad-sample line (its jq failed)"; return 1; }
  printf '%s\n' "$1" >> "$LS"; emit sample "$1"
}
lad_push() { ak2_push "$J" lad.jsonl > /dev/null && ak2_push "$LS" lad-samples.jsonl > /dev/null; }
# Cold by construction (Law 4): nothing of this run is cached before it starts.
ak2_drop_caches

# ---- parameters ----
for k in RUNG ARM COHORT WANT_N CLASSIFIER THREADS PROCS DB_STAGE DB_PLACE DB_LOAD HOST_TUNES GUNZIP IN_FETCH \
         IN_CLIENT IN_DEST OUT_UPLOAD REPLICAS SHARDS PLACEMENT INFLIGHT SETUP ETAG_CHECK; do
  v=${!k:-}
  [ -n "$v" ] || fail "parameter $k is missing (generate the spec with scripts/g3/mkspec-ladder.sh)"
  case $v in @*) fail "parameter $k=$v is an unresolved placeholder" ;; esac
done
lad_is() { [[ $2 =~ ^($3)$ ]] || fail "parameter $1=$2 is not one of $3"; }
lad_is CLASSIFIER "$CLASSIFIER" 'upstream|ours-plain|ours-engine'
lad_is THREADS "$THREADS" 'vcpus|vcpus/[1-9][0-9]*|[1-9][0-9]*'
lad_is PROCS "$PROCS" 'vcpus/[1-9][0-9]*|[1-9][0-9]*'
lad_is DB_STAGE "$DB_STAGE" 'awscp-default|s5cmd|ranged-get'
lad_is DB_PLACE "$DB_PLACE" 'nvme|tmpfs|tmpfs-huge|memory'
lad_is DB_LOAD "$DB_LOAD" 'load|mmap|resident'
lad_is GUNZIP "$GUNZIP" 'gzip|rapidgzip-P([1-9][0-9]*|auto)'
lad_is IN_FETCH "$IN_FETCH" 'serial|lanes[1-9][0-9]*'
lad_is IN_DEST "$IN_DEST" 'nvme|tmpfs'
lad_is OUT_UPLOAD "$OUT_UPLOAD" 'awscp-default|s5cmd-serial|s5cmd-overlap|sdk-stream'
lad_is REPLICAS "$REPLICAS" '[1-9][0-9]*'
lad_is SHARDS "$SHARDS" '[1-9][0-9]*'
lad_is PLACEMENT "$PLACEMENT" 'mod|lpt'
lad_is INFLIGHT "$INFLIGHT" '-|vcpus/[1-9][0-9]*|[1-9][0-9]*'
lad_is SETUP "$SETUP" 'serial|overlap'
lad_is ETAG_CHECK "$ETAG_CHECK" 'on'
[ "$WANT_N" = $((REPLICAS * SHARDS)) ] || fail "WANT_N $WANT_N is not REPLICAS x SHARDS"
ENGINE=0; [ "$CLASSIFIER" = ours-engine ] && ENGINE=1
if [ "$ENGINE" = 1 ]; then
  [ "$DB_STAGE/$DB_PLACE/$DB_LOAD" = ranged-get/memory/resident ] || fail "the engine loads by ranged GETs into memory (DB_STAGE/PLACE/LOAD ranged-get/memory/resident)"
  [ "$PROCS" = 1 ] && [ "$INFLIGHT" != - ] || fail "the engine is one process per node (PROCS 1) with INFLIGHT samples in flight"
  case $OUT_UPLOAD in *-serial|awscp-default) fail "OUT_UPLOAD $OUT_UPLOAD is serial: it cannot hold back the engine's next sample" ;; esac
else
  [ "$DB_STAGE" != ranged-get ] && [ "$DB_PLACE" != memory ] && [ "$DB_LOAD" != resident ] || fail "ranged-get/memory/resident is the engine's load"
  [ "$SHARDS" = 1 ] && [ "$INFLIGHT" = - ] || fail "SHARDS and INFLIGHT are the engine's"
  [ "$OUT_UPLOAD" != sdk-stream ] || fail "sdk-stream is the engine's emitter"
  case $DB_PLACE in tmpfs*) [ "$DB_LOAD" = mmap ] || fail "a tmpfs table is used with --memory-mapping" ;; esac
fi
case $ARM/$CLASSIFIER in S/upstream|O/ours-*) ;; *) fail "ARM $ARM does not run CLASSIFIER $CLASSIFIER (S: upstream; O: ours)" ;; esac

# ---- the fleet ----
SHA=$(echo "${AK2_COHORT_ID:-}" | cut -d- -f3)
RANK=${AK2_ENGINE_RANK:-}; FLEET=${AK2_ENGINE_N:-}
[ -n "${AK2_COHORT_ID:-}" ] && [ -n "$RANK" ] && [ "$FLEET" = "$WANT_N" ] && [ -n "${AK2_COHORT_PREFIX:-}" ] ||
  fail "not a member of a $WANT_N-node cohort (make run GATE=g3 SPEC=... NODES=$WANT_N)"
GROUP=$((RANK / SHARDS)); SHARD=$((RANK % SHARDS))
set -- $AK2_DATASETS
U=${1#s3://}; RB=${U%%/*}; HK=${U#*/}; RP=${HK%/*}
U=${4#s3://}; B=${U%%/*}; CK=${U#*/}; CK=${CK%/}
OUTURL="$AK2_COHORT_PREFIX/out/$RUNG"
ak2_say "ladder $RUNG ($ARM, $CLASSIFIER) cohort $COHORT: rank $RANK of $FLEET (replica $GROUP, shard $SHARD of $SHARDS); commit $SHA; RODA $RB/$RP; samples $B/$CK"

ak2_phase setup
sudo -n dnf install -y -q git gcc-c++ make zlib-devel perl jq gzip tar findutils python3 util-linux > "$W/dnf.log" 2>&1 ||
  { tail -5 "$W/dnf.log"; fail "dnf install failed"; }
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "no repo"
REAL_GZIP=$(command -v gzip)
. scripts/g3/lever.sh || fail "lever.sh did not load"
HT_ROOT=${AK2_REHEARSE_HT_ROOT:-}; HT_DIR="$W/hosttune"
. scripts/g3/hosttune.sh
ht_init || fail "ht_init failed"
ht_apply "$HOST_TUNES"; HTRC=$?
ht_record setup
[ "$HTRC" = 0 ] || fail "host tunes $HOST_TUNES did not read back as wanted (hosttune-apply.tsv)"
NPROC=$(nproc)
# Derived per host (docs/ladder.md, "Derived parameters"): vcpus and vcpus/<k> (at least 1) are
# resolved here from this host's nproc, so a rung that changes the host carries S4's P x T as a
# ratio of vCPUs. lad-config records the PARAM and the value used.
lad_vc() { case $1 in vcpus) echo "$NPROC" ;; vcpus/*) local v=$(( NPROC / ${1#vcpus/} )); echo $(( v < 1 ? 1 : v )) ;; *) echo "$1" ;; esac; }
THREADS_PARAM=$THREADS PROCS_PARAM=$PROCS INFLIGHT_PARAM=$INFLIGHT
T=$(lad_vc "$THREADS"); PROCS=$(lad_vc "$PROCS"); [ "$INFLIGHT" != - ] && INFLIGHT=$(lad_vc "$INFLIGHT")
[ "$ENGINE" = 0 ] || [ "$PROCS" = 1 ] || fail "the engine is one process per node (PROCS resolved to $PROCS)"
AT_ONCE=$PROCS; [ "$ENGINE" = 1 ] && AT_ONCE=$INFLIGHT

# The classifier, built from source (in the background; SETUP=serial waits for it here, overlap at load).
lad_build() {
  if [ "$CLASSIFIER" = upstream ]; then scripts/oracle-build.sh; return; fi
  if [ -z "${AK2_REHEARSE_GO:-}" ]; then
    local gov; gov=$(awk '$1=="go"{print $2}' go.mod)
    curl -fsSL --retry 5 --retry-delay 5 "https://go.dev/dl/go$gov.linux-arm64.tar.gz" -o "$W/go.tgz" || return 1
    tar -xzf "$W/go.tgz" -C "$W" || return 1
    export PATH="$W/go/bin:$PATH"
  fi
  make build
}
# The build records when it ended (build.end), so the overlap it bought is in the record.
( lad_build; rc=$?; now > "$W/build.end"; exit "$rc" ) > "$W/build.out" 2>&1 &
BUILD_PID=$!
BUILT=0
lad_build_wait() {
  [ "$BUILT" = 1 ] && return 0
  local t0 t1; t0=$(now)
  wait "$BUILD_PID" || { tail -30 "$W/build.out"; fail "build of $CLASSIFIER failed"; }
  t1=$(now)
  BUILT=1
  if [ "$CLASSIFIER" = upstream ]; then
    K2DIR=$(scripts/oracle-build.sh 2> /dev/null) || fail "upstream build not found"
    K2="$K2DIR/kraken2"
    # The wrapper runs PATH=$KRAKEN2_DIR:$PATH: a gzip there would be found by upstream alone (docs/oracle.md).
    [ ! -e "$K2DIR/gzip" ] && [ ! -e "$K2DIR/bzip2" ] || fail "a gzip or bzip2 in KRAKEN2_DIR $K2DIR (a shim goes on PATH only)"
    ak2_say "upstream $(tr '\n' ';' < "$K2DIR/BUILD"); KRAKEN2_DIR has no gzip or bzip2"
  else
    OURS="$W/repo/bin/aws-kraken2"
    [ -x "$OURS" ] || fail "no $OURS"
    ak2_say "ours built at $(git rev-parse HEAD); $(go version 2> /dev/null || echo 'go: on PATH in the build only')"
  fi
  emit build "$(jq -nc --arg c "$CLASSIFIER" --arg s "$SETUP" --arg t0 "$t0" --arg t1 "$t1" --arg ph "$(cat "$AK2_STATE/phase" 2> /dev/null)" \
    --arg be "$(cat "$W/build.end" 2> /dev/null)" \
    '{kind:"build", classifier:$c, setup:$s, waited_in_phase:$ph, wait_start:($t0|tonumber), wait_end:($t1|tonumber),
      wait_s:(($t1|tonumber)-($t0|tonumber)), build_end:(if $be == "" then null else ($be|tonumber) end)}')"
}
[ "$SETUP" = serial ] && lad_build_wait

# The cohort: the first COHORT runs of the recorded cohort, as env.AK2_ACCESSIONS names them.
RUNS="$W/repo/results/cohort/PRJNA398089/runs.tsv"
mapfile -t SAMPLES < <(awk -F'\t' -v c="$COHORT" 'NR>1 && $1<=c {print $2}' "$RUNS")
mapfile -t PAIRS < <(awk -F'\t' -v c="$COHORT" 'NR>1 && $1<=c {print $4}' "$RUNS")
mapfile -t BYTES < <(awk -F'\t' -v c="$COHORT" 'NR>1 && $1<=c {print $7 + $10}' "$RUNS")
ACC=$("$W/repo/scripts/lib/accessions.sh" -r "$W/repo" "${AK2_ACCESSIONS:-}") || fail "env.AK2_ACCESSIONS '${AK2_ACCESSIONS:-}' does not resolve on the node"
[ "$ACC" = "${SAMPLES[*]}" ] || fail "env.AK2_ACCESSIONS '${AK2_ACCESSIONS:-}' does not name the first $COHORT runs of runs.tsv"
if [ -n "${AK2_REHEARSE_SAMPLES:-}" ]; then
  read -r -a SAMPLES <<< "$AK2_REHEARSE_SAMPLES"; read -r -a PAIRS <<< "$AK2_REHEARSE_WEIGHTS"
  BYTES=(); for j in "${!SAMPLES[@]}"; do BYTES+=(0); done
fi
NS=${#SAMPLES[@]}
[ "$NS" -gt 0 ] && [ "${#PAIRS[@]}" = "$NS" ] || fail "want $COHORT samples and weights, got $NS and ${#PAIRS[@]}"
# lad_assign K MODE J...: the bin (0..K-1) of each sample index J, in argument order; mod by position,
# lpt heaviest first (ties in order) to the least-loaded bin (ties to the lowest), as place.go.
lad_assign() {
  local k=$1 mode=$2; shift 2
  local i=0 j
  for j in "$@"; do echo "$j ${PAIRS[$j]} $i"; i=$((i + 1)); done |
    awk -v k="$k" -v m="$mode" '{j[NR]=$1; w[NR]=$2; p[NR]=$3} END {
      n = NR; for (b = 0; b < k; b++) L[b] = 0
      if (m == "mod") { for (i = 1; i <= n; i++) print j[i], p[i] % k; exit }
      for (i = 1; i <= n; i++) o[i] = i
      for (a = 2; a <= n; a++) { x = o[a]; c = a - 1; while (c >= 1 && (w[o[c]] < w[x] || (w[o[c]] == w[x] && o[c] > x))) { o[c+1] = o[c]; c-- } o[c+1] = x }
      for (a = 1; a <= n; a++) { i = o[a]; best = 0; for (b = 1; b < k; b++) if (L[b] < L[best]) best = b; L[best] += w[i]; print j[i], best }
    }'
}
ALLJ=(); for ((j = 0; j < NS; j++)); do ALLJ+=("$j"); done
MINE=()
while read -r j g; do [ "$g" = "$GROUP" ] && MINE+=("$j"); done < <(lad_assign "$REPLICAS" "$PLACEMENT" "${ALLJ[@]}" | sort -n)
[ "${#MINE[@]}" -gt 0 ] || fail "replica $GROUP of $REPLICAS has no samples at cohort $NS"

# Storage. nvme: one instance-store device (lv_nvme single; RAID0 is tuning, not stock: Scott 2026-10-09).
UC=scripts/upstream-cohort.sh
MOUNTS=()
if [ "$DB_PLACE" = nvme ] || [ "$IN_DEST" = nvme ]; then lv_nvme single /mnt/nvme || fail "lv_nvme failed"; fi
case $DB_PLACE in
  nvme) DBDIR="$LV_NVME/db" ;;
  # tmpfs: huge=never (the tmpfs default; S2b-ii); tmpfs-huge: huge=always (S2d).
  tmpfs) DBDIR=$($UC mount roda 1150g never) || fail "tmpfs for the table failed"; MOUNTS+=(roda) ;;
  tmpfs-huge) DBDIR=$($UC mount roda 1150g always) || fail "tmpfs for the table failed"; MOUNTS+=(roda) ;;
  memory) DBDIR="$W/db" ;;
esac
mkdir -p "$DBDIR" || fail "mkdir $DBDIR"
INB=0; INP=0
for j in "${MINE[@]}"; do INB=$((INB + BYTES[j])); INP=$((INP + PAIRS[j])); done
if [ "$IN_DEST" = nvme ]; then INROOT="$LV_NVME/work"; mkdir -p "$INROOT" || fail "mkdir $INROOT"
else
  # inputs + outputs (150 B per pair, as the generator's memory check) + 8 GiB, in GiB.
  ING=$(( (INB * 102 / 100 + INP * 150) / 1073741824 + 8 ))
  # The inputs tmpfs is huge=never on every rung: S2d turns huge pages on for the table only.
  INROOT=$($UC mount inputs "${ING}g" never) || fail "tmpfs for the inputs failed"; MOUNTS+=(inputs)
fi
INDIR="$INROOT/in"; OUTD="$INROOT/out"; SD="$W/lad"
mkdir -p "$INDIR" "$OUTD" "$SD/done" "$SD/ack" "$SD/err" "$SD/start" || fail "mkdir under $INROOT"

# The gunzip shim (S5): on PATH only. Pauto: clamp(floor(nproc / (2 x samples at once)), 1, 16)
# threads per mate (the wrapper opens one gzip -dc per mate).
GZK=""; GZMODE=gzip
case $GUNZIP in
  rapidgzip-Pauto) GZK=$(( NPROC / (2 * AT_ONCE) )); [ "$GZK" -lt 1 ] && GZK=1; [ "$GZK" -gt 16 ] && GZK=16; GZMODE=rapidgzip-P$GZK ;;
  rapidgzip-P*) GZK=${GUNZIP#rapidgzip-P}; GZMODE=$GUNZIP ;;
esac
lv_gunzip_shim "$GZMODE" || fail "lv_gunzip_shim $GZMODE failed"
SHIMGZ=$(command -v gzip)
DECOMP=(); [ "$GZMODE" != gzip ] && [ "$CLASSIFIER" != upstream ] && DECOMP=(AK2_DECOMPRESS=pipe)
emit config "$(jq -nc --arg rung "$RUNG" --arg arm "$ARM" --arg cl "$CLASSIFIER" --argjson cohort "$COHORT" --argjson rank "$RANK" \
  --argjson fleet "$FLEET" --argjson group "$GROUP" --argjson shard "$SHARD" --argjson nproc "$NPROC" --argjson t "$T" \
  --arg params "THREADS=$THREADS_PARAM PROCS=$PROCS_PARAM DB_STAGE=$DB_STAGE DB_PLACE=$DB_PLACE DB_LOAD=$DB_LOAD HOST_TUNES=$HOST_TUNES GUNZIP=$GUNZIP IN_FETCH=$IN_FETCH IN_CLIENT=$IN_CLIENT IN_DEST=$IN_DEST OUT_UPLOAD=$OUT_UPLOAD REPLICAS=$REPLICAS SHARDS=$SHARDS PLACEMENT=$PLACEMENT INFLIGHT=$INFLIGHT_PARAM SETUP=$SETUP ETAG_CHECK=$ETAG_CHECK" \
  --arg gz "$GZMODE" --arg decomp "${DECOMP[*]:-}" --arg type "${AK2_INSTANCE_TYPE:-}" --arg db "$DBDIR" --arg in "$INROOT" \
  --argjson mine "$(printf '%s\n' "${MINE[@]}" | jq -sc 'map(tonumber)')" --argjson inb "$INB" \
  --argjson procs "$PROCS" --arg inflight "$INFLIGHT" --arg gzk "$GZK" \
  --arg mem "$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2> /dev/null)" \
  '{kind:"config", rung:$rung, arm:$arm, classifier:$cl, cohort:$cohort, rank:$rank, fleet:$fleet, replica:$group, shard:$shard,
    instance_type:$type, nproc:$nproc, mem_total_kb:$mem, threads:$t, params:$params, gunzip_mode:$gz, ours_decompress:$decomp,
    db_dir:$db, work_dir:$in, replica_samples:$mine, replica_input_bytes:$inb,
    resolved:{threads:$t, procs:$procs, inflight:$inflight, gunzip_P:(if $gzk == "" then null else ($gzk|tonumber) end), nproc:$nproc}}')"
lad_push

ak2_phase fetch-db
case $DB_STAGE in
  awscp-default|s5cmd) lv_stage_db "$DB_STAGE" "s3://$RB/$RP/" "$DBDIR" || fail "lv_stage_db $DB_STAGE failed" ;;
  ranged-get)
    lv_stage_db s5cmd "s3://$RB/$RP/" "$DBDIR" opts.k2d taxo.k2d || fail "lv_stage_db s5cmd (opts, taxo) failed"
    aws s3api head-object --no-sign-request --bucket "$RB" --key "$RP/hash.k2d" > "$W/head-hash.json" || fail "head-object hash.k2d failed"
    ak2_req HeadObject 1 "$RB"
    ETAG=$(jq -r '.ETag | gsub("\"";"")' "$W/head-hash.json"); SIZE=$(jq -r .ContentLength "$W/head-hash.json")
    URL=${AK2_REHEARSE_HASH_URL:-"https://$RB.s3.$AK2_REGION.amazonaws.com/$RP/hash.k2d"}
    ak2_say "hash.k2d etag=$ETAG size=$SIZE: loaded by the engine's ranged GETs" ;;
esac
if [ "$ENGINE" = 0 ]; then
  lv_etag "$DBDIR/hash.k2d" "$(lv_db_etag "$DBDIR" hash.k2d)" || fail "hash.k2d does not match its ETag"
fi

ak2_phase fetch-inputs
NEED=("${MINE[@]}")
M="$W/cohort.tsv"
if [ "$ENGINE" = 1 ]; then
  # One cohort-mode invocation over this replica's samples; the engine homes each on a shard.
  : > "$M"
  for j in "${MINE[@]}"; do
    s=${SAMPLES[$j]}; o="$OUTD/$s/output"; r="$OUTD/$s/report"; cl=-
    [ "$OUT_UPLOAD" = sdk-stream ] && { o="$OUTURL/$s/output"; r="$OUTURL/$s/report"; cl=sdk; }
    mkdir -p "$OUTD/$s"
    printf '0\t%s\tparallel:%s\t%s\t%s\tweight=%s\t--threads\t%s\t--output\t%s\t--report\t%s\t%s\t%s\n' "$INFLIGHT" "$PLACEMENT" "$cl" "$s" \
      "${PAIRS[$j]}" "$T" "$o" "$r" "$INDIR/${s}_1.fastq.gz" "$INDIR/${s}_2.fastq.gz" >> "$M"
  done
  ak2_push "$M" "cohort.tsv" > /dev/null
  # What this shard reads must be exactly what the placement homes here; either call failing, or
  # the two disagreeing (an empty NEED while samples are homed here, say), is fatal.
  NOUT=$(python3 scripts/lib/cohort_place.py needs "$SHARDS" "$SHARD" "$M") || fail "cohort_place.py needs failed"
  HOUT=$(python3 scripts/lib/cohort_place.py table "$SHARDS" "$M") || fail "cohort_place.py table failed"
  NEEDS=(); [ -n "$NOUT" ] && mapfile -t NEEDS <<< "$NOUT"
  HOMES=(); mapfile -t HOMES < <(awk -F'\t' -v r="$SHARD" 'NR > 1 && $5 == r {print $2}' <<< "$HOUT")
  [ "$(printf '%s\n' "${NEEDS[@]}" | sort)" = "$(printf '%s\n' "${HOMES[@]}" | sort)" ] ||
    fail "shard $SHARD would read ${#NEEDS[@]} samples but is home to ${#HOMES[@]} (cohort_place.py needs vs table)"
  [ "${#MINE[@]}" -gt 0 ] && [ "$SHARDS" = 1 ] && [ "${#NEEDS[@]}" = 0 ] && fail "no inputs to read with ${#MINE[@]} samples planned"
  ak2_say "placement: shard $SHARD of $SHARDS is home to ${#HOMES[@]} of the replica's ${#MINE[@]} samples"
  NEED=()
  for s in "${NEEDS[@]}"; do for j in "${MINE[@]}"; do [ "${SAMPLES[$j]}" = "$s" ] && NEED+=("$j"); done; done
fi
: > "$W/inputs.txt"
for j in "${NEED[@]}"; do
  printf 's3://%s/%s/%s_1.fastq.gz\ns3://%s/%s/%s_2.fastq.gz\n' "$B" "$CK" "${SAMPLES[$j]}" "$B" "$CK" "${SAMPLES[$j]}" >> "$W/inputs.txt"
done
if [ "${#NEED[@]}" -gt 0 ]; then
  lv_fetch_inputs "$IN_FETCH" "$IN_CLIENT" "$INDIR" "$W/inputs.txt" || fail "input fetch failed"
fi
ak2_say "inputs: ${#NEED[@]} samples of ${#MINE[@]} in replica $GROUP, into $INDIR ($(stat -f -c %T "$INDIR" 2> /dev/null))"


# ---- load and classify (from here to the end marker: the functions scripts/tests/ladder_stream_test.sh drives) ----
# lad_mem LABEL: meminfo's page-cache state. Cached includes tmpfs (Shmem), so on a tmpfs rung it
# holds the staged table; the cold check is Cached - Shmem small, and Dirty and Writeback ~0.
lad_mem() {
  emit mem "$(awk -v l="$1" 'BEGIN{printf "{\"kind\":\"mem\",\"label\":\"%s\"", l}
    /^(MemTotal|MemAvailable|Cached|Dirty|Writeback|Shmem|ShmemHugePages|AnonHugePages):/ {sub(":", "", $1); printf ",\"%s_kb\":%s", $1, $2}
    END{print "}"}' /proc/meminfo 2> /dev/null)"
}
# lad_one J LANE (in a lane): one per-sample classifier invocation, upstream's or ours' plain path.
# Its stderr goes to a file and, line by line as written, into the run log. Order matters: the 2>
# process substitution forks with the stdout in effect at that point (the log), so it comes before
# > /dev/null (scripts/tests/ladder_stream_test.sh checks this by behaviour, and that the reverse
# order loses every line).
lad_one() {
  local j=$1 lane=$2 s=${SAMPLES[$1]} d t0 t1 rc
  d="$OUTD/$s"; mkdir -p "$d"
  local -a cmd=("$K2") noeng=()
  # Ours' plain path runs without the engine env. make run gives every cohort node AK2_ENGINE_N,
  # _RANK and _RENDEZVOUS (scripts/run.sh), and ours takes the engine path whenever AK2_ENGINE_N
  # is set: resident shards, --memory-mapping ignored. O0 at c1 (843e958) so read a second,
  # anonymous copy of the 1.1 TB tmpfs table and was OOM-killed (rc 137) during the load.
  local v; for v in $(compgen -e); do case $v in AK2_ENGINE_*|AK2_COHORT|AK2_COHORT_CHECK) noeng+=(-u "$v") ;; esac; done
  [ "$CLASSIFIER" != upstream ] && cmd=(env "${noeng[@]}" "${DECOMP[@]}" "$OURS")
  local -a mm=(); [ "$DB_LOAD" = mmap ] && mm=(--memory-mapping)
  t0=$(now)
  printf '%s\n' "$t0" > "$SD/start/$j"   # its classify span starts (lad_crit reads the spans)
  "${cmd[@]}" --db "$DBDIR" "${mm[@]}" --paired --threads "$T" --output "$d/output" --report "$d/report" \
    "$INDIR/${s}_1.fastq.gz" "$INDIR/${s}_2.fastq.gz" 2> >(tee "$SD/err/$j" | sed -u "s/^/[$RUNG $s] /") > /dev/null
  rc=$?
  t1=$(now)
  wait "$!" 2> /dev/null || sleep 1   # the tee
  printf '%s %s %s %s\n' "$rc" "$t0" "$t1" "$lane" > "$SD/done/$j.tmp" && mv "$SD/done/$j.tmp" "$SD/done/$j"
  if [ "$UPSERIAL" = 1 ]; then
    # Serial upload: this lane's next sample waits until the main shell has uploaded this one.
    while [ ! -e "$SD/ack/$j" ]; do kill -0 "$AK2_MAIN_PID" 2> /dev/null || exit 1; sleep 0.2; done
  fi
  [ "$rc" = 0 ]
}
# lad_enq FILE: "<sha256> <sha256 seconds> <upload seconds or -> <hash end>" that lever.sh recorded
# for FILE (the sha256 computed on the node at enqueue, before the upload starts, ending at the
# record's t; the upload's seconds only once it has run, i.e. for a serial session).
lad_enq() {
  jq -rs --arg l "$1" '(map(select(.kind == "upload-enqueue" and .local == $l)) | last) as $e
    | (map(select(.kind == "upload" and .local == $l)) | last) as $u
    | "\($e.sha256 // "-") \($e.sha256_seconds // 0) \(if $u == null then "-" else ($u.t_end - $u.t_start) end) \($e.t // 0)"' "$LV_REC" 2> /dev/null
}
NDONE=0; NFB=0; FAIL=0; PENDING=(); DONEJ=(); UPENQ_T=()
ID_S=0; SHAGET_S=0; SHACRIT_S=0   # the node's measurement-only seconds (lad-net)
# lad_finish J RC T0 T1 LANE SRC [ENGINE_JSON]: enqueue sample J's outputs (lv_upload_enqueue
# computes and records their sha256 first) and stream its lad-sample line. Under sdk-stream the
# engine wrote the outputs to S3 itself: the line waits for their sha256, by GET, in push.
lad_finish() {
  local j=$1 rc=$2 t0=$3 t1=$4 lane=$5 src=$6 eng=${7:-} s=${SAMPLES[$1]} f e sha ss us te outs='{}' sh=0 up=0 upd=0 cs="" hiv=""
  NDONE=$((NDONE + 1)); DONEJ+=("$j")
  [ "$rc" = 0 ] || FAIL=1
  if [ "$OUT_UPLOAD" = sdk-stream ]; then
    PENDING+=("$j|$rc|$t0|$t1|$lane|$src|$eng")
    return 0
  fi
  for f in output report; do
    [ -f "$OUTD/$s/$f" ] || continue
    lv_upload_enqueue "$OUTD/$s/$f" "$OUTURL/$s/$f" || FAIL=1
    read -r sha ss us te <<< "$(lad_enq "$OUTD/$s/$f")"
    UPENQ_T+=("$te")   # the upload's enqueue time, by sequence (lad_crit's in-flight span)
    sh=$(awk -v a="$sh" -v b="$ss" 'BEGIN{printf "%.3f", a + b}')
    hiv="$hiv $(awk -v t="$te" -v d="$ss" 'BEGIN{printf "%.3f %.3f", t - d, t}')"
    [ "$us" != - ] && { up=$(awk -v a="$up" -v b="$us" 'BEGIN{printf "%.3f", a + b}'); upd=1; }
    [[ $sha =~ ^[0-9a-f]{64}$ ]] &&
      outs=$(jq -c --arg r "$f" --arg h "$sha" --argjson n "$(stat -c%s "$OUTD/$s/$f")" '. + {($r): {bytes:$n, sha256:$h}}' <<< "$outs")
  done
  [ "$UPSERIAL" = 1 ] && [ "$src" = per-sample ] && : > "$SD/ack/$j"
  lad_line "$j" "$rc" "$t0" "$t1" "$lane" "$src" "$eng" "$outs" "$sh" "$([ "$upd" = 1 ] && echo "$up")" \
    "node, at lv_upload_enqueue before the upload" "$(lad_crit $hiv)"
}
# lad_crit H0 H1 [H0 H1 ...]: the critical-path share of a sample's output sha256 (measurement
# only; docs/ladder.md, "Measurement-only phases"): the seconds of its hash intervals that no
# classify span on this node covers. Spans: per-sample path, each sample's [start, end] (start
# from $SD/start, end from $SD/done; a sample still running covers up to now); engine, the
# engine's classify phase, up to its exit. A hash done after the last classify ended (the tail)
# is all critical; one done while another sample classifies, or while an upload is in flight, is
# not. With one lane under a serial upload mode the lane is idle while it hashes, so its hash is
# critical; with several such lanes another lane's span can cover a hash that delays its own lane,
# and on the engine at N > 1 a peer's work is not a span here (net is then an upper bound).
lad_crit() {
  local f j a b
  {
    echo "H $*"
    if [ "$ENGINE" = 1 ]; then
      # The engine's classify span ends at its recorded exit (eng.end, written by lad_engine's
      # subshell as the engine exits); until that file exists the engine is running and covers.
      local ee=""; [ -s "$W/eng.end" ] && read -r ee < "$W/eng.end"
      [ -n "${CLS_T0:-}" ] && echo "S $CLS_T0 ${ee:-9e18}"
    else
      for f in "$SD"/start/*; do
        [ -e "$f" ] || continue
        j=${f##*/}; read -r a < "$f"
        b=9e18; [ -e "$SD/done/$j" ] && read -r _ _ b _ < "$SD/done/$j"
        echo "S $a $b"
      done
    fi
    # Uploads cover too (NB1): a hash is critical only if neither a classify span nor an upload in
    # flight covers it, since the node's end waits for the upload lane either way. Done uploads are
    # rows of lever.sh's uploads.tsv (t_start, t_end); the one in flight, in an overlap session,
    # started at the later of the last row's end and its own enqueue (to the lane's 0.2 s poll).
    if [ -n "${LV_UP_TSV:-}" ] && [ -f "$LV_UP_TSV" ]; then
      awk -F'\t' -v t0="${LV_UP_T0:-0}" 'NR > 1 && $7 >= t0 {print "S", $8, $9}' "$LV_UP_TSV"
      if [ "${LV_UP_LANE:-0}" = 1 ] && [ -n "${LV_UP_PID:-}" ] && kill -0 "$LV_UP_PID" 2> /dev/null; then
        local done_n last
        done_n=$(awk -F'\t' -v t0="${LV_UP_T0:-0}" 'NR > 1 && $7 >= t0' "$LV_UP_TSV" | wc -l | tr -d ' ')
        last=$(awk -F'\t' -v t0="${LV_UP_T0:-0}" 'NR > 1 && $7 >= t0 && $9 > m {m = $9} END {print m + 0}' "$LV_UP_TSV")
        if [ "${LV_UP_N:-0}" -gt "$done_n" ] && [ "${#UPENQ_T[@]}" -gt "$done_n" ]; then
          echo "S $(awk -v a="$last" -v b="${UPENQ_T[$done_n]}" 'BEGIN{printf "%.3f", (a > b ? a : b)}') 9e18"
        fi
      fi
    fi
  } | awk '$1 == "H" { for (i = 2; i < NF; i += 2) { n++; h0[n] = $i; h1[n] = $(i+1) } next }
           $1 == "S" { m++; s0[m] = $2; s1[m] = $3 }
           END {
             c = 0
             for (k = 1; k <= n; k++) {
               # the part of [h0, h1] outside the union of the spans: walk it in pieces
               x = h0[k]
               while (x < h1[k]) {
                 cov = 0
                 for (q = 1; q <= m; q++) if (s0[q] <= x && s1[q] > x) { if (s1[q] > cov) cov = s1[q] }
                 if (cov > x) { x = cov; continue }
                 nx = h1[k]
                 for (q = 1; q <= m; q++) if (s0[q] > x && s0[q] < nx) nx = s0[q]
                 c += nx - x; x = nx
               }
             }
             printf "%.3f", c
           }'
}
# lad_line J RC T0 T1 LANE SRC ENGINE_JSON OUTPUTS SHA_S UPLOAD_S SHA_SOURCE SHA_CRITICAL_S: the line itself.
lad_line() {
  local j=$1 s=${SAMPLES[$1]} cs="" st=n/a k=0 fb=none
  SHACRIT_S=$(awk -v a="$SHACRIT_S" -v b="${12:-0}" 'BEGIN{printf "%.3f", a + b}')
  [ "$6" = per-sample ] && cs=$(sed -nE 's/.*processed in ([0-9.]+)s.*/\1/p' "$SD/err/$j" 2> /dev/null | tail -1)
  if [ "$GZMODE" != gzip ]; then st=identical; k=$GZK; [ -n "${S5BAD[$s]:-}" ] && { st=differs; fb=gzip; NFB=$((NFB + 1)); }; fi
  emit_sample "$(jq -nc --arg rung "$RUNG" --arg arm "$ARM" --argjson cohort "$COHORT" --arg s "$s" --argjson pairs "${PAIRS[$j]}" \
    --argjson rc "$2" --arg t0 "$3" --arg t1 "$4" --arg lane "$5" --arg src "$6" --arg eng "$7" --argjson outs "$8" --arg sh "$9" \
    --arg up "${10}" --arg shsrc "${11}" --arg shc "${12:-}" --arg cs "$cs" --arg st "$st" --argjson k "$k" --argjson nproc "$NPROC" \
    --arg id "${IDSEC[$s]:-}" --argjson rank "$RANK" --argjson idx "$j" --argjson t "$T" --argjson inb "${BYTES[$j]:-0}" \
    --arg cl "$CLASSIFIER" --argjson group "$GROUP" --arg upm "$OUT_UPLOAD" --arg fb "$fb" --arg g1 "${GZSHA[${s}_1.fastq.gz]:-}" --arg g2 "${GZSHA[${s}_2.fastq.gz]:-}" --arg r1 "${RGSHA[${s}_1.fastq.gz]:-}" --arg r2 "${RGSHA[${s}_2.fastq.gz]:-}" --arg ge "${GZRC[${s}_1.fastq.gz]:--1} ${GZRC[${s}_2.fastq.gz]:--1}" --arg re "${RGRC[${s}_1.fastq.gz]:--1} ${RGRC[${s}_2.fastq.gz]:--1}" '
    def n($x): if $x == "" or $x == "null" then null else ($x | tonumber) end;
    def ms: . * 1000 | round / 1000;
    ($eng | if . == "" then null else fromjson end) as $e
    | {v:1, arm:$arm, rung:$rung, cohort:$cohort, accession:$s, pairs:$pairs, rc:$rc,
       phases:(({classify:(n($t1) - n($t0)), sha:n($sh), "sha-critical":n($shc)}
         + (if $up == "" then {} else {upload:n($up)} end)
         + (if $id == "" then {} else {"s5-identity":n($id)} end)
         + (if $cs == "" then {} else {"classify-process":n($cs)} end)
         + (if $e == null then {} else ({"engine-setup":n($e.setup_s), "engine-classify":n($e.classify_s), "engine-close":n($e.close_s),
             "engine-report":n($e.report_s)} | with_entries(select(.value != null))) end)) | map_values(ms)),
       outputs:$outs, s5:({status:$st, fallback:$fb, P:$k, nproc:$nproc} + (if $st == "n/a" then {} else {gz_sha256:[$g1, $g2], rg_sha256:[$r1, $r2], gz_exit:($ge | split(" ") | map(tonumber)), gz_warning:($ge | split(" ") | map(tonumber == 2)), rg_exit:($re | split(" ") | map(tonumber))} end)),
       rank:$rank, idx:$idx, t_start:(n($t0) | ms), t_end:(n($t1) | ms), input_bytes:$inb, threads:$t,
       replica:$group, lane:$lane, classifier:$cl, out_upload:$upm, sha256_source:$shsrc,
       s5_verdict:(if $st == "differs" then "S5 not output-preserving on this input" else null end), engine:$e}')"
}
# lad_lanes: PROCS lanes of per-sample classifiers over this replica's samples (PLACEMENT; a lane
# runs its samples in assignment order, heaviest first under lpt). Sets CPIDS.
lad_lanes() {
  local l j b
  local -a laneof lj
  mapfile -t laneof < <(lad_assign "$PROCS" "$PLACEMENT" "${MINE[@]}")
  for ((l = 0; l < PROCS; l++)); do
    lj=()
    while read -r j b; do [ "$b" = "$l" ] && lj+=("$j"); done < <(printf '%s\n' "${laneof[@]}")
    [ "${#lj[@]}" -gt 0 ] || continue
    ( r=0; for j in "${lj[@]}"; do lad_one "$j" "$l" || r=1; done; exit "$r" ) &
    CPIDS+=($!)
  done
}
# lad_engine: the one cohort-mode engine process (ENGINE_ENV), its stderr to eng.stderr and, as
# written, its ak2 lines into the run log (the same 2> >(...) > /dev/null order as lad_one). Sets CPIDS.
lad_engine() {
  : > "$W/eng.stderr"; rm -f "$W/eng.end"
  T_LAUNCH=$(now)   # the engine's start_s are seconds after its process start
  # The subshell writes the engine's exit time (eng.end) as soon as it exits, so lad_crit's engine
  # span ends there and not when the watch loop next notices (to the few ms of writing it).
  ( env "${ENGINE_ENV[@]}" "$OURS" --db "$DBDIR" --paired \
      2> >(tee "$W/eng.stderr" | grep --line-buffered -E '^ak2-(sample|timing|engine)' | sed -u "s/^/[$RUNG] /") > /dev/null
    rc=$?; now > "$W/eng.end.tmp" && mv "$W/eng.end.tmp" "$W/eng.end"; exit "$rc" ) &
  CPIDS+=($!)
}
# The watch loop (main shell: phases, uploads and lad-sample lines are its own). Phase boundaries
# come from the classifiers' own output; every completed sample is enqueued as it appears.
ST=load; SEEN=0; LASTPUSH=$(date +%s)
declare -A GOT=()
lad_phase_to() { ST=$1; [ "$1" = classify ] && CLS_T0=$(now); ak2_phase "$1"; emit phase "$(jq -nc --arg p "$1" --arg t "$(now)" --arg how "$2" '{kind:"phase", phase:$p, t:($t|tonumber), how:$how}')"; }
lad_scan() {
  local f j rc t0 t1 lane line
  if [ "$ENGINE" = 0 ]; then
    if [ "$ST" = load ] && grep -qs 'Loading database information\.\.\. *done' "$SD"/err/* 2> /dev/null; then
      lad_phase_to classify "first classifier reported the table loaded"
    fi
    for f in "$SD"/done/*; do
      [ -e "$f" ] || continue
      j=${f##*/}; case $j in *.tmp) continue ;; esac
      [ -n "${GOT[$j]:-}" ] && continue
      GOT[$j]=1
      read -r rc t0 t1 lane < "$f"
      lad_finish "$j" "$rc" "$t0" "$t1" "$lane" per-sample
    done
  else
    if [ "$ST" = load ] && grep -qE $'^ak2-timing\tshard-load-' "$W/eng.stderr"; then
      lad_phase_to etag-hash.k2d "engine shard-load line (its in-memory ETag check follows)"
    fi
    if [ "$ST" = etag-hash.k2d ] && grep -qE $'^ak2-(timing\tconnect\t|sample\t)' "$W/eng.stderr"; then
      lad_phase_to classify "engine connect line (ETag verified on every shard)"
    fi
    local -a L
    mapfile -t L < <(grep -E $'^ak2-sample\t' "$W/eng.stderr")
    while [ "$SEEN" -lt "${#L[@]}" ]; do
      line=${L[$SEEN]}; SEEN=$((SEEN + 1))
      local rk ro nm ex st wl js
      rk=$(awk -F'\t' '{for (i = 2; i < NF; i += 2) if ($i == "rank") print $(i+1)}' <<< "$line")
      ro=$(awk -F'\t' '{for (i = 2; i < NF; i += 2) if ($i == "role") print $(i+1)}' <<< "$line")
      [ "$rk" = "$SHARD" ] && [ "$ro" != peer ] || continue
      nm=$(awk -F'\t' '{for (i = 2; i < NF; i += 2) if ($i == "name") print $(i+1)}' <<< "$line")
      js=$(awk -F'\t' '{printf "{"; for (i = 2; i < NF; i += 2) printf "%s\"%s\":\"%s\"", (i > 2 ? "," : ""), $i, $(i+1); print "}"}' <<< "$line")
      ex=$(jq -r .status <<< "$js"); st=$(jq -r .start_s <<< "$js"); wl=$(jq -r .wall_s <<< "$js")
      for j in "${MINE[@]}"; do
        [ "${SAMPLES[$j]}" = "$nm" ] || continue
        lad_finish "$j" "$ex" "$(awk -v a="$T_LAUNCH" -v s="$st" 'BEGIN{printf "%.3f", a + s}')" \
          "$(awk -v a="$T_LAUNCH" -v s="$st" -v w="$wl" 'BEGIN{printf "%.3f", a + s + w}')" "rank$SHARD" engine "$js"
      done
    done
  fi
}
# lad_watch: until every classifier has exited; then CRC (0: all exited 0). A classifier that
# died before a boundary still gets the phases it never reached, so every run has them all.
lad_watch() {
  local alive p
  while :; do
    alive=0
    for p in "${CPIDS[@]}"; do kill -0 "$p" 2> /dev/null && alive=1; done
    [ "$alive" = 0 ] && sleep 1   # let the tees drain (the engine span ends at eng.end; lad_engine)
    lad_scan
    [ "$alive" = 0 ] && break
    if [ $(( $(date +%s) - LASTPUSH )) -ge 30 ]; then lad_push; LASTPUSH=$(date +%s); fi
    sleep 0.2
  done
  CRC=0
  for p in "${CPIDS[@]}"; do wait "$p" || CRC=1; done
  [ "$ST" = load ] && [ "$ENGINE" = 1 ] && lad_phase_to etag-hash.k2d "not observed (the engine ended first)"
  [ "$ST" != classify ] && lad_phase_to classify "not observed (the classifiers ended first)"
  return 0
}
# The fallback (per-sample shim behaviour, one mechanism for both arms): a gzip ahead of
# lever.sh's shim on PATH sends the inputs that failed to GNU gzip and everything else to the
# shim, so the run stays output-preserving. Its calls are logged and counted after classify.
lad_s5_fallback() {
  FBDIR="$W/s5fb"; mkdir -p "$FBDIR" || return 1; : > "$FBDIR/inputs"; : > "$FBDIR/calls"
  for s in "${!S5BAD[@]}"; do printf '%s\n%s\n' "$INDIR/${s}_1.fastq.gz" "$INDIR/${s}_2.fastq.gz" >> "$FBDIR/inputs"; done
  cat > "$FBDIR/gzip" << LADFB
#!/bin/bash
# ladder.body.sh S5 fallback: an input that failed the identity phase -> GNU gzip; all else -> lever.sh's shim.
for a in "\$@"; do :; done
if [ -n "\${a:-}" ] && grep -qxF -- "\$a" "$FBDIR/inputs"; then
printf '%s\tgzip-fallback\t%s\n' "\$(date +%s.%3N)" "\$*" >> "$FBDIR/calls"
exec "$REAL_GZIP" "\$@"
fi
exec "$SHIMGZ" "\$@"
LADFB
  chmod 0555 "$FBDIR/gzip" || return 1
  export PATH="$FBDIR:$PATH"; hash -r
  [ "$(command -v gzip)" = "$FBDIR/gzip" ] || { ak2_say "the S5 fallback gzip is not first on PATH"; return 1; }
  emit fallback "$(jq -nc --arg how "per-sample shim behaviour: $FBDIR/gzip ahead of lever.sh's shim on PATH" \
    --argjson n "${#S5BAD[@]}" --arg list "${!S5BAD[*]}" '{kind:"s5-fallback", how:$how, samples:$n, accessions:($list | split(" "))}')"
}
# lad_identity (S5): rapidgzip 0.14.5 drops output after trailing bytes, by an amount that
# depends on -P (docs/oracle.md), so every input this node reads is decompressed by both tools at
# this run's -P on this host, before any classify; its own phase, measurement only. Each tool's
# real exit status is taken inside its command substitution (the pipeline's PIPESTATUS is gone
# once the substitution returns). A sample differs if any mate's sha256 differ, rapidgzip exits
# non-zero, GNU gzip exits other than 0 or 2 (2 is its warning, gz_warning: the output is complete),
# or either tool's output is empty (the empty-stream sha256): it then falls back to GNU
# gzip (lad_s5_fallback). Sets S5BAD, IDSEC, GZSHA, RGSHA, GZRC, RGRC.
EMPTY_SHA=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
lad_identity() {
  local l i j f g gr h hr t0 t1 ok s p why idef gw
  local -a idf idpids
  IDL=$(( NPROC / (GZK + 2) )); [ "$IDL" -lt 1 ] && IDL=1
  for j in "${NEED[@]}"; do idf+=("${SAMPLES[$j]}_1.fastq.gz" "${SAMPLES[$j]}_2.fastq.gz"); done
  mkdir -p "$SD/id"
  for ((l = 0; l < IDL; l++)); do
    (
      for ((i = l; i < ${#idf[@]}; i += IDL)); do
        f=${idf[$i]}; t0=$(now)
        g=$("$REAL_GZIP" -dc "$INDIR/$f" | sha256sum | cut -d' ' -f1; exit "${PIPESTATUS[0]}"); gr=$?
        h=$("$LV_RG" -d -c -P "$GZK" "$INDIR/$f" | sha256sum | cut -d' ' -f1; exit "${PIPESTATUS[0]}"); hr=$?
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$g" "$gr" "$h" "$hr" "$t0" "$(now)" > "$SD/id/$f"
      done
    ) &
    idpids+=($!)
  done
  for p in "${idpids[@]}"; do wait "$p"; done
  for f in "${idf[@]}"; do
    IFS=$'\t' read -r _ g gr h hr t0 t1 < "$SD/id/$f" 2> /dev/null || { g=missing-gzip; h=missing-rapidgzip; gr=-1; hr=-1; t0=0; t1=0; }
    why=""
    [[ $g =~ ^[0-9a-f]{64}$ ]] && [[ $h =~ ^[0-9a-f]{64}$ ]] || why="no sha256"
    [ "$g" = "$h" ] || why="${why:+$why; }sha256 differ"
    # GNU gzip's exit 2 is its warning (e.g. "trailing garbage ignored"): the output is complete and
    # upstream's wrapper ignores the status, so stock reads the full stream. Recorded as gz_warning;
    # by itself it is neither a difference nor an input defect (Scott, 2026-10-11).
    gw=false
    case $gr in 0) ;; 2) gw=true ;; *) why="${why:+$why; }gzip exit $gr" ;; esac
    [ "$hr" = 0 ] || why="${why:+$why; }rapidgzip exit $hr"
    { [ "$g" = "$EMPTY_SHA" ] || [ "$h" = "$EMPTY_SHA" ]; } && why="${why:+$why; }empty output"
    ok=true; [ -z "$why" ] || ok=false
    # GNU gzip itself failing (an exit other than 0 or 2), or giving nothing, is an input/staging
    # defect (the input passed its sha256 against the staged metadata), not an S5 finding: flagged for the tables.
    idef=false; { ! [[ $gr =~ ^(0|2)$ ]] || [ "$g" = "$EMPTY_SHA" ] || ! [[ $g =~ ^[0-9a-f]{64}$ ]]; } && idef=true
    GZSHA[$f]=$g; RGSHA[$f]=$h; GZRC[$f]=$gr; RGRC[$f]=$hr
    s=${f%_[12].fastq.gz}
    [ "$ok" = true ] || S5BAD[$s]=1
    IDSEC[$s]=$(awk -v a="${IDSEC[$s]:-0}" -v b="$t0" -v c="$t1" 'BEGIN{printf "%.3f", a + c - b}')
    emit identity "$(jq -nc --arg f "$f" --arg s "$s" --arg g "$g" --arg h "$h" --argjson gr "$gr" --argjson hr "$hr" --argjson k "$GZK" \
      --argjson nproc "$NPROC" --argjson ok "$ok" --arg t0 "$t0" --arg t1 "$t1" --arg why "$why" --argjson idef "$idef" --argjson gw "$gw" \
      '{kind:"identity", file:$f, sample:$s, gzip_sha256:$g, gzip_exit:$gr, gz_warning:$gw, rapidgzip_sha256:$h, rapidgzip_exit:$hr, rapidgzip_P:$k,
        nproc:$nproc, identical:$ok, input_defect:$idef, why:(if $why == "" then null else $why end), seconds:(($t1|tonumber)-($t0|tonumber)),
        verdict:(if $ok then "output-preserving" else "S5 not output-preserving on this input" end)}')"
  done
  ak2_say "identity: ${#idf[@]} inputs at -P $GZK on $NPROC CPUs; ${#S5BAD[@]} samples not output-preserving"
  [ "${#S5BAD[@]}" -gt 0 ] && { lad_s5_fallback || return 1; }
  return 0
}
# ---- end of the functions scripts/tests/ladder_stream_test.sh drives ----
# SETUP=overlap: the build ran beside fetch-db and fetch-inputs; it is waited for in its own phase,
# build-wait (not measurement-only), before identity, so identity never overlaps the build and
# subtracting it is exact.
if [ "$SETUP" = overlap ]; then ak2_phase build-wait; lad_build_wait; fi
declare -A S5BAD=() IDSEC=() GZSHA=() RGSHA=() GZRC=() RGRC=()
if [ "$GZMODE" != gzip ]; then
  ak2_phase identity
  ID_T0=$(now)
  lad_identity || fail "the S5 fallback could not be installed"
  ID_S=$(awk -v a="$ID_T0" -v b="$(now)" 'BEGIN{printf "%.3f", b - a}')
  lad_push
fi
[ "$BUILT" = 1 ] || fail "the build was not waited for before load (SETUP=$SETUP)"

UPSERIAL=0
case $OUT_UPLOAD in awscp-default|s5cmd-serial) UPSERIAL=1 ;; esac
UPOPEN=0
CPIDS=()
if [ "$ENGINE" = 1 ]; then
  TOKEN=$(curl -sf -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 300" http://169.254.169.254/latest/api/token)
  IP=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
  [ -n "$IP" ] || fail "no private IP from IMDS"
  ENGINE_ENV=(AK2_ENGINE_N="$SHARDS" AK2_ENGINE_RANK="$SHARD" AK2_ENGINE_RENDEZVOUS="$AK2_ENGINE_RENDEZVOUS/g$GROUP"
    AK2_ENGINE_LISTEN="$IP" AK2_ENGINE_TIMEOUT=30m AK2_ENGINE_HASH_URL="$URL" AK2_ENGINE_HASH_ETAG="$ETAG"
    AK2_ENGINE_HASH_SIZE="$SIZE" AK2_ENGINE_VERIFY_ETAG=1 AK2_TIMINGS=1 K2_DB_READ_THREADS=48 AK2_COHORT="$M" "${DECOMP[@]}")
  env "${ENGINE_ENV[@]}" AK2_COHORT_CHECK=1 "$OURS" --db "$DBDIR" --paired > /dev/null 2> "$W/check.err" ||
    { cat "$W/check.err"; fail "cohort manifest $M does not check"; }
fi
ak2_drop_caches
ak2_phase load
lad_mem load-start
ht_record load
if [ "$OUT_UPLOAD" != sdk-stream ]; then lv_upload_start "$OUT_UPLOAD" || fail "lv_upload_start $OUT_UPLOAD failed"; UPOPEN=1; fi
if [ "$ENGINE" = 1 ]; then lad_engine; else lad_lanes; fi
ak2_say "load: ${#CPIDS[@]} classifier process(es), $T threads each, uploads $OUT_UPLOAD"
lad_watch
[ "$CRC" = 0 ] || { FAIL=1; ak2_say "a classifier exited non-zero"; }
[ "$NDONE" = "${#MINE[@]}" ] || [ "$ENGINE" = 1 ] || { FAIL=1; ak2_say "$NDONE of ${#MINE[@]} samples completed"; }
if [ "$ENGINE" = 1 ]; then
  sleep 1
  grep -vE '^ak2-(timing|engine|sample)' "$W/eng.stderr" | grep -v ' sequences ' | tail -5 | sed "s/^/[$RUNG stderr] /"
  F="$W/eng.stderr"
  v=$(awk -F'\t' '$1=="ak2-engine" && $2=="load" {print $6}' "$F" | tail -1); [ -n "$v" ] && ak2_req GetObject-range "$v" "$RB"
  v=$(awk -F'\t' '$1=="ak2-engine" && $2=="etag" {for (i = 3; i < NF; i++) if ($i == "requests") print $(i+1)}' "$F" | tail -1)
  [ -n "$v" ] && [ "$v" -gt 0 ] && ak2_req GetObject-range-etag "$v" "$RB"
  for op in put:PutObject get:GetObject create_multipart:CreateMultipartUpload upload_part:UploadPart \
            complete_multipart:CompleteMultipartUpload abort_multipart:AbortMultipartUpload; do
    v=$(awk -F'\t' -v k="${op%%:*}" '$1=="ak2-engine" && $2=="s3" { for (i = 3; i < NF; i++) if ($i == k) s += $(i+1) } END { print s+0 }' "$F")
    [ "$v" -gt 0 ] && ak2_req "${op#*:}" "$v" "$B"
  done
  v=$(awk -F'\t' '$1=="ak2-engine" && $2=="rendezvous" {print $4}' "$F" | tail -1); [ -n "$v" ] && ak2_req Rendezvous-PutObject "$v" "$B"
  v=$(awk -F'\t' '$1=="ak2-engine" && $2=="rendezvous" {print $6}' "$F" | tail -1); [ -n "$v" ] && ak2_req Rendezvous-GetObject "$v" "$B"
  grep -qE $'^ak2-engine\tetag\t' "$F" || { FAIL=1; ak2_say "ERROR: no ak2-engine etag line: the in-memory ETag check did not run"; }
  # Completeness: every sample homed here has its ak2-sample line (and so a lad-sample line).
  MISSING=()
  for s in "${HOMES[@]}"; do
    hit=0; for j in "${DONEJ[@]}"; do [ "${SAMPLES[$j]}" = "$s" ] && hit=1; done
    [ "$hit" = 1 ] || MISSING+=("$s")
  done
  [ "${#MISSING[@]}" = 0 ] || { FAIL=1; ak2_err 1 "engine: ${#MISSING[@]} of ${#HOMES[@]} home samples have no ak2-sample line: ${MISSING[*]:0:10}"; }
  ak2_push "$F" "eng-rank$RANK.stderr" > /dev/null
fi
# S5 cannot pass as a no-op: every input this node classified went through rapidgzip, except the
# fallback samples, which went through GNU gzip.
if [ "$GZMODE" != gzip ]; then
  NFBD=0
  for j in "${DONEJ[@]}"; do [ -n "${S5BAD[${SAMPLES[$j]}]:-}" ] && NFBD=$((NFBD + 1)); done
  NRG=$(grep -c $'\trapidgzip\t' "$LV_DIR/gzip-shim.calls" 2> /dev/null); NRG=${NRG:-0}
  NGF=0; [ -n "${FBDIR:-}" ] && NGF=$(grep -c $'\tgzip-fallback\t' "$FBDIR/calls" 2> /dev/null)
  WANTRG=$(( 2 * (${#DONEJ[@]} - NFBD) )); WANTFB=$(( 2 * NFBD ))
  emit shim "$(jq -nc --argjson n "$NRG" --argjson want "$WANTRG" --argjson nf "${NGF:-0}" --argjson wf "$WANTFB" --arg mode "$GZMODE" \
    '{kind:"shim", mode:$mode, rapidgzip_calls:$n, want_at_least:$want, fallback_calls:$nf, fallback_want_at_least:$wf,
      ok:($n >= $want and ($want == 0 or $n > 0) and $nf >= $wf)}')"
  [ "$NRG" -ge "$WANTRG" ] && { [ "$WANTRG" = 0 ] || [ "$NRG" -gt 0 ]; } ||
    { FAIL=1; ak2_err 1 "S5: gzip-shim.calls has $NRG rapidgzip lines, want at least $WANTRG"; }
  [ "${NGF:-0}" -ge "$WANTFB" ] || { FAIL=1; ak2_err 1 "S5 fallback: $NGF GNU gzip calls, want at least $WANTFB"; }
  ak2_push "$LV_DIR/gzip-shim.calls" gzip-shim.calls > /dev/null
  [ -n "${FBDIR:-}" ] && ak2_push "$FBDIR/calls" s5-fallback.calls > /dev/null
fi
lad_push

ak2_phase upload-drain
if [ "$UPOPEN" = 1 ]; then lv_upload_drain || FAIL=1; fi

if [ "$OUT_UPLOAD" = sdk-stream ]; then
  # The SDK emitter streamed every output to S3 with no local copy: its sha256 comes from a GET, in
  # its own sequential phase (measurement only, so the tables can subtract it exactly). Each
  # sample's lad-sample line streams, and is pushed, as soon as its GETs finish.
  ak2_phase sha-get
  SG_T0=$(now)
  for p in "${PENDING[@]}"; do
    IFS='|' read -r j rc t0 t1 lane src eng <<< "$p"
    s=${SAMPLES[$j]}; outs='{}'; sh=0
    for f in output report; do
      g="$W/get.tmp"; rm -f "$g"
      g0=$(now)
      aws s3 cp --only-show-errors "$OUTURL/$s/$f" "$g"; grc=$?
      if [ "$grc" = 0 ]; then
        h=$(sha256sum "$g" | cut -d' ' -f1); n=$(stat -c%s "$g")
        ak2_req HeadObject 1 "$B"; ak2_req GetObject $(( n < 8388608 ? 1 : (n + 8388607) / 8388608 )) "$B"
        outs=$(jq -c --arg r "$f" --arg h "$h" --argjson n "$n" '. + {($r): {bytes:$n, sha256:$h}}' <<< "$outs")
      else
        FAIL=1; ak2_say "GET of $OUTURL/$s/$f for its sha256 failed"
      fi
      sh=$(awk -v a="$sh" -v b="$g0" -v c="$(now)" 'BEGIN{printf "%.3f", a + c - b}')
      rm -f "$g"
    done
    lad_line "$j" "$rc" "$t0" "$t1" "$lane" "$src" "$eng" "$outs" "$sh" "" "s3 GET after the run (the SDK emitter keeps no local copy)" 0
    lad_push
  done
  SHAGET_S=$(awk -v a="$SG_T0" -v b="$(now)" 'BEGIN{printf "%.3f", b - a}')
fi
ak2_phase push
# lad-net: the seconds the net rule takes out of this node's gross wall (docs/ladder.md,
# "Measurement-only phases"): identity (sequential, after build-wait, so all of it) + sha-get
# (sequential) + the node's sha-critical (its hashes no classify span covered). One line per node.
NETJ=$(jq -nc --argjson rank "$RANK" --arg id "$ID_S" --arg sg "$SHAGET_S" --arg sc "$SHACRIT_S" '
  def ms: . * 1000 | round / 1000;
  {v:1, rank:$rank, critical_measurement_s:((($id|tonumber) + ($sg|tonumber) + ($sc|tonumber)) | ms),
   identity_s:($id|tonumber|ms), sha_get_s:($sg|tonumber|ms), sha_critical_s:($sc|tonumber|ms)}')
printf '%s\n' "$NETJ" > "$W/lad-net.jsonl"
emit net "$NETJ"
ak2_push "$W/lad-net.jsonl" lad-net.jsonl > /dev/null || FAIL=1
ht_restore || ak2_say "ht_restore did not restore every knob"
ht_record end
lad_push || FAIL=1
for n in "${MOUNTS[@]}"; do $UC umount "$n" || ak2_say "umount $n failed"; done
ak2_say "ladder $RUNG rank $RANK done: $NDONE samples, FAIL=$FAIL"
exit "$FAIL"
