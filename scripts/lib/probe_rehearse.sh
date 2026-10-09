#!/usr/bin/env bash
# make rehearse SPEC=runs/g3-probe-<decomp|stage|cont>-<type>.json (docs/probes.md): the probe
# spec's own body (its command[2], unmodified) run locally under the environment the harness gives
# a run, before any launch. Stand-ins: the ak2_* helpers; sudo (nothing); git clone (a git archive
# of the committed tree); nproc, sha256sum, stat -c, timeout (perl), pigz (gzip); S3 as one
# directory through the stub aws (scripts/lib/rehearse_aws.py); RODA's hash.k2d as a 320 MiB
# random file with a real 128 MiB-part multipart ETag, served over HTTP with Range and If-Match
# (k2probe serve-file) for the ranged-GET reader; s5cmd as a stub copying that file.
# What passes, on observed output:
#   decomp: exit 0; 10 identity lines (5 tools x 2 mates), all identical; 5 x 2 x REPS timing
#     lines, every exit 0; the same lines in the pushed out/decomp.jsonl; probe_tables.py decomp
#     makes both tables with 5 tools each, all identical = yes;
#   stage: exit 0; 3 sweep done lines; a complete whole-object rget and s5cmd write, each followed
#     by a passing ETag check; one aws s3 cp sample done line with more than 0 bytes; streamed lines = pushed lines;
#     probe_tables.py stage marks rget and s5cmd ok = yes;
#   cont: 3 members run concurrently (N = 3, stages 1 2 3), each exits 0; member k streams one
#     done line per stage with N > k; probe_tables.py cont reports N = 1, 2, 3 with N nodes each.
#   tune (#41): the viral DB stands in for RODA (its hash.k2d served by serve-file with a real
#     multipart ETag, and copied by the s5cmd stub), SRR062634 200k pairs for the fixed sample, a
#     fake /sys and /proc tree for the host knobs (AK2_REHEARSE_HT_ROOT); the full plan (the
#     warm-up pair, then 6 sets x 2 regimes x 3 reps in the registered SCHED). Exit 0; 38 trial
#     lines streamed and in the pushed tune.jsonl, each valid (load and classify exit 0, the set
#     applied), 2 of them warm-up, 3 per regime and set otherwise; one output sha256 and one report
#     sha256 across all 38 (upstream -M and ours' engine N = 1 agree); every trial has a
#     teardown_s; 2 net lines; the ht-record lines streamed equal the pushed hosttune.jsonl (97:
#     setup, pre and post per trial, load per regime-a trial, end); every none trial wrote nothing
#     (ht_writes 0, its apply rows all "kept"), every other
#     trial wrote; the end record is back at the tree's boot values; tune_tables.py makes a
#     selection row per regime and 12 cell rows.
# Usage: scripts/lib/probe_rehearse.sh runs/g3-probe-<kind>-<type>.json
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
KIND=$(basename "$SPEC" .json | sed -E 's/^g3-probe-([a-z]+)-.*/\1/')
mkdir -p results/rehearse || exit 1
LOGF="results/rehearse/$(basename "$SPEC" .json)-$(date -u +%Y%m%dT%H%M%SZ)-$SHA.log"
exec > >(tee "$LOGF") 2>&1
echo "rehearse: record $LOGF"
REAL_GIT=$(command -v git); REAL_TAR=$(command -v tar)
T=$(mktemp -d "${TMPDIR:-/tmp}/ak2-prehearse.XXXXXX")
SRV=
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; [ "${REHEARSE_KEEP:-0}" = 1 ] || { chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"; }; }
trap cleanup EXIT
echo "rehearse: $SPEC ($KIND) at $SHA, work $T"
DATASETS=$(jq -r '.env.AK2_DATASETS' "$SPEC")
RB=kraken2-ncbi-refseq-complete-v205; HK=Kraken2_RefSeqCompleteV205/hash.k2d
B=aws-kraken2-942542972736-us-west-2; CK=aws-kraken2/data/cohort
FAKE="$T/s3"; mkdir -p "$FAKE/$B/$CK" "$FAKE/$RB"

BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sudo"
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
f=${@: -1}; exec gzip -dc "$f"
EOF
cat > "$BIN/timeout" <<'EOF'
#!/usr/bin/env perl
my $lim = shift; my $pid = fork();
if ($pid == 0) { exec @ARGV or exit 127; }
local $SIG{ALRM} = sub { kill 'TERM', $pid; waitpid($pid, 0); exit 124; };
alarm $lim; waitpid($pid, 0); exit($? >> 8);
EOF
printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$ROOT/scripts/lib/rehearse_aws.py" > "$BIN/aws"
chmod +x "$BIN"/*
cat > "$T/helpers.sh" <<'EOF'
ak2_say() { echo "ak2: [$(date -u +%FT%TZ)] $*"; }
ak2_phase() { echo "ak2-phase $(date -u +%FT%TZ) $1"; }
ak2_req() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$AK2T_OUT/requests.tsv"; }
ak2_push() { mkdir -p "$AK2T_OUT" && cp "$1" "$AK2T_OUT/${2:-$(basename "$1")}"; }
ak2_drop_caches() { echo "ak2: drop_caches (rehearsal: nothing)"; }
ak2_stage() { aws s3 cp --only-show-errors "$1" "$2"; }
EOF
cat "$T/helpers.sh" <(jq -r '.command[2]' "$SPEC") > "$T/node.sh"

# The stand-in hash.k2d and its server (stage and cont).
HASH_ETAG=
if [ "$KIND" != decomp ]; then
  if [ "$KIND" = tune ]; then
    TDB="$K2_DB_ROOT/k2_viral_20260626"
    [ -s "$TDB/hash.k2d" ] || { echo "rehearse: need the viral DB at $TDB" >&2; exit 1; }
    ln -s "$TDB/hash.k2d" "$T/hash.k2d" || exit 1  # served and copied as is; no second copy on disk
  else
    head -c $((320 << 20)) /dev/urandom > "$T/hash.k2d" || exit 1
  fi
  HASH_ETAG=$(python3 - "$T/hash.k2d" <<'EOF'
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
  (cd "$ROOT" && CGO_ENABLED=0 go build -o "$T/k2probe" ./cmd/k2probe) || { echo "rehearse: k2probe build failed" >&2; exit 1; }
  "$T/k2probe" serve-file -file "$T/hash.k2d" -path "/$HK" -etag "$HASH_ETAG" -url-file "$T/url" > "$T/serve.log" 2>&1 &
  SRV=$!
  for _ in $(seq 50); do [ -s "$T/url" ] && break; sleep 0.1; done
  [ -s "$T/url" ] || { echo "rehearse: serve-file did not start" >&2; exit 1; }
  echo "rehearse: stand-in hash.k2d $(wc -c < "$T/hash.k2d" | tr -d ' ') bytes, ETag $HASH_ETAG, at $(cat "$T/url")"
  cat > "$BIN/s5cmd" <<EOF
#!/usr/bin/env bash
[ "\$1" = version ] && { echo "v-rehearse-stub"; exit 0; }
cp "$T/hash.k2d" "\${@: -1}"
EOF
  chmod +x "$BIN/s5cmd"
fi
ENVV=(PATH="$BIN:$PATH" TMPDIR="${TMPDIR:-/tmp}" K2_SHARED_ROOT="$K2_SHARED_ROOT"
  AK2T_FAKE="$FAKE" AK2T_LOG="$T/aws.log" AK2T_ROLE=instance
  AK2T_HASH_BUCKET="$RB" AK2T_HASH_KEY="$HK" AK2T_HASH_FILE="$T/hash.k2d" AK2T_HASH_ETAG="$HASH_ETAG"
  AK2_REGION=us-west-2 AK2_DATASETS="$DATASETS" AK2_REHEARSE_GO=1 GOMODCACHE="$(go env GOMODCACHE)" GOCACHE="$(go env GOCACHE)")
RC=0
case "$KIND" in
decomp)
  REPS=1
  PY=$(command -v python3.12) || { echo "rehearse: need python3.12 (the wheels' local match)" >&2; exit 1; }
  for m in 1 2; do cp "$K2_READS/SRR062634_200000_$m.fq.gz" "$FAKE/$B/$CK/SRR5935773_$m.fastq.gz" || exit 1; done
  mkdir -p "$T/out" "$T/home" "$T/shm"
  env -i "${ENVV[@]}" HOME="$T/home" AK2T_OUT="$T/out" AK2_RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$SHA" \
    AK2_REHEARSE_REPS=$REPS AK2_REHEARSE_SHM="$T/shm" AK2_REHEARSE_PYTHON="$PY" \
    bash -c "$(cat "$T/node.sh")" > "$T/body.log" 2>&1
  b=$?; echo "rehearse: body exit $b"; [ "$b" = 0 ] || { tail -25 "$T/body.log" | sed 's/^/  body | /'; RC=1; }
  J="$T/out/decomp.jsonl"
  si=$(grep -c '^probe-decomp {"kind":"identity"' "$T/body.log"); st=$(grep -c '^probe-decomp {"kind":"time"' "$T/body.log")
  ji=$(grep -c '"kind":"identity"' "$J" 2>/dev/null); jt=$(grep -c '"kind":"time"' "$J" 2>/dev/null)
  ni=$(grep '"kind":"identity"' "$J" 2>/dev/null | grep -c '"identical":true'); bad=$(grep '"kind":"time"' "$J" 2>/dev/null | grep -vc '"exit":0')
  echo "rehearse: streamed $si identity and $st timing lines; decomp.jsonl has $ji and $jt; want 10 and $((10 * REPS)); $ni identical; $bad non-zero exits"
  [ "$si" = 10 ] && [ "$ji" = 10 ] && [ "$ni" = 10 ] && [ "$st" = $((10 * REPS)) ] && [ "$jt" = $((10 * REPS)) ] && [ "$bad" = 0 ] \
    || { echo "rehearse: decomp streaming or counts wrong" >&2; RC=1; }
  mkdir -p "$T/run/out" && cp "$J" "$T/run/out/"
  python3 scripts/lib/probe_tables.py decomp "$T/run" || RC=1
  for f in probe-decomp.tsv probe-decomp-conc.tsv; do
    n=$(awk -F'\t' 'NR>1 && $7=="yes"' "$T/run/tables/$f" | grep -c .)
    [ "$n" = 5 ] || { echo "rehearse: $f has $n identical tools, want 5" >&2; RC=1; }
  done
  ;;
stage)
  mkdir -p "$T/out" "$T/home"
  env -i "${ENVV[@]}" HOME="$T/home" AK2T_OUT="$T/out" AK2_RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$SHA" \
    AK2_REHEARSE_HASH_URL="$(cat "$T/url")" AK2_REHEARSE_S5CMD="$BIN/s5cmd" AK2_REHEARSE_SWEEP_S=2 AK2_REHEARSE_CRT_S=3 \
    AK2_REHEARSE_RAMDB_ROOT="$T/ramdb" \
    bash -c "cd \$HOME; $(cat "$T/node.sh")" > "$T/body.log" 2>&1
  b=$?; echo "rehearse: body exit $b"; [ "$b" = 0 ] || { tail -25 "$T/body.log" | sed 's/^/  body | /'; RC=1; }
  J="$T/out/stage.jsonl"
  sl=$(grep -c '^probe-stage ' "$T/body.log"); jl=$(grep -c . "$J" 2>/dev/null)
  sw=$(grep '"kind":"done"' "$J" | grep -c '"label":"sweep-w')
  fr=$(grep '"kind":"done"' "$J" | grep '"label":"full-rget' | grep -c '"complete":true')
  fs=$(grep '"kind":"done"' "$J" | grep '"label":"full-s5cmd' | grep -c '"complete":true')
  eo=$(grep '"kind":"etag"' "$J" | grep -c '"ok":true'); cr=$(grep '"kind":"done"' "$J" | grep -c '"label":"awscrt')
  cb=$(grep '"kind":"done"' "$J" | grep '"label":"awscrt' | jq -r '.bytes_allocated' | tail -1)
  echo "rehearse: streamed $sl lines, stage.jsonl $jl; sweep done $sw (want 3); full rget $fr, s5cmd $fs complete; ETag ok $eo (want 2); aws sample $cr with ${cb:-0} bytes (want > 0)"
  [ "$sl" = "$jl" ] && [ "$sw" = 3 ] && [ "$fr" = 1 ] && [ "$fs" = 1 ] && [ "$eo" = 2 ] && [ "$cr" = 1 ] && [ "${cb:-0}" -gt 0 ] \
    || { echo "rehearse: stage streaming or results wrong" >&2; RC=1; }
  mkdir -p "$T/run/out" && cp "$J" "$T/run/out/"
  python3 scripts/lib/probe_tables.py stage "$T/run" || RC=1
  n=$(awk -F'\t' 'NR>1 && $8=="yes"' "$T/run/tables/probe-staging.tsv" | grep -c .)
  [ "$n" = 2 ] || { echo "rehearse: probe-staging.tsv has $n ok rows, want 2" >&2; RC=1; }
  ;;
cont)
  N=3; CID="$(date -u +%Y%m%d-%H%M%S)-$SHA-abcd-n$N"; PFX="s3://$B/aws-kraken2/g3/$CID"
  mkdir -p "$T/g3/$CID"
  pids=()
  for ((k = 0; k < N; k++)); do
    mkdir -p "$T/g3/$CID-r$k/out" "$T/home$k"
    env -i "${ENVV[@]}" HOME="$T/home$k" AK2T_OUT="$T/g3/$CID-r$k/out" AK2_RUN_ID="$CID-r$k" AK2_COHORT_ID="$CID" \
      AK2_COHORT_PREFIX="$PFX" AK2_ENGINE_N=$N AK2_ENGINE_RANK=$k AK2_ENGINE_RENDEZVOUS="$PFX/rendezvous" \
      AK2_REHEARSE_HASH_URL="$(cat "$T/url")" AK2_REHEARSE_STAGE_S=4 AK2_REHEARSE_GAP_S=2 AK2_REHEARSE_WAIT_S=120 \
      AK2_REHEARSE_STAGES="1 2 3" \
      bash -c "$(cat "$T/node.sh")" > "$T/body$k.log" 2>&1 &
    pids+=($!)
  done
  for ((k = 0; k < N; k++)); do
    wait "${pids[$k]}"; b=$?
    d=$(grep '^probe-cont ' "$T/body$k.log" | grep -c '"kind":"done"'); want=$((N - k))
    echo "rehearse: member $k exit $b; streamed $d done lines, want $want"
    [ "$b" = 0 ] && [ "$d" = "$want" ] || { tail -15 "$T/body$k.log" | sed "s/^/  body$k | /"; RC=1; }
  done
  jq -n --arg n "$N" --arg cid "$CID" '{nodes: ($n|tonumber), members: [range(0; ($n|tonumber)) | {rank: ., run_id: ($cid + "-r" + (.|tostring))}]}' \
    > "$T/g3/$CID/cohort.json"
  python3 scripts/lib/probe_tables.py cont "$T/g3/$CID" || RC=1
  cat "$T/g3/$CID/tables/probe-contention.tsv"
  ;;
tune)
  RP=Kraken2_RefSeqCompleteV205
  mkdir -p "$FAKE/$RB/$RP" "$T/out" "$T/home" || exit 1
  cp "$TDB/opts.k2d" "$TDB/taxo.k2d" "$FAKE/$RB/$RP/" || exit 1
  for m in 1 2; do cp "$K2_READS/SRR062634_200000_$m.fq.gz" "$FAKE/$B/$CK/SRR5935740_$m.fastq.gz" || exit 1; done
  # The fake host: THP and compaction knobs at an instance's boot values, and a buddyinfo,
  # vmstat and meminfo (U1's ref 0 values) for ht_record.
  H="$T/htroot"; mkdir -p "$H/sys/kernel/mm/transparent_hugepage" "$H/proc/sys/vm" || exit 1
  echo 'always [madvise] never' > "$H/sys/kernel/mm/transparent_hugepage/enabled"
  echo 'always defer defer+madvise [madvise] never' > "$H/sys/kernel/mm/transparent_hugepage/defrag"
  echo 'always within_size advise [never] deny force' > "$H/sys/kernel/mm/transparent_hugepage/shmem_enabled"
  echo 20 > "$H/proc/sys/vm/compaction_proactiveness"; : > "$H/proc/sys/vm/compact_memory"
  printf 'Node 0, zone      DMA      4      4      4      4      8     11      8      7      7      5    218 \nNode 0, zone   Normal  28665  38806  26483  13971   5428   2445    682    420    337      2  68158 \n' > "$H/proc/buddyinfo"
  printf 'compact_stall 0\ncompact_success 0\ncompact_fail 0\nthp_fault_alloc 0\nthp_fault_fallback 0\nthp_file_alloc 618601\nthp_file_fallback 0\nnr_free_pages 1\n' > "$H/proc/vmstat"
  printf 'MemFree:        1500000000 kB\nAnonHugePages:         0 kB\nShmemHugePages:  1200000000 kB\nShmemPmdMapped:        0 kB\n' > "$H/proc/meminfo"
  env -i "${ENVV[@]}" HOME="$T/home" AK2T_OUT="$T/out" AK2_RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$SHA" \
    AK2_REHEARSE_HASH_URL="$(cat "$T/url")" AK2_REHEARSE_S5CMD="$BIN/s5cmd" AK2_REHEARSE_NET_S=2 \
    AK2_REHEARSE_RAMDB_ROOT="$T/ramdb" AK2_REHEARSE_HT_ROOT="$H" \
    bash -c "cd \$HOME; $(cat "$T/node.sh")" > "$T/body.log" 2>&1
  b=$?; echo "rehearse: body exit $b"; [ "$b" = 0 ] || { tail -25 "$T/body.log" | sed 's/^/  body | /'; RC=1; }
  J="$T/out/tune.jsonl"
  st=$(grep -c '^probe-tune {"kind":"trial"' "$T/body.log"); jt=$(grep -c '"kind":"trial"' "$J" 2>/dev/null)
  bad=$(jq -c 'select(.kind == "trial" and (.load_exit != 0 or .classify_exit != 0 or .applied != true))' "$J" | grep -c .)
  cells=$(jq -r 'select(.kind == "trial" and .warmup == false) | "\(.regime) \(.set)"' "$J" | sort | uniq -c | awk '$1 == 3' | grep -c .)
  warm=$(jq -c 'select(.kind == "trial" and .warmup == true and .set == "none")' "$J" | grep -c .)
  shas=$(jq -r 'select(.kind == "trial") | .output_sha256' "$J" | sort -u | grep -vc '^-$')
  rshas=$(jq -r 'select(.kind == "trial") | .report_sha256' "$J" | sort -u | grep -vc '^-$')
  notd=$(jq -c 'select(.kind == "trial" and .teardown_s == null)' "$J" | grep -c .)
  nets=$(jq -c 'select(.kind == "net" and .exit == 0)' "$J" | grep -c .)
  echo "rehearse: streamed $st trial lines, tune.jsonl has $jt (want 38); $bad invalid; $warm warm-up (want 2); $cells cells of 3 (want 12); $shas distinct outputs and $rshas reports (want 1, 1); $notd without teardown_s (want 0); $nets net lines (want 2)"
  [ "$st" = 38 ] && [ "$jt" = 38 ] && [ "$bad" = 0 ] && [ "$warm" = 2 ] && [ "$cells" = 12 ] && [ "$shas" = 1 ] && [ "$rshas" = 1 ] \
    && [ "$notd" = 0 ] && [ "$nets" = 2 ] \
    || { echo "rehearse: tune trials wrong" >&2; RC=1; }
  sr=$(grep -c '^ht-record ' "$T/body.log"); jr=$(grep -c . "$T/out/hosttune.jsonl" 2>/dev/null)
  echo "rehearse: streamed $sr ht-record lines, hosttune.jsonl has $jr (want 97)"
  [ "$sr" = 97 ] && [ "$jr" = 97 ] || { echo "rehearse: ht_record streaming wrong" >&2; RC=1; }
  nw=$(jq -c 'select(.kind == "trial" and .set == "none" and .ht_writes != 0)' "$J" | grep -c .)
  ow=$(jq -c 'select(.kind == "trial" and .set != "none" and .ht_writes == 0)' "$J" | grep -c .)
  nk=$(awk -F'\t' '$3 == "none" && $8 != "kept"' "$T/out/hosttune-apply.tsv" | grep -c .)
  nr=$(awk -F'\t' '$3 == "none"' "$T/out/hosttune-apply.tsv" | grep -c .)
  endrec=$(grep '"label":"end"' "$T/out/hosttune.jsonl" | jq -r '"\(.enabled) \(.defrag) \(.proactiveness)"')
  echo "rehearse: none trials that wrote: $nw (want 0); other trials that did not: $ow (want 0); none apply rows $nr, not kept $nk (want 0); end state $endrec (want madvise madvise 20)"
  [ "$nw" = 0 ] && [ "$ow" = 0 ] && [ "$nr" -gt 0 ] && [ "$nk" = 0 ] && [ "$endrec" = "madvise madvise 20" ] \
    || { echo "rehearse: host-tune application wrong" >&2; RC=1; }
  mkdir -p "$T/run/out" && cp "$J" "$T/run/out/"
  python3 scripts/lib/tune_tables.py "$T/run" || RC=1
  ns=$(awk 'END{print NR - 1}' "$T/run/tables/probe-tune-selection.tsv" 2>/dev/null); nc=$(awk 'END{print NR - 1}' "$T/run/tables/probe-tune.tsv" 2>/dev/null)
  [ "$ns" = 2 ] && [ "$nc" = 12 ] || { echo "rehearse: tune tables have $ns selection and $nc cell rows, want 2 and 12" >&2; RC=1; }
  # Carry-over in the record: every trial but the first names its predecessor, and the trial
  # order the body ran is the registered one (warm-up, then SCHED).
  np=$(awk -F'\t' 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == "prev_regime") c = i} NR > 1 && $c != "-"' "$T/run/tables/probe-tune-trials.tsv" | grep -c .)
  ran=$(jq -r 'select(.kind == "trial") | "\(.set):\(.regime)"' "$J" | tr '\n' ' ')
  want="none:a none:b $(awk '/^SCHED=\(/{f=1; next} f && /^\)/{f=0} f' scripts/g3/probe-tune.body.sh | tr -d '"' | tr -s ' \n' ' ' | sed 's/^ //')"
  echo "rehearse: $np trials with a predecessor (want 37); trial order $([ "$ran" = "$want" ] && echo "is" || echo "is NOT") warm-up + SCHED"
  [ "$np" = 37 ] && [ "$ran" = "$want" ] || { echo "rehearse: prev_regime column or trial order wrong" >&2; RC=1; }
  cat "$T/run/tables/probe-tune-selection.tsv"
  ;;
*) echo "rehearse: unknown probe kind $KIND" >&2; exit 2 ;;
esac
[ "$RC" = 0 ] && echo "rehearse: ok" || echo "rehearse: FAILED (logs: REHEARSE_KEEP=1 keeps $T)" >&2
exit "$RC"
