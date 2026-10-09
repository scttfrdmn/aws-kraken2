# G3 tune-selection probe (#41; #25 WP-5, ladder 1 rung S3): which host-tune set, if any, S3 uses.
# One x8g.24xlarge (96 vCPU, 1536 GiB, kernel 6.18, THP enabled=madvise defrag=madvise at boot).
# Regimes (one table load each, cold, end to end):
#   a  upstream at the pin, -M on a huge=always tmpfs (S2b's context, which S3 inherits): RODA v205's
#      hash.k2d staged onto the tmpfs by s5cmd (S1's stager); load_s = that staging. Then
#      kraken2 --memory-mapping --paired --threads $(nproc) on the fixed sample; the tmpfs unmounted.
#   b  ours, engine N = 1: the shard read by 48 parallel ranged GETs (If-Match, K2_DB_READ_THREADS
#      = 48 as E2's x8g.24xlarge N = 1 point) into MADV_HUGEPAGE anonymous memory; load_s = the
#      shard-load-0 phase. Then the same classify, in the same process.
# Sets (scripts/g3/hosttune.sh; rationale in docs/probes.md): none, precompact, proactive, defer,
# defermadv, always. Order: rep r runs the sets rotated by r-1 places; each set's two regimes run
# back to back, a first when r + i is odd, else b (the first trial is none, a, at fresh boot).
# REPS = 3: 36 trials. Before every trial: ht_restore (the boot values), drop_caches (Law 4; a
# cold rung), ht_apply SET (its knobs, then its timed pre-compaction step), ht_record. After: an
# ht_record. Between load and classify (a), an ht_record; during both, a 2 s sampler of meminfo's
# AnonHugePages and ShmemPmdMapped (huge-page coverage). Fragmentation is not reset between
# trials: trial position is recorded, so the state after successive loads is in the record.
# Fixed sample: SRR5935740 (rank 1 of results/cohort/PRJNA398089/runs.tsv, U1's drift reference),
# gunzipped once onto a tmpfs before any trial (not timed), so classify is table-bound.
# Network ceiling: a 30 s ranged-GET discard read at 48 workers, before the trials and after;
# hash bytes / that rate is the load floor, so median(load none) - floor bounds a load-side gain.
#
# SELECTION RULE (registered here before any run; scripts/lib/tune_tables.py applies it):
#   Per regime, separately. A trial is valid if its load and classify exit 0, ht_apply returned 0
#   (the set read back as wanted) and its --output sha256 equals the run's modal one. Per trial
#   total_s = precompact_s (0 without the step) + load_s + classify_s. A cell (regime, set) needs
#   >= 3 valid trials. range(cell) = max - min of total_s; crange(cell) the same of classify_s.
#   A set S != none qualifies iff
#     gain = median total(none) - median total(S) > 2 x max(range(none), range(S)), and
#     median classify(S) <= median classify(none) + 2 x max(crange(none), crange(S))
#       (no classify regression the probe can resolve: it would scale with a cohort).
#   Pick the qualifying set with the lowest median total_s; else none.
#   S3's set is regime a's pick. Regime b's pick is recorded for ours (O0b); it does not change S3.
# RESOLUTION (computed by the post before any verdict): the smallest gain the rule can accept is
#   2 x range(none); with the load ceiling (median load none - floor) it is printed per regime.
#   If the ceiling is below the resolution, a "none" verdict is not evidence that no set helps.
# Every result line streams as "probe-tune {json}" and into out/tune.jsonl (pushed after every
# trial); every ht_record line as "ht-record {json}" into out/hosttune.{txt,jsonl}, pushed per call.
W=$HOME/ak2; mkdir -p "$W"
SHA=${AK2_RUN_ID##*-}
HT_ROOT=${AK2_REHEARSE_HT_ROOT:-}
# The host's state before this body does anything (the stub and the preamble ran before it).
{ echo "== boot-raw $(date -u +%FT%TZ)"; cat "$HT_ROOT/proc/buddyinfo"; grep -E '^(compact_|thp_)' "$HT_ROOT/proc/vmstat"; } > "$W/boot-raw.txt" 2>&1
ak2_push "$W/boot-raw.txt" boot-raw.txt > /dev/null
RB=kraken2-ncbi-refseq-complete-v205; RP=Kraken2_RefSeqCompleteV205
B=aws-kraken2-942542972736-us-west-2; CK=aws-kraken2/data/cohort
S1=SRR5935740
SETS=(none precompact proactive defer defermadv always)
REPS=${AK2_REHEARSE_REPS:-3}
NET_S=${AK2_REHEARSE_NET_S:-30}
RW=48
S5V=2.3.0
fail() { ak2_say "ERROR: $*"; exit 1; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
J="$W/tune.jsonl"; : > "$J"
emit() { echo "$1" >> "$J"; echo "probe-tune $1"; }

ak2_phase setup
sudo -n dnf install -y -q git gcc-c++ make zlib-devel perl jq gzip tar findutils python3 pigz > "$W/dnf.log" 2>&1 ||
  { tail -5 "$W/dnf.log"; fail "dnf failed"; }
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "no repo"
HT_DIR="$W/hosttune"
. scripts/g3/hosttune.sh
ht_init || fail "ht_init failed"
ht_record setup
( scripts/oracle-build.sh > "$W/build.out" 2>&1 ) &
BUILD_PID=$!
GOV=$(awk '$1=="go"{print $2}' go.mod)
if [ -z "${AK2_REHEARSE_GO:-}" ]; then
  curl -fsSL --retry 5 "https://go.dev/dl/go$GOV.linux-arm64.tar.gz" -o "$W/go.tgz" || fail "Go download failed"
  tar -xzf "$W/go.tgz" -C "$W" || fail "Go unpack failed"
  export PATH="$W/go/bin:$PATH"
fi
make build > "$W/make-build.out" 2>&1 || { tail -20 "$W/make-build.out"; fail "make build failed"; }
OURS="$W/repo/bin/aws-kraken2"; K2P="$W/repo/bin/k2probe"
if [ -n "${AK2_REHEARSE_S5CMD:-}" ]; then S5=$AK2_REHEARSE_S5CMD; else
  T5=s5cmd_${S5V}_Linux-arm64.tar.gz
  curl -fsSL --retry 5 "https://github.com/peak/s5cmd/releases/download/v$S5V/$T5" -o "$W/$T5" || fail "s5cmd download failed"
  curl -fsSL --retry 5 "https://github.com/peak/s5cmd/releases/download/v$S5V/s5cmd_checksums.txt" -o "$W/s5sums" || fail "s5cmd checksums failed"
  ( cd "$W" && grep " $T5\$" s5sums | sha256sum -c - ) || fail "s5cmd checksum mismatch"
  tar -xzf "$W/$T5" -C "$W" s5cmd || fail "s5cmd unpack failed"
  S5=$W/s5cmd
fi
wait "$BUILD_PID" || { cat "$W/build.out"; fail "upstream build failed"; }
K2DIR=$(scripts/oracle-build.sh 2>/dev/null) || fail "upstream build not found"
K2="$K2DIR/kraken2"
T=$(nproc)
ak2_say "upstream $(tr '\n' ';' < "$K2DIR/BUILD"); ours $(git rev-parse HEAD); s5cmd $("$S5" version 2>&1 | head -1); threads $T; ranged-GET workers $RW"

ak2_phase fetch-inputs
DB="$W/db"; mkdir -p "$DB"
for f in opts.k2d taxo.k2d; do
  ak2_stage "s3://$RB/$RP/$f" "$DB/$f" || fail "stage of RODA $f failed"
  ak2_req GetObject 1 "$RB"
done
ET=$(aws s3api head-object --no-sign-request --bucket "$RB" --key "$RP/hash.k2d" --query ETag --output text | tr -d '"')
SZ=$(aws s3api head-object --no-sign-request --bucket "$RB" --key "$RP/hash.k2d" --query ContentLength --output text)
ak2_req HeadObject 2 "$RB"
[[ "$SZ" =~ ^[0-9]+$ ]] && [ -n "$ET" ] || fail "head-object of hash.k2d failed"
URL=${AK2_REHEARSE_HASH_URL:-https://$RB.s3.us-west-2.amazonaws.com/$RP/hash.k2d}
ak2_say "hash.k2d etag=$ET size=$SZ"
IN=$(scripts/upstream-cohort.sh mount inputs 24g) || fail "tmpfs for inputs failed"
"$W/repo/scripts/g3/fetch.sh" "$B" "$CK" "$IN" 2 "${S1}_1.fastq.gz" "${S1}_2.fastq.gz" > "$W/fetched.txt" 2>&1
FERR=$?
cat "$W/fetched.txt"
[ "$FERR" = 0 ] && [ "$(grep -vc ERROR "$W/fetched.txt")" = 2 ] || fail "input fetch failed"
ak2_req GetObject "$(awk '!/ERROR/{n += int(($2 + 8388607) / 8388608)} END{print n+0}' "$W/fetched.txt")" "$B"
ak2_req HeadObject 2 "$B"
t0=$(now)
for m in 1 2; do pigz -dc -p 16 "$IN/${S1}_$m.fastq.gz" > "$IN/${S1}_$m.fq" || fail "gunzip of mate $m failed"; done
t1=$(now)
FQ1="$IN/${S1}_1.fq"; FQ2="$IN/${S1}_2.fq"
emit "$(jq -nc --arg s "$S1" --arg t0 "$t0" --arg t1 "$t1" --argjson b "$(( $(stat -c%s "$FQ1") + $(stat -c%s "$FQ2") ))" \
  '{kind:"prep", sample:$s, tool:"pigz -dc -p 16", seconds:(($t1|tonumber)-($t0|tonumber)), fq_bytes:$b}')"

# net LABEL: the network ceiling, a NET_S-second ranged-GET discard read at RW workers.
net() {
  "$K2P" rget -url "$URL" -etag "$ET" -size "$SZ" -out "" -seconds "$NET_S" -workers "$RW" -chunk-mib 64 -every 5 -label "$1" \
    > "$W/net.out" 2> "$W/net.err"
  local rc=$? d
  d=$(grep '"kind":"done"' "$W/net.out" | tail -1)
  [ -n "$d" ] || d='{}'
  emit "$(jq -nc --arg l "$1" --argjson rc "$rc" --argjson d "$d" --argjson sz "$SZ" --argjson w "$RW" \
    '{kind:"net", label:$l, exit:$rc, workers:$w, gbps:$d.gbps_cum, requests:$d.requests, object_bytes:$sz,
      load_floor_s:(if ($d.gbps_cum // 0) > 0 then $sz / ($d.gbps_cum * 1e9) else null end)}')"
  ak2_req GetObject "$(jq -r '.requests // 0' <<< "$d")" "$RB"
  [ "$rc" = 0 ]
}
# hugewatch FILE: every 2 s, meminfo's AnonHugePages and ShmemPmdMapped (kB), until killed.
hugewatch() {
  while :; do
    awk -v t="$(date +%s)" '/^AnonHugePages:/{a=$2} /^ShmemPmdMapped:/{s=$2} END{print t, a+0, s+0}' "$HT_ROOT/proc/meminfo" >> "$1" 2>/dev/null
    sleep 2
  done
}
peak() { awk -v c="$2" 'BEGIN{m=0} $c > m {m = $c} END{print m+0}' "$1" 2>/dev/null || echo 0; }
sec() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b - a}'; }

# trial POS REP SET REGIME: one cold load and classify; one "trial" line.
FAIL=0
trial() {
  local pos=$1 rep=$2 set=$3 reg=$4 tag="t$1-$4-$3" d arc pre mid=null post t0 t1 tl0 tl1 tc0 tc1 td0 td1 lrc=1 crc=1 cs ls hw
  local RAMDB req=0 osha=- rsha=- applied
  ak2_phase "$tag"
  ht_restore || ak2_say "ht_restore before $tag did not restore every knob"
  ak2_drop_caches
  ht_apply "$set"; arc=$?
  applied=$HT_APPLIED
  local writes=$HT_WRITES pcs=${HT_PRECOMPACT_S:-}
  ht_record "pre-$tag"; pre=$HT_LAST_JSON
  d="$IN/out/$tag"; mkdir -p "$d"
  hugewatch "$d/huge.txt" & hw=$!
  t0=$(now)
  if [ "$reg" = a ]; then
    RAMDB=$(scripts/upstream-cohort.sh mount roda 1150g)
    if [ -n "$RAMDB" ] && cp "$DB/opts.k2d" "$DB/taxo.k2d" "$RAMDB/"; then
      tl0=$(now)
      "$S5" --no-sign-request --numworkers 256 cp --concurrency 128 --part-size 64 "s3://$RB/$RP/hash.k2d" "$RAMDB/hash.k2d" > "$d/load.log" 2>&1
      lrc=$?; tl1=$(now)
      req=$(( (SZ + 67108863) / 67108864 ))
      if [ "$lrc" = 0 ] && [ "$(stat -c%s "$RAMDB/hash.k2d" 2>/dev/null)" != "$SZ" ]; then lrc=1; fi
      [ "$lrc" = 0 ] || tail -3 "$d/load.log"
      ls=$(sec "$tl0" "$tl1")
      ht_record "load-$tag"; mid=$HT_LAST_JSON
      if [ "$lrc" = 0 ]; then
        tc0=$(now)
        "$K2" --db "$RAMDB" --memory-mapping --paired --threads "$T" --output "$d/output" --report "$d/report" "$FQ1" "$FQ2" \
          > /dev/null 2> "$d/stderr"
        crc=$?; tc1=$(now)
      fi
    else
      ak2_say "tmpfs for $tag failed"
    fi
    td0=$(now)
    scripts/upstream-cohort.sh umount roda || { kill "$hw" 2>/dev/null; fail "umount of the RODA tmpfs after $tag failed (the next trial would not fit)"; }
    td1=$(now)
  else
    mkdir -p "$W/rv/$tag"
    env AK2_ENGINE_N=1 AK2_ENGINE_RANK=0 AK2_ENGINE_RENDEZVOUS="$W/rv/$tag" AK2_ENGINE_LISTEN=127.0.0.1 AK2_ENGINE_TIMEOUT=30m \
      AK2_ENGINE_HASH_URL="$URL" AK2_ENGINE_HASH_ETAG="$ET" AK2_ENGINE_HASH_SIZE="$SZ" AK2_TIMINGS=1 K2_DB_READ_THREADS="$RW" \
      "$OURS" --db "$DB" --paired --threads "$T" --output "$d/output" --report "$d/report" "$FQ1" "$FQ2" \
      2> >(tee "$d/stderr" | grep --line-buffered -E '^ak2-(timing|engine)' | sed -u "s/^/[$tag] /") > /dev/null
    crc=$?
    sleep 1 # let the tee drain
    ls=$(awk -F'\t' '$1 == "ak2-timing" && $2 == "shard-load-0" {print $4}' "$d/stderr" | tail -1)
    [ -n "$ls" ] && lrc=0
    req=$(awk -F'\t' '$1 == "ak2-engine" && $2 == "load" {print $6}' "$d/stderr" | tail -1)
    tc0=; tc1=; td0=; td1=
  fi
  t1=$(now)
  kill "$hw" 2>/dev/null; wait "$hw" 2>/dev/null
  ak2_req GetObject "${req:-0}" "$RB"
  cs=$(sed -nE 's/.*processed in ([0-9.]+)s.*/\1/p' "$d/stderr" 2>/dev/null | tail -1)
  [ -s "$d/output" ] && osha=$(sha256sum "$d/output" | cut -d' ' -f1)
  [ -s "$d/report" ] && rsha=$(sha256sum "$d/report" | cut -d' ' -f1)
  ht_record "post-$tag"; post=$HT_LAST_JSON
  emit "$(jq -nc --argjson pos "$pos" --argjson rep "$rep" --arg set "$set" --arg reg "$reg" --argjson arc "$arc" --arg applied "$applied" \
    --argjson writes "$writes" --arg pcs "$pcs" --arg ls "${ls:-}" --arg cs "${cs:-}" --argjson lrc "$lrc" --argjson crc "$crc" \
    --arg t0 "$t0" --arg t1 "$t1" --arg tc0 "${tc0:-}" --arg tc1 "${tc1:-}" --arg td0 "${td0:-}" --arg td1 "${td1:-}" \
    --arg osha "$osha" --arg rsha "$rsha" --argjson pre "$pre" --argjson mid "$mid" --argjson post "$post" \
    --argjson ha "$(peak "$d/huge.txt" 2)" --argjson hs "$(peak "$d/huge.txt" 3)" --arg tail "$(tail -2 "$d/stderr" 2>/dev/null | tr '\n' ' ' | cut -c1-200)" '
    def n($s): if $s == "" then null else ($s | tonumber) end;
    def delta($k): if ($pre.vmstat[$k] != null and $post.vmstat[$k] != null) then $post.vmstat[$k] - $pre.vmstat[$k] else null end;
    {kind:"trial", pos:$pos, rep:$rep, set:$set, regime:$reg, applied:($applied == "true" and $arc == 0), ht_apply_rc:$arc,
     ht_writes:$writes, precompact_s:n($pcs), load_s:n($ls), classify_s:n($cs), load_exit:$lrc, classify_exit:$crc,
     classify_wall_s:(if $tc0 == "" or $tc1 == "" then null else n($tc1) - n($tc0) end),
     teardown_s:(if $td0 == "" then null else n($td1) - n($td0) end),
     wall_s:(n($t1) - n($t0)),
     total_s:(if $ls == "" or $cs == "" then null else (n($pcs) // 0) + n($ls) + n($cs) end),
     output_sha256:$osha, report_sha256:$rsha,
     pre_free_huge_frac:$pre.free_huge_frac, pre_free_bytes:$pre.free_bytes, pre_buddy:$pre.buddy,
     thp:{enabled:$pre.enabled, defrag:$pre.defrag, proactiveness:$pre.proactiveness},
     vmstat_delta:([ "compact_stall", "compact_success", "compact_fail", "compact_migrate_scanned", "compact_free_scanned",
       "compact_daemon_wake", "thp_fault_alloc", "thp_fault_fallback", "thp_file_alloc", "thp_file_fallback" ]
       | map({(.): delta(.)}) | add),
     shmem_huge_kb_after_load:(if $mid == null then null else $mid.meminfo_kb.ShmemHugePages end),
     anon_huge_kb_peak:$ha, shmem_pmd_mapped_kb_peak:$hs, stderr_tail:$tail}')"
  ak2_push "$J" tune.jsonl > /dev/null
  rm -rf "$d"
  [ "$lrc" = 0 ] && [ "$crc" = 0 ] && [ "$arc" = 0 ]
}

ak2_phase net-0
net net-0 || FAIL=1
NS=${#SETS[@]}; POS=0
for ((rep = 1; rep <= REPS; rep++)); do
  for ((i = 0; i < NS; i++)); do
    set=${SETS[$(( (i + rep - 1) % NS ))]}
    if (( (rep + i) % 2 == 1 )); then regs="a b"; else regs="b a"; fi
    for reg in $regs; do
      POS=$((POS + 1))
      trial "$POS" "$rep" "$set" "$reg" || { FAIL=1; ak2_say "trial $POS ($reg, $set) failed"; }
    done
  done
done
ak2_phase net-1
net net-1 || FAIL=1

ak2_phase push
ht_restore || FAIL=1
ht_record end
scripts/upstream-cohort.sh umount inputs || ak2_say "umount inputs failed"
ak2_push "$J" tune.jsonl || FAIL=1
ak2_say "tune probe done: $POS trials, FAIL=$FAIL"
exit "$FAIL"
