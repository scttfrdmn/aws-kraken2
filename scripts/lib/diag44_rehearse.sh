#!/usr/bin/env bash
# make rehearse SPEC=runs/g3-diag44-<type>.json: the #44 diagnostic spec's own body (its
# command[2], unmodified; scripts/g3/diag44.body.sh) run locally as one instance, before launch.
# Stand-ins as scripts/lib/u2_rehearse.sh's (harness helpers, sudo, git archive of the committed
# tree, GNU tools, the stub aws over a fake bucket, Standard-8 as RODA v205 with a real 128 MiB-part
# ETag, a plain directory as the NVMe, ak2_drop_caches a no-op), with two 200k-pair read sets
# standing in for SRR5935755 and SRR5935807, 4 threads, and AK2_REHEARSE_TAMPER altering one of
# our output lines on SRR5935755 so that there is a difference to diagnose.
# What passes, on observed output:
#   - the body exits 0, and one "d44-summary" line streams per sample;
#   - SRR5935807 (untampered): 0 differing records and no diag.jsonl;
#   - SRR5935755 (tampered): 1 differing record; diff.tsv, sel_{1,2}.fq (one pair each) and
#     diag.jsonl pushed; diag.jsonl's read has scanner_equal on both mates, no lookup differences,
#     its upstream-events replay equal to upstream's line, and diverging_stage "reading or
#     pipeline" (the tamper is after classification), which shows each stage's check ran;
#   - requests: ak2_req GetObject and HeadObject on the results bucket equal what the stub served.
# Usage: scripts/lib/diag44_rehearse.sh runs/g3-diag44-<type>.json
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
T=$(mktemp -d "${TMPDIR:-/tmp}/ak2-urehearse.XXXXXX"); T=$(cd "$T" && pwd)  # one spelling: the git stub matches paths under it
cleanup() { [ "${REHEARSE_KEEP:-0}" = 1 ] || rm -rf "$T"; }
trap cleanup EXIT
echo "rehearse: $SPEC at $SHA, work $T"

NS=2
DATASETS=$(jq -r '.env.AK2_DATASETS' "$SPEC")
set -- $DATASETS
U=${1#s3://}; RB=${U%%/*}; HK=${U#*/}; RP=${HK%/*}
U=${4#s3://}; B=${U%%/*}; CK=${U#*/}; CK=${CK%/}
FAKE="$T/s3"; mkdir -p "$FAKE/$B/$CK" "$FAKE/$RB/$RP"
for m in 1 2; do
  cp "$K2_READS/SRR062634_200000_$m.fq.gz" "$FAKE/$B/$CK/SRR5935755_$m.fastq.gz" || exit 1
  cp "$K2_READS/ERR478965_200000_$m.fq.gz" "$FAKE/$B/$CK/SRR5935807_$m.fastq.gz" || exit 1
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
# clone: the committed tree of the commit; checkout and rev-parse are faked only for that clone
# (an archive, not a repository); every other repository (the upstream source at the pin, which
# harness-build.sh checks) gets the real git.
case "\$1 \$2" in
  "clone -q") mkdir -p "\${@: -1}" && "$REAL_GIT" -C "$ROOT" archive "$SHA" | "$REAL_TAR" -x -C "\${@: -1}"; exit ;;
esac
dir=\$PWD; [ "\$1" = -C ] && dir=\$2
case "\$dir" in
  "$T"/home/ak2/repo*) case " \$* " in *" checkout "*) exit 0 ;; *" rev-parse "*) echo "$SHA"; exit 0 ;; esac ;;
esac
exec "$REAL_GIT" "\$@"
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
  AK2_REHEARSE_NVME="$T/nvme" AK2_REHEARSE_SAMPLES="SRR5935755 SRR5935807" AK2_REHEARSE_THREADS=4 \
  AK2_REHEARSE_TAMPER=SRR5935755 GOCACHE="$(go env GOCACHE)" GOPATH="$(go env GOPATH)" GOMODCACHE="$(go env GOMODCACHE)" \
  bash -c "$(cat "$T/node.sh")" > "$T/body.log" 2>&1
RC=$?
echo "rehearse: body exit $RC"
[ "$RC" = 0 ] || { tail -25 "$T/body.log" | sed 's/^/  body | /'; }

O="$T/out/d44"
ns=$(grep -c '^d44-summary ' "$T/body.log")
echo "rehearse: streamed $ns d44-summary lines (want 2)"
[ "$ns" = 2 ] || { echo "rehearse: summary lines wrong" >&2; RC=1; }
nst=$(grep -c '^d44: ' "$T/body.log")
echo "rehearse: streamed $nst d44 step lines (want at least 9: upstream, ours, extract, done per sample, diag-reads once)"
[ "$nst" -ge 9 ] || { echo "rehearse: step lines not streamed" >&2; RC=1; }
a=$(jq -r .differing_records "$O/SRR5935807/summary.json" 2>/dev/null)
[ "$a" = 0 ] && [ ! -e "$O/SRR5935807/diag.jsonl" ] || { echo "rehearse: SRR5935807 should not differ ($a)" >&2; RC=1; }
b=$(jq -r .differing_records "$O/SRR5935755/summary.json" 2>/dev/null)
st=$(jq -r .diverging_stage "$O/SRR5935755/diag.jsonl" 2>/dev/null)
sc=$(jq -r '[.mates[].scanner_equal] | all' "$O/SRR5935755/diag.jsonl" 2>/dev/null)
ld=$(jq -r '.lookup_diffs | length' "$O/SRR5935755/diag.jsonl" 2>/dev/null)
nl=$(jq -r '.lookups' "$O/SRR5935755/diag.jsonl" 2>/dev/null)
eq=$(jq -r '.replay_from_upstream_events_and_values == .upstream_line' "$O/SRR5935755/diag.jsonl" 2>/dev/null)
tr=$(jq -r '.resolve_tree_from_upstream_events | length' "$O/SRR5935755/diag.jsonl" 2>/dev/null)
r1=$(grep -c '^@' "$O/SRR5935755/sel_1.fq" 2>/dev/null)
echo "rehearse: SRR5935755: $b differing; stage \"$st\"; scanners equal $sc; $ld of $nl lookups differ; upstream-events replay equals upstream $eq; $tr ResolveTree events; $r1 read pair extracted"
[ "$b" = 1 ] && [ "$st" = "reading or pipeline (our replay equals upstream; our run's line differs)" ] && [ "$sc" = true ] && \
  [ "$ld" = 0 ] && [ "${nl:-0}" -gt 0 ] && [ "$eq" = true ] && [ "${tr:-0}" -gt 0 ] && [ "$r1" = 1 ] || { echo "rehearse: the tampered sample's diagnosis is wrong" >&2; RC=1; }
gets=$(grep -cE "^s3 cp .*s3://$B/" "$T/aws.log"); heads=$(grep -E "^s3api head-object .*--bucket $B( |$)" "$T/aws.log" | grep -c .)
parts=0
for f in "$FAKE/$B/$CK/"*; do sz=$(wc -c < "$f" | tr -d ' '); parts=$(( parts + (sz + 8388607) / 8388608 )); done
rg=$(awk -F'\t' -v b="$B" '$1 == "GetObject" && $3 == b {s += $2} END {print s+0}' "$T/out/requests.tsv")
rh=$(awk -F'\t' -v b="$B" '$1 == "HeadObject" && $3 == b {s += $2} END {print s+0}' "$T/out/requests.tsv")
echo "rehearse: stub served $gets objects and $heads head-objects on $B; ak2_req GetObject $rg (want $parts), HeadObject $rh"
[ "$gets" = 4 ] && [ "$rg" = "$parts" ] && [ "$rh" = "$heads" ] || { echo "rehearse: request counts disagree" >&2; RC=1; }
[ "$RC" = 0 ] && echo "rehearse: ok" || echo "rehearse: FAILED (logs: REHEARSE_KEEP=1 keeps $T)" >&2
exit "$RC"
