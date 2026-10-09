#!/usr/bin/env bash
# make rehearse SPEC=runs/g3-u2-<type>.json (docs/cohort.md, "Rehearsal"): the U2 spec's own body
# (its command[2], unmodified; scripts/g3/u2.body.sh) run locally as one instance, before any
# launch. Stand-ins as scripts/lib/u_rehearse.sh's, plus: the instance-store NVMe as a plain
# directory (g2i_nvme's AK2_REHEARSE_NVME); SRR062634's 200k-pair set standing in for its 8M-pair
# prefix (AK2_REHEARSE_STEM8M) through a plan derived from scripts/g2/u2.plan by that one
# substitution (AK2_REHEARSE_PLAN: the same lines, reps and thread counts); a 200k-pair set
# standing in for the cohort's sample 1 in the cohort prefix; ak2_drop_caches a no-op (the
# rehearsal host cannot drop caches: its "cold" rungs are not cold).
# What passes, on observed output:
#   - the body exits 0, and no rung failed;
#   - streaming: one "g2: L<n>-run-..." line in the body's output (the run log on AWS) per rung of
#     the plan, and the pushed out/g2-u2/runs.jsonl has the same rungs;
#   - requests: the body's ak2_req GetObject and HeadObject on the results bucket equal the
#     objects the stub served (one GET and one head-object per staged reads or cohort file) and
#     their 8 MiB parts;
#   - g2summary's summary.tsv is pushed.
# Usage: scripts/lib/u2_rehearse.sh runs/g3-u2-<type>.json
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

STEM=SRR062634_200000
DATASETS=$(jq -r '.env.AK2_DATASETS' "$SPEC")
set -- $DATASETS
U=${1#s3://}; RB=${U%%/*}; HK=${U#*/}; RP=${HK%/*}
U=${4#s3://}; B=${U%%/*}; CK=${U#*/}; CK=${CK%/}
FAKE="$T/s3"; mkdir -p "$FAKE/$B/$CK" "$FAKE/$RB/$RP"
mkdir -p "$FAKE/$B/aws-kraken2/data/reads"
for f in "$STEM.SOURCE" "${STEM}_1.fq" "${STEM}_2.fq" "${STEM}_1.fq.gz" "${STEM}_2.fq.gz"; do
  cp "$K2_READS/$f" "$FAKE/$B/aws-kraken2/data/reads/$f" || exit 1
done
for m in 1 2; do cp "$K2_READS/ERR478965_200000_$m.fq.gz" "$FAKE/$B/$CK/SRR5935740_$m.fastq.gz" || exit 1; done
sed "s/SRR062634_8000000/$STEM/g" scripts/g2/u2.plan > "$T/u2-rehearse.plan"
NR=$(awk '$1 == "run" {n = 0; for (i = 6; i <= NF; i++) n++; t += $5 * n} END {print t}' "$T/u2-rehearse.plan")
echo "rehearse: plan $T/u2-rehearse.plan: $NR rungs"
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
printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$ROOT/scripts/lib/rehearse_aws.py" > "$BIN/aws"
chmod +x "$BIN"/*
# The upstream build: the rehearsal's own (scripts/oracle-build.sh caches by pin; the archive's
# copy finds the same cache through K2_SHARED_ROOT).
cat > "$T/helpers.sh" <<'EOF'
ak2_say() { echo "ak2: [$(date -u +%FT%TZ)] $*"; }
ak2_phase() { echo "ak2-phase $(date -u +%FT%TZ) $1"; }
ak2_req() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$AK2T_OUT/requests.tsv"; }
ak2_push() { mkdir -p "$AK2T_OUT/$(dirname "${2:-$(basename "$1")}")" && cp "$1" "$AK2T_OUT/${2:-$(basename "$1")}"; }
ak2_stage() {  # SRC DST from the fake bucket
  local src=${1#s3://}; mkdir -p "$(dirname "$2")"
  cp "$AK2T_FAKE/$src" "$2" && echo "ak2: staged $1 -> $2" && printf '%s\n' "s3 cp s3://$src $2 (ak2_stage)" >> "$AK2T_LOG"
}
ak2_drop_caches() { echo "ak2: drop_caches (rehearsal: nothing; this rung is not cold)"; }
EOF
cat "$T/helpers.sh" <(jq -r '.command[2]' "$SPEC") > "$T/node.sh"
mkdir -p "$T/out" "$T/home"
env -i PATH="$BIN:$PATH" HOME="$T/home" TMPDIR="${TMPDIR:-/tmp}" K2_SHARED_ROOT="$K2_SHARED_ROOT" K2_DB_ROOT="$K2_DB_ROOT" \
  AK2T_FAKE="$FAKE" AK2T_OUT="$T/out" AK2T_LOG="$T/aws.log" AK2T_ROLE=instance \
  AK2T_HASH_BUCKET="$RB" AK2T_HASH_KEY="$HK" AK2T_HASH_FILE="$DB/hash.k2d" AK2T_HASH_ETAG="$HASH_ETAG" \
  AK2_REGION=us-west-2 AK2_DATASETS="$DATASETS" AK2_RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$SHA" \
  AK2_REHEARSE_NVME="$T/nvme" AK2_REHEARSE_PLAN="$T/u2-rehearse.plan" AK2_REHEARSE_STEM8M="$STEM" \
  bash -c "$(cat "$T/node.sh")" > "$T/body.log" 2>&1
RC=$?
echo "rehearse: body exit $RC"
[ "$RC" = 0 ] || { tail -25 "$T/body.log" | sed 's/^/  body | /'; }

J="$T/out/g2-u2/runs.jsonl"
sr=$(grep -cE '^g2: L[0-9]+-run-' "$T/body.log"); jr=$(grep -c . "$J" 2>/dev/null)
fails=$(grep -E '^g2: [0-9]+ rungs' "$T/body.log" | tail -1)
echo "rehearse: streamed $sr rung lines; runs.jsonl has $jr; the plan has $NR; $fails"
[ "$sr" = "$NR" ] && [ "$jr" = "$NR" ] && [[ "$fails" == *" 0 failures"* ]] || { echo "rehearse: streaming or rung counts wrong" >&2; RC=1; }
gets=$(grep -cE "^s3 cp s3://$B/" "$T/aws.log"); heads=$(grep -E "^s3api head-object .*--bucket $B( |$)" "$T/aws.log" | grep -c .)
parts=0
for f in "$FAKE/$B/aws-kraken2/data/reads/"* "$FAKE/$B/$CK/"*; do
  sz=$(wc -c < "$f" | tr -d ' '); parts=$(( parts + (sz < 8388608 ? 1 : (sz + 8388607) / 8388608) )); done
rg=$(awk -F'\t' -v b="$B" '$1 == "GetObject" && $3 == b {s += $2} END {print s+0}' "$T/out/requests.tsv")
rh=$(awk -F'\t' -v b="$B" '$1 == "HeadObject" && $3 == b {s += $2} END {print s+0}' "$T/out/requests.tsv")
echo "rehearse: stub served $gets objects and $heads head-objects on $B; ak2_req GetObject $rg (want $parts parts), HeadObject $rh"
[ "$gets" = 7 ] && [ "$rg" = "$parts" ] && [ "$rh" = "$heads" ] || { echo "rehearse: request counts disagree" >&2; RC=1; }
[ -s "$T/out/g2-u2/summary.tsv" ] || { echo "rehearse: no summary.tsv pushed" >&2; RC=1; }
[ "$RC" = 0 ] && echo "rehearse: ok" || echo "rehearse: FAILED (logs: REHEARSE_KEEP=1 keeps $T)" >&2
exit "$RC"
