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

# shellcheck disable=SC2016,SC2024,SC2034  # literal jq/bash text; sudo dnf's log is ours; PARAMS are read below
# G2 input-path sweep I0-I4 (#90; docs/inputpath.md). One instance of one family runs the whole
# matrix for one engine: Standard-8 resident on tmpfs, loaded once per classifier run from RAM
# (upstream at the pin rebuilds nothing between runs: every point after the warm-up is warm),
# and every arm against it:
#   I0  pre-decompressed FASTQ on tmpfs (the families have no instance store; tmpfs is the page
#       cache, warm by construction)
#   I1  the .fastq.gz with --gzip-compressed (upstream's wrapper pipes gzip -dc per mate; ours
#       twice: AK2_DECOMPRESS=pipe, the same pipe, and in process)
#   I2  rapidgzip -d -c -P p --chunk-size 4096 per mate in a process substitution, no
#       --gzip-compressed; p in PS; at the best p (below) also chunk sizes CHUNKS (KiB) and the
#       default pipe size (the pipe-size contrast)
#   I3  I2 with --import-index (the prebuilt index of inputs.tsv), at the best p
#   I4  the BGZF re-encode decoded by rapidgzip, at the best p
# at kraken2 --threads in THREADS, for one paired-end and one single-end sample (inputs.tsv).
# THP: every point runs at MAIN_THP (enabled=always: upstream's table from a tmpfs mounted
# huge=always); with THP_CONTRAST=1 I0 runs again at enabled=never from a huge=never copy.
# Pipe: every rapidgzip decode writes into a pipe raised to PIPE_BYTES by
# scripts/inputpath/pipesz.py (F_SETPIPE_SZ; the size it got is recorded per mate).
# Best p (the rule, recorded in each select line): per sample and threads, among rep 1's I2 points
# of the PyPI build at chunk 4096 and PIPE_BYTES with status ok and identity ok, the smallest p
# whose wall_s is within 1% of the minimum wall_s. Rep 2 reuses rep 1's choice and runs rep 1's
# points in reverse order.
# Identity (Scott, 2026-10-18): before a rapidgzip build and configuration decodes a file in a
# point, it decodes it to sha256sum, which must equal gzip -dc's. A failed attempt is retried once
# (the rpmalloc race, #89: ~0.25% of decodes); each attempt is an identity line, and only two
# failures make every point needing it skipped (skipped-identity), never run. A decoder that exits
# non-zero inside a point makes it a decode-crash point (excluded).
# Law 1: each sample's warm-up I0 must equal upstream at the pin (#95's g1_reference in G1_REF),
# or the run stops (defect line, exit 1) before any other point; every later point's --output,
# --report and sequence count must equal the warm-up's, otherwise a defect line.
# RG2_WHEEL / RG2_SCRIPT (off by default): a second rapidgzip build (a pinned wheel, e.g. the 0.16.0
# aarch64 wheel with ISA-L, #97; or a source build) adds I2, I3 and I4 at the best p with it (decomp
# rapidgzip-2).
# Streams one `inputpath {json}` line per event (also in out/points.jsonl, pushed after every
# point with the point's pidstat CSV, stderr and time records as out/points/<id>.tgz), so a TTL
# kill loses no finished point. A point not started by DEADLINE (launch + TTL - MARGIN_S) is
# skipped (skipped-deadline). drop_caches runs once before the first point; its failure ends the
# run (exit 95, the preamble's rule).
# make rehearse seams (AK2_REHEARSE_*, refused by run.sh in a spec's env): INPUTS_TSV (another
# inputs.tsv), DEADLINE_S (seconds from the measure phase's start; also lifts the 64-vCPU check), THP_ROOT (a fake sysfs root), GO (Go is on
# PATH), RAPIDGZIP / WHEELS (lever.sh's), TMPFS (plain directories instead of tmpfs mounts), G1_REF
# (another Law 1 reference file).
# Parameters (scripts/inputpath/mkspec.sh):
FAMILY=c8g; ENGINE=upstream; TTL_S=7020; REPS=2; THREADS="48 32 16"; PS="16 8 4 2"; CHUNKS="8192 16384"; MAIN_THP=always; THP_CONTRAST=1; PIPE_BYTES=1048576; PIPE_CONTRAST=1; POINT_TIMEOUT=900; ID_TIMEOUT=360; MARGIN_S=600; LAUNCH_LEAD_S=120; G1_REF=results/inputpath/preflight-inputs-20261018T224922Z-89e0340/manifest.json; RG2_SCRIPT=; RG2_WHEEL=https://files.pythonhosted.org/packages/46/5e/bfd0ba68015806de0959c6514a61b162548014c550a30e83be81943878c7/rapidgzip-0.16.0-cp39-cp39-manylinux_2_26_aarch64.manylinux_2_28_aarch64.whl@2c3d75cb314b6dc28cf8fa238ff56f5ffae142af581f531fc674229184386f1d
PARAMS_LINE='FAMILY=c8g; ENGINE=upstream; TTL_S=7020; REPS=2; THREADS="48 32 16"; PS="16 8 4 2"; CHUNKS="8192 16384"; MAIN_THP=always; THP_CONTRAST=1; PIPE_BYTES=1048576; PIPE_CONTRAST=1; POINT_TIMEOUT=900; ID_TIMEOUT=360; MARGIN_S=600; LAUNCH_LEAD_S=120; G1_REF=results/inputpath/preflight-inputs-20261018T224922Z-89e0340/manifest.json; RG2_SCRIPT=; RG2_WHEEL=https://files.pythonhosted.org/packages/46/5e/bfd0ba68015806de0959c6514a61b162548014c550a30e83be81943878c7/rapidgzip-0.16.0-cp39-cp39-manylinux_2_26_aarch64.manylinux_2_28_aarch64.whl@2c3d75cb314b6dc28cf8fa238ff56f5ffae142af581f531fc674229184386f1d'
W=$HOME/ak2; mkdir -p "$W"
T_START=$(date +%s)
SHA=${AK2_RUN_ID##*-}
B=aws-kraken2-942542972736-us-west-2; DATA=aws-kraken2/data; DBNAME=k2_standard_08_GB_20260626
# Two records: out/events.jsonl, every line streamed (host, tool, db, input, identity, select,
# drop-caches, every point, defect, summary, fatal; field kind); out/points.jsonl, the point
# records only (schema inputpath-point/1, what make inputpath-report reads).
J=$W/events.jsonl; PJ=$W/points.jsonl; : > "$J"; : > "$PJ"
emit() { printf '%s\n' "$1" >> "$J"; printf 'inputpath %s\n' "$1"; }
emit_point() { printf '%s\n' "$1" >> "$PJ"; emit "$(jq -c '{kind:"point"} + .' <<< "$1")"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
THP_F=${AK2_REHEARSE_THP_ROOT:-}/sys/kernel/mm/transparent_hugepage/enabled
THP0=""
cur_thp() { local v; v=$(cat "$THP_F" 2> /dev/null); if [[ $v == *"["* ]]; then v=${v#*[}; v=${v%%]*}; fi; echo "$v"; }
restore_thp() { [ -n "$THP0" ] && [ "$(cur_thp)" != "$THP0" ] && echo "$THP0" | sudo -n tee "$THP_F" > /dev/null 2>&1; }
fail() {
  ak2_say "ERROR: $*"
  emit "$(jq -nc --arg m "$*" '{kind:"fatal", message:$m}' 2> /dev/null || printf '{"kind":"fatal"}')"
  restore_thp; ak2_push "$J" events.jsonl > /dev/null; ak2_push "$PJ" points.jsonl > /dev/null; exit 1
}
ak2_say "shell flags $- (body start)"
# The TTL counts from the launch request, taken as boot - LAUNCH_LEAD_S.
BOOT=$(awk -v n="$T_START" '{printf "%d", n - $1}' /proc/uptime)
DEADLINE=$((BOOT - LAUNCH_LEAD_S + TTL_S - MARGIN_S))
# (make rehearse: AK2_REHEARSE_DEADLINE_S replaces it, counted from the start of the measure phase.)
ak2_say "inputpath: family $FAMILY engine $ENGINE; points start until $(date -u -d "@$DEADLINE" +%FT%TZ 2> /dev/null || echo "$DEADLINE") (TTL ${TTL_S}s, margin ${MARGIN_S}s)"

ak2_phase setup
sudo -n dnf install -y -q git gcc-c++ make zlib-devel perl jq gzip tar findutils python3 python3-pip sysstat time procps-ng util-linux \
  > "$W/dnf.log" 2>&1 || { tail -5 "$W/dnf.log"; fail "dnf install failed"; }
for t in pidstat /usr/bin/time jq perl sha256sum; do command -v "$t" > /dev/null || fail "$t is missing after dnf"; done
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "cd repo"
IP=$W/repo/scripts/inputpath
# The inputs first: a missing or incomplete inputs.tsv fails here, before any build or stage.
ITSV=${AK2_REHEARSE_INPUTS_TSV:-scripts/inputpath/inputs.tsv}
ROWS=$(python3 "$IP/inputs.py" check "$ITSV" --accessions "$AK2_ACCESSIONS" 2>&1) || fail "inputs: $ROWS"
emit "$(jq -nc --arg f "$ITSV" --arg sha "$(sha256sum "$ITSV" | cut -d' ' -f1)" --argjson n "$(grep -c . <<< "$ROWS")" \
  '{kind:"inputs-tsv", file:$f, sha256:$sha, rows:$n}')"

# Law 1 against upstream at the pin, before any point: the warm-up I0 of each sample must equal
# #95's recorded reference (the I0 --output/--report sha256 of upstream at the pin on these inputs and
# Standard-8: g1_reference in G1_REF's manifest). A mismatch is a defect line and ends the run, so for
# ENGINE=ours nothing is measured unless ours equals upstream on these inputs.
G1F=${AK2_REHEARSE_G1_REF:-$G1_REF}
[ -s "$G1F" ] || fail "the Law 1 reference $G1F is missing"
G1J=$(jq -c --arg f "$G1F" --arg sha "$(sha256sum "$G1F" | cut -d' ' -f1)" '[.g1_reference[] | select(.db == "standard8")]
  | map({key:.role, value:{file:$f, sha256:$sha, output_sha256:.i0_output_sha256, report_sha256:.i0_report_sha256}}) | from_entries' "$G1F") ||
  fail "cannot read g1_reference from $G1F"
[ "$(jq -r '[.pe.output_sha256, .pe.report_sha256, .se.output_sha256, .se.report_sha256] | map(select(. != null and test("^[0-9a-f]{64}$"))) | length' <<< "$G1J")" = 4 ] ||
  fail "$G1F has no standard8 pe and se reference with both sha256s"
emit "$(jq -c '{kind:"g1-reference", rule:"each sample warm-up I0 output and report sha256 must equal these (upstream at the pin, #95), else defect and stop"} + {references:.}' <<< "$G1J")"

NPROC=$(nproc)
THP0=$(cur_thp)
[ -n "$THP0" ] || fail "cannot read $THP_F"
emit "$(jq -nc --arg fam "$FAMILY" --arg eng "$ENGINE" --arg type "${AK2_INSTANCE_TYPE:-}" --arg ami "${AK2_AMI:-}" \
  --argjson nproc "$NPROC" --arg mem "$(awk '/^MemTotal/{print $2}' /proc/meminfo)" --arg kern "$(uname -r)" \
  --arg cpu "$(lscpu 2> /dev/null | awk -F: '/Model name/{gsub(/^ +/, "", $2); print $2; exit}')" \
  --arg thp "$(cat "$THP_F" 2> /dev/null)" \
  --arg defrag "$(cat "${AK2_REHEARSE_THP_ROOT:-}/sys/kernel/mm/transparent_hugepage/defrag" 2> /dev/null)" \
  --arg shmem "$(cat "${AK2_REHEARSE_THP_ROOT:-}/sys/kernel/mm/transparent_hugepage/shmem_enabled" 2> /dev/null)" \
  --arg pmax "$(cat /proc/sys/fs/pipe-max-size 2> /dev/null)" --arg params "$PARAMS_LINE" \
  '{kind:"host", family:$fam, engine:$eng, instance_type:$type, ami:$ami, nproc:$nproc, mem_total_kb:($mem|tonumber? // null),
    kernel:$kern, cpu:$cpu, thp_enabled_boot:$thp, thp_defrag:$defrag, thp_shmem_enabled:$shmem,
    pipe_max_size:($pmax|tonumber? // null), params:$params}')"
[ "$NPROC" -ge 64 ] || [ -n "${AK2_REHEARSE_DEADLINE_S:-}" ] || fail "nproc $NPROC: the sweep is sized for a 64-vCPU host"

# The engine, built while the inputs stage.
BUILD_PID=""
if [ "$ENGINE" = upstream ]; then
  ( scripts/oracle-build.sh > "$W/build.out" 2> "$W/build.err" ) &
  BUILD_PID=$!
else
  if [ -z "${AK2_REHEARSE_GO:-}" ]; then
    GOV=$(awk '$1=="go"{print $2}' go.mod)
    curl -fsSL --retry 5 --retry-delay 5 "https://go.dev/dl/go$GOV.linux-arm64.tar.gz" -o "$W/go.tgz" || fail "Go $GOV download failed"
    tar -xzf "$W/go.tgz" -C "$W" || fail "Go unpack failed"
    export PATH="$W/go/bin:$PATH"
  fi
  ( make build > "$W/build.out" 2> "$W/build.err" ) &
  BUILD_PID=$!
fi
LV_DIR=$W/lever
# shellcheck source=/dev/null
. scripts/g3/lever.sh || fail "lever.sh did not load"
lv__rg_ensure || fail "rapidgzip $LV_RG_VERSION (lever.sh) install failed"
RG=$LV_RG
RGI=$W/rapidgzip-info.txt
{ echo "== $RG --version"; "$RG" --version 2>&1; echo "== $RG --help"; "$RG" --help 2>&1
  echo "== $RG --oss-attributions"; "$RG" --oss-attributions 2>&1
  echo "== extension"; find "$LV_DIR/rg-venv" -name 'rapidgzip*.so' -exec sh -c 'echo "$1"; sha256sum "$1"; (ldd "$1" 2>&1 || true)' _ {} \; 2> /dev/null
} > "$RGI"
# ISA-L (the plan: confirm the Graviton wheel has it), with #95's detector (scripts/inputpath/lib.sh):
# static, ip_isal_static on the extension (an isal_inflate_init symbol or the isa-l attribution; the
# literal isal_inflate is in an error string of every build, so it is not evidence); runtime,
# ip_isal_runtime ("Time spent decoding with ISA-L" of rapidgzip -v on an input, after staging).
# isal true if either says so, false if static none and runtime 0, else null. #95 found none in
# every pinned aarch64 wheel (docs/inputpath.md, "Pre-flight and inputs").
# shellcheck source=/dev/null
. scripts/inputpath/lib.sh || fail "scripts/inputpath/lib.sh did not load"
RG_SO=$(find "$LV_DIR/rg-venv" -name 'rapidgzip*.so' 2> /dev/null | head -1)
ISAL_STATIC=unknown; [ -n "$RG_SO" ] && ISAL_STATIC=$(ip_isal_static "$RG_SO")
emit "$(jq -nc --arg v "$LV_RG_VERSION" --arg rv "$("$RG" --version 2>&1 | head -1)" --arg path "$RG" \
  --arg whl "$(find "$LV_DIR/rg-wheels" -name 'rapidgzip-*.whl' 2> /dev/null | head -1 | xargs -r basename)" \
  --arg wsha "$(find "$LV_DIR/rg-wheels" -name 'rapidgzip-*.whl' 2> /dev/null | head -1 | xargs -r sha256sum | cut -d' ' -f1)" \
  --arg st "$ISAL_STATIC" --arg so "$RG_SO" --arg info "$(sha256sum "$RGI" | cut -d' ' -f1)" \
  '{kind:"tool", name:"rapidgzip", build_label:"pypi", version:$v, reports:$rv, path:$path, build:("PyPI wheel " + $whl), wheel_sha256:$wsha,
    extension:$so, isal_static:$st, info_file:"rapidgzip-info.txt", info_sha256:$info}')"
ak2_push "$RGI" rapidgzip-info.txt > /dev/null

# ---- RAM: the database, the inputs, the outputs (tmpfs) ----
ak2_phase stage
mnt() {  # DIR SIZE HUGE
  if [ -n "${AK2_REHEARSE_TMPFS:-}" ]; then mkdir -p "$1" && chmod 1777 "$1"; return; fi
  sudo -n mkdir -p "$1" && sudo -n mount -t tmpfs -o "size=$2,huge=$3,mode=1777" tmpfs "$1"
}
R=${AK2_REHEARSE_TMPFS:-/mnt}
DBN=$R/ip-db; DBH=$R/ip-db-huge; IN=$R/ip-in; OUT=$R/ip-out
mnt "$DBN" 12g never || fail "tmpfs $DBN"
mnt "$IN" 90g never || fail "tmpfs $IN"
mnt "$OUT" 24g never || fail "tmpfs $OUT"
for f in opts.k2d taxo.k2d hash.k2d; do
  ak2_stage "s3://$B/$DATA/$DBNAME/$f" "$DBN/$f" || fail "stage of $DBNAME/$f failed"
  s=$(stat -c%s "$DBN/$f")
  ak2_req GetObject $(( s < 8388608 ? 1 : (s + 8388607) / 8388608 )) "$B"
  want=$(aws s3api head-object --bucket "$B" --key "$DATA/$DBNAME/$f" --query Metadata.sha256 --output text)
  ak2_req HeadObject 1 "$B"
  got=$(sha256sum "$DBN/$f" | cut -d' ' -f1)
  [ "$got" = "$want" ] || fail "$DBNAME/$f sha256 $got != metadata $want"
  emit "$(jq -nc --arg f "$f" --arg sha "$got" --argjson b "$s" --arg d "$DBN" '{kind:"db", file:$f, sha256:$sha, bytes:$b, dir:$d}')"
done
if [ "$ENGINE" = upstream ] && { [ "$MAIN_THP" = always ] || [ "$THP_CONTRAST" = 1 ]; }; then
  mnt "$DBH" 12g always || fail "tmpfs $DBH (huge=always)"
  cp "$DBN/opts.k2d" "$DBN/taxo.k2d" "$DBN/hash.k2d" "$DBH/" || fail "copy to $DBH failed"
  for f in opts.k2d taxo.k2d hash.k2d; do cmp -s "$DBN/$f" "$DBH/$f" || fail "$DBH/$f differs from $DBN/$f"; done
  emit "$(jq -nc --arg d "$DBH" --arg shp "$(awk '/^ShmemHugePages/{print $2}' /proc/meminfo)" '{kind:"db-huge", dir:$d, huge:"always", shmem_huge_pages_kb:($shp|tonumber? // null)}')"
fi
# Inputs: every object staged and checked against its row; FASTQ derived with gzip -dc (its sha256
# is the reference every decode must equal); the BGZF's gzip -dc must equal it too.
declare -A REF=() OSHA=() FQB=() KEYS=()
while IFS=$'\t' read -r role acc mate bkt key osha kind src; do
  [ "$kind" = fastq ] && continue
  n="${role}_$mate.$kind"
  ak2_stage "s3://$bkt/$key" "$IN/$n" || fail "stage of s3://$bkt/$key failed"
  s=$(stat -c%s "$IN/$n"); ak2_req GetObject $(( s < 8388608 ? 1 : (s + 8388607) / 8388608 )) "$bkt"
  got=$(sha256sum "$IN/$n" | cut -d' ' -f1)
  [ "$got" = "$osha" ] || fail "$key: sha256 $got != inputs.tsv $osha"
  OSHA[$n]=$got; KEYS[$n]=$key
done <<< "$ROWS"
DERIVE=()
for f in "$IN"/*.gz; do
  ( gzip -dc "$f" | tee "${f%.gz}.fq" | sha256sum | cut -d' ' -f1 > "$f.ref"; [ "${PIPESTATUS[0]}" = 0 ] ) &
  DERIVE+=($!)
done
for f in "$IN"/*.bgzf; do
  ( gzip -dc "$f" | sha256sum | cut -d' ' -f1 > "$f.ref"; [ "${PIPESTATUS[0]}" = 0 ] ) &
  DERIVE+=($!)
done
for p in "${DERIVE[@]}"; do wait "$p" || fail "gzip -dc of an input failed"; done
while IFS=$'\t' read -r role acc mate bkt key osha kind src; do
  m="${role}_$mate"; ref=$(cat "$IN/$m.gz.ref")
  REF[$m]=$ref
  case $kind in
    gz) ok=$([ "$src" = - ] || [ "$src" = "$ref" ] && echo true || echo false) ;;
    fastq) ok=$([ "$osha" = "$ref" ] && echo true || echo false) ;;
    bgzf) [ "$(cat "$IN/$m.bgzf.ref")" = "$ref" ] || fail "$key: gzip -dc gives $(cat "$IN/$m.bgzf.ref"), not $m.gz's $ref"
          ok=$([ "$src" = - ] || [ "$src" = "$ref" ] || [ "$src" = "${OSHA[$m.gz]}" ] && echo true || echo false) ;;
    index) ok=$([ "$src" = - ] || [ "$src" = "$ref" ] || [ "$src" = "${OSHA[$m.gz]}" ] && echo true || echo false) ;;
  esac
  [ "$ok" = true ] || fail "$key ($kind): source_sha256 $src is neither $m's FASTQ ($ref) nor its gz (${OSHA[$m.gz]})"
  [ "$kind" = gz ] && FQB[$m]=$(stat -c%s "$IN/$m.fq")
  emit "$(jq -nc --arg role "$role" --arg acc "$acc" --arg mate "$mate" --arg uri "s3://$bkt/$key" --arg sha "$osha" --arg kind "$kind" \
    --arg src "$src" --arg ref "$ref" --arg file "$IN/$m.$kind" --arg b "$(stat -c%s "$IN/$m.$kind" 2> /dev/null)" --arg fqb "${FQB[$m]:-}" \
    '{kind:"input", role:$role, accession:$acc, mate:($mate|tonumber), uri:$uri, sha256:$sha, input_kind:$kind, source_sha256:$src,
      fastq_sha256:$ref, file:(if $kind == "fastq" then null else $file end), bytes:($b|tonumber? // null), fastq_bytes:($fqb|tonumber? // null)}')"
done <<< "$ROWS"
FQ_PE=$(( FQB[pe_1] + FQB[pe_2] )); FQ_SE=${FQB[se_1]}
ACC_PE=$(awk -F'\t' '$1 == "pe" {print $2; exit}' <<< "$ROWS"); ACC_SE=$(awk -F'\t' '$1 == "se" {print $2; exit}' <<< "$ROWS")

wait "$BUILD_PID" || { tail -30 "$W/build.err"; fail "the $ENGINE build failed"; }
if [ "$ENGINE" = upstream ]; then
  K2DIR=$(scripts/oracle-build.sh 2> /dev/null) || fail "upstream build not found"
  BIN=$K2DIR/kraken2; BUILD=$(tr '\n' ';' < "$K2DIR/BUILD")
else
  BIN=$W/repo/bin/aws-kraken2; BUILD="ours $(git rev-parse HEAD); $(go version 2> /dev/null)"
fi
[ -x "$BIN" ] || fail "no classifier at $BIN"
emit "$(jq -nc --arg e "$ENGINE" --arg bin "$BIN" --arg b "$BUILD" '{kind:"engine", engine:$e, bin:$bin, build:$b}')"
ak2_push "$J" events.jsonl > /dev/null
ak2_push "$LV_REC" lever.jsonl > /dev/null

# ---- the points ----
TFMT='ak2time wall_s=%e maxrss_kb=%M exit=%x user_s=%U sys_s=%S'
TIMEQ=$(printf '/usr/bin/time -f %q' "$TFMT")
declare -A IDS=() IDJ=() BESTP=()
POINTS_DONE=0; DEFECTS=0
# The rapidgzip builds of the matrix, by the points' decomp label: rapidgzip (lever.sh's pinned PyPI
# wheel, always) and, off by default, rapidgzip-2, a second build, from exactly one of:
#   RG2_WHEEL=<https url>@<sha256>: a pinned wheel, downloaded, checked against the sha256 and
#     installed with pip --require-hashes into its own venv (as lever.sh installs the first); e.g.
#     the 0.16.0 cp39 aarch64 wheel, which carries ISA-L (#97). Its use waits for #97's verdict on
#     whether 0.16.0 is crash-free on Graviton.
#   RG2_SCRIPT=<script in the tree>: a source build (e.g. scripts/g3/rg-build.sh); it gets a work
#     dir and prints the binary's path as its last stdout line. (0.14.5 cannot build ISA-L on
#     aarch64, #97.)
# Its version, build and ISA-L verdict go into every one of its points (rapidgzip {...}).
declare -A RGBIN=() RGJS=()
isal_of() {  # LABEL BIN STATIC: rapidgzip -v's ISA-L time on the se gz, then the isal verdict line
  local rt v
  rt=$(ip_isal_runtime "$2" "$IN/se_1.gz")
  v=null
  if [ "$3" = isal ] || awk -v r="${rt:-0}" 'BEGIN{exit !(r > 0)}'; then v=true
  elif [ "$3" = none ] && [ -n "$rt" ] && awk -v r="$rt" 'BEGIN{exit !(r == 0)}'; then v=false; fi
  emit "$(jq -nc --arg l "$1" --arg st "$3" --arg rt "$rt" --argjson v "$v" '{kind:"isal", build_label:$l, isal:$v, static:$st,
    runtime_isal_s:($rt|tonumber? // null), rule:"true if the static check (#95: isal_inflate_init symbol or the isa-l attribution) or rapidgzip -v ISA-L time > 0; false if static none and 0 s; else null",
    reference:"#95: the pinned 0.14.5 manylinux aarch64 wheels carry no ISA-L (docs/inputpath.md, Pre-flight and inputs)"}')"
  ISAL_V=$v
}
RGBIN[rapidgzip]=$RG
isal_of rapidgzip "$RG" "$ISAL_STATIC"; ISAL=$ISAL_V
RGJS[rapidgzip]=$(jq -nc --arg v "$LV_RG_VERSION" --argjson isal "$ISAL" '{version:$v, build:"pypi", isal:$isal}')
RG2="" RG2_SO="" RG2_BUILD="" RG2_DETAIL=""
[ -n "$RG2_SCRIPT" ] && [ -n "$RG2_WHEEL" ] && fail "RG2_SCRIPT and RG2_WHEEL are exclusive"
if [ -n "$RG2_WHEEL" ]; then
  RG2_URL=${RG2_WHEEL%@*}; RG2_SHA=${RG2_WHEEL##*@}
  [[ $RG2_URL == https://*.whl && $RG2_SHA =~ ^[0-9a-f]{64}$ ]] || fail "RG2_WHEEL must be <https url of a .whl>@<sha256> (got $RG2_WHEEL)"
  mkdir -p "$W/rg2/wheels" || fail "mkdir rg2"
  RG2_WHL=$W/rg2/wheels/$(basename "$RG2_URL")
  curl -fsSL --retry 5 --retry-delay 5 "$RG2_URL" -o "$RG2_WHL" || fail "download of $RG2_URL failed"
  [ "$(sha256sum "$RG2_WHL" | cut -d' ' -f1)" = "$RG2_SHA" ] || fail "$RG2_WHL: sha256 is not the pinned $RG2_SHA"
  python3 -m venv "$W/rg2/venv" || fail "venv for the second rapidgzip failed"
  printf '%s --hash=sha256:%s\n' "$RG2_WHL" "$RG2_SHA" > "$W/rg2/requirements.txt"
  "$W/rg2/venv/bin/pip" install -q --no-deps --no-index --only-binary=:all: --require-hashes -r "$W/rg2/requirements.txt" > "$W/rg2/pip.log" 2>&1 ||
    { tail -5 "$W/rg2/pip.log"; fail "pip install --require-hashes of $RG2_WHL failed"; }
  RG2=$W/rg2/venv/bin/rapidgzip; RG2_SO=$(find "$W/rg2/venv" -name 'rapidgzip*.so' | head -1)
  RG2_BUILD=pypi; RG2_DETAIL="PyPI wheel $(basename "$RG2_WHL") (sha256 $RG2_SHA, pip --require-hashes)"
elif [ -n "$RG2_SCRIPT" ]; then
  [ -f "$RG2_SCRIPT" ] || fail "RG2_SCRIPT $RG2_SCRIPT is not in the tree"
  RG2=$(bash "$RG2_SCRIPT" "$W/rg2" 2> "$W/rg2.err" | tail -1) || { tail -20 "$W/rg2.err"; fail "$RG2_SCRIPT failed"; }
  RG2_SO=$(find "$(dirname "$(dirname "$RG2")")" -name 'rapidgzip*.so' 2> /dev/null | head -1)
  RG2_BUILD=source; RG2_DETAIL="source build by $RG2_SCRIPT (sha256 $(sha256sum "$RG2_SCRIPT" | cut -d' ' -f1))"
fi
if [ -n "$RG2" ]; then
  RG2_V=$("$RG2" --version 2>&1 | sed -n 's/.*rapidgzip version \([0-9][0-9.]*\).*/\1/p' | head -1)
  [ -x "$RG2" ] && [ -n "$RG2_V" ] || fail "the second rapidgzip ($RG2) does not report a version"
  RGBIN[rapidgzip-2]=$RG2
  isal_of rapidgzip-2 "$RG2" "$(ip_isal_static "${RG2_SO:-$RG2}")"; ISAL2=$ISAL_V
  RGJS[rapidgzip-2]=$(jq -nc --arg v "$RG2_V" --arg b "$RG2_BUILD" --argjson isal "$ISAL2" --arg d "$RG2_DETAIL" '{version:$v, build:$b, isal:$isal, build_detail:$d}')
  emit "$(jq -nc --arg p "$RG2" --arg v "$RG2_V" --arg b "$RG2_BUILD" --arg d "$RG2_DETAIL" --arg so "$RG2_SO" \
    --arg sosha "$([ -n "$RG2_SO" ] && sha256sum "$RG2_SO" | cut -d' ' -f1)" \
    '{kind:"tool", name:"rapidgzip", build_label:"rapidgzip-2", version:$v, build:$b, build_detail:$d, path:$p, extension:$so, extension_sha256:$sosha}')"
fi
set_thp() {
  [ "$(cur_thp)" = "$1" ] && return 0
  echo "$1" | sudo -n tee "$THP_F" > /dev/null 2>&1
  [ "$(cur_thp)" = "$1" ] || fail "THP enabled=$1 was not applied (reads $(cur_thp))"
}
time_exit() { awk '/terminated by signal/ {s = 128 + $NF} /ak2time/ {for (i = 1; i <= NF; i++) if ($i ~ /^exit=/) e = substr($i, 6)} END {print (s != "" ? s : (e != "" ? e : "missing"))}' "$1" 2> /dev/null || echo missing; }
# identity BIN FILE MATEKEY ARGS...: that rapidgzip build and configuration on FILE, to sha256sum,
# against gzip -dc's. A failed attempt (crash, timeout, mismatch) is retried once: 0.14.5's rpmalloc
# race crashes about 0.25% of decodes on Graviton (#89), so one crash is not the configuration's
# verdict. Each attempt is its own identity line (attempt 1, 2); the configuration is excluded only
# if both fail. The point's identity object is the deciding attempt's, with every attempt listed.
identity() {
  local bin=$1 f=$2 m=$3; shift 3
  local key="$bin|$f|$*" tf=$W/identity.time t0 t1 got rc ex st line att atts="[]"
  case ${IDS[$key]:-} in ok) return 0 ;; ?*) return 1 ;; esac
  for att in 1 2; do
    rm -f "$tf"; t0=$(now); st=ok
    got=$(timeout -k 30 "$ID_TIMEOUT" /usr/bin/time -f "$TFMT" -o "$tf" "$bin" -d -c "$@" "$f" 2> "$W/identity.err" | sha256sum | cut -d' ' -f1)
    rc=${PIPESTATUS[0]}; t1=$(now)
    ex=$(time_exit "$tf")
    if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then st=timeout; elif [ "$rc" != 0 ] || [ "$ex" != 0 ]; then st=crash; elif [ "$got" != "${REF[$m]}" ]; then st=mismatch; fi
    line=$(jq -nc --arg bin "$bin" --arg f "$f" --arg m "$m" --arg args "$*" --arg st "$st" --arg rc "$rc" --arg ex "$ex" --arg got "$got" --arg want "${REF[$m]}" \
      --arg t0 "$t0" --arg t1 "$t1" --arg fqb "${FQB[$m]}" --arg err "$(tail -c 400 "$W/identity.err")" --argjson att "$att" \
      '{kind:"identity", attempt:$att, bin:$bin, file:$f, mate:$m, args:$args, status:$st, ok:($st == "ok"), exit:($rc|tonumber? // $rc),
        decoder_exit:($ex|tonumber? // $ex), sha256:$got, want_sha256:$want, seconds:(($t1|tonumber) - ($t0|tonumber)),
        mb_per_s:(($fqb|tonumber) / (($t1|tonumber) - ($t0|tonumber)) / 1e6), stderr_tail:(if $st == "ok" then null else $err end)}')
    emit "$line"
    atts=$(jq -c --argjson l "$line" '. + [$l | {attempt, status, decoder_exit, sha256}]' <<< "$atts")
    [ "$st" = ok ] && break
  done
  IDS[$key]=$st
  IDJ[$key]=$(jq -c --argjson a "$atts" '{mate:(.mate | split("_")[1] | tonumber), gz_sha256:.want_sha256, rg_sha256:.sha256,
    rg_exit:(if (.decoder_exit|type) == "number" then .decoder_exit else 255 end), ok, status, args, attempts:$a}' <<< "$line")
  [ "$st" = ok ]
}
# point REP SAMPLE ARM T P CHUNK PIPE THP DECOMP [WARMUP]: one classifier run (- for n/a), recorded
# by scripts/inputpath/record.py (schema inputpath-point/1).
point() {
  local rep=$1 s=$2 arm=$3 t=$4 p=$5 ck=$6 pipe=$7 thp=$8 dec=$9 warm=${10:-0}
  local id="r$rep-$s-$arm-t$t-p$p-c$ck-pipe$pipe-thp$thp-$dec"; [ "$warm" = 1 ] && id="warmup-$s"
  id=${id//[^A-Za-z0-9._-]/_}
  local D=$W/pts/$id paired=0 fqb=$FQ_SE mates="1" db=$DBN files="" m rgargs="" envp="" sho="" shr="" rec st idl="[]" mj="[]" kind=gz rgb="" rgj=null
  [ "$s" = pe ] && { paired=1; fqb=$FQ_PE; mates="1 2"; }
  [ "$ENGINE" = upstream ] && [ "$thp" = always ] && [ -s "$DBH/hash.k2d" ] && db=$DBH
  [ "$arm" = I4 ] && kind=bgzf
  rm -rf "$D"; mkdir -p "$D"
  for m in $mates; do
    mj=$(jq -c --argjson m "$m" --arg k "${KEYS[${s}_$m.$kind]}" --arg h "${OSHA[${s}_$m.$kind]}" --arg f "${REF[${s}_$m]}" \
      --arg ik "${KEYS[${s}_$m.index]}" --arg ih "${OSHA[${s}_$m.index]}" \
      '. + [{mate:$m, s3_key:$k, sha256:$h, fastq_sha256:$f, index_s3_key:$ik, index_sha256:$ih}]' <<< "$mj")
  done
  local skip=""
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then skip="deadline: not started before the run's deadline (launch + TTL - margin)"
  elif [ "$warm" != 1 ] && [ ! -s "$W/ref-$s.json" ]; then skip="no-reference: the sample's warm-up I0 did not give a reference"
  fi
  case $arm in
    I0) for m in $mates; do files="$files $IN/${s}_$m.fq"; done ;;
    I1) for m in $mates; do files="$files $IN/${s}_$m.gz"; done; files=" --gzip-compressed$files"
        [ "$dec" = pipe ] && envp="env AK2_DECOMPRESS=pipe "; [ "$dec" = inproc ] && envp="env -u AK2_DECOMPRESS " ;;
    I2|I3|I4)
      if [ -z "$skip" ] && [ "$p" = - ]; then skip="no-best-p: rep 1 gave no usable I2 point at these threads"; fi
      rgb=${RGBIN[$dec]:-}; rgj=${RGJS[$dec]:-null}
      [ -n "$rgb" ] || fail "point $id: no rapidgzip build '$dec'"
      for m in $mates; do
        [ -n "$skip" ] && break
        local src=$IN/${s}_$m.gz
        case $arm in
          I2) rgargs="-P $p --chunk-size $ck" ;;
          I3) rgargs="-P $p --import-index $IN/${s}_$m.index" ;;
          I4) rgargs="-P $p --chunk-size $ck"; src=$IN/${s}_$m.bgzf ;;
        esac
        # shellcheck disable=SC2086  # rgargs is a word list
        identity "$rgb" "$src" "${s}_$m" $rgargs || skip="identity: $dec $rgargs on $(basename "$src") was ${IDS[$rgb|$src|$rgargs]} in both identity attempts"
        idl=$(jq -c --argjson i "${IDJ[$rgb|$src|$rgargs]:-null}" '. + [$i]' <<< "$idl")
        files="$files <(python3 $IP/pipesz.py $pipe $D/pipe$m.txt $TIMEQ -o $D/rg$m.time $rgb -d -c $rgargs $src)"
      done ;;
  esac
  local cmd="$envp$TIMEQ -o $D/k2.time $BIN --db $db --threads $t$([ "$paired" = 1 ] && echo " --paired") --output $OUT/output --report $OUT/report$files"
  jq -n --arg id "$id" --argjson rep "$rep" --argjson warm "$warm" --arg fam "$FAMILY" --arg eng "$ENGINE" --arg it "${AK2_INSTANCE_TYPE:-}" \
    --arg dbn "$DBNAME" --arg db "$db" --arg s "$s" --arg acc "$([ "$s" = pe ] && echo "$ACC_PE" || echo "$ACC_SE")" --arg arm "$arm" \
    --argjson t "$t" --arg p "$p" --arg ck "$ck" --arg pipe "$pipe" --arg thp "$thp" --arg dec "$dec" --argjson fqb "$fqb" \
    --argjson nproc "$NPROC" --argjson mates "$mj" --argjson ids "$idl" --argjson rg "$rgj" --argjson g1 "$G1J" --arg cmd "$cmd" '
    {id:$id, rep:$rep, warmup:($warm == 1), family:$fam, engine:$eng, instance_type:$it, db:$dbn, db_dir:$db, role:$s, accession:$acc,
     arm:$arm, threads:$t, p:($p|tonumber? // null), chunk_kib:($ck|tonumber? // null), pipe_requested:$pipe, thp_requested:$thp,
     decomp:$dec, fq_bytes:$fqb, nproc:$nproc, mates:$mates, identity:$ids, rapidgzip:$rg, g1_reference:($g1[$s] // null), cmd:$cmd}' > "$D/params.json"
  if [ -n "$skip" ]; then
    rec=$(python3 "$IP/record.py" --params "$D/params.json" --skip "$skip")
    emit_point "$rec"; return 0
  fi
  set_thp "$thp"
  rm -rf "${OUT:?}"/*
  printf '%s\n' "$cmd" > "$D/cmd.txt"
  python3 "$IP/run_point.py" --dir "$D" --fq-bytes "$fqb" --paired "$paired" --timeout "$POINT_TIMEOUT" -- "$cmd" > "$D/result.json" 2> "$D/run_point.err"
  [ -s "$OUT/output" ] && sho=$(sha256sum "$OUT/output" | cut -d' ' -f1)
  [ -s "$OUT/report" ] && shr=$(sha256sum "$OUT/report" | cut -d' ' -f1)
  rec=$(python3 "$IP/record.py" --params "$D/params.json" --result "$D/result.json" --dir "$D" --thp "$(cur_thp)" \
    --pidstat-csv "out/pidstat/$id.csv" --output-sha256 "$sho" --report-sha256 "$shr" --reference "$W/ref-$s.json" 2> "$D/record.err")
  jq -e . <<< "$rec" > /dev/null 2>&1 || fail "record.py failed on $id: $(tail -c 300 "$D/record.err")"
  st=$(jq -r '.harness.status_detail' <<< "$rec")
  [ "$st" = reference ] && jq -c '{output_sha256, report_sha256, sequences:.harness.sequences, point_id}' <<< "$rec" > "$W/ref-$s.json"
  emit_point "$rec"
  if [ "$(jq -r .status <<< "$rec")" = defect ]; then
    DEFECTS=$((DEFECTS + 1))
    emit "$(jq -c '{kind:"defect", point_id, arm, threads, p, status_detail:.harness.status_detail, note}' <<< "$rec")"
  fi
  [ "$st" = law1-g1-mismatch ] && fail "Law 1: the $s warm-up I0 differs from upstream at the pin ($G1F): $(jq -r .note <<< "$rec")"
  [ -s "$D/pidstat.csv" ] && ak2_push "$D/pidstat.csv" "pidstat/$id.csv" > /dev/null
  rm -f "$D/pidstat.txt"
  tar -czf "$W/pt.tgz" -C "$D" . 2> /dev/null && ak2_push "$W/pt.tgz" "points/$id.tgz" > /dev/null
  ak2_push "$PJ" points.jsonl > /dev/null
  rm -rf "${OUT:?}"/*
  POINTS_DONE=$((POINTS_DONE + 1))
}
# select_p SAMPLE T: rep 1's best p for that sample and thread count (the rule in the header).
select_p() {
  local s=$1 t=$2 bp role=single
  [ "$s" = pe ] && role=paired
  bp=$(jq -s -r --arg r "$role" --argjson t "$t" --arg pipe "$PIPE_BYTES" --arg thp "$MAIN_THP" '
    [.[] | select(.rep == 1 and .input.role == $r and .arm == "I2" and .threads == $t and .chunk_mib == 4
      and .harness.pipe_requested == $pipe and .harness.thp_requested == $thp and .harness.decomp == "rapidgzip"
      and .status == "ok" and .identity.ok == true and .wall_s != null)] as $c
    | if ($c | length) == 0 then "-" else ($c | map(.wall_s) | min) as $m | [$c[] | select(.wall_s <= $m * 1.01) | .p] | min | tostring end' "$PJ")
  BESTP[$s:$t]=$bp
  emit "$(jq -nc --arg s "$s" --arg r "$role" --argjson t "$t" --arg bp "$bp" --slurpfile all "$PJ" '{kind:"select", sample:$s, threads:$t, best_p:($bp|tonumber? // null),
    rule:"rep 1 I2 points of the PyPI build at chunk 4 MiB, the main pipe size and THP, status ok and identity ok: the smallest p with wall_s <= 1.01 x the minimum wall_s",
    candidates:[$all[] | select(.rep == 1 and .input.role == $r and .arm == "I2" and .threads == $t and .chunk_mib == 4) | {p, wall_s, status, point_id}]}')"
}
OTHER_THP=never; [ "$MAIN_THP" = never ] && OTHER_THP=always
# Rep 1's list, sample by sample (the smaller FASTQ first: cheapest first), built as it runs
# (the best p comes from its own I2 points); rep 2 runs the same list reversed.
SAMPLES="se pe"; [ "$FQ_PE" -lt "$FQ_SE" ] && SAMPLES="pe se"
LIST=()
run1() { LIST+=("$*"); point 1 "$@"; }
ak2_drop_caches
emit "$(jq -nc --arg m "$(awk '/^(MemAvailable|Shmem):/{printf "%s=%s ", $1, $2}' /proc/meminfo)" '{kind:"drop-caches", ok:true, meminfo:$m}')"
ak2_phase measure
[ -n "${AK2_REHEARSE_DEADLINE_S:-}" ] && DEADLINE=$(( $(date +%s) + AK2_REHEARSE_DEADLINE_S ))
TMAX=$(tr ' ' '\n' <<< "$THREADS" | sort -n | tail -1)
for s in $SAMPLES; do
  point 1 "$s" I0 "$TMAX" - - - "$MAIN_THP" - 1
  for t in $THREADS; do run1 "$s" I0 "$t" - - - "$MAIN_THP" -; done
  [ "$THP_CONTRAST" = 1 ] && for t in $THREADS; do run1 "$s" I0 "$t" - - - "$OTHER_THP" -; done
  for p in $PS; do for t in $THREADS; do run1 "$s" I2 "$t" "$p" 4096 "$PIPE_BYTES" "$MAIN_THP" rapidgzip; done; done
  for t in $THREADS; do select_p "$s" "$t"; done
  for t in $THREADS; do run1 "$s" I3 "$t" "${BESTP[$s:$t]}" - "$PIPE_BYTES" "$MAIN_THP" rapidgzip; done
  for t in $THREADS; do run1 "$s" I4 "$t" "${BESTP[$s:$t]}" 4096 "$PIPE_BYTES" "$MAIN_THP" rapidgzip; done
  for c in $CHUNKS; do for t in $THREADS; do run1 "$s" I2 "$t" "${BESTP[$s:$t]}" "$c" "$PIPE_BYTES" "$MAIN_THP" rapidgzip; done; done
  [ "$PIPE_CONTRAST" = 1 ] && for t in $THREADS; do run1 "$s" I2 "$t" "${BESTP[$s:$t]}" 4096 default "$MAIN_THP" rapidgzip; done
  if [ -n "${RGBIN[rapidgzip-2]:-}" ]; then
    for t in $THREADS; do run1 "$s" I2 "$t" "${BESTP[$s:$t]}" 4096 "$PIPE_BYTES" "$MAIN_THP" rapidgzip-2; done
    for t in $THREADS; do run1 "$s" I3 "$t" "${BESTP[$s:$t]}" - "$PIPE_BYTES" "$MAIN_THP" rapidgzip-2; done
    for t in $THREADS; do run1 "$s" I4 "$t" "${BESTP[$s:$t]}" 4096 "$PIPE_BYTES" "$MAIN_THP" rapidgzip-2; done
  fi
  if [ "$ENGINE" = ours ]; then
    for t in $THREADS; do run1 "$s" I1 "$t" - - - "$MAIN_THP" inproc; done
    for t in $THREADS; do run1 "$s" I1 "$t" - - - "$MAIN_THP" pipe; done
  else
    for t in $THREADS; do run1 "$s" I1 "$t" - - - "$MAIN_THP" wrapper-gzip; done
  fi
done
for ((rep = 2; rep <= REPS; rep++)); do
  for ((i = ${#LIST[@]} - 1; i >= 0; i--)); do
    # shellcheck disable=SC2086  # a list entry is a word list
    point "$rep" ${LIST[$i]}
  done
done
ak2_phase wrapup
restore_thp
python3 "$IP/tables.py" "$PJ" "$W/inputpath.tsv" > "$W/tables.log" 2>&1 || ak2_say "WARN: tables.py failed: $(tail -3 "$W/tables.log")"
[ -s "$W/inputpath.tsv" ] && ak2_push "$W/inputpath.tsv" inputpath.tsv > /dev/null
emit "$(jq -s -c --argjson d "$DEFECTS" --arg thp0 "$THP0" --arg thp "$(cur_thp)" --slurpfile ev "$J" '{kind:"summary", points:length,
  by_status:(group_by(.status) | map({key:.[0].status, value:length}) | from_entries),
  by_detail:(group_by(.harness.status_detail) | map({key:.[0].harness.status_detail, value:length}) | from_entries),
  identity:([$ev[] | select(.kind == "identity")] | group_by(.status) | map({key:.[0].status, value:length}) | from_entries),
  defects:$d, thp_boot:$thp0, thp_restored:($thp == $thp0)}' "$PJ")"
ak2_push "$PJ" points.jsonl > /dev/null
ak2_push "$J" events.jsonl > /dev/null
ak2_push "$LV_REC" lever.jsonl > /dev/null
ak2_say "inputpath: $POINTS_DONE points run, $DEFECTS defects"
exit 0
