#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the checks' conditions are literal text for eval
# make rehearse SPEC=runs/inputpath-<family>-<engine>.json (docs/inputpath.md, "The rehearsal";
# #90): the spec's own body (command[2], unmodified) on Amazon Linux 2023 aarch64 containers
# (rootful podman, --privileged: real tmpfs mounts with huge=), as ec2-user with sudo, under
# `bash -e -c` as spawn runs it, after the probe rehearsals' helper stand-ins. Real on the node:
# the clone of the committed tree (a git bundle of HEAD), upstream built at the pin by
# scripts/oracle-build.sh (from the shared upstream checkout) or ours by make build (Go and the
# module cache from the image and the host), rapidgzip 0.14.5 by lever.sh's pip --require-hashes
# (from wheels in the image), pidstat, /usr/bin/time, F_SETPIPE_SZ, tmpfs huge=always, process
# substitution into the classifier. Stand-ins at the edges: S3 is one directory through the stub
# aws (scripts/lib/rehearse_aws.py; Metadata.sha256 computed); the Standard-8 key holds the viral
# DB; the inputs are real public read sets (.cache/reads: SRR062634, the first 1,000,000 pairs, as the paired
# sample, ERR478965 200,000 reads of mate 1 as the single-end one), re-encoded as BGZF (a python
# BGZF writer) and indexed (rapidgzip --export-index) in a prep container, listed in a rehearsal
# inputs.tsv (AK2_REHEARSE_INPUTS_TSV); THP is a fake sysfs file (AK2_REHEARSE_THP_ROOT), so the
# podman VM's setting is never written; the 64-vCPU host is the VM's 8 CPUs (the spec's threads
# run oversubscribed); AK2_INSTANCE_TYPE is the spec's type.
# The Law 1 reference (AK2_REHEARSE_G1_REF, #95's g1_reference format): upstream at the pin (the
# shared oracle build, scripts/oracle-build.sh) on the rehearsal inputs and the viral DB, run on the
# host before the cases.
# Cases, by the spec's engine:
#   upstream: A, the full matrix (REPS of the spec), rapidgzip installed as on the node;
#             B, a missing inputs.tsv: exit 1 with a fatal line before any build or stage;
#             D, ak2_drop_caches failing: exit 95, no point run;
#             F, a Law 1 reference whose report sha256s differ: the run stops after the first warm-up.
#   ours:     C, the full matrix with induced rapidgzip crashes (a wrapper around the image's
#             rapidgzip 0.14.5, AK2_REHEARSE_RAPIDGZIP): SIGSEGV in both identity attempts of
#             -P 4 on pe_2.gz, in the first identity attempt of -P 2 on pe_1.gz (a transient), and
#             in the first timed -P 8 --chunk-size 4096 decode of se_1.gz; B and F as above
#             (F: ours against upstream's reference); E, a deadline 60 s into the measure phase.
# What passes, on observed output (each check printed ok/FAILED):
#   A, C: body exit 0, shell flags without e; 1 tool line 0.14.5 (A: the wheel's sha256 is lever.sh's
#   cp39 aarch64 pin); 9 input lines, each fastq_sha256 = the read set's SOURCE sha256; 3 db
#   lines; the point lines streamed = the pushed points.jsonl; the expected point count
#   (2 x (1 + REPS x the rep-1 list)); every point record valid for the report's contract
#   (scripts/lib/inputpath_report.py, from the tree or origin/inputpath-report, on a run dir
#   mock: exit 0, no DEFECT; skipped if neither exists); every ok I2-I4 point with identity
#   ok and gz = rg sha256; 6 select lines with a best p; every run point's pidstat CSV pushed with
#   the report's header; THP: never points read from the huge=never DB and always points
#   (upstream) from the huge=always one; pipe_bytes 1048576 (and 65536 on the default-pipe
#   points); summary thp_restored; tables.py on the mock run dir: one row per point. (Both
#   warm-ups passed the Law 1 reference, or the run would have stopped.)
#   A: the isal line false (static none, 0 s of ISA-L) and isal false on every rapidgzip point;
#   the g1-reference line and every record cite the reference file; every identity line ok; no
#   point skipped except the 2 warm-ups; 0 defects.
#   C: two crash identity lines (attempts 1 and 2) for pe_2.gz -P 4 and exactly the REPS x threads
#   pe I2 p=4 points skipped-identity; pe_1.gz -P 2's attempt 1 crash, attempt 2 ok, and its
#   points ok; exactly one decode-crash point (rep 1, se, I2, p 8, chunk 4096, threads 48) with
#   rg1 exit 139, excluded (status skipped); 0 defects.
#   B: exit 1; a fatal line naming inputs.tsv; no engine line. D: exit 95; no point line.
#   E: exit 0; at least one skipped-deadline point, every point after the first one too, and
#   the record still complete (every listed point has a line).
#   F: exit 1; one point record, the warm-up, status defect (law1-g1-mismatch) citing the
#   reference file; a defect line and a fatal line.
#   Every case: all six committed runs/inputpath-*.json carry this body (only the parameter
#   lines differ).
# Usage: scripts/lib/inputpath_rehearse.sh runs/inputpath-<family>-<engine>.json   (REHEARSE_KEEP=1 keeps the scratch dir;
#        IPREH_CASES="A B D" picks cases)
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
. scripts/pin.env
. scripts/paths.sh
SPEC=${1:?SPEC}
[ -f "$SPEC" ] || { echo "inputpath-rehearse: no $SPEC" >&2; exit 2; }
git diff --quiet HEAD -- "$SPEC" scripts cmd internal || { echo "inputpath-rehearse: commit first (the rehearsal runs the committed tree)" >&2; exit 2; }
SHA=$(git rev-parse --short=7 HEAD)
mkdir -p results/rehearse || exit 1
LOGF="results/rehearse/$(basename "$SPEC" .json)-$(date -u +%Y%m%dT%H%M%SZ)-$SHA.log"
exec > >(tee "$LOGF") 2>&1
say() { echo "inputpath-rehearse: $*"; }
BODY=$(jq -r '.command[2]' "$SPEC")
ENGINE=$(sed -n 's/^FAMILY=[a-z0-9]*; ENGINE=\([a-z]*\);.*/\1/p' <<< "$BODY")
REPS=$(sed -n 's/^FAMILY=.*; REPS=\([0-9]*\);.*/\1/p' <<< "$BODY")
TYPE=$(jq -r .resources.instance_type "$SPEC")
case "$ENGINE" in upstream) CASES=${IPREH_CASES:-A B D F} ;; ours) CASES=${IPREH_CASES:-C B E F} ;; *) say "cannot read ENGINE from $SPEC"; exit 2 ;; esac
say "record $LOGF; $SPEC ($ENGINE, $TYPE, REPS $REPS) at $SHA; cases $CASES; shell flags $-"
OK=0
chk() { if eval "$2"; then say "ok: $1"; else say "FAILED: $1"; OK=1; fi; }
strip() { grep -v -E '^(FAMILY=|PARAMS_LINE=)'; }
same=0; for s in runs/inputpath-*.json; do
  [ "$(jq -r '.command[2]' "$s" | strip)" = "$(strip <<< "$BODY")" ] || { say "body differs beyond the parameters: $s"; same=1; }
done
chk "every runs/inputpath-*.json carries this body ($(ls runs/inputpath-*.json | wc -l | tr -d ' ') specs; only the parameter lines differ)" '[ "$same" = 0 ]'

command -v podman > /dev/null || { say "need podman"; exit 1; }
CONN=$(podman system connection list --format '{{.Name}}' 2> /dev/null | grep -- '-root$' | head -1)
[ -n "$CONN" ] || { say "need a rootful podman connection"; exit 1; }
PM=(podman --connection "$CONN")
T=$(mktemp -d "$HOME/.ak2-ipreh.XXXXXX") || exit 1   # under $HOME: the podman machine shares it
chmod 0755 "$T"
CTRS=()
cleanup() {
  for c in "${CTRS[@]}"; do "${PM[@]}" rm -f "$c" > /dev/null 2>&1; done
  if [ "${REHEARSE_KEEP:-0}" = 1 ]; then say "kept $T"; else chmod -R u+w "$T" 2> /dev/null; rm -rf "$T"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

cat > "$T/Containerfile" << 'EOF'
FROM public.ecr.aws/amazonlinux/amazonlinux:2023
RUN dnf install -y -q git gcc-c++ make zlib-devel perl jq gzip tar findutils python3 python3-pip sysstat time procps-ng util-linux sudo shadow-utils diffutils && dnf clean all
RUN useradd -m -u 1000 ec2-user && echo 'ec2-user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ec2-user && chmod 0440 /etc/sudoers.d/ec2-user
RUN git config --system safe.directory '*'
RUN python3 -m pip download -q --no-deps --only-binary=:all: -d /opt/wheels rapidgzip==0.14.5
RUN python3 -m venv /opt/rgprep && /opt/rgprep/bin/pip install -q --no-index --find-links /opt/wheels rapidgzip==0.14.5
RUN curl -fsSL https://go.dev/dl/go1.27.1.linux-arm64.tar.gz | tar -xz -C /usr/local
EOF
IMG=localhost/ak2-inputpath-rehearse:$(shasum -a 256 "$T/Containerfile" | cut -c1-12)
if ! "${PM[@]}" image exists "$IMG"; then
  say "building $IMG"
  "${PM[@]}" build -q -t "$IMG" -f "$T/Containerfile" "$T" > /dev/null || { say "could not build $IMG"; exit 1; }
fi

# ---- the stand-ins ----
B=aws-kraken2-942542972736-us-west-2; DK=aws-kraken2/data/k2_standard_08_GB_20260626; IK=aws-kraken2/data/inputpath-rehearse
mkdir -p "$T/bin" "$T/s3/$B/$DK" "$T/s3/$B/$IK" "$T/crash" "$T/gocache" "$T/thp/sys/kernel/mm/transparent_hugepage" || exit 1
git bundle create -q "$T/repo.bundle" HEAD || exit 1
cp scripts/lib/rehearse_aws.py "$T/rehearse_aws.py" || exit 1
VDB=$K2_DB_ROOT/k2_viral_20260626
for f in hash.k2d opts.k2d taxo.k2d; do cp "$VDB/$f" "$T/s3/$B/$DK/$f" || { say "need the viral DB at $VDB"; exit 1; }; done
sh256f() { shasum -a 256 "$1" | cut -d' ' -f1; }
# The paired sample: the first PE_N pairs of SRR062634 (a prefix of the real sample, as make g2
# derives its subsets), long enough for pidstat's 1 s samples to see the classifier and decoders.
PE_N=${IPREH_PE_N:-1000000}
for m in 1 2; do
  head -n $((4 * PE_N)) "$K2_READS/SRR062634_8000000_$m.fq" > "$T/pe_$m.fq" || exit 1
  gzip -6 -n -c "$T/pe_$m.fq" > "$T/s3/$B/$IK/pe_$m.gz" || exit 1
done
cp "$K2_READS/ERR478965_200000_1.fq.gz" "$T/s3/$B/$IK/se_1.gz" || exit 1
WANT_PE1=$(shasum -a 256 "$T/pe_1.fq" | cut -d' ' -f1); WANT_PE2=$(shasum -a 256 "$T/pe_2.fq" | cut -d' ' -f1)
# The Law 1 reference the body checks its warm-ups against (#95's g1_reference format): upstream at
# the pin (scripts/oracle-build.sh, the shared oracle build) on these inputs and the stand-in DB, run
# here on the host; and a copy with both report sha256s altered (case F: the run must stop).
K2DIR=$(scripts/oracle-build.sh) || { say "upstream build at the pin failed"; exit 1; }
"$K2DIR/kraken2" --db "$VDB" --threads 8 --paired --output "$T/ref-pe.out" --report "$T/ref-pe.rep" "$T/pe_1.fq" "$T/pe_2.fq" 2> "$T/ref-pe.err" &&
  "$K2DIR/kraken2" --db "$VDB" --threads 8 --output "$T/ref-se.out" --report "$T/ref-se.rep" "$K2_READS/ERR478965_200000_1.fq" 2> "$T/ref-se.err" ||
  { say "the reference runs failed"; exit 1; }
jq -n --arg po "$(sh256f "$T/ref-pe.out")" --arg pr "$(sh256f "$T/ref-pe.rep")" --arg so "$(sh256f "$T/ref-se.out")" --arg sr "$(sh256f "$T/ref-se.rep")" \
  --arg b "$(tr '\n' ';' < "$K2DIR/BUILD")" '{note:"inputpath rehearsal: upstream at the pin on the rehearsal inputs, the viral DB under the standard8 label", build:$b,
  g1_reference:[{role:"pe", db:"standard8", i0_output_sha256:$po, i0_report_sha256:$pr}, {role:"se", db:"standard8", i0_output_sha256:$so, i0_report_sha256:$sr}]}' > "$T/g1ref.json"
jq '.g1_reference |= map(.i0_report_sha256 |= ("0" + .[1:]))' "$T/g1ref.json" > "$T/g1ref-bad.json"
rm -f "$T/pe_1.fq" "$T/pe_2.fq" "$T"/ref-*.out
WANT_SE1=$(awk '$1 == "sha256" && $3 ~ /_1.fq$/ {print $2}' "$K2_READS/ERR478965_200000.SOURCE")
cat > "$T/bin/git" << 'EOF'
#!/bin/bash
if [ "${1:-}" = clone ]; then
  dst=${*: -1}; src=${*: -2:1}
  case $src in
    https://github.com/scttfrdmn/aws-kraken2.git) exec /usr/bin/git clone -q /rh/repo.bundle "$dst" ;;
    https://github.com/DerrickWood/kraken2.git) exec /usr/bin/git clone -q /upstream-src "$dst" ;;
    *) echo "rehearsal git: no clone of $src" >&2; exit 1 ;;
  esac
fi
exec /usr/bin/git "$@"
EOF
cat > "$T/bin/sudo" << 'EOF'
#!/bin/bash
# `dnf install` of packages already in the image: answered by rpm -q; everything else: real sudo.
if [ "${1:-}" = -n ] && [ "${2:-}" = dnf ] && [ "${3:-}" = install ]; then
  pk=(); for x in "${@:4}"; do case $x in -*) ;; *) pk+=("$x") ;; esac; done
  rpm -q "${pk[@]}" > /dev/null && exit 0
fi
exec /usr/bin/sudo "$@"
EOF
printf '#!/usr/bin/env bash\nexec python3 /rh/rehearse_aws.py "$@"\n' > "$T/bin/aws"
# Case C's decoder: the image's rapidgzip 0.14.5, with SIGSEGV induced (after some output) on the
# 1st and 2nd calls of -P 4 on pe_2.gz (both identity attempts: excluded), the 1st call of -P 2 on
# pe_1.gz (a transient: the retry passes) and the 2nd call of -P 8 --chunk-size 4096 on se_1.gz (the
# identity check is the 1st; the 2nd is rep 1's first timed -P 8 point).
cat > "$T/bin/rapidgzip-crashy" << 'EOF'
#!/bin/bash
REAL=/opt/rgprep/bin/rapidgzip
case " $* " in *" -d "*) ;; *) exec "$REAL" "$@" ;; esac
k=$(printf '%s' "$*" | md5sum | cut -c1-12); n=$(( $(cat "/rh/crash/$k" 2> /dev/null || echo 0) + 1 )); echo "$n" > "/rh/crash/$k"
if { [[ " $* " == *" -P 4 --chunk-size 4096 "* && "$*" == *"/pe_2.gz" && $n -le 2 ]] || [[ " $* " == *" -P 2 --chunk-size 4096 "* && "$*" == *"/pe_1.gz" && $n == 1 ]] ||
     [[ " $* " == *" -P 8 --chunk-size 4096 "* && "$*" == *"/se_1.gz" && $n == 2 ]]; }; then
  echo "$(date +%s) crash $n: $*" >> /rh/crash/log
  "$REAL" "$@" | head -c 100000
  kill -SEGV $$
fi
exec "$REAL" "$@"
EOF
chmod 0755 "$T/bin"/*
echo 'always [madvise] never' > "$T/thp/sys/kernel/mm/transparent_hugepage/enabled"
echo 'always defer defer+madvise [madvise] never' > "$T/thp/sys/kernel/mm/transparent_hugepage/defrag"
echo 'always within_size advise [never] deny force' > "$T/thp/sys/kernel/mm/transparent_hugepage/shmem_enabled"
cp -r "$T/thp" "$T/thp0"

# ---- the prep container: BGZF re-encodes and rapidgzip indexes, and the rehearsal inputs.tsv ----
cat > "$T/prep.sh" << 'EOF'
set +e
D=/rh/s3/aws-kraken2-942542972736-us-west-2/aws-kraken2/data/inputpath-rehearse
for n in pe_1 pe_2 se_1; do
  gzip -dc "$D/$n.gz" | python3 -c '
import struct, sys, zlib
out = open(sys.argv[1], "wb")
def block(data):
    c = zlib.compressobj(6, zlib.DEFLATED, -15)
    cd = c.compress(data) + c.flush()
    out.write(b"\x1f\x8b\x08\x04\x00\x00\x00\x00\x00\xff" + struct.pack("<H", 6) + b"BC" + struct.pack("<HH", 2, len(cd) + 25)
              + cd + struct.pack("<II", zlib.crc32(data) & 0xffffffff, len(data)))
while True:
    b = sys.stdin.buffer.read(65280)
    if not b:
        break
    block(b)
block(b"")
' "$D/$n.bgzf" || exit 1
  /opt/rgprep/bin/rapidgzip -d -c --export-index "$D/$n.index" "$D/$n.gz" > /dev/null || exit 1
  [ -s "$D/$n.index" ] || exit 1
done
EOF
"${PM[@]}" run --rm -v "$T:/rh" "$IMG" bash "/rh/prep.sh" || { say "prep (BGZF, index) failed"; exit 1; }
sh256() { shasum -a 256 "$1" | cut -d' ' -f1; }
fqsha() { gzip -dc "$1" | shasum -a 256 | cut -d' ' -f1; }
{ printf 'role\taccession\tmate\ts3_key\tsha256\tkind\tsource_sha256\n'
  for n in pe_1 pe_2 se_1; do
    role=${n%_*}; mate=${n#*_}; acc=SRR062634; [ "$role" = se ] && acc=ERR478965
    fq=$(fqsha "$T/s3/$B/$IK/$n.gz"); gz=$(sh256 "$T/s3/$B/$IK/$n.gz")
    printf '%s\t%s\t%s\t%s\t%s\tgz\t%s\n' "$role" "$acc" "$mate" "$IK/$n.gz" "$gz" "$fq"
    printf '%s\t%s\t%s\ts3://%s/%s\t%s\tbgzf\t%s\n' "$role" "$acc" "$mate" "$B" "$IK/$n.bgzf" "$(sh256 "$T/s3/$B/$IK/$n.bgzf")" "$fq"
    printf '%s\t%s\t%s\t%s\t%s\tindex\t%s\n' "$role" "$acc" "$mate" "$IK/$n.index" "$(sh256 "$T/s3/$B/$IK/$n.index")" "$gz"
  done; } > "$T/inputs.tsv"
python3 scripts/inputpath/inputs.py check "$T/inputs.tsv" --accessions "SRR062634 ERR478965" > /dev/null || { say "the rehearsal inputs.tsv does not check"; exit 1; }
chmod -R a+rwX "$T"
say "stand-ins: viral DB under $DK; inputs $(ls "$T/s3/$B/$IK" | tr '\n' ' ')"

cat > "$T/helpers.sh" << 'EOF'
set +e
ak2_say() { echo "ak2: [$(date -u +%FT%TZ)] $*"; }
ak2_err() { printf '%s\t%s\n' "$1" "$2" >> "$AK2T_OUT/helper-errors.tsv"; ak2_say "ERROR: $2"; }
ak2_phase() { echo "ak2-phase $(date -u +%FT%TZ) $1"; }
ak2_req() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$AK2T_OUT/requests.tsv"; }
ak2_push() { local n=${2:-$(basename "$1")}; mkdir -p "$(dirname "$AK2T_OUT/$n")" && cp "$1" "$AK2T_OUT/$n" && ak2_say "pushed out/$n"; }
ak2_stage() { aws s3 cp --only-show-errors "$1" "$2" && ak2_say "staged $1 -> $2"; }
EOF
cp "$T/helpers.sh" "$T/helpers-dcfail.sh"
echo 'ak2_drop_caches() { ak2_say "ERROR: FATAL: DROP_CACHES FAILED (rehearsal, case D): the next rung would not be cold"; exit 95; }' >> "$T/helpers-dcfail.sh"
echo 'ak2_drop_caches() { ak2_say "drop_caches (rehearsal: nothing)"; }' >> "$T/helpers.sh"
cat "$T/helpers.sh" <(printf '%s\n' "$BODY") > "$T/node.sh"
cat "$T/helpers-dcfail.sh" <(printf '%s\n' "$BODY") > "$T/node-dcfail.sh"

# run_case NAME NODE_SCRIPT [-e K=V ...]: one node; sets RC and L (its log), J/PJ (pushed records).
run_case() {
  local name=$1 node=$2; shift 2
  local ctr=ak2ip-$$-$name out=$T/out-$name
  CTRS+=("$ctr")
  mkdir -p "$out"; chmod 1777 "$out"
  rm -rf "$T/thp"; cp -r "$T/thp0" "$T/thp"; chmod -R a+rwX "$T/thp"
  say "case $name: starting"
  "${PM[@]}" run -d --privileged --name "$ctr" --user ec2-user --tmpfs /home/ec2-user:rw,size=8g,mode=1777 \
    --tmpfs /tmp:rw,size=4g,mode=1777 -v "$T:/rh" -v "$ORACLE_SRC:/upstream-src:ro" -v "$(go env GOMODCACHE):/gomod:ro" \
    -w /home/ec2-user -e HOME=/home/ec2-user -e PATH=/rh/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin \
    -e GOFLAGS=-mod=mod -e GOPROXY=off -e GOTOOLCHAIN=local -e GOMODCACHE=/gomod -e GOCACHE=/rh/gocache \
    -e AK2T_FAKE=/rh/s3 -e AK2T_LOG=/rh/aws-$name.log -e AK2T_ROLE=instance -e AK2T_OUT="/rh/out-$name" \
    -e AK2_RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$SHA" -e AK2_REGION=us-west-2 -e AK2_ACCESSIONS="SRR062634 ERR478965" \
    -e AK2_DATASETS="$(jq -r .env.AK2_DATASETS "$SPEC")" -e AK2_INSTANCE_TYPE="$TYPE" -e AK2_ALLOWED_BUCKETS="$B" \
    -e AK2_REHEARSE_THP_ROOT=/rh/thp -e AK2_REHEARSE_G1_REF="${G1REF:-/rh/g1ref.json}" -e AK2_REHEARSE_GO=1 -e AK2_REHEARSE_WHEELS=/opt/wheels "$@" \
    "$IMG" bash -e -c "$(cat "$node")" > /dev/null || { say "case $name: could not start"; RC=99; return; }
  RC=$("${PM[@]}" wait "$ctr"); RC=${RC:-1}
  "${PM[@]}" logs "$ctr" > "$T/body-$name.log" 2>&1
  L=$T/body-$name.log; J=$out/events.jsonl; PJ=$out/points.jsonl
  say "case $name: body exit $RC; $(grep -c '^inputpath ' "$L") streamed lines; $(cat "$PJ" 2> /dev/null | grep -c .) point records"
}
sl() { grep '^inputpath ' "$L" | sed 's/^inputpath //' | jq -c "select($1)"; }
pl() { jq -c "select($1)" "$J" 2> /dev/null; }
pp() { jq -c "select($1)" "$PJ" 2> /dev/null; }
cnt() { grep -c . || true; }
# The rep-1 list per sample at the spec's parameters (mirrors the body's loops).
P_THREADS=$(sed -n 's/.*; THREADS="\([0-9 ]*\)";.*/\1/p' <<< "$BODY" | head -1); NT=$(wc -w <<< "$P_THREADS" | tr -d ' ')
NPS=$(sed -n 's/.*; PS="\([0-9 ]*\)";.*/\1/p' <<< "$BODY" | head -1 | wc -w | tr -d ' ')
NCK=$(sed -n 's/.*; CHUNKS="\([0-9 ]*\)";.*/\1/p' <<< "$BODY" | head -1 | wc -w | tr -d ' ')
THPC=$(sed -n 's/.*; THP_CONTRAST=\([01]\);.*/\1/p' <<< "$BODY" | head -1); PIPEC=$(sed -n 's/.*; PIPE_CONTRAST=\([01]\);.*/\1/p' <<< "$BODY" | head -1)
NI1=1; [ "$ENGINE" = ours ] && NI1=2
LIST1=$(( NT * (1 + THPC + NPS + 2 + NCK + PIPEC + NI1) ))
WANT_POINTS=$(( 2 * (1 + REPS * LIST1) ))
say "expected: $LIST1 points per sample in rep 1, $WANT_POINTS point records per full run"

# The report's contract: scripts/lib/inputpath_report.py from the tree, else origin/inputpath-report.
REPORT=""
if [ -f scripts/lib/inputpath_report.py ]; then REPORT=scripts/lib/inputpath_report.py
elif git show origin/inputpath-report:scripts/lib/inputpath_report.py > "$T/inputpath_report.py" 2> /dev/null; then REPORT=$T/inputpath_report.py; fi
mockrun() {  # NAME: a results-like run dir from case NAME's pushed out/ and a manifest stand-in
  local r=$T/run-$1
  rm -rf "$r"; mkdir -p "$r/out" && cp -r "$T/out-$1/." "$r/out/"
  jq -n --arg t "$TYPE" --arg c "$(git rev-parse HEAD)" '{gate:"inputpath", run_id:"rehearsal", commit:$c, manifest_finalised_at:"rehearsal",
    instance:{type:$t, ami:"rehearsal (AL2023 container)", az:"rehearsal"}, truffle_price_usd_per_hour:2.55232, billed_seconds:3600,
    cost_usd:2.55232, cost_basis:"rehearsal stand-in", upstream:{pin:"2731b35f7abb26ec926517274f3d87e78d42fd76"}}' > "$r/manifest.json"
  echo "$r"
}
full_checks() {  # NAME: what A and C share
  local n=$1 r ipr_rc ndef
  chk "$n: body exit 0" '[ "$RC" = 0 ]'
  fl=$(grep -m1 'shell flags' "$L" | grep -oE 'flags [^ ]+' | cut -d' ' -f2)
  chk "$n: the body's shell flags ($fl) lack e" '[ -n "$fl" ] && [[ $fl != *e* ]]'
  chk "$n: 1 tool line, rapidgzip 0.14.5 (isal: $(pl '.kind == "tool"' | jq -r .isal))" '[ "$(pl '\''.kind == "tool" and .version == "0.14.5"'\'' | cnt)" = 1 ]'
  chk "$n: 9 input lines, each fastq_sha256 = the read set's SOURCE" \
    '[ "$(pl '\''.kind == "input"'\'' | cnt)" = 9 ] && [ "$(pl '\''.kind == "input"'\'' | jq -r '\''"\(.role)_\(.mate) \(.fastq_sha256)"'\'' | sort -u | tr "\n" " ")" = "pe_1 $WANT_PE1 pe_2 $WANT_PE2 se_1 $WANT_SE1 " ]'
  chk "$n: 3 db lines" '[ "$(pl '\''.kind == "db"'\'' | cnt)" = 3 ]'
  chk "$n: the point lines streamed = the pushed points.jsonl" '[ "$(sl '\''.kind == "point"'\'' | jq -c '\''del(.kind)'\'' | sort)" = "$(sort "$PJ")" ]'
  chk "$n: $WANT_POINTS point records ($(grep -c . "$PJ"))" '[ "$(grep -c . "$PJ")" = "$WANT_POINTS" ]'
  chk "$n: every point has schema inputpath-point/1 and a unique point_id" \
    '[ "$(pp '\''.schema != "inputpath-point/1"'\'' | cnt)" = 0 ] && [ "$(jq -r .point_id "$PJ" | sort | uniq -d | cnt)" = 0 ]'
  chk "$n: every ok I2-I4 point has identity ok, rg_exit 0, gz = rg sha256" \
    '[ "$(pp '\''.status == "ok" and (.arm == "I2" or .arm == "I3" or .arm == "I4") and (.identity.ok != true or .identity.rg_exit != 0 or .identity.gz_sha256 != .identity.rg_sha256)'\'' | cnt)" = 0 ]'
  chk "$n: 6 select lines, each with a best p" '[ "$(pl '\''.kind == "select" and .best_p != null'\'' | cnt)" = 6 ]'
  local miss=0 hdr=0 csv
  for csv in $(pp '.pidstat_csv != null' | jq -r .pidstat_csv); do
    [ -s "$T/out-$n/${csv#out/}" ] || miss=$((miss + 1))
    head -1 "$T/out-$n/${csv#out/}" 2> /dev/null | grep -q '^t_s,tgid,tid,command,role,cpu_pct' || hdr=$((hdr + 1))
  done
  chk "$n: every run point's pidstat CSV pushed ($(pp '.pidstat_csv != null' | cnt) points; $miss missing, $hdr without the report's header)" \
    '[ "$miss" = 0 ] && [ "$hdr" = 0 ] && [ "$(pp '\''.pidstat_csv != null'\'' | cnt)" -gt 0 ]'
  chk "$n: some pidstat CSV has kraken2: engine rows" 'grep -q -h ",kraken2:" "$T/out-$n"/pidstat/*.csv 2> /dev/null'
  chk "$n: the pe I1 points' CSVs have gzip-role rows (upstream's wrapper gzip -dc, or ours' pipe)" \
    'grep -q -h ",gzip,gzip," "$T/out-$n"/pidstat/r1-pe-I1-*.csv 2> /dev/null'
  chk "$n: THP: never points from ip-db; always points from $([ "$ENGINE" = upstream ] && echo ip-db-huge || echo ip-db)" \
    '[ "$(pp '\''.status == "ok" and .thp == "never" and (.harness.db_dir | endswith("/ip-db") | not)'\'' | cnt)" = 0 ] && [ "$(pp '\''.status == "ok" and .thp == "always" and (.harness.db_dir | endswith("'"$([ "$ENGINE" = upstream ] && echo /ip-db-huge || echo /ip-db)"'") | not)'\'' | cnt)" = 0 ]'
  [ "$THPC" = 1 ] && chk "$n: THP contrast: $((2 * REPS * NT)) I0 points at thp never" '[ "$(pp '\''.arm == "I0" and .thp == "never" and .status == "ok"'\'' | cnt)" = $((2 * REPS * NT)) ]'
  chk "$n: pipe_bytes 1048576 on the rapidgzip points, 65536 on the default-pipe ones" \
    '[ "$(pp '\''.status == "ok" and .p != null and ((.harness.pipe_requested == "1048576" and .pipe_bytes != 1048576) or (.harness.pipe_requested == "default" and .pipe_bytes != 65536))'\'' | cnt)" = 0 ] && [ "$(pp '\''.harness.pipe_requested == "default" and .pipe_bytes == 65536'\'' | cnt)" -gt 0 ]'
  chk "$n: summary: THP restored" '[ "$(pl '\''.kind == "summary"'\'' | jq -r .thp_restored)" = true ]'
  r=$(mockrun "$n")
  python3 scripts/inputpath/tables.py --run "$r" > "$T/tables-$n.log" 2>&1
  chk "$n: tables.py: one row per point ($(($(wc -l < "$r/tables/inputpath.tsv") - 1)))" '[ "$(($(wc -l < "$r/tables/inputpath.tsv") - 1))" = "$(grep -c . "$PJ")" ]'
  if [ -n "$REPORT" ]; then
    python3 "$REPORT" "$r" "$r/report.md" > "$T/report-$n.out" 2> "$T/report-$n.err"; ipr_rc=$?
    ndef=$(grep -c 'DEFECT (' "$r/report.md" 2> /dev/null); ndef=${ndef:-0}
    chk "$n: the report's contract: $REPORT on the mock run dir exits $ipr_rc, $ndef DEFECT lines (want 0, 0)" '[ "$ipr_rc" = 0 ] && [ "$ndef" = 0 ]'
    grep -m5 'DEFECT' "$r/report.md" 2> /dev/null | cut -c1-240
    grep -m12 -E '^- \*\*R[1-4]|^\| I[0-4] ' "$r/report.md" 2> /dev/null | cut -c1-200
  else
    say "note: no scripts/lib/inputpath_report.py in the tree or on origin/inputpath-report: the report contract is not checked"
  fi
  column -t -s$'\t' "$r/tables/inputpath.tsv" 2> /dev/null | cut -c1-260 | head -14
}

for c in $CASES; do
  case $c in
  A)
    run_case A "$T/node.sh" -e AK2_REHEARSE_INPUTS_TSV=/rh/inputs.tsv -e AK2_REHEARSE_DEADLINE_S=100000
    full_checks A
    chk "A: the tool line's wheel is lever.sh's cp39 aarch64 pin" '[ "$(pl '\''.kind == "tool"'\'' | jq -r .wheel_sha256)" = 499dfb8e24bf86607e87e8ec4f1c1797ea258078ddd550ce010b2fb1c17eafee ]'
    chk "A: ISA-L: the pinned wheel is isal false (static none, rapidgzip -v 0 s of ISA-L), as #95 found; every rapidgzip point records isal false" \
      '[ "$(pl '\''.kind == "isal" and .build_label == "rapidgzip" and .isal == false and .static == "none" and .runtime_isal_s == 0'\'' | cnt)" = 1 ] && [ "$(pp '\''.p != null and .rapidgzip.isal != false'\'' | cnt)" = 0 ]'
    chk "A: the g1-reference line cites the reference file with its sha256, and every point record carries it" \
      '[ "$(pl '\''.kind == "g1-reference" and .references.pe.file == "/rh/g1ref.json" and (.references.se.sha256 | length) == 64'\'' | cnt)" = 1 ] && [ "$(pp '\''.harness.g1_reference.file != "/rh/g1ref.json"'\'' | cnt)" = 0 ]'
    chk "A: every identity line ok ($(pl '.kind == "identity"' | cnt))" '[ "$(pl '\''.kind == "identity" and .status != "ok"'\'' | cnt)" = 0 ] && [ "$(pl '\''.kind == "identity"'\'' | cnt)" -ge 24 ]'
    chk "A: no point skipped but the 2 warm-ups, 0 defects" '[ "$(pp '\''.status != "ok"'\'' | jq -r .harness.status_detail | sort | tr "\n" " ")" = "reference reference " ]'
    ;;
  C)
    run_case C "$T/node.sh" -e AK2_REHEARSE_INPUTS_TSV=/rh/inputs.tsv -e AK2_REHEARSE_DEADLINE_S=100000 -e AK2_REHEARSE_RAPIDGZIP=/rh/bin/rapidgzip-crashy
    full_checks C
    cat "$T/crash/log" 2> /dev/null | sed 's/^/  induced | /'
    chk "C: pe_2.gz -P 4: two identity lines (attempts 1, 2), both crash, decoder exit 139" \
      '[ "$(pl '\''.kind == "identity" and .status == "crash" and (.file | endswith("/pe_2.gz")) and (.args | startswith("-P 4 ")) and .decoder_exit == 139'\'' | jq -r .attempt | tr "\n" " ")" = "1 2 " ]'
    TA=$(pl '.kind == "identity" and (.file | endswith("/pe_1.gz")) and (.args | startswith("-P 2 --chunk-size 4096"))' | jq -r '"\(.attempt):\(.status)"' | tr "\n" " ")
    TP=$(pp '.input.role == "paired" and .arm == "I2" and .p == 2 and .chunk_mib == 4 and .harness.pipe_requested == "1048576" and .harness.decomp == "rapidgzip" and .status == "ok" and (.identity.mates[0].attempts | length) == 2' | cnt)
    chk "C: pe_1.gz -P 2 (a transient): identity attempts '$TA' (want 1:crash 2:ok), and its REPS x threads pe I2 p=2 points ok ($TP)" \
      '[ "$TA" = "1:crash 2:ok " ] && [ "$TP" = $((REPS * NT)) ]'
    chk "C: exactly the $((2 * REPS * NT / 2)) pe I2 p=4 chunk-4096 points skipped-identity" \
      '[ "$(pp '\''.harness.status_detail == "skipped-identity"'\'' | cnt)" = $((REPS * NT)) ] && [ "$(pp '\''.harness.status_detail == "skipped-identity" and (.input.role != "paired" or .arm != "I2" or .p != 4)'\'' | cnt)" = 0 ]'
    chk "C: exactly one decode-crash point: rep 1, se, I2, p 8, chunk 4, threads 48, rg1 exit 139, status skipped" \
      '[ "$(pp '\''.harness.status_detail == "decode-crash"'\'' | jq -r '\''"\(.rep) \(.input.role) \(.arm) \(.p) \(.chunk_mib) \(.threads) \(.harness.time.rg1.exit) \(.status)"'\'')" = "1 single I2 8 4 48 139 skipped" ]'
    chk "C: 0 defects; every other point ok or a warm-up" '[ "$(pp '\''.status == "defect"'\'' | cnt)" = 0 ] && [ "$(pp '\''.status != "ok"'\'' | cnt)" = $((2 + REPS * NT + 1)) ]'
    ;;
  B)
    run_case B "$T/node.sh" -e AK2_REHEARSE_INPUTS_TSV=/rh/no-such-inputs.tsv -e AK2_REHEARSE_DEADLINE_S=100000
    chk "B: exit 1" '[ "$RC" = 1 ]'
    chk "B: a fatal line naming the inputs file" '[ "$(pl '\''.kind == "fatal" and (.message | test("no-such-inputs.tsv"))'\'' | cnt)" = 1 ]'
    chk "B: no engine, db or point line (it failed before any build or stage)" '[ "$(pl '\''.kind == "engine" or .kind == "db" or .kind == "point"'\'' | cnt)" = 0 ]'
    ;;
  D)
    run_case D "$T/node-dcfail.sh" -e AK2_REHEARSE_INPUTS_TSV=/rh/inputs.tsv -e AK2_REHEARSE_DEADLINE_S=100000
    chk "D: exit 95 (drop_caches failed)" '[ "$RC" = 95 ]'
    chk "D: no point and no drop-caches line" '[ "$(pl '\''.kind == "point" or .kind == "drop-caches"'\'' | cnt)" = 0 ] && ! grep -q "^inputpath .*\"kind\":\"point\"" "$L"'
    ;;
  F)
    G1REF=/rh/g1ref-bad.json run_case F "$T/node.sh" -e AK2_REHEARSE_INPUTS_TSV=/rh/inputs.tsv -e AK2_REHEARSE_DEADLINE_S=100000
    chk "F: a reference that differs from upstream's output stops the run: exit 1" '[ "$RC" = 1 ]'
    chk "F: one point record, the first warm-up, status defect (law1-g1-mismatch), citing the reference file" \
      '[ "$(grep -c . "$PJ")" = 1 ] && [ "$(pp '\''.harness.warmup and .status == "defect" and .harness.status_detail == "law1-g1-mismatch" and .harness.g1_reference.file == "/rh/g1ref-bad.json"'\'' | cnt)" = 1 ]'
    chk "F: a defect line and a fatal line naming Law 1" '[ "$(pl '\''.kind == "defect" and .status_detail == "law1-g1-mismatch"'\'' | cnt)" = 1 ] && [ "$(pl '\''.kind == "fatal" and (.message | test("Law 1"))'\'' | cnt)" = 1 ]'
    ;;
  E)
    run_case E "$T/node.sh" -e AK2_REHEARSE_INPUTS_TSV=/rh/inputs.tsv -e AK2_REHEARSE_DEADLINE_S=60
    chk "E: body exit 0" '[ "$RC" = 0 ]'
    first=$(jq -r '.harness.status_detail' "$PJ" | grep -n '^skipped-deadline$' | head -1 | cut -d: -f1)
    chk "E: skipped-deadline from point ${first:-none} of $(grep -c . "$PJ"), and every point after it" \
      '[ -n "$first" ] && [ "$(tail -n +"$first" "$PJ" | jq -r .harness.status_detail | sort -u)" = skipped-deadline ]'
    chk "E: the record is complete ($WANT_POINTS point records)" '[ "$(grep -c . "$PJ")" = "$WANT_POINTS" ]'
    ;;
  esac
  if [ "$RC" != 0 ] && [ "$c" != B ] && [ "$c" != D ]; then tail -30 "$L" | sed "s/^/  body $c | /"; fi
done
if [ "$OK" = 0 ]; then say "ok"; else say "FAILED (REHEARSE_KEEP=1 keeps the scratch dir)"; fi
exit "$OK"
