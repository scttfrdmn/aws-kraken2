#!/usr/bin/env bash
# make rehearse SPEC=runs/g3-e1.json (docs/cohort.md, "Rehearsal"): run the spec's own body (its
# command[2], unmodified) locally as N nodes, under the environment the harness gives a cohort
# member, before any launch. Two E1 spec bugs were found only on AWS (repeated sample names; a
# manifest check without the engine env); this finds that kind of bug for free.
#
# What stands in for AWS:
#   - the run harness: the ak2_* helpers (ak2_stage copies from local stand-ins, ak2_push into
#     out/rank<r>/…), and the cohort env (AK2_COHORT_ID with the commit, AK2_ENGINE_N/RANK,
#     AK2_ENGINE_RENDEZVOUS and AK2_COHORT_PREFIX in a fake bucket, AK2_ALLOWED_BUCKETS);
#   - the instance: sudo/dnf, git clone (a git archive of the commit in the cohort id: the
#     committed tree is what runs), the Go download, IMDS (127.0.0.1), and the GNU tools the
#     body uses (nproc, free, sha256sum, stat -c);
#   - RODA's hash.k2d: Standard-8's, served by k2probe serve-file (ranged GETs with If-Match, as
#     the nodes fetch RODA), its opts.k2d and taxo.k2d staged; no local hash.k2d on any node;
#   - S3: one directory, written by the SDK path through k2probe fakes3 and by the CLI path
#     through a stub aws (scripts/lib/rehearse_aws.py) on the same layout;
#   - the cohort's staged samples: REHEARSE_SAMPLES (default 3) real local read sets, gzip.
# The body runs end to end on every rank: setup, fetch, the manifests and AK2_COHORT_CHECK, every
# invocation, rank 0's consistency check. Then every output of every variant of every sample is
# compared with upstream kraken2 at the pin on the same sample (--paired, plain defaults).
# Seams: the body reads AK2_REHEARSE_N, AK2_REHEARSE_HASH_URL and AK2_REHEARSE_SAMPLES (run.sh
# refuses them in a spec's env, so they are always unset on AWS).
#
# Usage: scripts/lib/e1_rehearse.sh runs/g3-e1.json [N]   (N default 3)
# Exits 0 only if every rank's body exits 0 and every output is identical to upstream's.
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
. scripts/pin.env
. scripts/paths.sh
echo "rehearse: shell flags $-"
SPEC=${1:-runs/g3-e1.json}; N=${2:-3}
[ -f "$SPEC" ] || { echo "rehearse: no $SPEC" >&2; exit 2; }
git diff --quiet HEAD -- "$SPEC" scripts cmd internal || { echo "rehearse: commit first (the rehearsal runs the committed tree)" >&2; exit 2; }
SHA=$(git rev-parse --short=7 HEAD)
DB="$K2_DB_ROOT/k2_standard_08_GB_20260626"
[ -s "$DB/hash.k2d" ] || { echo "rehearse: need Standard-8 at $DB" >&2; exit 1; }
K2DIR=$(scripts/oracle-build.sh) || { echo "rehearse: upstream build failed" >&2; exit 1; }
make -s build || exit 1
K2P="$ROOT/bin/k2probe"
# The rehearsal's record: everything it prints, in results/rehearse/<spec>-<UTC>-<commit>.log.
mkdir -p results/rehearse || exit 1
LOGF="results/rehearse/$(basename "$SPEC" .json)-$(date -u +%Y%m%dT%H%M%SZ)-$SHA.log"
exec > >(tee "$LOGF") 2>&1
echo "rehearse: record $LOGF"
REAL_GIT=$(command -v git); REAL_TAR=$(command -v tar); REAL_CURL=$(command -v curl)
T=$(mktemp -d "${TMPDIR:-/tmp}/ak2-rehearse.XXXXXX")
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; [ "${REHEARSE_KEEP:-0}" = 1 ] || rm -rf "$T"; }
trap cleanup EXIT
echo "rehearse: $SPEC at $SHA, N=$N, work $T"

# The cohort's samples: real local read sets, as <name>_{1,2}.fastq.gz.
SAMPLE_SRC=(SRR062634 ERR478965 SRR28305653)
NS=${REHEARSE_SAMPLES:-3}
COH="$T/cohort-src"; mkdir -p "$COH"
NAMES=()
for ((i = 0; i < NS; i++)); do
  s=${SAMPLE_SRC[$i]}
  for m in 1 2; do cp "$K2_READS/${s}_200000_$m.fq.gz" "$COH/${s}_$m.fastq.gz" || exit 1; done
  NAMES+=("$s")
done

# The spec: its body, its datasets (RODA's bucket and key, the cohort prefix).
jq -r '.command[2]' "$SPEC" > "$T/body.sh"
DATASETS=$(jq -r '.env.AK2_DATASETS' "$SPEC")
set -- $DATASETS
U=${1#s3://}; RB=${U%%/*}; HK=${U#*/}
U=${4#s3://}; B=${U%%/*}; CK=${U#*/}; CK=${CK%/}
HASH_ETAG=$(shasum -a 256 "$DB/hash.k2d" | cut -c1-32)-rehearse

# Stand-ins: the hash object, the fake S3 (with the staged cohort objects in place before any
# rank starts, as on AWS: head-object reads their metadata).
FAKE="$T/s3"; mkdir -p "$FAKE/$B/$CK"
cp "$COH"/*.fastq.gz "$FAKE/$B/$CK/" || exit 1
"$K2P" serve-file -file "$DB/hash.k2d" -path "/$HK" -etag "$HASH_ETAG" -url-file "$T/hash.url" 2> "$T/serve-file.log" & PIDS+=($!)
"$K2P" fakes3 -dir "$FAKE" -url-file "$T/fakes3.url" 2> "$T/fakes3.log" & PIDS+=($!)
for _ in $(seq 100); do [ -s "$T/hash.url" ] && [ -s "$T/fakes3.url" ] && break; sleep 0.1; done
[ -s "$T/hash.url" ] && [ -s "$T/fakes3.url" ] || { echo "rehearse: stand-in servers did not start" >&2; exit 1; }

# Stub tools on PATH.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
# clone: the committed tree of the cohort's commit; checkout: nothing; rev-parse: the commit.
case "\$1 \$2" in
  "clone -q") mkdir -p "\${@: -1}" && "$REAL_GIT" -C "$ROOT" archive "$SHA" | "$REAL_TAR" -x -C "\${@: -1}" ;;
  *) case " \$* " in *" checkout "*) exit 0 ;; *" rev-parse HEAD"*) echo "$SHA" ;; *) exec "$REAL_GIT" "\$@" ;; esac ;;
esac
EOF
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
# IMDS answers 127.0.0.1; the Go download is skipped (the local toolchain builds).
case " \$* " in
  *169.254.169.254*api/token*) echo rehearse-token ;;
  *169.254.169.254*local-ipv4*) echo 127.0.0.1 ;;
  *go.dev/dl/*) out=; while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done; : > "\$out" ;;
  *) exec "$REAL_CURL" "\$@" ;;
esac
EOF
cat > "$BIN/tar" <<EOF
#!/usr/bin/env bash
case " \$* " in *go.tgz*) exit 0 ;; *) exec "$REAL_TAR" "\$@" ;; esac
EOF
printf '#!/usr/bin/env bash\necho 4\n' > "$BIN/nproc"
printf '#!/usr/bin/env bash\necho "Mem: 64 0 0"\n' > "$BIN/free"
printf '#!/usr/bin/env bash\nexec shasum -a 256 "$@"\n' > "$BIN/sha256sum"
cat > "$BIN/stat" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -c%s ]; then wc -c < "$2" | tr -d ' '; else exec /usr/bin/stat "$@"; fi
EOF
printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$ROOT/scripts/lib/rehearse_aws.py" > "$BIN/aws"
chmod +x "$BIN"/*

# The harness helpers, in front of the body.
cat > "$T/helpers.sh" <<'EOF'
ak2_say() { echo "ak2: [$(date -u +%FT%TZ)] $*"; }
ak2_phase() { echo "ak2-phase $(date -u +%FT%TZ) $1"; }
ak2_req() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$AK2T_OUT/requests.tsv"; }
ak2_push() { mkdir -p "$AK2T_OUT/$(dirname "${2:-$(basename "$1")}")" && cp "$1" "$AK2T_OUT/${2:-$(basename "$1")}"; }
ak2_stage() {  # SRC DST: the stand-ins for RODA's opts/taxo and the staged cohort files
  local src=$1 dst=$2 f=${1##*/}
  mkdir -p "$(dirname "$dst")"
  case "$src" in
    s3://"$AK2T_RB"/*) cp "$AK2T_DB/$f" "$dst" ;;
    s3://"$AK2T_B"/*) cp "$AK2T_COH/$f" "$dst" ;;
    *) echo "rehearse ak2_stage: unknown source $src" >&2; return 1 ;;
  esac
  echo "ak2: staged $src -> $dst"
}
EOF
cat "$T/helpers.sh" "$T/body.sh" > "$T/node.sh"

COHORT="$(date -u +%Y%m%d-%H%M%S)-$SHA-beef-n$N"
PREFIX="s3://$B/aws-kraken2/g3/$COHORT"
pids=()
set -m # each rank in its own process group, so fail fast can stop it and its engine
for ((k = 0; k < N; k++)); do
  H="$T/home-r$k"; mkdir -p "$H" "$T/out-r$k"
  env -i PATH="$BIN:$PATH" HOME="$H" TMPDIR="${TMPDIR:-/tmp}" GOCACHE="$(go env GOCACHE)" GOPATH="$(go env GOPATH)" \
    GOMODCACHE="$(go env GOMODCACHE)" GOFLAGS="${GOFLAGS:-}" \
    AK2T_FAKE="$FAKE" AK2T_OUT="$T/out-r$k" AK2T_LOG="$T/aws-r$k.log" AK2T_DB="$DB" AK2T_COH="$COH" \
    AK2T_RB="$RB" AK2T_B="$B" AK2T_CK="$CK" AK2T_HASH_BUCKET="$RB" AK2T_HASH_KEY="$HK" AK2T_HASH_FILE="$DB/hash.k2d" \
    AK2T_HASH_ETAG="$HASH_ETAG" AK2T_ROLE=instance \
    AK2_REGION=us-west-2 AK2_DATASETS="$DATASETS" AK2_ALLOWED_BUCKETS="$RB $B" AK2_RUN_ID="$COHORT-r$k" \
    AK2_COHORT_ID="$COHORT" AK2_COHORT_PREFIX="$PREFIX" AK2_ENGINE_N="$N" AK2_ENGINE_RANK="$k" \
    AK2_ENGINE_RENDEZVOUS="$PREFIX/rendezvous" AK2_S3_ENDPOINT="$(cat "$T/fakes3.url")" \
    AK2_REHEARSE_N="$N" AK2_REHEARSE_HASH_URL="$(cat "$T/hash.url")" AK2_REHEARSE_SAMPLES="${NAMES[*]}" \
    bash -c "$(cat "$T/node.sh")" > "$T/rank$k.log" 2>&1 &
  pids+=($!)
done
set +m
# Fail fast, as make run does: the first rank that exits non-zero stops the others.
RC=0; left=$N; done_=()
while [ "$left" -gt 0 ]; do
  for k in "${!pids[@]}"; do
    [ -n "${done_[$k]:-}" ] && continue
    kill -0 "${pids[$k]}" 2>/dev/null && continue
    wait "${pids[$k]}"; rc=$?; done_[$k]=$rc; left=$((left - 1))
    echo "rehearse: rank $k body exit $rc"
    if [ "$rc" != 0 ]; then
      RC=1; tail -15 "$T/rank$k.log" | sed "s/^/  rank$k | /"
      for j in "${!pids[@]}"; do [ -z "${done_[$j]:-}" ] && kill -TERM -- "-${pids[$j]}" 2>/dev/null; done
    fi
  done
  [ "$left" -gt 0 ] && sleep 1
done
grep -h 'consistency ' "$T/rank0.log" | sed 's/^/  /'
# Streaming: each rank's body output (its run log on AWS) carries the engine's lines as they are
# written. E1 at cb0cea7 streamed nothing (a redirection-order bug) and only the per-invocation
# stderr pushes kept the data.
for ((k = 0; k < N; k++)); do
  ns=$(grep -cE '^\[c10\] ak2-sample[[:space:]]' "$T/rank$k.log")
  echo "rehearse: rank $k streamed $ns [c10] ak2-sample lines"
  [ "$ns" -gt 0 ] || { echo "rehearse: rank $k streamed no [c10] ak2-sample lines" >&2; RC=1; }
done

# Upstream at the pin on each sample; every variant's output and report must equal it.
UPD="$T/upstream"; mkdir -p "$UPD"
cmpn=0; same=0
for s in "${NAMES[@]}"; do
  "$K2DIR/kraken2" --db "$DB" --threads 4 --paired --output "$UPD/$s.output" --report "$UPD/$s.report" \
    "$COH/${s}_1.fastq.gz" "$COH/${s}_2.fastq.gz" 2> "$UPD/$s.stderr" > /dev/null || { echo "rehearse: upstream failed on $s" >&2; RC=1; }
  for d in $(find "$FAKE/$B/aws-kraken2/g3/$COHORT/out" -type d -name "*-$s" 2>/dev/null); do
    for f in output report; do
      cmpn=$((cmpn + 1))
      if cmp -s "$d/$f" "$UPD/$s.$f"; then same=$((same + 1)); else echo "rehearse: DIFF ${d#$FAKE/} $f vs upstream" >&2; RC=1; fi
    done
  done
done
want=$(( (NS * 5 + 3) * 2 ))  # every sample in c10's 5 batches, sample 1 in a, b, c too
echo "rehearse: $same of $cmpn outputs identical to upstream (want $want)"
[ "$cmpn" = "$want" ] || { echo "rehearse: expected $want compared outputs" >&2; RC=1; }
[ -z "$(ls "$FAKE/.uploads" 2>/dev/null)" ] || { echo "rehearse: multipart uploads left open" >&2; RC=1; }
[ "$RC" = 0 ] && echo "rehearse: ok" || echo "rehearse: FAILED (logs: REHEARSE_KEEP=1 keeps $T)" >&2
exit "$RC"
