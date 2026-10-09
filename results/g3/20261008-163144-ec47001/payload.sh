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

# G3 U1 (#25, #41; Scott approved the campaign 2026-10-08): upstream kraken2 at the pin (pristine,
# built from source here) at its best for a cohort, resident: RODA v205 on a huge=always tmpfs
# (G2's ram regime) with --memory-mapping, so no sample reloads the table, on x8g.24xlarge (96
# vCPU, 1536 GiB). The first 100 samples of the recorded cohort (results/cohort/PRJNA398089/
# runs.tsv), gz as staged and fq (gunzipped onto a tmpfs before the sample's rungs; not timed).
# Rungs (scripts/g3/u1.plan order; one upstream invocation per sample, --paired):
#   A  cohort 1 (sample 1): gz and fq, T in {48, 96, 192}, n = 3, the T order rotated per rep
#   B  cohort 10: fq T in {48, 96, 192} (sample-major: each sample's fq made once, its three
#      T back to back); gz T = 48 one sample at a time; gz P = 10 samples at once, T = 8
#   C  cohort 100: fq T in {48, 96, 192} (sample-major), the T = 96 rung also computing the
#      engine's S3 ETag of every output and report (scripts/lib/ak2etag.py) for the Law-1
#      cross-check with E2's outputs; gz P = 12 x T = 8, P = 24 x T = 4 and (an addition, Scott 2026-10-08) P = 48 x T = 2 (upstream decompresses
#      gz on one thread per process, so at a cohort its best is several processes at once)
#   ref  sample 1 fq T = 96 before A and after A, B and C, with /proc/buddyinfo and the vmstat
#      compaction counters (#41: drift over the run)
# Upstream at cohort 100 gz one process at a time is not run (about 50 min): it is dominated by
# the P x T rungs and modelled from B's per-sample rate, flagged. Upstream at cohort 1000 is
# modelled (Scott, 2026-10-07). Every sample line streams into the run log as "u1-sample {json}"
# and into out/u1.jsonl (pushed after every rung); tables come from scripts/post/<spec>.sh.
W=$HOME/ak2; mkdir -p "$W"
SHA=${AK2_RUN_ID##*-}
B=aws-kraken2-942542972736-us-west-2; CK=aws-kraken2/data/cohort
COHORT=100; C10=10
# make rehearse's seams (scripts/lib/u_rehearse.sh; run.sh refuses AK2_REHEARSE_* in a spec's env,
# so on AWS they are unset): fewer samples.
COHORT=${AK2_REHEARSE_COHORT:-$COHORT}; C10=${AK2_REHEARSE_C10:-$C10}
fail() { ak2_say "ERROR: $*"; exit 1; }
hex64() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

ak2_phase setup
sudo -n dnf install -y -q git > "$W/dnf0.log" 2>&1 || fail "dnf git failed"
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "no repo"
. scripts/g2-instance.sh
g2i_setup
sudo -n dnf install -y -q pigz > "$W/dnf1.log" 2>&1 || fail "dnf pigz failed"
U=scripts/upstream-cohort.sh
RAMDB=$($U mount roda 1150g) || fail "tmpfs for RODA failed"
IN=$($U mount inputs 140g) || fail "tmpfs for inputs failed"
SCR=$($U mount scratch 160g) || fail "tmpfs for scratch failed"
ak2_say "tmpfs: $RAMDB $IN $SCR; $(df -h "$RAMDB" "$IN" "$SCR" | tail -3 | tr -s ' ' | tr '\n' ';')"

ak2_phase fetch-db
( scripts/oracle-build.sh > "$W/build.out" 2>&1 ) &
BUILD_PID=$!
g2i_awscfg 40Gb/s
g2i_stage_roda "$RAMDB"
wait "$BUILD_PID" || { cat "$W/build.out"; fail "build failed"; }
cat "$W/build.out"
K2DIR=$(scripts/oracle-build.sh 2>/dev/null) || fail "upstream build not found"
K2="$K2DIR/kraken2"
ak2_say "upstream $(tr '\n' ';' < "$K2DIR/BUILD")"
unset AWS_CONFIG_FILE

ak2_phase fetch-inputs
RUNS=results/cohort/PRJNA398089/runs.tsv
mapfile -t SAMPLES < <(awk -F'\t' -v c="$COHORT" 'NR>1 && $1<=c {print $2}' "$RUNS")
mapfile -t PAIRS < <(awk -F'\t' -v c="$COHORT" 'NR>1 && $1<=c {print $4}' "$RUNS")
if [ -n "${AK2_REHEARSE_SAMPLES:-}" ]; then
  read -r -a SAMPLES <<< "$AK2_REHEARSE_SAMPLES"; read -r -a PAIRS <<< "$AK2_REHEARSE_WEIGHTS"
fi
[ "${#SAMPLES[@]}" = "$COHORT" ] || fail "want $COHORT cohort runs, got ${#SAMPLES[@]}"
FILES=()
for s in "${SAMPLES[@]}"; do FILES+=("${s}_1.fastq.gz" "${s}_2.fastq.gz"); done
DEST=$IN; LANES=16
# scripts/g3/fetch.sh, a child process (its lanes are its own jobs, waited for by PID: the
# body's earlier wait -n, bare and then with -p over a PID list, miscounted at 8a6dbe6 and looped
# on "no such job" at 1a4dbfe), under a watchdog of FETCH_LIMIT seconds.
FETCH_LIMIT=1500
"$W/repo/scripts/g3/fetch.sh" "$B" "$CK" "$DEST" "$LANES" "${FILES[@]}" > "$W/fetched.txt" 2>&1 &
FP=$!
( sleep "$FETCH_LIMIT"; kill -TERM "$FP" 2>/dev/null ) > /dev/null 2>&1 &
WD=$!
wait "$FP"; FERR=$?
kill "$WD" 2>/dev/null
grep ERROR "$W/fetched.txt" | head -5
[ "$FERR" = 0 ] && [ "$(grep -vc ERROR "$W/fetched.txt")" = $((2 * COHORT)) ] || fail "input fetch failed"
ak2_req GetObject "$(awk '!/ERROR/{n += int(($2 + 8388607) / 8388608)} END{print n+0}' "$W/fetched.txt")" "$B"
ak2_req HeadObject "$((2 * COHORT))" "$B"
ak2_say "inputs staged and verified: $((2 * COHORT)) files, $(awk '!/ERROR/{s+=$2} END{printf "%.2f GB", s/1e9}' "$W/fetched.txt")"

# One sample, one upstream invocation. u1_one RUNG INPUT T J ETAG -> a u1-sample json line.
J="$W/u1.jsonl"; : > "$J"
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
u1_one() {
  local rung=$1 input=$2 t=$3 j=$4 doetag=$5 s=${SAMPLES[$4]} d="$SCR/out/$1/${SAMPLES[$4]}" i1 i2 t0 t1 rc cs oe=- re=-
  mkdir -p "$d"
  if [ "$input" = gz ]; then i1="$IN/${s}_1.fastq.gz"; i2="$IN/${s}_2.fastq.gz"; else i1="$SCR/fq/${s}_1.fq"; i2="$SCR/fq/${s}_2.fq"; fi
  t0=$(now)
  "$K2" --db "$RAMDB" --memory-mapping --paired --threads "$t" --output "$d/output" --report "$d/report" "$i1" "$i2" \
    > /dev/null 2> "$d/stderr"
  rc=$?
  t1=$(now)
  cs=$(sed -nE 's/.*processed in ([0-9.]+)s.*/\1/p' "$d/stderr" | tail -1)
  if [ "$doetag" = 1 ] && [ "$rc" = 0 ]; then
    oe=$(python3 scripts/lib/ak2etag.py output "$d/output" | cut -f1); re=$(python3 scripts/lib/ak2etag.py report "$d/report" | cut -f1)
  fi
  local line
  line=$(jq -nc --arg rung "$rung" --arg input "$input" --argjson t "$t" --arg sample "$s" --argjson pairs "${PAIRS[$j]}" \
    --argjson exit "$rc" --arg t0 "$t0" --arg t1 "$t1" --arg cs "${cs:-}" --arg oe "$oe" --arg re "$re" \
    --arg tail "$(tail -2 "$d/stderr" | tr '\n' ' ' | cut -c1-200)" \
    '{kind:"sample", rung:$rung, input:$input, threads:$t, sample:$sample, pairs:$pairs, exit:$exit,
      start:($t0|tonumber), end:($t1|tonumber), wall_s:(($t1|tonumber)-($t0|tonumber)),
      classify_s:(if $cs == "" then null else ($cs|tonumber) end), output_etag:$oe, report_etag:$re, stderr_tail:$tail}')
  echo "$line" >> "$J"
  echo "u1-sample $line"
  rm -rf "$d"
  [ "$rc" = 0 ]
}
# u1_fq J: sample J's fq onto the scratch tmpfs (not timed in any rung).
u1_fq() {
  local s=${SAMPLES[$1]} m t0 t1 line
  mkdir -p "$SCR/fq"
  t0=$(now)
  for m in 1 2; do pigz -dc -p 16 "$IN/${s}_$m.fastq.gz" > "$SCR/fq/${s}_$m.fq" || return 1; done
  t1=$(now)
  # The preparation's own time, so fq rungs are reported as pre-decompressed with what that cost.
  line=$(jq -nc --arg s "$s" --arg t0 "$t0" --arg t1 "$t1" --argjson b "$(( $(stat -c%s "$SCR/fq/${s}_1.fq") + $(stat -c%s "$SCR/fq/${s}_2.fq") ))" \
    '{kind:"prep", sample:$s, tool:"pigz -dc -p 16", start:($t0|tonumber), seconds:(($t1|tonumber)-($t0|tonumber)), fq_bytes:$b}')
  echo "$line" >> "$J"; echo "u1-prep $line"
}
u1_fq_rm() { rm -f "$SCR/fq/${SAMPLES[$1]}_"[12].fq; }
# u1_pass RUNG INPUT T P COHORT ETAG: the first COHORT samples on P processes at once (gz), and
# a u1-rung line. The samples go to the P lanes largest first, each to the lane with the fewest
# pairs so far (LPT, as the engine places them): upstream at its best with known sizes.
FAIL=0
u1_pass() {
  local rung=$1 input=$2 t=$3 p=$4 c=$5 doetag=$6 j t0 t1 l best
  ak2_phase "$rung"
  local -a load lane order
  for ((l = 0; l < p; l++)); do load[$l]=0; lane[$l]=""; done
  mapfile -t order < <(for ((j = 0; j < c; j++)); do echo "$j ${PAIRS[$j]}"; done | sort -k2,2nr -k1,1n | cut -d' ' -f1)
  for j in "${order[@]}"; do
    best=0
    for ((l = 1; l < p; l++)); do [ "${load[$l]}" -lt "${load[$best]}" ] && best=$l; done
    lane[$best]="${lane[$best]} $j"; load[$best]=$(( load[best] + PAIRS[j] ))
  done
  t0=$(now)
  local pids=() pid
  for ((l = 0; l < p; l++)); do
    ( r=0; for j in ${lane[$l]}; do u1_one "$rung" "$input" "$t" "$j" "$doetag" || r=1; done; exit "$r" ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" || FAIL=1; done
  t1=$(now)
  u1_rungline "$rung" "$input" "$t" "$p" "$c" "$t0" "$t1"
}
u1_rungline() {
  local line
  line=$(jq -nc --arg rung "$1" --arg input "$2" --argjson t "$3" --argjson p "$4" --argjson c "$5" --arg t0 "$6" --arg t1 "$7" \
    '{kind:"rung", rung:$rung, input:$input, threads:$t, procs:$p, cohort:$c, start:($t0|tonumber), end:($t1|tonumber),
      pass_wall_s:(($t1|tonumber)-($t0|tonumber))}')
  echo "$line" >> "$J"; echo "u1-rung $line"
  ak2_push "$J" u1.jsonl > /dev/null
}
# u1_fqpass PREFIX C ETAG96 T...: fq rungs over the first C samples, sample-major (each sample's
# fq made once, its T rungs back to back); one u1-rung line per T, its pass time the sum of
# its samples' walls (the fq preparation excluded).
u1_fqpass() {
  local pre=$1 c=$2 e96=$3 j t; shift 3
  ak2_phase "$pre-fq"
  for ((j = 0; j < c; j++)); do
    u1_fq "$j" || { FAIL=1; ak2_say "fq of ${SAMPLES[$j]} failed"; return 1; }
    for t in "$@"; do
      local e=0; [ "$t" = 96 ] && e=$e96
      u1_one "$pre-fq-t$t" fq "$t" "$j" "$e" || FAIL=1
    done
    u1_fq_rm "$j"
  done
  for t in "$@"; do
    jq -s --arg r "$pre-fq-t$t" '[.[] | select(.kind == "sample" and .rung == $r)] | {s: (map(.wall_s) | add), a: (map(.start) | min), b: (map(.end) | max)}' "$J" > "$W/sum.json"
    u1_rungline "$pre-fq-t$t" fq "$t" 1 "$c" "$(jq -r .a "$W/sum.json")" "$(jq -r '.a + .s' "$W/sum.json")"
  done
}
# u1_ref K: the drift reference, with the host's fragmentation state.
u1_ref() {
  { echo "== ref $1 $(date -u +%FT%TZ)"; cat /proc/buddyinfo; grep -E '^(compact_|thp_)' /proc/vmstat; } >> "$W/drift.txt"
  ak2_push "$W/drift.txt" drift.txt > /dev/null
  u1_fq 0 && u1_one "ref$1-fq-t96" fq 96 0 0 || FAIL=1
  u1_fq_rm 0
}

ak2_phase rungs
u1_ref 0
# A: cohort 1, n = 3, T order rotated per rep.
ORDERS=("48 96 192" "96 192 48" "192 48 96")
for rep in 1 2 3; do
  for t in ${ORDERS[$((rep - 1))]}; do u1_pass "A-c1-gz-t$t-r$rep" gz "$t" 1 1 0; done
  u1_fq 0 || FAIL=1
  for t in ${ORDERS[$((rep - 1))]}; do u1_one "A-c1-fq-t$t-r$rep" fq "$t" 0 0 || FAIL=1; done
  u1_fq_rm 0
done
u1_ref 1
# B: cohort 10.
u1_fqpass B-c10 "$C10" 0 48 96 192
u1_pass B-c10-gz-t48 gz 48 1 "$C10" 0
u1_pass B-c10-gz-p10-t8 gz 8 10 "$C10" 0
u1_ref 2
# C: cohort 100.
u1_fqpass C-c100 "$COHORT" 1 96 48 192
u1_pass C-c100-gz-p12-t8 gz 8 12 "$COHORT" 0
u1_pass C-c100-gz-p24-t4 gz 4 24 "$COHORT" 0
# An addition to the registered U1 (Scott, 2026-10-08): P = 48 x T = 2, to bracket the P x T optimum.
u1_pass C-c100-gz-p48-t2 gz 2 48 "$COHORT" 0
u1_ref 3

ak2_phase push
ak2_push "$J" u1.jsonl
ak2_push "$W/drift.txt" drift.txt
for n in scratch inputs roda; do $U umount "$n" || ak2_say "umount $n failed"; done
ak2_say "u1 done (failed=$FAIL)"
exit "$FAIL"

