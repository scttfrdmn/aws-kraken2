#!/usr/bin/env bash
# make rehearse SPEC=runs/g3-u1-<type>.json (docs/cohort.md, "Rehearsal"): the U1 spec's own body
# (its command[2], unmodified; scripts/g3/u1.body.sh) run locally as one instance under the
# environment the harness gives a run, before any launch.
# Stand-ins: the ak2_* helpers; sudo (dnf, sysctl, chmod: nothing), git clone (a git archive of
# the committed tree), the GNU tools the body uses (nproc, sha256sum, stat -c, pigz as gzip);
# the tmpfs mounts as plain directories (upstream-cohort.sh's AK2_REHEARSE_RAMDB_ROOT, no sudo);
# S3 as one directory through the stub aws (scripts/lib/rehearse_aws.py: s3 cp, s3api), with
# Standard-8 standing in for RODA v205 (its hash.k2d given a real 128 MiB-part multipart ETag, so
# the body's ETag check runs for real); REHEARSE_SAMPLES (3) real local read sets as the cohort,
# with cohort 10 -> 2 samples and cohort 100 -> 3 (AK2_REHEARSE_C10 / _COHORT).
# What passes, on observed output:
#   - the body exits 0, and every sample line's exit is 0;
#   - streaming: the body's output (its run log on AWS) carries one "u1-sample" line per sample run,
#     one "u1-rung" line per rung and one "u1-prep" line per fq preparation, as many as the plan
#     makes (18 + 4 + 5 x C10 + 6 x COHORT sample runs; 9 + 5 + 6 rungs; 7 + C10 + COHORT
#     preparations), and the same lines are in the pushed out/u1.jsonl;
#   - requests: the cohort GETs the stub saw (s3 cp from the cohort prefix) are 2 x COHORT, and
#     the body's ak2_req GetObject on the results bucket equals the 8 MiB parts of those files;
#     its HeadObject count on the results bucket equals the head-object calls the stub saw;
#   - Law 1 for the ETag cross-check's input: every C-c100-fq-t96 sample has an output and report
#     ETag, each equal to scripts/lib/ak2etag.py on upstream's own output for that sample, run here;
#   - scripts/lib/u1_tables.py runs on the record and exits 0.
# Usage: scripts/lib/u_rehearse.sh runs/g3-u1-<type>.json
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
. scripts/pin.env
. scripts/paths.sh
echo "rehearse: shell flags $-"
SPEC=${1:?SPEC}
[ -f "$SPEC" ] || { echo "rehearse: no $SPEC" >&2; exit 2; }
git diff --quiet HEAD -- "$SPEC" scripts cmd internal || { echo "rehearse: commit first (the rehearsal runs the committed tree)" >&2; exit 2; }
SHA=$(git rev-parse --short=7 HEAD)
DB="$K2_DB_ROOT/k2_standard_08_GB_20260626"
[ -s "$DB/hash.k2d" ] || { echo "rehearse: need Standard-8 at $DB" >&2; exit 1; }
K2DIR=$(scripts/oracle-build.sh 2>/dev/null) || { echo "rehearse: upstream build failed" >&2; exit 1; }
mkdir -p results/rehearse || exit 1
LOGF="results/rehearse/$(basename "$SPEC" .json)-$(date -u +%Y%m%dT%H%M%SZ)-$SHA.log"
exec > >(tee "$LOGF") 2>&1
echo "rehearse: record $LOGF"
REAL_GIT=$(command -v git); REAL_TAR=$(command -v tar)
T=$(mktemp -d "${TMPDIR:-/tmp}/ak2-urehearse.XXXXXX")
cleanup() { [ "${REHEARSE_KEEP:-0}" = 1 ] || rm -rf "$T"; }
trap cleanup EXIT
echo "rehearse: $SPEC at $SHA, work $T"

SAMPLE_SRC=(SRR062634 ERR478965 SRR28305653)
NS=${REHEARSE_SAMPLES:-3}; C10=2
NAMES=(); PAIRS=()
DATASETS=$(jq -r '.env.AK2_DATASETS' "$SPEC")
set -- $DATASETS
U=${1#s3://}; RB=${U%%/*}; HK=${U#*/}; RP=${HK%/*}
U=${4#s3://}; B=${U%%/*}; CK=${U#*/}; CK=${CK%/}
FAKE="$T/s3"; mkdir -p "$FAKE/$B/$CK" "$FAKE/$RB/$RP"
for ((i = 0; i < NS; i++)); do
  s=${SAMPLE_SRC[$i]}
  for m in 1 2; do cp "$K2_READS/${s}_200000_$m.fq.gz" "$FAKE/$B/$CK/${s}_$m.fastq.gz" || exit 1; done
  NAMES+=("$s"); PAIRS+=(200000)
done
cp "$DB/opts.k2d" "$DB/taxo.k2d" "$FAKE/$RB/$RP/" || exit 1
# A real multipart ETag for the stand-in hash.k2d (128 MiB parts, as RODA's).
HASH_ETAG=$(python3 - "$DB/hash.k2d" <<'EOF'
import hashlib, sys
ds, p = [], 128 << 20
with open(sys.argv[1], "rb") as f:
    while True:
        b = f.read(p)
        if not b:
            break
        ds.append(hashlib.md5(b).digest())
print(f"{hashlib.md5(b''.join(ds)).hexdigest()}-{len(ds)}")
EOF
)
echo "rehearse: stand-in hash.k2d ETag $HASH_ETAG"

BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
# dnf, sysctl, chmod and the like: nothing (the rehearsal host is not the instance).
exit 0
EOF
cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "clone -q") mkdir -p "\${@: -1}" && "$REAL_GIT" -C "$ROOT" archive "$SHA" | "$REAL_TAR" -x -C "\${@: -1}" ;;
  *) case " \$* " in *" checkout "*) exit 0 ;; *" rev-parse HEAD"*) echo "$SHA" ;; *) exec "$REAL_GIT" "\$@" ;; esac ;;
esac
EOF
printf '#!/usr/bin/env bash\necho 8\n' > "$BIN/nproc"
printf '#!/usr/bin/env bash\nexec shasum -a 256 "$@"\n' > "$BIN/sha256sum"
cat > "$BIN/stat" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -c%s ]; then wc -c < "$2" | tr -d ' '; else exec /usr/bin/stat "$@"; fi
EOF
cat > "$BIN/pigz" <<'EOF'
#!/usr/bin/env bash
# pigz -dc -p N FILE -> gzip -dc FILE
f=${@: -1}; exec gzip -dc "$f"
EOF
printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$ROOT/scripts/lib/rehearse_aws.py" > "$BIN/aws"
chmod +x "$BIN"/*
# The upstream build: the rehearsal's own (scripts/oracle-build.sh caches by pin; the archive's
# copy finds the same cache through K2_SHARED_ROOT).
cat > "$T/helpers.sh" <<'EOF'
ak2_say() { echo "ak2: [$(date -u +%FT%TZ)] $*"; }
ak2_phase() { echo "ak2-phase $(date -u +%FT%TZ) $1"; }
ak2_req() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$AK2T_OUT/requests.tsv"; }
ak2_push() { mkdir -p "$AK2T_OUT/$(dirname "${2:-$(basename "$1")}")" && cp "$1" "$AK2T_OUT/${2:-$(basename "$1")}"; }
EOF
cat "$T/helpers.sh" <(jq -r '.command[2]' "$SPEC") > "$T/node.sh"
mkdir -p "$T/out" "$T/home"
env -i PATH="$BIN:$PATH" HOME="$T/home" TMPDIR="${TMPDIR:-/tmp}" K2_SHARED_ROOT="$K2_SHARED_ROOT" K2_DB_ROOT="$K2_DB_ROOT" \
  AK2T_FAKE="$FAKE" AK2T_OUT="$T/out" AK2T_LOG="$T/aws.log" AK2T_ROLE=instance \
  AK2T_HASH_BUCKET="$RB" AK2T_HASH_KEY="$HK" AK2T_HASH_FILE="$DB/hash.k2d" AK2T_HASH_ETAG="$HASH_ETAG" \
  AK2_REGION=us-west-2 AK2_DATASETS="$DATASETS" AK2_RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$SHA" \
  AK2_REHEARSE_COHORT="$NS" AK2_REHEARSE_C10="$C10" AK2_REHEARSE_SAMPLES="${NAMES[*]}" AK2_REHEARSE_WEIGHTS="${PAIRS[*]}" \
  AK2_REHEARSE_RAMDB_ROOT="$T/ramdb" \
  bash -c "$(cat "$T/node.sh")" > "$T/body.log" 2>&1
RC=$?
echo "rehearse: body exit $RC"
[ "$RC" = 0 ] || { tail -25 "$T/body.log" | sed 's/^/  body | /'; }

J="$T/out/u1.jsonl"
WS=$(( 18 + 4 + 5 * C10 + 6 * NS )); WR=20; WP=$(( 7 + C10 + NS ))
ss=$(grep -c '^u1-sample ' "$T/body.log"); sr=$(grep -c '^u1-rung ' "$T/body.log")
js=$(grep -c '"kind":"sample"' "$J" 2>/dev/null); jr=$(grep -c '"kind":"rung"' "$J" 2>/dev/null)
bad=$(grep '"kind":"sample"' "$J" 2>/dev/null | grep -vc '"exit":0,')
sp=$(grep -c '^u1-prep ' "$T/body.log"); jp=$(grep -c '"kind":"prep"' "$J" 2>/dev/null)
echo "rehearse: streamed $sp fq preparation lines; u1.jsonl has $jp; want $WP"
[ "$sp" = "$WP" ] && [ "$jp" = "$WP" ] || { echo "rehearse: fq preparation lines wrong" >&2; RC=1; }
echo "rehearse: streamed $ss sample and $sr rung lines; u1.jsonl has $js and $jr; want $WS and $WR; $bad sample runs exited non-zero"
[ "$ss" = "$WS" ] && [ "$js" = "$WS" ] && [ "$sr" = "$WR" ] && [ "$jr" = "$WR" ] && [ "$bad" = 0 ] || { echo "rehearse: streaming or sample counts wrong" >&2; RC=1; }
# Requests, against what the stub saw.
gets=$(grep -c "^s3 cp .*s3://$B/$CK/" "$T/aws.log"); heads=$(grep -E "^s3api head-object .*--bucket $B( |$)" "$T/aws.log" | grep -c .)
parts=0
for ((i = 0; i < NS; i++)); do for m in 1 2; do
  sz=$(wc -c < "$FAKE/$B/$CK/${NAMES[$i]}_$m.fastq.gz" | tr -d ' '); parts=$(( parts + (sz + 8388607) / 8388608 )); done; done
rg=$(awk -F'\t' -v b="$B" '$1 == "GetObject" && $3 == b {s += $2} END {print s+0}' "$T/out/requests.tsv")
rh=$(awk -F'\t' -v b="$B" '$1 == "HeadObject" && $3 == b {s += $2} END {print s+0}' "$T/out/requests.tsv")
echo "rehearse: stub saw $gets cohort GETs (want $((2 * NS))) and $heads head-objects on $B; ak2_req GetObject $rg (want $parts parts), HeadObject $rh"
[ "$gets" = $((2 * NS)) ] && [ "$rg" = "$parts" ] && [ "$rh" = "$heads" ] || { echo "rehearse: request counts disagree" >&2; RC=1; }
# The ETags the cross-check will compare, against upstream run here on each sample.
ok=0
for s in "${NAMES[@]}"; do
  "$K2DIR/kraken2" --db "$DB" --memory-mapping --paired --threads 4 --output "$T/$s.output" --report "$T/$s.report" \
    "$FAKE/$B/$CK/${s}_1.fastq.gz" "$FAKE/$B/$CK/${s}_2.fastq.gz" > /dev/null 2>&1 || { echo "rehearse: upstream failed on $s" >&2; RC=1; }
  wo=$(python3 scripts/lib/ak2etag.py output "$T/$s.output" | cut -f1); wr=$(python3 scripts/lib/ak2etag.py report "$T/$s.report" | cut -f1)
  go=$(jq -r --arg s "$s" 'select(.kind == "sample" and .rung == "C-c100-fq-t96" and .sample == $s) | .output_etag' "$J")
  gr=$(jq -r --arg s "$s" 'select(.kind == "sample" and .rung == "C-c100-fq-t96" and .sample == $s) | .report_etag' "$J")
  if [ "$go" = "$wo" ] && [ "$gr" = "$wr" ]; then ok=$((ok + 1)); else echo "rehearse: $s ETags $go $gr, want $wo $wr" >&2; RC=1; fi
  printf 'aws-kraken2/g3/fake/out/c3/0-%s/output\tv\t1\t%s\naws-kraken2/g3/fake/out/c3/0-%s/report\tv\t1\t%s\n' "$s" "$wo" "$s" "$wr" >> "$T/fake.tsv"
done
echo "rehearse: $ok of $NS samples' C-c100-fq-t96 ETags equal upstream's outputs here"
# u1_tables' cross-check against a stand-in engine cohort carrying the ETags of upstream's outputs
# here: it must pass with every sample's output and report compared, and must fail when one ETag
# differs and when a sample's file is missing.
mkdir -p "$T/run/out" "$T/fake-e2/tables" && cp "$J" "$T/run/out/"
echo '{"spec": "runs/g3-e2-rehearse.json", "cohort_id": "fake-e2"}' > "$T/fake-e2/cohort.json"; : > "$T/fake-e2/tables/point.tsv"
cp "$T/fake.tsv" "$T/fake-e2/outputs.tsv"
python3 scripts/lib/u1_tables.py "$T/run" || { echo "rehearse: u1_tables failed on matching ETags" >&2; RC=1; }
n=$(awk 'END{print NR - 1}' "$T/run/tables/law1-crosscheck.tsv")
[ "$n" = $((2 * NS)) ] || { echo "rehearse: u1_tables compared $n files, want $((2 * NS))" >&2; RC=1; }
awk 'NR == 1 {sub(/"/, "\"x")} {print}' "$T/fake.tsv" > "$T/fake-e2/outputs.tsv"
python3 scripts/lib/u1_tables.py "$T/run" > /dev/null 2>&1 && { echo "rehearse: u1_tables passed a differing ETag" >&2; RC=1; }
sed '$d' "$T/fake.tsv" > "$T/fake-e2/outputs.tsv"
python3 scripts/lib/u1_tables.py "$T/run" > /dev/null 2>&1 && { echo "rehearse: u1_tables passed a missing file" >&2; RC=1; }
echo "rehearse: u1_tables cross-check: $n files compared; a differing ETag and a missing file both fail"
[ "$RC" = 0 ] && echo "rehearse: ok" || echo "rehearse: FAILED (logs: REHEARSE_KEEP=1 keeps $T)" >&2
exit "$RC"
