# G3 U1 (#25, #41; Scott approved the campaign 2026-10-08): upstream kraken2 at the pin (pristine,
# built from source here) at its best for a cohort, resident: RODA v205 on a huge=always tmpfs
# (G2's ram regime) with --memory-mapping, so no sample reloads the table, on x8g.24xlarge (96
# vCPU, 1536 GiB). The first 100 samples of the recorded cohort (results/cohort/PRJNA398089/
# runs.tsv), gz as staged and fq (gunzipped onto a tmpfs before the sample's rungs; not timed).
# Rungs (scripts/g3/u1.plan order; one upstream invocation per sample, --paired):
#   A  cohort 1 (sample 1): gz and fq, T in {48, 96, 192}, n = 3, the T order rotated per rep
#   B  cohort 10: fq T in {48, 96, 192} (sample-major: each sample's fq made once, its three
#      T back to back); gz T = 48 one sample at a time; gz P = 10 samples at once, T = 8
#   C  cohort 100: fq T in {48, 96, 192} (sample-major), the T = 96 rung also computing the
#      engine's S3 ETag of every output and report (scripts/lib/ak2etag.py) for the Law-1
#      cross-check with E2's outputs; gz P = 12 x T = 8 and P = 24 x T = 4 (upstream decompresses
#      gz on one thread per process, so at a cohort its best is several processes at once)
#   ref  sample 1 fq T = 96 before A and after A, B and C, with /proc/buddyinfo and the vmstat
#      compaction counters (#41: drift over the run)
# Upstream at cohort 100 gz one process at a time is not run (about 50 min): it is dominated by
# the P x T rungs and modelled from B's per-sample rate, flagged. Upstream at cohort 1000 is
# modelled (Scott, 2026-10-07). Every sample line streams into the run log as "u1-sample {json}"
# and into out/u1.jsonl (pushed after every rung); tables come from scripts/post/<spec>.sh.
W=$HOME/ak2; mkdir -p "$W"
SHA=${AK2_RUN_ID##*-}
B=aws-kraken2-942542972736-us-west-2; CK=aws-kraken2/data/cohort
COHORT=100; C10=10
# make rehearse's seams (scripts/lib/u_rehearse.sh; run.sh refuses AK2_REHEARSE_* in a spec's env,
# so on AWS they are unset): fewer samples.
COHORT=${AK2_REHEARSE_COHORT:-$COHORT}; C10=${AK2_REHEARSE_C10:-$C10}
fail() { ak2_say "ERROR: $*"; exit 1; }
hex64() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

ak2_phase setup
sudo -n dnf install -y -q git > "$W/dnf0.log" 2>&1 || fail "dnf git failed"
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "no repo"
. scripts/g2-instance.sh
g2i_setup
sudo -n dnf install -y -q pigz > "$W/dnf1.log" 2>&1 || fail "dnf pigz failed"
U=scripts/upstream-cohort.sh
RAMDB=$($U mount roda 1150g) || fail "tmpfs for RODA failed"
IN=$($U mount inputs 140g) || fail "tmpfs for inputs failed"
SCR=$($U mount scratch 160g) || fail "tmpfs for scratch failed"
ak2_say "tmpfs: $RAMDB $IN $SCR; $(df -h "$RAMDB" "$IN" "$SCR" | tail -3 | tr -s ' ' | tr '\n' ';')"

ak2_phase fetch-db
( scripts/oracle-build.sh > "$W/build.out" 2>&1 ) &
BUILD_PID=$!
g2i_awscfg 40Gb/s
g2i_stage_roda "$RAMDB"
wait "$BUILD_PID" || { cat "$W/build.out"; fail "build failed"; }
cat "$W/build.out"
K2DIR=$(scripts/oracle-build.sh 2>/dev/null) || fail "upstream build not found"
K2="$K2DIR/kraken2"
ak2_say "upstream $(tr '\n' ';' < "$K2DIR/BUILD")"
unset AWS_CONFIG_FILE

ak2_phase fetch-inputs
RUNS=results/cohort/PRJNA398089/runs.tsv
mapfile -t SAMPLES < <(awk -F'\t' -v c="$COHORT" 'NR>1 && $1<=c {print $2}' "$RUNS")
mapfile -t PAIRS < <(awk -F'\t' -v c="$COHORT" 'NR>1 && $1<=c {print $4}' "$RUNS")
if [ -n "${AK2_REHEARSE_SAMPLES:-}" ]; then
  read -r -a SAMPLES <<< "$AK2_REHEARSE_SAMPLES"; read -r -a PAIRS <<< "$AK2_REHEARSE_WEIGHTS"
fi
[ "${#SAMPLES[@]}" = "$COHORT" ] || fail "want $COHORT cohort runs, got ${#SAMPLES[@]}"
fetch_one() {
  local f=$1 want got
  aws s3 cp --only-show-errors "s3://$B/$CK/$f" "$IN/$f" || { echo "ERROR: get $f"; return 1; }
  want=$(aws s3api head-object --bucket "$B" --key "$CK/$f" --query Metadata.sha256 --output text)
  got=$(sha256sum "$IN/$f" | cut -d' ' -f1)
  hex64 "$want" && [ "$got" = "$want" ] || { echo "ERROR: $f sha256 $got != metadata $want"; return 1; }
  echo "$f $(stat -c%s "$IN/$f")"
}
: > "$W/fetched.txt"; FERR=0; RUNNING=0
for s in "${SAMPLES[@]}"; do
  for m in 1 2; do
    fetch_one "${s}_$m.fastq.gz" >> "$W/fetched.txt" 2>&1 &
    RUNNING=$((RUNNING + 1))
    if [ "$RUNNING" -ge 16 ]; then wait -n || FERR=1; RUNNING=$((RUNNING - 1)); fi
  done
done
while [ "$RUNNING" -gt 0 ]; do wait -n || FERR=1; RUNNING=$((RUNNING - 1)); done
grep ERROR "$W/fetched.txt" | head -5
[ "$FERR" = 0 ] && [ "$(grep -vc ERROR "$W/fetched.txt")" = $((2 * COHORT)) ] || fail "input fetch failed"
ak2_req GetObject "$(awk '!/ERROR/{n += int(($2 + 8388607) / 8388608)} END{print n+0}' "$W/fetched.txt")" "$B"
ak2_req HeadObject "$((2 * COHORT))" "$B"
ak2_say "inputs staged and verified: $((2 * COHORT)) files, $(awk '!/ERROR/{s+=$2} END{printf "%.2f GB", s/1e9}' "$W/fetched.txt")"

# One sample, one upstream invocation. u1_one RUNG INPUT T J ETAG -> a u1-sample json line.
J="$W/u1.jsonl"; : > "$J"
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
u1_one() {
  local rung=$1 input=$2 t=$3 j=$4 doetag=$5 s=${SAMPLES[$4]} d="$SCR/out/$1/${SAMPLES[$4]}" i1 i2 t0 t1 rc cs oe=- re=-
  mkdir -p "$d"
  if [ "$input" = gz ]; then i1="$IN/${s}_1.fastq.gz"; i2="$IN/${s}_2.fastq.gz"; else i1="$SCR/fq/${s}_1.fq"; i2="$SCR/fq/${s}_2.fq"; fi
  t0=$(now)
  "$K2" --db "$RAMDB" --memory-mapping --paired --threads "$t" --output "$d/output" --report "$d/report" "$i1" "$i2" \
    > /dev/null 2> "$d/stderr"
  rc=$?
  t1=$(now)
  cs=$(sed -nE 's/.*processed in ([0-9.]+)s.*/\1/p' "$d/stderr" | tail -1)
  if [ "$doetag" = 1 ] && [ "$rc" = 0 ]; then
    oe=$(python3 scripts/lib/ak2etag.py output "$d/output" | cut -f1); re=$(python3 scripts/lib/ak2etag.py report "$d/report" | cut -f1)
  fi
  local line
  line=$(jq -nc --arg rung "$rung" --arg input "$input" --argjson t "$t" --arg sample "$s" --argjson pairs "${PAIRS[$j]}" \
    --argjson exit "$rc" --arg t0 "$t0" --arg t1 "$t1" --arg cs "${cs:-}" --arg oe "$oe" --arg re "$re" \
    --arg tail "$(tail -2 "$d/stderr" | tr '\n' ' ' | cut -c1-200)" \
    '{kind:"sample", rung:$rung, input:$input, threads:$t, sample:$sample, pairs:$pairs, exit:$exit,
      start:($t0|tonumber), end:($t1|tonumber), wall_s:(($t1|tonumber)-($t0|tonumber)),
      classify_s:(if $cs == "" then null else ($cs|tonumber) end), output_etag:$oe, report_etag:$re, stderr_tail:$tail}')
  echo "$line" >> "$J"
  echo "u1-sample $line"
  rm -rf "$d"
  [ "$rc" = 0 ]
}
# u1_fq J: sample J's fq onto the scratch tmpfs (not timed in any rung).
u1_fq() {
  local s=${SAMPLES[$1]} m
  mkdir -p "$SCR/fq"
  for m in 1 2; do pigz -dc -p 16 "$IN/${s}_$m.fastq.gz" > "$SCR/fq/${s}_$m.fq" || return 1; done
}
u1_fq_rm() { rm -f "$SCR/fq/${SAMPLES[$1]}_"[12].fq; }
# u1_pass RUNG INPUT T P COHORT ETAG: the first COHORT samples, P at a time (gz), and a u1-rung line.
FAIL=0
u1_pass() {
  local rung=$1 input=$2 t=$3 p=$4 c=$5 doetag=$6 j run=0 t0 t1
  ak2_phase "$rung"
  t0=$(now)
  for ((j = 0; j < c; j++)); do
    u1_one "$rung" "$input" "$t" "$j" "$doetag" &
    run=$((run + 1))
    if [ "$run" -ge "$p" ]; then wait -n || FAIL=1; run=$((run - 1)); fi
  done
  while [ "$run" -gt 0 ]; do wait -n || FAIL=1; run=$((run - 1)); done
  t1=$(now)
  u1_rungline "$rung" "$input" "$t" "$p" "$c" "$t0" "$t1"
}
u1_rungline() {
  local line
  line=$(jq -nc --arg rung "$1" --arg input "$2" --argjson t "$3" --argjson p "$4" --argjson c "$5" --arg t0 "$6" --arg t1 "$7" \
    '{kind:"rung", rung:$rung, input:$input, threads:$t, procs:$p, cohort:$c, start:($t0|tonumber), end:($t1|tonumber),
      pass_wall_s:(($t1|tonumber)-($t0|tonumber))}')
  echo "$line" >> "$J"; echo "u1-rung $line"
  ak2_push "$J" u1.jsonl > /dev/null
}
# u1_fqpass PREFIX C ETAG96 T...: fq rungs over the first C samples, sample-major (each sample's
# fq made once, its T rungs back to back); one u1-rung line per T, its pass time the sum of
# its samples' walls (the fq preparation excluded).
u1_fqpass() {
  local pre=$1 c=$2 e96=$3 j t; shift 3
  ak2_phase "$pre-fq"
  for ((j = 0; j < c; j++)); do
    u1_fq "$j" || { FAIL=1; ak2_say "fq of ${SAMPLES[$j]} failed"; return 1; }
    for t in "$@"; do
      local e=0; [ "$t" = 96 ] && e=$e96
      u1_one "$pre-fq-t$t" fq "$t" "$j" "$e" || FAIL=1
    done
    u1_fq_rm "$j"
  done
  for t in "$@"; do
    jq -s --arg r "$pre-fq-t$t" '[.[] | select(.kind == "sample" and .rung == $r)] | {s: (map(.wall_s) | add), a: (map(.start) | min), b: (map(.end) | max)}' "$J" > "$W/sum.json"
    u1_rungline "$pre-fq-t$t" fq "$t" 1 "$c" "$(jq -r .a "$W/sum.json")" "$(jq -r '.a + .s' "$W/sum.json")"
  done
}
# u1_ref K: the drift reference, with the host's fragmentation state.
u1_ref() {
  { echo "== ref $1 $(date -u +%FT%TZ)"; cat /proc/buddyinfo; grep -E '^(compact_|thp_)' /proc/vmstat; } >> "$W/drift.txt"
  ak2_push "$W/drift.txt" drift.txt > /dev/null
  u1_fq 0 && u1_one "ref$1-fq-t96" fq 96 0 0 || FAIL=1
  u1_fq_rm 0
}

ak2_phase rungs
u1_ref 0
# A: cohort 1, n = 3, T order rotated per rep.
ORDERS=("48 96 192" "96 192 48" "192 48 96")
for rep in 1 2 3; do
  for t in ${ORDERS[$((rep - 1))]}; do u1_pass "A-c1-gz-t$t-r$rep" gz "$t" 1 1 0; done
  u1_fq 0 || FAIL=1
  for t in ${ORDERS[$((rep - 1))]}; do u1_one "A-c1-fq-t$t-r$rep" fq "$t" 0 0 || FAIL=1; done
  u1_fq_rm 0
done
u1_ref 1
# B: cohort 10.
u1_fqpass B-c10 "$C10" 0 48 96 192
u1_pass B-c10-gz-t48 gz 48 1 "$C10" 0
u1_pass B-c10-gz-p10-t8 gz 8 10 "$C10" 0
u1_ref 2
# C: cohort 100.
u1_fqpass C-c100 "$COHORT" 1 96 48 192
u1_pass C-c100-gz-p12-t8 gz 8 12 "$COHORT" 0
u1_pass C-c100-gz-p24-t4 gz 4 24 "$COHORT" 0
u1_ref 3

ak2_phase push
ak2_push "$J" u1.jsonl
ak2_push "$W/drift.txt" drift.txt
for n in scratch inputs roda; do $U umount "$n" || ak2_say "umount $n failed"; done
ak2_say "u1 done (failed=$FAIL)"
exit "$FAIL"
