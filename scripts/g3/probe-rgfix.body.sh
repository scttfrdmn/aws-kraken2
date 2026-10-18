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
#      ISA-L stays off as in the PyPI aarch64 wheel: 0.14.5 cannot build it on aarch64), so the
#      one lever against the crashing wheel is rpmalloc. Cached by recipe sha256 in
#      s3://.../aws-kraken2/data/rg-build/ (the input-path sweep, #90, reuses the same wheel).
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
# Per variant: crashed, or a null that resolves (P(no crash at probe (g)'s 9/3588 over its jobs)
# <= 0.05: the fix is supported at 5%), or a null that does not; a variant that did not run says why.
for v in a b; do
  jq -c -s --arg var "$v" --arg v "${RGN[$v]}" --arg ran "${OK[$v]:-0}" --argjson rn "$RATE_N" --argjson rd "$RATE_D" --argjson lanes "$LANES" \
    --arg bstatus "$(jq -r '.status // "failed"' <<< "$BREC")" \
    '[.[] | select(.kind == "job" and .variant == $var)] as $x | ($rn / $rd) as $rate | ($x | length) as $c
     | ((-$rate * $c) | exp) as $p0 | ($x | map(select(.signal != null)) | length) as $cr
     | {kind:"summary", variant:$var, version:$v, mode:"identity", lanes:$lanes, ran:($ran == "1"),
        build:(if $var == "a" then $bstatus else "pypi wheel" end), jobs:$c,
        crashes:$cr, sigsegv:($x | map(select(.signal == 11)) | length),
        timeouts:($x | map(select(.timeout)) | length), nonzero_exit:($x | map(select(.exit != 0)) | length),
        wrong_sha:($x | map(select(.match | not)) | length), wrong_sha_exit0:($x | map(select(.exit == 0 and (.match | not))) | length),
        gzip_mismatch:($x | map(select(.gzip_match | not)) | length),
        crash_rate:(if $c > 0 then $cr / $c else null end), mean_step_s:(if $c > 0 then ($x | map(.step_seconds) | add / $c) else null end),
        reference_rate:$rate, p_no_crash_at_reference_rate:(if $c > 0 then $p0 else null end), null_resolves:($c > 0 and $cr == 0 and $p0 <= 0.05),
        verdict:(if $ran != "1" then "not run: build failed (see the rg-build line and rg-build-log)"
                 elif $cr > 0 then "crashed: not a fix"
                 elif $p0 <= 0.05 then "no crash; the null resolves (P(no crash at 9/3588) <= 0.05): the fix is supported"
                 else "no crash; the null does NOT resolve (P(no crash at 9/3588) > 0.05)" end)}' "$J" > "$W/summary-$v.json"
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
