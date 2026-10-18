# shellcheck disable=SC2015,SC2016,SC2024  # A && B || C is meant; the gdb and sh -c text is literal; the logs are ours
# G3 probe (g): rapidgzip SIGSEGV on Graviton4 (Scott approved 2026-10-18, "Graviton4 repro
# probe"; docs/probes.md, "The rapidgzip crash probe"). The c10 ladder's identity step (lad_identity)
# saw rapidgzip 0.14.5 exit 139 twice in about 1,553 decompressions (O4b-if4 on r8g.16xlarge,
# SRR5935745_1, -P 8; S6 c10 rep 2, SRR5935748_2), each after a ~300 s stall (systemd-coredump),
# so no core survived, and 2,700 runs on Apple silicon did not reproduce it. This body repeats the
# identity step's rapidgzip command, `rapidgzip -d -c -P K FILE | sha256sum`, on the c10 cohort's
# 20 gz files on /dev/shm, 8 lanes at once, until 95 min after it starts (>= 25 min before the
# 120 min TTL), with cores written to /dev/shm/cores (kernel.core_pattern, restored at the end).
# Versions alternate job by job: 0.14.5 (lever.sh's pinned install) and 0.16.0 (pinned here the
# same way); -P 16 on every fourth job of a lane, -P 8 otherwise; files round-robin. Every job
# streams one "probe-rgcrash {json}" line (also in out/rgcrash.jsonl). A non-zero exit or a sha256
# other than GNU gzip's is streamed with its stderr; if a core exists, gdb -batch's bt, thread apply
# all bt, info registers, x/16i $pc, $_siginfo and info sharedlibrary stream as "rgcrash-gdb N | ..."
# lines (and out/gdb/N.txt), the core goes to out/cores/ (zstd; the first MAXCORES only), and the
# loop goes on. Each version's .so, the python it runs under and libpython go to out/bundle-*.tar.zst
# for offline analysis. The tally (out/rgcrash-tally.tsv) and the jsonl are pushed every PUSH_N
# jobs and on every failure. Not a timing probe: no drop_caches; page-cache state is logged.
# make rehearse seams (AK2_REHEARSE_*, refused by run.sh in a spec's env): LOOP_S (the loop
# budget), SHM (the input dir), MAXCORES, PUSH_N.
W=$HOME/ak2; mkdir -p "$W"
T_START=$(date +%s)
T_END=$(( T_START + ${AK2_REHEARSE_LOOP_S:-$((95 * 60))} ))
SHA=${AK2_RUN_ID##*-}
B=aws-kraken2-942542972736-us-west-2; CK=aws-kraken2/data/cohort
LANES=8; MAXCORES=${AK2_REHEARSE_MAXCORES:-6}; PUSH_N=${AK2_REHEARSE_PUSH_N:-100}; JOB_TIMEOUT=300
RG16_VERSION=0.16.0
# sha256 of rapidgzip-0.16.0-cp39-cp39-manylinux_2_26_aarch64.manylinux_2_28_aarch64.whl (PyPI's
# JSON API, checked on 2026-10-18 by hashing the downloaded wheel): pip --require-hashes accepts only it.
RG16_HASH=2c3d75cb314b6dc28cf8fa238ff56f5ffae142af581f531fc674229184386f1d
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

ak2_phase setup
sudo -n dnf install -y -q git gzip python3-pip perl jq gdb zstd tar findutils procps-ng util-linux file > "$W/dnf.log" 2>&1 || { tail -5 "$W/dnf.log"; fail "dnf failed"; }
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "cd repo"
LV_DIR=$W/lever
# shellcheck source=/dev/null
. scripts/g3/lever.sh || fail "lever.sh did not load"
lv__rg_ensure || fail "rapidgzip $LV_RG_VERSION (lever.sh) install failed"
RGA=$LV_RG; VA=$LV_RG_VERSION
# 0.16.0: lever.sh's install, in its own venv: pip download --require-hashes, then install from it.
V16=$W/rg16-venv; WD16=$W/rg16-wheels; REQ16=$W/rg16-requirements.txt
printf 'rapidgzip==%s \\\n    --hash=sha256:%s\n' "$RG16_VERSION" "$RG16_HASH" > "$REQ16"
python3 -m venv "$V16" > /dev/null 2>&1 || fail "venv for rapidgzip $RG16_VERSION failed"
"$V16/bin/pip" download -q --no-deps --only-binary=:all: --require-hashes -r "$REQ16" -d "$WD16" > "$W/rg16-pip.log" 2>&1 &&
  "$V16/bin/pip" install -q --no-deps --no-index --only-binary=:all: --require-hashes --find-links "$WD16" -r "$REQ16" >> "$W/rg16-pip.log" 2>&1 ||
  { tail -5 "$W/rg16-pip.log"; fail "pip install --require-hashes rapidgzip==$RG16_VERSION failed"; }
RGB=$V16/bin/rapidgzip; VB=$RG16_VERSION
declare -A RGV=([a]=$RGA [b]=$RGB) RGN=([a]=$VA [b]=$VB) WHL WSHA SO SOSHA PYX
WHL[a]=$(find "$LV_DIR/rg-wheels" -name 'rapidgzip-*.whl' | head -1); WHL[b]=$(find "$WD16" -name 'rapidgzip-*.whl' | head -1)
SO[a]=$(find "$LV_DIR/rg-venv" -name 'rapidgzip*.so' | head -1); SO[b]=$(find "$V16" -name 'rapidgzip*.so' | head -1)
for v in a b; do
  vv=$("${RGV[$v]}" --version 2>&1 | head -1)
  [[ $vv == *"version ${RGN[$v]}"* ]] || fail "rapidgzip at ${RGV[$v]} reports '$vv', want ${RGN[$v]}"
  WSHA[$v]=$(sha256sum "${WHL[$v]}" | cut -d' ' -f1); SOSHA[$v]=$(sha256sum "${SO[$v]}" | cut -d' ' -f1)
  PYX[$v]=$(readlink -f "$(dirname "${RGV[$v]}")/python")
  emit "$(jq -nc --arg v "${RGN[$v]}" --arg rv "$vv" --arg path "${RGV[$v]}" --arg whl "$(basename "${WHL[$v]}")" --arg wsha "${WSHA[$v]}" \
    --arg so "${SO[$v]}" --arg sosha "${SOSHA[$v]}" --arg py "${PYX[$v]}" --arg pyv "$("${PYX[$v]}" -V 2>&1)" \
    --arg sofile "$(file -b "${SO[$v]}" 2> /dev/null || echo unknown)" \
    '{kind:"tool", version:$v, reports:$rv, path:$path, wheel:$whl, wheel_sha256:$wsha, extension:$so, extension_sha256:$sosha,
      extension_file:$sofile, python:$py, python_version:$pyv}')"
done
[ "${WSHA[a]}" != "${WSHA[b]}" ] || fail "both versions resolved to the same wheel"
# gdb, and the debuginfo the distribution has (the wheels' .so carry what symbols they have; best effort).
DI=skipped
timeout 900 sudo -n dnf debuginfo-install -y -q python3 python3-libs glibc libstdc++ > "$W/debuginfo.log" 2>&1 && DI=ok || DI="failed rc $?"
emit "$(jq -nc --arg gdb "$(gdb --version 2> /dev/null | head -1)" --arg di "$DI" --arg ditail "$(tail -3 "$W/debuginfo.log" | tr '\n' ' ' | cut -c1-400)" \
  --arg kernel "$(uname -r)" --arg cpu "$(lscpu 2> /dev/null | awk -F: '/Model name/ {gsub(/^ +/, "", $2); print $2; exit}')" \
  --argjson nproc "$(nproc)" --arg glibc "$(ldd --version 2> /dev/null | head -1)" --arg itype "${AK2_INSTANCE_TYPE:-}" \
  '{kind:"host", gdb:$gdb, debuginfo_install:$di, debuginfo_tail:$ditail, kernel:$kernel, cpu:$cpu, nproc:$nproc, glibc:$glibc, instance_type:$itype}')"
# Analysis bundles (each version's .so, the python it runs under, libpython): pushed now, so a core
# pushed later can be opened offline whatever happens to the run.
for v in a b; do
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
# The control: a python (the same binary rapidgzip runs under) that SIGSEGVs itself must leave a
# core gdb can open. Without it, "no core" after a crash would not be evidence of anything.
"${PYX[a]}" -c 'import os, signal; os.kill(os.getpid(), signal.SIGSEGV)' 2> /dev/null; src=$?
sleep 1
sc=$(find "$CORE_DIR" -name 'core.*' | head -1)
sg=""; [ -n "$sc" ] && sg=$(gdb -batch -nx -ex 'set pagination off' -ex bt "${PYX[a]}" "$sc" 2>&1 | grep -c '^#')
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
for f in "${FILES[@]}"; do
  IFS=$'\t' read -r g gr t0 t1 < "$W/ref/$f" || { g=missing; gr=-1; t0=0; t1=0; }
  REF[$f]=$g
  emit "$(jq -nc --arg f "$f" --arg g "$g" --argjson gr "$gr" --arg t0 "$t0" --arg t1 "$t1" \
    '{kind:"reference", file:$f, tool:"gzip -dc", sha256:$g, exit:$gr, seconds:(($t1|tonumber)-($t0|tonumber))}')"
  [[ $g =~ ^[0-9a-f]{64}$ ]] && [[ $gr =~ ^(0|2)$ ]] || fail "GNU gzip reference failed on $f (exit $gr)"
done
ak2_push "$J" rgcrash.jsonl > /dev/null

# ---- the loop ----
# on_fail N V FILE PID: stream the failure's evidence: stderr, dmesg, and gdb on its core if any.
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
    sed "s/^/rgcrash-gdb $n | /" "$W/gdb/$n.txt"
    ak2_push "$W/gdb/$n.txt" "gdb/$n.txt" > /dev/null
    for ((k = 1; k <= MAXCORES; k++)); do mkdir "$W/coreslot.$k" 2> /dev/null && { slot=$k; break; }; done
    if [ -n "$slot" ]; then
      zc=cores/$(basename "$core")-job$n-${RGN[$v]}.zst
      zstd -q -T0 -3 "$core" -o "$core.zst" && ak2_push "$core.zst" "$zc" > /dev/null || zc="push failed"
      rm -f "$core.zst"
    fi
  fi
  emit "$(jq -nc --argjson n "$n" --arg v "${RGN[$v]}" --arg f "$f" --arg core "$core" --arg sz "$([ -n "$core" ] && stat -c%s "$core")" \
    --arg zc "$zc" --argjson frames "$frames" --arg err "$(head -c 2000 "$W/err/$n" 2> /dev/null)" --arg dm "$dm" \
    --arg sig "$(grep -m1 -oE 'si_addr = 0x[0-9a-f]+' "$W/gdb/$n.txt" 2> /dev/null)" \
    '{kind:"failure", n:$n, version:$v, file:$f, core:(if $core == "" then null else $core end), core_bytes:($sz|tonumber? // 0),
      core_pushed:(if $zc == "" then null else $zc end), gdb_frames:$frames, fault:(if $sig == "" then null else $sig end),
      stderr:$err, dmesg:$dm}')"
  [ -n "$core" ] && rm -f "$core"
  return 0
}
lane() {
  local l=$1 k=0 n v p f h rc t0 t1 pid ok sig
  while [ "$(date +%s)" -lt "$T_END" ]; do
    n=$((l + LANES * k)); v=a; (( (k + l) % 2 )) && v=b
    p=8; [ $((k % 4)) = 3 ] && p=16
    f=${FILES[$((n % ${#FILES[@]}))]}
    t0=$(now)
    h=$(timeout -s ABRT -k 30 "$JOB_TIMEOUT" sh -c 'echo $$ > "$0"; exec "$@"' "$W/pid/$n" "${RGV[$v]}" -d -c -P "$p" "$IN/$f" 2> "$W/err/$n" |
      sha256sum | cut -d' ' -f1; exit "${PIPESTATUS[0]}"); rc=$?
    t1=$(now)
    pid=$(cat "$W/pid/$n" 2> /dev/null); rm -f "$W/pid/$n"
    ok=false; [ "$h" = "${REF[$f]}" ] && ok=true
    sig=null; [ "$rc" -gt 128 ] && [ "$rc" -lt 160 ] && sig=$((rc - 128))
    emit "$(jq -nc --argjson n "$n" --argjson lane "$l" --arg v "${RGN[$v]}" --arg f "$f" --argjson p "$p" --argjson rc "$rc" --argjson sig "$sig" \
      --arg h "$h" --argjson ok "$ok" --arg t0 "$t0" --arg t1 "$t1" --arg pid "$pid" \
      '{kind:"job", n:$n, lane:$lane, version:$v, file:$f, P:$p, exit:$rc, signal:$sig, timeout:($rc == 124), sha256:$h, match:$ok,
        seconds:(($t1|tonumber)-($t0|tonumber)), t0:($t0|tonumber), pid:($pid|tonumber? // null)}')"
    if [ "$rc" != 0 ] || [ "$ok" != true ]; then
      ak2_say "FAILURE job $n: rapidgzip ${RGN[$v]} -P $p $f exit $rc, sha256 ${h:0:16} (match $ok)"
      on_fail "$n" "$v" "$f" "$pid"
      : > "$W/push-now"
    else
      rm -f "$W/err/$n"
    fi
    k=$((k + 1))
  done
}
tally() {
  jq -r 'select(.kind == "job") | [.version, .P, .exit, .match] | @tsv' "$J" | awk -F'\t' '
    {k = $1 "\t" $2; jobs[k]++; if ($3 != 0) nz[k]++; if ($3 > 128 && $3 < 160) cr[k]++; if ($3 == 124) to[k]++; if ($4 != "true") ws[k]++}
    END {print "version\tP\tjobs\tnonzero_exit\tcrashes\ttimeouts\twrong_sha"; for (k in jobs) printf "%s\t%d\t%d\t%d\t%d\t%d\n", k, jobs[k], nz[k], cr[k], to[k], ws[k]}' |
    { IFS= read -r h; echo "$h"; sort; } > "$W/rgcrash-tally.tsv"
}
ak2_phase loop
meminfo loop-start
mkdir -p "$W/pid" "$W/err"
ak2_say "loop: $LANES lanes until $(date -u -d "@$T_END" +%FT%TZ 2> /dev/null || echo "$T_END"), rapidgzip $VA and $VB alternating, -P 8 (-P 16 every 4th job), cores to $CP"
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
  if [ $(( $(date +%s) - lastp )) -ge 300 ]; then
    ak2_say "progress: $c jobs, $(grep '"kind":"job"' "$J" | grep -vc '"exit":0,') non-zero exits, $(grep -c '"kind":"failure"' "$J") failures"
    meminfo progress; lastp=$(date +%s)
  fi
done
for p in "${LPIDS[@]}"; do wait "$p"; done

ak2_phase summary
meminfo end
tally
jq -c -s --arg va "$VA" --arg vb "$VB" '[.[] | select(.kind == "job")] as $j
  | ([$va, $vb][] as $v | ($j | map(select(.version == $v))) as $x
     | {kind:"summary", version:$v, jobs:($x | length), P8:($x | map(select(.P == 8)) | length), P16:($x | map(select(.P == 16)) | length),
        crashes:($x | map(select(.signal != null)) | length), sigsegv:($x | map(select(.signal == 11)) | length),
        timeouts:($x | map(select(.timeout)) | length), nonzero_exit:($x | map(select(.exit != 0)) | length),
        wrong_sha:($x | map(select(.match | not)) | length), wrong_sha_exit0:($x | map(select(.exit == 0 and (.match | not))) | length),
        crash_rate:(if ($x | length) > 0 then (($x | map(select(.signal != null)) | length) / ($x | length)) else null end),
        seconds:($x | map(.seconds) | add // 0)})' "$J" > "$W/summary.jsonl"
while IFS= read -r s; do emit "$s"; done < "$W/summary.jsonl"
restore_cp
ak2_phase push
ak2_push "$W/rgcrash-tally.tsv" rgcrash-tally.tsv > /dev/null
ak2_push "$J" rgcrash.jsonl || exit 1
nj=$(grep -c '"kind":"summary"' "$J")
ak2_say "rgcrash probe done: $(grep -c '"kind":"job"' "$J") jobs, $(grep -c '"kind":"failure"' "$J") failures, $(find "$W" -maxdepth 1 -name 'coreslot.*' | wc -l) cores pushed"
[ "$nj" = 2 ] || exit 1
exit 0
