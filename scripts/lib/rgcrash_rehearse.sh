#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the container-side snippets are literal; chk's conditions read variables through eval
# make rehearse SPEC=runs/g3-probe-rgcrash-<type>.json (docs/probes.md, "The rapidgzip crash probe";
# called by scripts/lib/probe_rehearse.sh for kind rgcrash): the spec's own body (command[2],
# unmodified) on an Amazon Linux 2023 aarch64 container (rootful podman, --privileged: the VM's
# own kernel.core_pattern and core dumps), as ec2-user with sudo, under `bash -e -c` as spawn runs
# it, after the probe rehearsal's helper stand-ins. Real on the node: dnf (gdb, zstd, the
# debuginfo attempt), lever.sh's pip --require-hashes install of rapidgzip 0.14.5 and the body's
# of 0.16.0 (from PyPI), sysctl, the cores, gdb. Stand-ins at the edges: S3 is one directory
# through the stub aws (scripts/lib/rehearse_aws.py, Metadata.sha256 computed), git clone is the
# committed tree (git archive), and the c10 cohort's 20 files are small real public read sets
# (the .cache/reads 200,000-pair gz files, cycled under the c10 names). The crash is induced: once
# the loop runs, the host sends SIGSEGV to K = 3 running rapidgzip processes (0.14.5, 0.16.0,
# 0.14.5), which dump real cores of the real binary; MAXCORES = 2, so the third is analysed but not
# pushed.
# What passes, on observed output:
#   body exit 0, its shell flags without e; 2 tool lines (0.14.5 and 0.16.0, wheel sha256 = the
#   pins); the core control ok; 20 reference lines, exit 0; the job lines streamed = the pushed
#   rgcrash.jsonl's; both versions at -P 8 and -P 16; exactly the K killed jobs failed (exit 139,
#   signal 11; the sha256 is right if the kill came after the last write), every other job exit 0 with the reference sha256; a failure line per
#   killed job with a core and gdb frames > 0, its gdb output streamed (rgcrash-gdb lines through
#   "---- x/16i") and pushed (out/gdb/N.txt); min(K, MAXCORES) cores in out/cores/, each a valid
#   zstd frame; 2 analysis bundles; the tally's jobs = the job lines; 2 summary lines whose crashes
#   sum to K; the restore line restored = true, and the VM's core_pattern after = before.
# Usage: scripts/lib/rgcrash_rehearse.sh runs/g3-probe-rgcrash-<type>.json   (REHEARSE_KEEP=1 keeps the scratch dir)
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
. scripts/pin.env
. scripts/paths.sh
SPEC=${1:?SPEC}
[ -f "$SPEC" ] || { echo "rgcrash-rehearse: no $SPEC" >&2; exit 2; }
git diff --quiet HEAD -- "$SPEC" scripts cmd internal || { echo "rgcrash-rehearse: commit first (the rehearsal runs the committed tree)" >&2; exit 2; }
SHA=$(git rev-parse --short=7 HEAD)
mkdir -p results/rehearse || exit 1
LOGF="results/rehearse/$(basename "$SPEC" .json)-$(date -u +%Y%m%dT%H%M%SZ)-$SHA.log"
exec > >(tee "$LOGF") 2>&1
say() { echo "rgcrash-rehearse: $*"; }
say "record $LOGF; $SPEC at $SHA; shell flags $-"
K=3; MAXC=2; LOOP_S=${RGREH_LOOP_S:-150}
B=aws-kraken2-942542972736-us-west-2; CK=aws-kraken2/data/cohort
PIN_A=499dfb8e24bf86607e87e8ec4f1c1797ea258078ddd550ce010b2fb1c17eafee   # lever.sh's cp39 manylinux_2_17_aarch64
PIN_B=$(jq -r '.command[2]' "$SPEC" | awk -F= '/^RG16_HASH=/ {print $2; exit}')

command -v podman > /dev/null || { say "need podman"; exit 1; }
CONN=$(podman system connection list --format '{{.Name}}' 2> /dev/null | grep -- '-root$' | head -1)
[ -n "$CONN" ] || { say "need a rootful podman connection"; exit 1; }
PM=(podman --connection "$CONN")
T=$(mktemp -d "$HOME/.ak2-rgreh.XXXXXX") || exit 1   # under $HOME: the podman machine shares it
chmod 0755 "$T"
CTR=ak2rg-$$
cleanup() {
  "${PM[@]}" rm -f "$CTR" > /dev/null 2>&1
  if [ "${REHEARSE_KEEP:-0}" = 1 ]; then say "kept $T"; else chmod -R u+w "$T" 2> /dev/null; rm -rf "$T"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

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
mkdir -p "$T/bin" "$T/s3/$B/$CK" "$T/out" || exit 1
chmod 1777 "$T/out" "$T"
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

CP0=$("${PM[@]}" run --rm "$IMG" cat /proc/sys/kernel/core_pattern)
say "the VM's kernel.core_pattern before: $CP0"
RID="$(date -u +%Y%m%d-%H%M%S)-$SHA"
"${PM[@]}" run -d --privileged --name "$CTR" --user ec2-user --shm-size=8g --tmpfs /home/ec2-user:rw,size=4g,mode=1777 \
  -v "$T:/rh" -w /home/ec2-user \
  -e HOME=/home/ec2-user -e PATH=/rh/bin:/usr/local/bin:/usr/bin:/bin -e AK2T_FAKE=/rh/s3 -e AK2T_LOG=/rh/aws.log \
  -e AK2T_ROLE=instance -e AK2T_OUT=/rh/out -e AK2_RUN_ID="$RID" -e AK2_REGION=us-west-2 \
  -e AK2_DATASETS="$(jq -r .env.AK2_DATASETS "$SPEC")" -e AK2_INSTANCE_TYPE="$(jq -r .resources.instance_type "$SPEC")" \
  -e AK2_REHEARSE_LOOP_S="$LOOP_S" -e AK2_REHEARSE_MAXCORES="$MAXC" -e AK2_REHEARSE_PUSH_N=40 \
  "$IMG" bash -e -c "$(cat "$T/node.sh")" > /dev/null || { say "could not start the node"; exit 1; }
"${PM[@]}" logs -f "$CTR" > "$T/body.log" 2>&1 &
LOGP=$!

# ---- the induced crashes: K running rapidgzip processes get SIGSEGV, alternating versions ----
for _ in $(seq 1800); do grep -q '^ak2-phase .* loop$' "$T/body.log" && break; "${PM[@]}" container exists "$CTR" || break; sleep 1; done
grep -q '^ak2-phase .* loop$' "$T/body.log" || { say "the body never reached the loop"; tail -30 "$T/body.log" | sed 's/^/  body | /'; exit 1; }
say "loop started; inducing $K crashes"
KILLED=()
for ((c = 1; c <= K; c++)); do
  want=rg-venv; [ $((c % 2)) = 0 ] && want=rg16-venv
  sleep 10
  for _ in $(seq 200); do
    p=$("${PM[@]}" exec "$CTR" bash -c 'for p in $(pgrep -x rapidgzip); do tr "\0" " " < /proc/$p/cmdline | grep -q "/'"$want"'/bin/rapidgzip " && { kill -SEGV $p && echo $p; break; }; done' 2> /dev/null)
    [ -n "$p" ] && break
    sleep 0.2
  done
  [ -n "$p" ] || { say "could not find a running $want rapidgzip to kill"; break; }
  KILLED+=("$p"); say "crash $c: SIGSEGV to pid $p ($want)"
done
RC=$("${PM[@]}" wait "$CTR"); RC=${RC:-1}
sleep 2; kill "$LOGP" 2> /dev/null
CP1=$("${PM[@]}" run --rm "$IMG" cat /proc/sys/kernel/core_pattern)
say "body exit $RC; the VM's kernel.core_pattern after: $CP1"
OK=0
chk() { if eval "$2"; then say "ok: $1"; else say "FAILED: $1"; OK=1; fi; }
L=$T/body.log; J=$T/out/rgcrash.jsonl
sl() { grep "^probe-rgcrash " "$L" | sed 's/^probe-rgcrash //' | jq -c "select($1)"; }
pl() { jq -c "select($1)" "$J" 2> /dev/null; }
cnt() { grep -c . || true; }
chk "body exit 0" '[ "$RC" = 0 ]'
fl=$(grep -m1 'shell flags' "$L" | grep -oE 'flags [^ ]+' | cut -d' ' -f2)
chk "the body's shell flags ($fl) lack e" '[ -n "$fl" ] && [[ $fl != *e* ]]'
chk "tool lines: 0.14.5 wheel $PIN_A, 0.16.0 wheel $PIN_B" \
  '[ "$(pl '\''.kind == "tool"'\'' | jq -r '\''"\(.version) \(.wheel_sha256)"'\'' | sort | tr "\n" " ")" = "0.14.5 $PIN_A 0.16.0 $PIN_B " ]'
chk "core control ok" '[ "$(pl '\''.kind == "core-control"'\'' | jq -r .ok)" = true ]'
chk "20 reference lines, exit 0" '[ "$(pl '\''.kind == "reference" and .exit == 0'\'' | cnt)" = 20 ]'
sj=$(sl '.kind == "job"' | sort); pj=$(pl '.kind == "job"' | sort)
nj=$(printf '%s\n' "$pj" | cnt)
chk "job lines streamed = pushed ($nj)" '[ -n "$pj" ] && [ "$sj" = "$pj" ]'
for v in 0.14.5 0.16.0; do for p in 8 16; do
  chk "jobs at $v -P $p" '[ "$(pl ".kind == \"job\" and .version == \"$v\" and .P == $p" | cnt)" -gt 0 ]'
done; done
fj=$(pl '.kind == "job" and (.exit != 0 or (.match | not))')
# (A kill that lands after the last write leaves the right sha256: the exit alone is checked.)
chk "exactly the $K killed jobs failed, each exit 139 signal 11 ($(printf '%s\n' "$fj" | jq -c 'select(.match | not)' | cnt) with a wrong sha256)" \
  '[ "$(printf "%s\n" "$fj" | jq -r .pid | sort | tr "\n" " ")" = "$(printf "%s\n" "${KILLED[@]}" | sort | tr "\n" " ")" ] && [ "$(printf "%s\n" "$fj" | jq -c "select(.exit == 139 and .signal == 11)" | cnt)" = "$K" ]'
chk "every other job exit 0 with the reference sha256" '[ "$(pl '\''.kind == "job" and .exit == 0 and .match'\'' | cnt)" = $((nj - K)) ]'
for n in $(printf '%s\n' "$fj" | jq -r .n); do
  chk "job $n: failure line with a core and gdb frames" '[ "$(pl ".kind == \"failure\" and .n == $n and .core != null and .gdb_frames > 0" | cnt)" = 1 ]'
  chk "job $n: gdb output streamed through x/16i, and pushed" 'grep -q "^rgcrash-gdb $n | ---- x/16i" "$L" && grep -q "^rgcrash-gdb $n | #0 " "$L" && [ -s "$T/out/gdb/$n.txt" ]'
done
nc=$(find "$T/out/cores" -name 'core.*.zst' 2> /dev/null | cnt)
ztest() { local z; for z in "$T"/out/cores/*.zst; do zstd -q -t "$z" || return 1; done; }
chk "$MAXC cores pushed (of $K), valid zstd" '[ "$nc" = "$MAXC" ] && ztest'
chk "2 analysis bundles" '[ -s "$T/out/bundle-0.14.5.tar.zst" ] && [ -s "$T/out/bundle-0.16.0.tar.zst" ]'
chk "tally jobs = job lines" '[ "$(awk -F"\t" "NR > 1 {s += \$3} END {print s + 0}" "$T/out/rgcrash-tally.tsv")" = "$nj" ]'
chk "2 summary lines, crashes sum to $K" '[ "$(pl '\''.kind == "summary"'\'' | cnt)" = 2 ] && [ "$(pl '\''.kind == "summary"'\'' | jq -s "map(.crashes) | add")" = "$K" ]'
chk "restore line restored" '[ "$(pl '\''.kind == "restore"'\'' | jq -r .restored)" = true ]'
chk "the VM's core_pattern restored ($CP1)" '[ "$CP1" = "$CP0" ]'
grep -E '^probe-rgcrash \{"kind":"(tool|host|core-control|summary|restore)"' "$L" | cut -c1-400
grep -E '^rgcrash-gdb [0-9]+ \| (#[0-4] |\$1 = |pc )' "$L" | head -24 | cut -c1-220
column -t -s$'\t' "$T/out/rgcrash-tally.tsv"
if [ "$OK" = 0 ]; then say "ok"; else say "FAILED (REHEARSE_KEEP=1 keeps the scratch dir)"; tail -30 "$L" | sed 's/^/  body | /'; fi
exit "$OK"
