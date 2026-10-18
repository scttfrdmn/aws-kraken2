# shellcheck disable=SC2015,SC2016,SC2024  # A && B || C is meant; the gdb and sh -c text is literal; the logs are ours
# G3 probe (g): rapidgzip SIGSEGV on Graviton4 (Scott approved 2026-10-18, "Graviton4 repro
# probe"; docs/probes.md, "The rapidgzip crash probe"). The c10 ladder's identity step (lad_identity)
# saw rapidgzip 0.14.5 exit 139 twice in about 1,553 decompressions (O4b-if4 on r8g.16xlarge,
# SRR5935745_1, -P 8; S6 c10 rep 2, SRR5935748_2), each after a ~300 s stall (systemd-coredump),
# so no core survived, and 2,700 runs on Apple silicon did not reproduce it.
# One question: does lad_identity's own load on r8g.16xlarge reproduce the crash of 0.14.5, at a
# job count that resolves a null? So this body runs lad_identity exactly and nothing else: IDL =
# nproc/(P+2) lanes (6 on r8g.16xlarge, P = 8), lane l taking jobs n = l + IDL*k, each job GNU
# gzip -dc FILE | sha256sum, then rapidgzip 0.14.5 -d -c -P 8 FILE | sha256sum on the same FILE
# (FILE = the c10 cohort's 20 gz files on /dev/shm, round-robin). 0.16.0 is not run (a follow-up).
# Resolution: the plan line streams the expected job count (IDL x loop seconds / 14.6 s, the
# review's estimate of one identity step on a 64-vCPU host) and exp(-(2/1553) x jobs); progress
# lines re-project it from the probe's own per-job seconds; the summary says whether the null
# resolves (P(no crash at the ladder's rate) <= 0.05). The loop starts jobs until the latest time
# that leaves >= 15 min before the 150 min TTL (Scott, 2026-10-18: TTL 150 min) after a 300 s job
# timeout, one gzip pass and wrap-up (TTL counted from launch, taken as boot - 120 s).
# Cores go to /dev/shm/cores (kernel.core_pattern, restored at the end), after a positive control.
# Every job streams one "probe-rgcrash {json}" line (also in out/rgcrash.jsonl). A non-zero exit or
# a sha256 other than GNU gzip's is streamed with its stderr; if a core exists, gdb -batch's bt,
# thread apply all bt, info registers, x/16i $pc, $_siginfo and info sharedlibrary stream as
# "rgcrash-gdb N | ..." lines (and out/gdb/N.txt), the core goes to out/cores/ (zstd; the first
# MAXCORES only), and the loop goes on. The .so, the python it runs under and libpython go to
# out/bundle-<version>.tar.zst for offline analysis. The tally and the jsonl are pushed every
# PUSH_N jobs and on every failure. Not a timing probe: no drop_caches; page-cache state is logged.
# make rehearse seams (AK2_REHEARSE_*, refused by run.sh in a spec's env): LOOP_S (the loop length,
# replacing the TTL rule), LANES (replacing nproc/(P+2)), SHM (the input dir), MAXCORES, PUSH_N,
# PROGRESS_S.
W=$HOME/ak2; mkdir -p "$W"
T_START=$(date +%s)
SHA=${AK2_RUN_ID##*-}
B=aws-kraken2-942542972736-us-west-2; CK=aws-kraken2/data/cohort
P=8; JOB_TIMEOUT=300; KILL_GRACE=30
TTL_S=9000; MARGIN_S=900; WRAP_S=120; LAUNCH_LEAD_S=120   # the spec's TTL (150m); >= 15 min left at the end
PRIOR_JOB_S=14.6; RATE_N=2; RATE_D=1553                    # the review's per-step estimate; the ladder's rate
MAXCORES=${AK2_REHEARSE_MAXCORES:-6}; PUSH_N=${AK2_REHEARSE_PUSH_N:-100}; PROGRESS_S=${AK2_REHEARSE_PROGRESS_S:-300}
NPROC=$(nproc)
LANES=$(( NPROC / (P + 2) )); [ "$LANES" -lt 1 ] && LANES=1
[ -n "${AK2_REHEARSE_LANES:-}" ] && LANES=$AK2_REHEARSE_LANES
J="$W/rgcrash.jsonl"; : > "$J"
emit() { printf '%s\n' "$1" >> "$J"; printf 'probe-rgcrash %s\n' "$1"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
CORE_DIR=/dev/shm/cores; PREV_CP=""
restore_cp() {
  [ -n "$PREV_CP" ] || return 0
  sudo -n sysctl -q -w "kernel.core_pattern=$PREV_CP" > /dev/null 2>&1
  local now_cp; now_cp=$(cat /proc/sys/kernel/core_pattern)
  emit "$(jq -nc --arg prev "$PREV_CP" --arg now "$now_cp" '{kind:"restore", core_pattern_prev:$prev, core_pattern_now:$now, restored:($prev == $now)}')"
  PREV_CP=""
}
fail() { ak2_say "ERROR: $*"; restore_cp; ak2_push "$J" rgcrash.jsonl > /dev/null; exit 1; }
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
LV_DIR=$W/lever
# shellcheck source=/dev/null
. scripts/g3/lever.sh || fail "lever.sh did not load"
lv__rg_ensure || fail "rapidgzip $LV_RG_VERSION (lever.sh) install failed"
RG=$LV_RG; V=$LV_RG_VERSION
WHL=$(find "$LV_DIR/rg-wheels" -name 'rapidgzip-*.whl' | head -1)
SO=$(find "$LV_DIR/rg-venv" -name 'rapidgzip*.so' | head -1)
PYX=$(readlink -f "$(dirname "$RG")/python")
emit "$(jq -nc --arg v "$V" --arg rv "$("$RG" --version 2>&1 | head -1)" --arg path "$RG" --arg whl "$(basename "$WHL")" --arg wsha "$(sha256sum "$WHL" | cut -d' ' -f1)" \
  --arg so "$SO" --arg sosha "$(sha256sum "$SO" | cut -d' ' -f1)" --arg py "$PYX" --arg pyv "$("$PYX" -V 2>&1)" \
  --arg sofile "$(file -b "$SO" 2> /dev/null || echo unknown)" \
  '{kind:"tool", version:$v, reports:$rv, path:$path, wheel:$whl, wheel_sha256:$wsha, extension:$so, extension_sha256:$sosha,
    extension_file:$sofile, python:$py, python_version:$pyv}')"
# gdb, and the debuginfo the distribution has (the wheel's .so carries what symbols it has; best effort).
DI=skipped
timeout 900 sudo -n dnf debuginfo-install -y -q python3 python3-libs glibc libstdc++ > "$W/debuginfo.log" 2>&1 && DI=ok || DI="failed rc $?"
emit "$(jq -nc --arg gdb "$(gdb --version 2> /dev/null | head -1)" --arg di "$DI" --arg ditail "$(tail -3 "$W/debuginfo.log" | tr '\n' ' ' | cut -c1-400)" \
  --arg kernel "$(uname -r)" --arg cpu "$(lscpu 2> /dev/null | awk -F: '/Model name/ {gsub(/^ +/, "", $2); print $2; exit}')" \
  --argjson nproc "$NPROC" --argjson lanes "$LANES" --argjson p "$P" --arg glibc "$(ldd --version 2> /dev/null | head -1)" --arg itype "${AK2_INSTANCE_TYPE:-}" \
  '{kind:"host", gdb:$gdb, debuginfo_install:$di, debuginfo_tail:$ditail, kernel:$kernel, cpu:$cpu, nproc:$nproc, lanes:$lanes, P:$p,
    lanes_rule:"lad_identity: IDL = nproc / (P + 2)", glibc:$glibc, instance_type:$itype}')"
# The analysis bundle (the .so, the python it runs under, libpython): pushed now, so a core pushed
# later can be opened offline whatever happens to the run.
lp=$(ldd "$PYX" 2> /dev/null | awk '/libpython/ {print $3; exit}')
tar -cf - --dereference "$SO" "$PYX" ${lp:+"$lp"} 2> /dev/null | zstd -q -T0 -3 -o "$W/bundle-$V.tar.zst" -f &&
  ak2_push "$W/bundle-$V.tar.zst" "bundle-$V.tar.zst" > /dev/null || ak2_say "WARN: bundle $V not pushed"

# ---- core capture: ulimit, core_pattern to tmpfs, and a positive control ----
ulimit -c unlimited 2> /dev/null || sudo -n prlimit --pid $$ --core=unlimited:unlimited
mkdir -p "$CORE_DIR" && chmod 1777 "$CORE_DIR" || fail "mkdir $CORE_DIR"
PREV_CP0=$(cat /proc/sys/kernel/core_pattern)
sudo -n sysctl -q -w "kernel.core_pattern=$CORE_DIR/core.%p.%e.%t" > /dev/null || fail "cannot set kernel.core_pattern"
PREV_CP=$PREV_CP0
CP=$(cat /proc/sys/kernel/core_pattern)
# The control: the python rapidgzip runs under SIGSEGVs itself and must leave a core gdb can open.
# Without it, "no core" after a crash would not be evidence of anything.
"$PYX" -c 'import os, signal; os.kill(os.getpid(), signal.SIGSEGV)' 2> /dev/null; src=$?
sleep 1
sc=$(find "$CORE_DIR" -name 'core.*' | head -1)
sg=""; [ -n "$sc" ] && sg=$(gdb -batch -nx -ex 'set pagination off' -ex bt "$PYX" "$sc" 2>&1 | grep -c '^#')
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
ak2_push "$J" rgcrash.jsonl > /dev/null

# ---- the loop's end, and the resolution it can reach ----
# The last job may start at LAST_START: it can then run one gzip pass (GZ_MAX, the slowest
# reference pass, run at the same lane count) and a full rapidgzip timeout with its kill grace,
# and gdb and the pushes (WRAP_S) still end MARGIN_S before the TTL. The TTL is counted from launch
# at the earliest; launch is taken as LAUNCH_LEAD_S before boot.
T0_LOOP=$(date +%s)
BOOT=$(( T0_LOOP - $(cut -d. -f1 /proc/uptime) ))
TTL_END=$(( BOOT - LAUNCH_LEAD_S + TTL_S ))
LAST_START=$(( TTL_END - MARGIN_S - WRAP_S - JOB_TIMEOUT - KILL_GRACE - GZ_MAX ))
T95=$(( T_START + 95 * 60 ))
T_END=$LAST_START; END_BASIS="ttl"
[ -n "${AK2_REHEARSE_LOOP_S:-}" ] && { T_END=$(( T0_LOOP + AK2_REHEARSE_LOOP_S )); END_BASIS="rehearsal"; }
[ "$T_END" -gt "$T0_LOOP" ] || fail "no loop time left (last start $T_END, now $T0_LOOP)"
emit "$(jq -nc --argjson lanes "$LANES" --argjson t0 "$T0_LOOP" --argjson tend "$T_END" --argjson t95 "$T95" --argjson ttl_end "$TTL_END" \
  --argjson boot "$BOOT" --argjson gzmax "$GZ_MAX" --argjson prior "$PRIOR_JOB_S" --argjson rn "$RATE_N" --argjson rd "$RATE_D" \
  --argjson margin "$MARGIN_S" --argjson wrap "$WRAP_S" --argjson to "$JOB_TIMEOUT" --argjson kg "$KILL_GRACE" --arg basis "$END_BASIS" --argjson ls "$LAST_START" \
  '($rn / $rd) as $rate | (($tend - $t0) * $lanes / $prior | floor) as $e
   | {kind:"plan", lanes:$lanes, loop_start:$t0, last_start:$tend, end_basis:$basis, loop_s:($tend - $t0),
      ttl_rule_last_start:$ls, margin_s:$margin, wrap_s:$wrap, job_timeout_s:$to, kill_grace_s:$kg, body_start_plus_95min:$t95, last_start_minus_95min_s:($tend - $t95), ttl_end_est:$ttl_end, boot:$boot,
      worst_end_before_ttl_s:($ttl_end - ($tend + $gzmax + $to + $kg + $wrap)), gzip_max_s:$gzmax, prior_job_s:$prior,
      ladder_rate:$rate, expected_jobs:$e, p_no_crash_expected:((-$rate * $e) | exp),
      resolves_expected:(((-$rate * $e) | exp) <= 0.05)}')"
ak2_say "loop: $LANES lanes (lad_identity: gzip -dc then rapidgzip $V -P $P on the same file), last start $(date -u -d "@$T_END" +%FT%TZ 2> /dev/null || echo "$T_END") ($END_BASIS), cores to $CP"

# on_fail N FILE PID: stream the failure's evidence: stderr, dmesg, and gdb on its core if any.
on_fail() {
  local n=$1 f=$2 pid=$3 core k slot="" zc="" frames=0 dm
  core=$(find "$CORE_DIR" -maxdepth 1 -name "core.$pid.*" 2> /dev/null | head -1)
  dm=$(sudo -n dmesg 2> /dev/null | grep -E "\[$pid\]|rapidgzip|python" | tail -5)
  if [ -n "$core" ]; then
    mkdir -p "$W/gdb"
    gdb -batch -nx -ex 'set pagination off' -ex 'set print thread-events off' -ex 'info sharedlibrary' -ex 'p $_siginfo' \
      -ex 'echo ---- bt\n' -ex bt -ex 'echo ---- thread apply all bt\n' -ex 'thread apply all bt' -ex 'echo ---- info registers\n' \
      -ex 'info registers' -ex 'echo ---- x/16i $pc\n' -ex 'x/16i $pc' "$PYX" "$core" > "$W/gdb/$n.txt" 2>&1
    frames=$(grep -c '^#' "$W/gdb/$n.txt")
    sed "s/^/rgcrash-gdb $n | /" "$W/gdb/$n.txt"
    ak2_push "$W/gdb/$n.txt" "gdb/$n.txt" > /dev/null
    for ((k = 1; k <= MAXCORES; k++)); do mkdir "$W/coreslot.$k" 2> /dev/null && { slot=$k; break; }; done
    if [ -n "$slot" ]; then
      zc=cores/$(basename "$core")-job$n-$V.zst
      zstd -q -T0 -3 "$core" -o "$core.zst" && ak2_push "$core.zst" "$zc" > /dev/null || zc="push failed"
      rm -f "$core.zst"
    fi
  fi
  emit "$(jq -nc --argjson n "$n" --arg v "$V" --arg f "$f" --arg core "$core" --arg sz "$([ -n "$core" ] && stat -c%s "$core")" \
    --arg zc "$zc" --argjson frames "$frames" --arg err "$(head -c 2000 "$W/err/$n" 2> /dev/null)" --arg dm "$dm" \
    --arg sig "$(grep -m1 -oE 'si_addr = 0x[0-9a-f]+' "$W/gdb/$n.txt" 2> /dev/null)" \
    '{kind:"failure", n:$n, version:$v, file:$f, core:(if $core == "" then null else $core end), core_bytes:($sz|tonumber? // 0),
      core_pushed:(if $zc == "" then null else $zc end), gdb_frames:$frames, fault:(if $sig == "" then null else $sig end),
      stderr:$err, dmesg:$dm}')"
  [ -n "$core" ] && rm -f "$core"
  return 0
}
# lane L: lad_identity's lane L, repeated: jobs n = L + LANES*k, file n mod 20; GNU gzip, then rapidgzip.
lane() {
  local l=$1 k=0 n f h rc t0 t1 pid ok sig g gr gt0 gok
  while [ "$(date +%s)" -lt "$T_END" ]; do
    n=$((l + LANES * k))
    f=${FILES[$((n % ${#FILES[@]}))]}
    gt0=$(now)
    g=$(gzip -dc "$IN/$f" | sha256sum | cut -d' ' -f1; exit "${PIPESTATUS[0]}"); gr=$?
    gok=false; [ "$g" = "${REF[$f]}" ] && gok=true
    t0=$(now)
    h=$(timeout -s ABRT -k "$KILL_GRACE" "$JOB_TIMEOUT" sh -c 'echo $$ > "$0"; exec "$@"' "$W/pid/$n" "$RG" -d -c -P "$P" "$IN/$f" 2> "$W/err/$n" |
      sha256sum | cut -d' ' -f1; exit "${PIPESTATUS[0]}"); rc=$?
    t1=$(now)
    pid=$(cat "$W/pid/$n" 2> /dev/null); rm -f "$W/pid/$n"
    ok=false; [ "$h" = "${REF[$f]}" ] && ok=true
    sig=null; [ "$rc" -gt 128 ] && [ "$rc" -lt 160 ] && sig=$((rc - 128))
    emit "$(jq -nc --argjson n "$n" --argjson lane "$l" --arg v "$V" --arg f "$f" --argjson p "$P" --argjson rc "$rc" --argjson sig "$sig" \
      --arg h "$h" --argjson ok "$ok" --arg t0 "$t0" --arg t1 "$t1" --arg pid "$pid" --arg g "$g" --argjson gr "$gr" --argjson gok "$gok" --arg gt0 "$gt0" \
      '{kind:"job", n:$n, lane:$lane, mode:"identity", version:$v, file:$f, P:$p, exit:$rc, signal:$sig, timeout:($rc == 124), sha256:$h, match:$ok,
        seconds:(($t1|tonumber)-($t0|tonumber)), t0:($t0|tonumber), pid:($pid|tonumber? // null),
        gzip_sha256:$g, gzip_exit:$gr, gzip_match:$gok, gzip_seconds:(($t0|tonumber)-($gt0|tonumber)),
        step_seconds:(($t1|tonumber)-($gt0|tonumber))}')"
    if [ "$rc" != 0 ] || [ "$ok" != true ] || [ "$gok" != true ]; then
      ak2_say "FAILURE job $n: rapidgzip $V -P $P $f exit $rc, sha256 ${h:0:16} (match $ok; gzip match $gok)"
      on_fail "$n" "$f" "$pid"
      : > "$W/push-now"
    else
      rm -f "$W/err/$n"
    fi
    k=$((k + 1))
  done
}
tally() {
  jq -r 'select(.kind == "job") | [.version, .P, .exit, .match, .gzip_match] | @tsv' "$J" | awk -F'\t' '
    {k = $1 "\t" $2; jobs[k]++; if ($3 != 0) nz[k]++; if ($3 > 128 && $3 < 160) cr[k]++; if ($3 == 124) to[k]++; if ($4 != "true") ws[k]++; if ($5 != "true") gm[k]++}
    END {print "version\tP\tjobs\tnonzero_exit\tcrashes\ttimeouts\twrong_sha\tgzip_mismatch"; for (k in jobs) printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\n", k, jobs[k], nz[k], cr[k], to[k], ws[k], gm[k]}' |
    { IFS= read -r h; echo "$h"; sort; } > "$W/rgcrash-tally.tsv"
}
# progress: jobs so far, the measured mean step (gzip + rapidgzip) and the projection to LAST_START.
progress() {
  jq -c -s --argjson lanes "$LANES" --argjson now "$(date +%s)" --argjson tend "$T_END" --argjson rn "$RATE_N" --argjson rd "$RATE_D" \
    '[.[] | select(.kind == "job")] as $j | ($rn / $rd) as $rate | ($j | length) as $c
     | (if $c > 0 then ($j | map(.step_seconds) | add / $c) else null end) as $m
     | (if $m then ($c + ((([$tend - $now, 0] | max) * $lanes / $m) | floor)) else null end) as $proj
     | {kind:"progress", jobs:$c, crashes:($j | map(select(.signal != null)) | length), failures:($j | map(select(.exit != 0 or (.match | not) or (.gzip_match | not))) | length),
        mean_step_s:$m, projected_jobs:$proj, p_no_crash_projected:(if $proj then ((-$rate * $proj) | exp) else null end),
        resolves_projected:(if $proj then (((-$rate * $proj) | exp) <= 0.05) else null end)}' "$J"
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
    ak2_push "$W/rgcrash-tally.tsv" rgcrash-tally.tsv > /dev/null; ak2_push "$J" rgcrash.jsonl > /dev/null
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
# The verdict: reproduced (a crash), or a null that resolves (P(no crash at the ladder's rate 2/1553
# over these jobs) <= 0.05), or a null that does not.
jq -c -s --arg v "$V" --argjson rn "$RATE_N" --argjson rd "$RATE_D" --argjson lanes "$LANES" \
  '[.[] | select(.kind == "job")] as $x | ($rn / $rd) as $rate | ($x | length) as $c
   | ((-$rate * $c) | exp) as $p0 | ($x | map(select(.signal != null)) | length) as $cr
   | {kind:"summary", version:$v, mode:"identity", lanes:$lanes, jobs:$c,
      crashes:$cr, sigsegv:($x | map(select(.signal == 11)) | length),
      timeouts:($x | map(select(.timeout)) | length), nonzero_exit:($x | map(select(.exit != 0)) | length),
      wrong_sha:($x | map(select(.match | not)) | length), wrong_sha_exit0:($x | map(select(.exit == 0 and (.match | not))) | length),
      gzip_mismatch:($x | map(select(.gzip_match | not)) | length),
      crash_rate:(if $c > 0 then $cr / $c else null end), mean_step_s:(if $c > 0 then ($x | map(.step_seconds) | add / $c) else null end),
      ladder_rate:$rate, p_no_crash_at_ladder_rate:$p0, null_resolves:($p0 <= 0.05),
      verdict:(if $cr > 0 then "reproduced"
               elif $p0 <= 0.05 then "not reproduced; the null resolves (P(no crash at 2/1553) <= 0.05)"
               else "not reproduced; the null does NOT resolve (P(no crash at 2/1553) > 0.05)" end)}' "$J" > "$W/summary.json"
emit "$(cat "$W/summary.json")"
restore_cp
ak2_phase push
ak2_push "$W/rgcrash-tally.tsv" rgcrash-tally.tsv > /dev/null
ak2_push "$J" rgcrash.jsonl || exit 1
ak2_say "rgcrash probe done: $(jq -r .verdict "$W/summary.json"); $(jq -r .jobs "$W/summary.json") jobs, $(grep -c '"kind":"failure"' "$J") failures, $(find "$W" -maxdepth 1 -name 'coreslot.*' | wc -l) cores pushed"
[ "$(grep -c '"kind":"summary"' "$J")" = 1 ] || exit 1
exit 0
