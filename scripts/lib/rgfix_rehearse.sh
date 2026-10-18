#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the container-side snippets are literal; chk's conditions read variables through eval
# make rehearse SPEC=runs/g3-probe-rgfix-<type>.json (docs/probes.md, "The rapidgzip fix probe";
# called by scripts/lib/probe_rehearse.sh for kind rgfix): the spec's own body (command[2],
# unmodified) on Amazon Linux 2023 aarch64 containers (rootful podman, --privileged: the VM's own
# kernel.core_pattern and core dumps), as ec2-user with sudo, under `bash -e -c` as spawn runs it,
# after the probe rehearsal's helper stand-ins. Real on the node: dnf (gdb, zstd, gcc-c++,
# python3-devel, the debuginfo attempt), scripts/g3/rg-build.sh's source build of rapidgzip 0.14.5
# without rpmalloc (pip --require-hashes from PyPI), the 0.16.0 wheel's --require-hashes install,
# sysctl, the cores, gdb. Stand-ins at the edges: S3 is one directory through the stub aws
# (scripts/lib/rehearse_aws.py; the rg-build cache lives there too), git clone is the committed tree
# (git archive), and the c10 cohort's 20 files are small real public read sets (.cache/reads),
# cycled under the c10 names. Three runs:
#   1. the probe: a 150 s loop (AK2_REHEARSE_LOOP_S), 6 lanes (AK2_REHEARSE_LANES; the VM has 8
#      CPUs), MAXCORES = 2; once the loop runs the host sends SIGSEGV to K = 3 running rapidgzip
#      processes (a, b, a), which dump real cores.
#   2. a failed build (rg-build.sh's seam AK2_REHEARSE_RGBUILD_SDIST_SHA256: a wrong sdist pin):
#      the probe must still run b, for a 40 s loop.
#   3. rg-build.sh alone after run 1: a cache hit giving run 1's wheel.
# What passes, on observed output:
#   run 1: body exit 0, its shell flags without e; an rg-build line with status ok, cache stored,
#   build_s measured, rpmalloc_symbols 0 and isal_symbols 0; 2 tool lines: a (0.14.5-norpmalloc, 0
#   rpmalloc functions, 0 ISA-L symbols, version 0.14.5) and b (0.16.0, wheel sha256 = the pin, ISA-L
#   symbols > 0); host lanes 6 and variants a b; the core control ok; 20 reference lines; a plan
#   line with build_s, expected_jobs > 0 and per variant p_no_crash_expected = exp(-(9/3588) x n);
#   progress lines per variant; the job lines streamed = the pushed rgfix.jsonl's; every job is
#   lad_identity's (-P 8, lane = n mod 6, file = n mod 20, gzip's sha256 = the reference) with its
#   variant alternating ((k + lane) mod 2, k = n div 6); exactly the K killed jobs failed (exit 139,
#   signal 11), each with a failure line, a core, gdb frames and gdb output streamed and pushed;
#   min(K, MAXCORES) valid zstd cores; every other job matched; 2 analysis bundles; the tally's
#   jobs = the job lines; 2 summary lines, both ran, crashes summing to K (a 2, b 1), each
#   p_no_crash_at_reference_rate = exp(-(9/3588) x jobs) and verdict "crashed: not a fix"; the
#   restore line, and the VM's core_pattern after = before; the cache object in the stand-in S3.
#   run 2: body exit 0; the rg-build line status failed; rg-build-log lines streamed; host
#   variants b only; every job variant b; summary a not run ("not run: build failed"), b with jobs.
#   run 3: rg-build.sh exit 0, cache hit, wheel sha256 = run 1's.
# Usage: scripts/lib/rgfix_rehearse.sh runs/g3-probe-rgfix-<type>.json   (REHEARSE_KEEP=1 keeps the scratch dir)
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
. scripts/pin.env
. scripts/paths.sh
SPEC=${1:?SPEC}
[ -f "$SPEC" ] || { echo "rgfix-rehearse: no $SPEC" >&2; exit 2; }
git diff --quiet HEAD -- "$SPEC" scripts cmd internal || { echo "rgfix-rehearse: commit first (the rehearsal runs the committed tree)" >&2; exit 2; }
SHA=$(git rev-parse --short=7 HEAD)
mkdir -p results/rehearse || exit 1
LOGF="results/rehearse/$(basename "$SPEC" .json)-$(date -u +%Y%m%dT%H%M%SZ)-$SHA.log"
exec > >(tee "$LOGF") 2>&1
say() { echo "rgfix-rehearse: $*"; }
say "record $LOGF; $SPEC at $SHA; shell flags $-"
K=3; MAXC=2; LOOP_S=${RGREH_LOOP_S:-150}
B=aws-kraken2-942542972736-us-west-2; CK=aws-kraken2/data/cohort
PIN_B=$(jq -r '.command[2]' "$SPEC" | awk -F= '/^RG16_HASH=/ {print $2; exit}')

command -v podman > /dev/null || { say "need podman"; exit 1; }
CONN=$(podman system connection list --format '{{.Name}}' 2> /dev/null | grep -- '-root$' | head -1)
[ -n "$CONN" ] || { say "need a rootful podman connection"; exit 1; }
PM=(podman --connection "$CONN")
T=$(mktemp -d "$HOME/.ak2-rgfreh.XXXXXX") || exit 1   # under $HOME: the podman machine shares it
chmod 0755 "$T"
CTR=ak2rgf-$$
cleanup() {
  "${PM[@]}" rm -f "$CTR-1" "$CTR-2" "$CTR-3" > /dev/null 2>&1
  if [ "${REHEARSE_KEEP:-0}" = 1 ]; then say "kept $T"; else chmod -R u+w "$T" 2> /dev/null; rm -rf "$T"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# The same image as probe (g)'s rehearsal: the body's own dnf installs the rest (gcc-c++ included).
cat > "$T/Containerfile" << 'EOF'
FROM public.ecr.aws/amazonlinux/amazonlinux:2023
RUN dnf install -y -q git gzip python3-pip perl jq gdb zstd tar findutils procps-ng util-linux file sudo shadow-utils && dnf clean all
RUN useradd -m -u 1000 ec2-user && echo 'ec2-user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ec2-user && chmod 0440 /etc/sudoers.d/ec2-user
EOF
IMG=localhost/ak2-rgcrash-rehearse:$(shasum -a 256 "$T/Containerfile" | cut -c1-12)
if ! "${PM[@]}" image exists "$IMG"; then
  say "building $IMG"
  "${PM[@]}" build -q -t "$IMG" -f "$T/Containerfile" "$T" > /dev/null || { say "could not build $IMG"; exit 1; }
fi

# ---- the stand-ins ----
mkdir -p "$T/bin" "$T/s3/$B/$CK" "$T/out1" "$T/out2" "$T/out3" || exit 1
chmod 1777 "$T/out1" "$T/out2" "$T/out3" "$T"
git archive "$SHA" > "$T/src.tar" || exit 1
cp scripts/lib/rehearse_aws.py "$T/rehearse_aws.py" || exit 1
cat > "$T/bin/git" << 'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "clone -q") mkdir -p "${@: -1}" && tar -x -C "${@: -1}" -f /rh/src.tar ;;
  *) case " $* " in *" checkout "*) exit 0 ;; *) exec /usr/bin/git "$@" ;; esac ;;
esac
EOF
printf '#!/usr/bin/env bash\nexec python3 /rh/rehearse_aws.py "$@"\n' > "$T/bin/aws"
chmod +x "$T/bin/"*
mapfile -t SRC < <(find "$K2_READS" -name '*_200000_[12].fq.gz' | sort)
[ "${#SRC[@]}" -ge 2 ] || { say "need the 200,000-pair read sets in $K2_READS (make stage-reads)"; exit 1; }
mapfile -t NAMES < <(awk -F'\t' 'NR > 1 && $1 >= 1 && $1 <= 10 {print $2 "_1.fastq.gz"; print $2 "_2.fastq.gz"}' results/cohort/PRJNA398089/runs.tsv)
for i in "${!NAMES[@]}"; do cp "${SRC[$((i % ${#SRC[@]}))]}" "$T/s3/$B/$CK/${NAMES[$i]}" || exit 1; done
chmod -R a+rwX "$T/s3"
say "stand-in cohort: ${#NAMES[@]} files from ${#SRC[@]} read sets, $(du -sh "$T/s3" | cut -f1)"
cat > "$T/helpers.sh" << 'EOF'
set +e
ak2_say() { echo "ak2: [$(date -u +%FT%TZ)] $*"; }
ak2_err() { printf '%s\t%s\n' "$1" "$2" >> "$AK2T_OUT/helper-errors.tsv"; ak2_say "ERROR: $2"; }
ak2_phase() { echo "ak2-phase $(date -u +%FT%TZ) $1"; }
ak2_req() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$AK2T_OUT/requests.tsv"; }
ak2_push() { local n=${2:-$(basename "$1")}; mkdir -p "$(dirname "$AK2T_OUT/$n")" && cp "$1" "$AK2T_OUT/$n" && ak2_say "pushed out/$n"; }
ak2_drop_caches() { echo "ak2: drop_caches (rehearsal: nothing)"; }
EOF
cat "$T/helpers.sh" <(jq -r '.command[2]' "$SPEC") > "$T/node.sh"
# node N LOOP_S [ENV...]: start run N's container (detached), its log in $T/body$N.log.
node() {
  local n=$1 loop=$2 e=(); shift 2
  for kv in "$@"; do e+=(-e "$kv"); done
  "${PM[@]}" run -d --privileged --name "$CTR-$n" --user ec2-user --shm-size=8g --tmpfs /home/ec2-user:rw,size=4g,mode=1777 \
    -v "$T:/rh" -w /home/ec2-user \
    -e HOME=/home/ec2-user -e PATH=/rh/bin:/usr/local/bin:/usr/bin:/bin -e AK2T_FAKE=/rh/s3 -e AK2T_LOG=/rh/aws.log \
    -e AK2T_ROLE=instance -e AK2T_OUT="/rh/out$n" -e AK2_RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$SHA" -e AK2_REGION=us-west-2 \
    -e AK2_DATASETS="$(jq -r .env.AK2_DATASETS "$SPEC")" -e AK2_INSTANCE_TYPE="$(jq -r .resources.instance_type "$SPEC")" \
    -e AK2_REHEARSE_LOOP_S="$loop" -e AK2_REHEARSE_MAXCORES="$MAXC" -e AK2_REHEARSE_PUSH_N=40 \
    -e AK2_REHEARSE_LANES=6 -e AK2_REHEARSE_PROGRESS_S=30 "${e[@]}" \
    "$IMG" bash -e -c "$(cat "$T/node.sh")" > /dev/null || { say "could not start node $n"; return 1; }
  "${PM[@]}" logs -f "$CTR-$n" > "$T/body$n.log" 2>&1 &
}

CP0=$("${PM[@]}" run --rm "$IMG" cat /proc/sys/kernel/core_pattern)
say "the VM's kernel.core_pattern before: $CP0"
# ---- run 1: the probe, with K induced crashes (a, b, a) ----
node 1 "$LOOP_S" || exit 1
for _ in $(seq 2400); do grep -q '^ak2-phase .* loop$' "$T/body1.log" && break; "${PM[@]}" container exists "$CTR-1" || break; sleep 1; done
grep -q '^ak2-phase .* loop$' "$T/body1.log" || { say "run 1 never reached the loop"; tail -40 "$T/body1.log" | sed 's/^/  body | /'; exit 1; }
say "run 1: loop started; inducing $K crashes"
KILLED=()
for ((c = 1; c <= K; c++)); do
  want=rga-venv; [ $((c % 2)) = 0 ] && want=rg16-venv
  sleep 10
  for _ in $(seq 200); do
    p=$("${PM[@]}" exec "$CTR-1" bash -c 'for p in $(pgrep -x rapidgzip); do tr "\0" " " < /proc/$p/cmdline | grep -q "/'"$want"'/bin/rapidgzip " && { kill -SEGV $p && echo $p; break; }; done' 2> /dev/null)
    [ -n "$p" ] && break
    sleep 0.2
  done
  [ -n "$p" ] || { say "could not find a running $want rapidgzip to kill"; break; }
  KILLED+=("$p"); say "crash $c: SIGSEGV to pid $p ($want)"
done
RC1=$("${PM[@]}" wait "$CTR-1"); RC1=${RC1:-1}
CP1=$("${PM[@]}" run --rm "$IMG" cat /proc/sys/kernel/core_pattern)
say "run 1: body exit $RC1; the VM's kernel.core_pattern after: $CP1"
# ---- run 2: a failed build; b must still run ----
node 2 40 AK2_REHEARSE_RGBUILD_SDIST_SHA256=0000000000000000000000000000000000000000000000000000000000000000 || exit 1
RC2=$("${PM[@]}" wait "$CTR-2"); RC2=${RC2:-1}
say "run 2 (failed build): body exit $RC2"
# ---- run 3: rg-build.sh alone, after run 1 stored its wheel: a cache hit ----
"${PM[@]}" run --name "$CTR-3" --user ec2-user -v "$T:/rh" -w /tmp \
  -e PATH=/rh/bin:/usr/local/bin:/usr/bin:/bin -e AK2T_FAKE=/rh/s3 -e AK2T_LOG=/rh/aws.log -e AK2T_ROLE=instance \
  "$IMG" bash -c "mkdir -p /tmp/repo && tar -x -C /tmp/repo -f /rh/src.tar && /tmp/repo/scripts/g3/rg-build.sh /tmp/o s3://$B/aws-kraken2/data/rg-build" \
  > "$T/out3/rg-build.out" 2> "$T/out3/rg-build.err"; RC3=$?
say "run 3 (rg-build.sh alone): exit $RC3"
sleep 2; jobs -p | xargs kill 2> /dev/null

OK=0
chk() { if eval "$2"; then say "ok: $1"; else say "FAILED: $1"; OK=1; fi; }
cnt() { grep -c . || true; }
L=$T/body1.log; J=$T/out1/rgfix.jsonl
sl() { grep "^probe-rgfix " "$L" | sed 's/^probe-rgfix //' | jq -c "select($1)"; }
pl() { jq -c "select($1)" "$J" 2> /dev/null; }
R='(9 / 3588)'
say "---- run 1"
chk "body exit 0" '[ "$RC1" = 0 ]'
fl=$(grep -m1 'shell flags' "$L" | grep -oE 'flags [^ ]+' | cut -d' ' -f2)
chk "the body's shell flags ($fl) lack e" '[ -n "$fl" ] && [[ $fl != *e* ]]'
BS=$(pl '.kind == "rg-build"' | jq -r '"\(.status) \(.cache) \(.rpmalloc_symbols) \(.isal_symbols) \(.wall_seconds)"')
chk "rg-build: ok, stored in the cache, 0 rpmalloc and 0 ISA-L symbols, measured ($BS s)" '[[ $BS =~ ^ok\ stored\ 0\ 0\ [1-9][0-9]*$ ]]'
chk "tool a: 0.14.5-norpmalloc, 0 rpmalloc functions, 0 ISA-L symbols, reports 0.14.5" \
  '[ "$(pl '\''.kind == "tool" and .variant == "a" and .version == "0.14.5-norpmalloc" and .rpmalloc_functions == 0 and .isal_symbols == 0 and (.reports | test("version 0.14.5")) and (.oss_attributions | test("rpmalloc") | not)'\'' | cnt)" = 1 ]'
chk "tool b: 0.16.0, wheel $PIN_B, ISA-L symbols > 0" \
  '[ "$(pl ".kind == \"tool\" and .variant == \"b\" and .version == \"0.16.0\" and .wheel_sha256 == \"$PIN_B\" and .isal_symbols > 0" | cnt)" = 1 ]'
chk "host line: 6 lanes, P 8, variants a b" '[ "$(pl '\''.kind == "host"'\'' | jq -r '\''"\(.lanes) \(.P) \(.variants | join(","))"'\'')" = "6 8 a,b" ]'
chk "core control ok" '[ "$(pl '\''.kind == "core-control"'\'' | jq -r .ok)" = true ]'
chk "20 reference lines, exit 0" '[ "$(pl '\''.kind == "reference" and .exit == 0'\'' | cnt)" = 20 ]'
chk "plan: build_s > 0, expected_jobs > 0, per variant p = exp(-(9/3588) x n)" \
  '[ "$(pl ".kind == \"plan\" and .build_s > 0 and .expected_jobs > 0 and .end_basis == \"rehearsal\" and (.per_variant | length) == 2 and (.per_variant | all(((.p_no_crash_expected - ((-$R * .expected_jobs) | exp)) | fabs) < 1e-9))" | cnt)" = 1 ]'
chk "progress lines per variant" '[ "$(pl '\''.kind == "progress" and .mean_step_s != null and (.per_variant | length) == 2 and (.per_variant | all(.projected_jobs != null))'\'' | cnt)" -ge 2 ]'
sj=$(sl '.kind == "job"' | sort); pj=$(pl '.kind == "job"' | sort)
nj=$(printf '%s\n' "$pj" | cnt)
chk "job lines streamed = pushed ($nj)" '[ -n "$pj" ] && [ "$sj" = "$pj" ]'
NJS=$(printf '%s\n' "${NAMES[@]}" | jq -R . | jq -sc .)
chk "every job lad_identity's: -P 8, lane = n mod 6, file = n mod 20, gzip = the reference; variant = (k + lane) mod 2" \
  '[ "$(jq -c --argjson names "$NJS" '\''select(.kind == "job" and (.P != 8 or .mode != "identity" or .lane != (.n % 6) or .file != $names[.n % 20] or .gzip_match != true or .gzip_exit != 0 or .variant != (if ((((.n - .lane) / 6) + .lane) % 2) == 0 then "a" else "b" end)))'\'' "$J" | cnt)" = 0 ]'
chk "both variants ran jobs" '[ "$(pl '\''.kind == "job" and .variant == "a"'\'' | cnt)" -gt 0 ] && [ "$(pl '\''.kind == "job" and .variant == "b"'\'' | cnt)" -gt 0 ]'
fj=$(pl '.kind == "job" and (.exit != 0 or (.match | not))')
chk "exactly the $K killed jobs failed, each exit 139 signal 11 (variants $(printf '%s\n' "$fj" | jq -r .variant | tr '\n' ' '))" \
  '[ "$(printf "%s\n" "$fj" | jq -r .pid | sort | tr "\n" " ")" = "$(printf "%s\n" "${KILLED[@]}" | sort | tr "\n" " ")" ] && [ "$(printf "%s\n" "$fj" | jq -c "select(.exit == 139 and .signal == 11)" | cnt)" = "$K" ]'
chk "every other job exit 0 with the reference sha256" '[ "$(pl '\''.kind == "job" and .exit == 0 and .match'\'' | cnt)" = $((nj - K)) ]'
for n in $(printf '%s\n' "$fj" | jq -r .n); do
  chk "job $n: failure line with a core, gdb frames and frame0" '[ "$(pl ".kind == \"failure\" and .n == $n and .core != null and .gdb_frames > 0 and .frame0 != null" | cnt)" = 1 ]'
  chk "job $n: gdb output streamed through x/16i, and pushed" 'grep -q "^rgfix-gdb $n | ---- x/16i" "$L" && grep -q "^rgfix-gdb $n | #0 " "$L" && [ -s "$T/out1/gdb/$n.txt" ]'
done
nc=$(find "$T/out1/cores" -name 'core.*.zst' 2> /dev/null | cnt)
ztest() { local z; for z in "$T"/out1/cores/*.zst; do zstd -q -t "$z" || return 1; done; }
chk "$MAXC cores pushed (of $K), valid zstd" '[ "$nc" = "$MAXC" ] && ztest'
chk "2 analysis bundles, the built wheel and the build log pushed" \
  '[ -s "$T/out1/bundle-0.14.5-norpmalloc.tar.zst" ] && [ -s "$T/out1/bundle-0.16.0.tar.zst" ] && ls "$T"/out1/rapidgzip-0.14.5-*.whl > /dev/null && [ -s "$T/out1/rg-build.log" ]'
chk "tally jobs = job lines" '[ "$(awk -F"\t" "NR > 1 {s += \$3} END {print s + 0}" "$T/out1/rgfix-tally.tsv")" = "$nj" ]'
chk "2 summary lines, both ran, crashes a 2 b 1, p = exp(-(9/3588) x jobs), verdict crashed" \
  '[ "$(pl ".kind == \"summary\" and .ran and .verdict == \"crashed: not a fix\" and ((.p_no_crash_at_reference_rate - ((-$R * .jobs) | exp)) | fabs) < 1e-9" | jq -r "\"\(.variant)\(.crashes)\"" | sort | tr -d "\n")" = "a2b1" ]'
chk "restore line restored" '[ "$(pl '\''.kind == "restore"'\'' | jq -r .restored)" = true ]'
chk "the VM's core_pattern restored ($CP1)" '[ "$CP1" = "$CP0" ]'
RECIPE=$(pl '.kind == "rg-build"' | jq -r .recipe_sha256)
chk "the cache entry in the stand-in S3 (recipe ${RECIPE:0:12})" '[ -s "$T/s3/$B/aws-kraken2/data/rg-build/$RECIPE/build.json" ] && ls "$T/s3/$B/aws-kraken2/data/rg-build/$RECIPE/"rapidgzip-0.14.5-*.whl > /dev/null'
grep -E '^probe-rgfix \{"kind":"(rg-build|tool|host|core-control|plan|summary|restore)"' "$L" | cut -c1-500
grep -E '^rgfix-gdb [0-9]+ \| #0 ' "$L" | head -6 | cut -c1-220
column -t -s$'\t' "$T/out1/rgfix-tally.tsv"
say "---- run 2 (failed build)"
L2=$T/body2.log; J2=$T/out2/rgfix.jsonl
chk "body exit 0" '[ "$RC2" = 0 ]'
chk "rg-build line status failed" '[ "$(jq -r '\''select(.kind == "rg-build") | .status'\'' "$J2")" = failed ]'
chk "the build log streamed (rg-build-log lines)" '[ "$(grep -c "^rg-build-log | " "$L2")" -gt 0 ]'
chk "host variants b only; every job variant b" '[ "$(jq -r '\''select(.kind == "host") | .variants | join(",")'\'' "$J2")" = b ] && [ "$(jq -c '\''select(.kind == "job" and .variant != "b")'\'' "$J2" | cnt)" = 0 ] && [ "$(jq -c '\''select(.kind == "job")'\'' "$J2" | cnt)" -gt 0 ]'
chk "summary a not run (build failed), b ran with jobs" \
  '[ "$(jq -r '\''select(.kind == "summary") | "\(.variant):\(.ran):\(.jobs > 0):\(.verdict | startswith("not run"))"'\'' "$J2" | sort | tr "\n" " ")" = "a:false:false:true b:true:true:false " ]'
say "---- run 3 (rg-build.sh alone)"
W1=$(pl '.kind == "tool" and .variant == "a"' | jq -r .wheel_sha256)
R3=$(sed -n 's/^rg-build //p' "$T/out3/rg-build.out" | tail -1)
chk "exit 0, cache hit, wheel sha256 = run 1's (${W1:0:12})" '[ "$RC3" = 0 ] && [ "$(jq -r .cache <<< "$R3")" = hit ] && [ "$(jq -r .wheel_sha256 <<< "$R3")" = "$W1" ]'
if [ "$OK" = 0 ]; then say "ok"; else say "FAILED (REHEARSE_KEEP=1 keeps the scratch dir)"; tail -30 "$L" | sed 's/^/  body1 | /'; tail -15 "$L2" | sed 's/^/  body2 | /'; fi
exit "$OK"
