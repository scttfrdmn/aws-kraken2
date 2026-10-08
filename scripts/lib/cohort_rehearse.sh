#!/usr/bin/env bash
# make rehearse SPEC=runs/g3-<exp>-<type>-n<N>.json (docs/cohort.md, "Rehearsal"): a G3 campaign
# spec's own body (its command[2], unmodified; scripts/g3/campaign.body.sh) run locally as N nodes
# under the environment the harness gives a cohort member, before any launch. The stand-ins are
# scripts/lib/e1_rehearse.sh's (the harness helpers and cohort env; sudo/dnf, git clone as a git
# archive of the committed tree, the Go download, IMDS, GNU tools; Standard-8's hash.k2d served as
# RODA's by k2probe serve-file; S3 as one directory through k2probe fakes3 and the stub aws, which
# models the instance role's IAM; REHEARSE_SAMPLES (3) real local read sets as the cohort).
# What passes, each checked on observed output, not on code:
#   - every rank's body exits 0;
#   - streaming: every rank's body output (its run log on AWS) has [c<C>] ak2-sample lines, and
#     the home and emitter lines across ranks number exactly the manifest's lines;
#   - placement: the streamed home ranks equal the manifest's placement (scripts/lib/lpt_check.py),
#     and batch 0's LPT placement differs from j mod N here (the weights seam makes it), so the
#     check can tell LPT from j mod N;
#   - requests: every rank recorded the shard load's ranged GETs (GetObject-range > 0); the
#     objects under out/ in the fake bucket number exactly the manifest's outputs, and equal
#     CompleteMultipartUpload + PutObject - Rendezvous-PutObject summed over the ranks' requests;
#   - Law 1: every output and report of every batch is byte-identical to upstream kraken2 at the
#     pin on that sample (--paired, plain defaults); no multipart upload is left open.
# Seams: the body reads AK2_REHEARSE_N, AK2_REHEARSE_HASH_URL, AK2_REHEARSE_SAMPLES and
# AK2_REHEARSE_WEIGHTS (run.sh refuses AK2_* keys outside its allow-list in a spec's env, so they
# are always unset on AWS).
#
# Usage: scripts/lib/cohort_rehearse.sh runs/<spec>.json [N]   (N default 3)
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
# Weights for the LPT batches: chosen so that LPT's placement differs from j mod N (lpt_check
# reports whether it does; the rehearsal requires it).
WEIGHTS=(5 1 9 3 7 2); WEIGHTS=("${WEIGHTS[@]:0:$NS}")

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
    AK2_REHEARSE_WEIGHTS="${WEIGHTS[*]}" \
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
OUTP="$FAKE/$B/aws-kraken2/g3/$COHORT/out"
MAN=$(ls "$T"/out-r0/rank0/c*.tsv 2>/dev/null | head -1)
[ -s "$MAN" ] || { echo "rehearse: rank 0 pushed no manifest" >&2; RC=1; MAN=/dev/null; }
INV=$(basename "$MAN" .tsv)
NL=$(grep -c . "$MAN")
# Streaming.
tot=0
for ((k = 0; k < N; k++)); do
  ns=$(grep -cE "^\[$INV\] ak2-sample[[:space:]]" "$T/rank$k.log")
  nh=$(grep -E "^\[$INV\] ak2-sample[[:space:]]" "$T/rank$k.log" | grep -cE $'\trole\t(home|emitter)\t')
  tot=$((tot + nh))
  echo "rehearse: rank $k streamed $ns [$INV] ak2-sample lines ($nh home or emitter)"
  [ "$ns" -gt 0 ] || { echo "rehearse: rank $k streamed no [$INV] ak2-sample lines" >&2; RC=1; }
done
echo "rehearse: $tot home/emitter sample lines streamed, manifest has $NL"
[ "$tot" = "$NL" ] || { echo "rehearse: streamed sample lines $tot != manifest lines $NL" >&2; RC=1; }
# Placement.
python3 scripts/lib/lpt_check.py "$N" "$MAN" "$T"/rank*.log > "$T/placement.txt" 2>&1 || RC=1
sed 's/^/rehearse: /' "$T/placement.txt"
if [ "$N" -gt 1 ]; then  # one node: every placement is rank 0, nothing to tell apart
  grep -q '^lpt_check: batch 0 (lpt): .*differs from j mod N: yes' "$T/placement.txt" ||
    { echo "rehearse: batch 0's LPT placement is not distinguishable from j mod N" >&2; RC=1; }
fi
# Requests.
sum() { awk -F'\t' -v op="$1" '$1 == op {s += $2} END {print s+0}' "$T"/out-r*/requests.tsv; }
for ((k = 0; k < N; k++)); do
  g=$(awk -F'\t' '$1 == "GetObject-range" {s += $2} END {print s+0}' "$T/out-r$k/requests.tsv")
  [ "$g" -gt 0 ] || { echo "rehearse: rank $k recorded no GetObject-range (the shard load)" >&2; RC=1; }
done
NOBJ=$(find "$OUTP" -type f 2>/dev/null | wc -l | tr -d ' ')
WOBJ=$(( NL * 2 ))
REQ=$(( $(sum CompleteMultipartUpload) + $(sum PutObject) - $(sum Rendezvous-PutObject) ))
echo "rehearse: $NOBJ objects under out/ (want $WOBJ); requests say $REQ (CompleteMultipartUpload $(sum CompleteMultipartUpload) + PutObject $(sum PutObject) - Rendezvous-PutObject $(sum Rendezvous-PutObject))"
[ "$NOBJ" = "$WOBJ" ] && [ "$REQ" = "$WOBJ" ] || { echo "rehearse: object and request counts disagree" >&2; RC=1; }

# Memory: the spec's instance type must hold its shard of RODA v205's hash.k2d (1189 GB / N) plus
# 15%, 8 GB, and 7.5 GB per sample in flight: the engine's measured working memory above its shard is 6.3-6.6 GiB at 1 in
# flight, 12.1-12.5 at 2, 12.7-15.1 at 3 and 25.1-27.1 at 4, at T16 (results/g3/campaign/memory.tsv,
# scripts/lib/g3_memory.py). The earlier 2 GB, from a 200k-pair local run, let E3 c8g.12xlarge at 3
# in flight through at e6ff22b, and it was OOM-killed (a6b2c95); and every rank must have streamed the engine's memory samples (ak2-engine mem).
TYPE=$(jq -r .resources.instance_type "$SPEC")
PAR=$(jq -r '.command[2]' "$SPEC" | grep -m1 '^EXP=')
WN=$(echo "$PAR" | sed -E 's/.*WANT_N=([0-9]+).*/\1/'); IFL=$(echo "$PAR" | sed -E 's/.*INFLIGHT=([a-z0-9]+).*/\1/')
INFO=$(truffle find "$TYPE" --regions us-west-2 --show-price -o json 2>/dev/null |
  jq -c '[.. | objects | select(has("memory_mib") and .instance_type == "'"$TYPE"'")][0]')
MEM=$(echo "$INFO" | jq -r .memory_mib); VC=$(echo "$INFO" | jq -r .vcpus)
[ "$IFL" = auto ] && IFL=$(( VC / 8 > 0 ? VC / 8 : 1 ))
if [[ "$MEM" =~ ^[0-9]+$ && "$WN" =~ ^[0-9]+$ ]]; then
  need=$(awk -v n="$WN" -v i="$IFL" 'BEGIN{printf "%.1f", (1.15 * 1189091671800 / n + 8e9 + 7.5e9 * i) / 1e9}')
  have=$(awk -v m="$MEM" 'BEGIN{printf "%.1f", m * 1048576 / 1e9}')
  echo "rehearse: memory: $TYPE has $have GB; N=$WN at $IFL in flight needs $need GB"
  awk -v a="$have" -v b="$need" 'BEGIN{exit !(a >= b)}' || { echo "rehearse: $TYPE cannot hold its shard and working memory" >&2; RC=1; }
else
  echo "rehearse: memory: cannot size $TYPE (truffle: $INFO; N=$WN)" >&2; RC=1
fi
for ((k = 0; k < N; k++)); do
  nm=$(grep -cE "^\[$INV\] ak2-engine[[:space:]]mem[[:space:]]" "$T/rank$k.log")
  [ "$nm" -gt 0 ] || { echo "rehearse: rank $k streamed no ak2-engine mem lines" >&2; RC=1; }
done
echo "rehearse: every rank streamed ak2-engine mem lines"

# Law 1: upstream at the pin on each sample; every batch's output and report must equal it.
UPD="$T/upstream"; mkdir -p "$UPD"
cmpn=0; same=0
for s in "${NAMES[@]}"; do
  "$K2DIR/kraken2" --db "$DB" --threads 4 --paired --output "$UPD/$s.output" --report "$UPD/$s.report" \
    "$COH/${s}_1.fastq.gz" "$COH/${s}_2.fastq.gz" 2> "$UPD/$s.stderr" > /dev/null || { echo "rehearse: upstream failed on $s" >&2; RC=1; }
  for d in $(find "$OUTP" -type d -name "*-$s" 2>/dev/null); do
    for f in output report; do
      cmpn=$((cmpn + 1))
      if cmp -s "$d/$f" "$UPD/$s.$f"; then same=$((same + 1)); else echo "rehearse: DIFF ${d#$FAKE/} $f vs upstream" >&2; RC=1; fi
    done
  done
done
echo "rehearse: $same of $cmpn outputs identical to upstream (want $WOBJ)"
[ "$cmpn" = "$WOBJ" ] || { echo "rehearse: expected $WOBJ compared outputs" >&2; RC=1; }
[ -z "$(ls "$FAKE/.uploads" 2>/dev/null)" ] || { echo "rehearse: multipart uploads left open" >&2; RC=1; }
[ "$RC" = 0 ] && echo "rehearse: ok" || echo "rehearse: FAILED (logs: REHEARSE_KEEP=1 keeps $T)" >&2
exit "$RC"
