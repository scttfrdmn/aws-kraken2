#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016,SC2329  # variables and stubs are for the sourced body block; the fake scripts are literal
# make ladder-stream-test (in make test; docs/ladder.md, "The body"): the ladder body's own launch,
# watch and sample-record functions (scripts/g3/ladder.body.sh, from its "load and classify" marker
# to its end marker, unmodified), driven with a fake classifier, checked on observed output:
#   A  per-sample path, serial uploads, 2 lanes over 3 samples: every classifier stderr line is in
#      the run log as written ("[RUNG SAMPLE] ..."), and in its file; the load -> classify boundary
#      comes from "Loading database information... done."; 3 lad-sample lines (contract v1) whose
#      output and report sha256 equal the files'; the pushed lad-samples.jsonl equals the streamed
#      lines; a lane's next sample starts only after the previous one's uploads ended (serial);
#   B  the same with an overlapped upload: the lane's next sample starts before the previous one's
#      uploads end (so A's check can tell serial from overlap);
#   C  the engine path: a fake cohort-mode engine; the boundaries load -> etag-hash.k2d (shard-load
#      line) -> classify (connect line); lad-sample lines only for this rank's home samples; the
#      engine's ak2 lines streamed;
#   S  one serial lane: every hash is critical (sha-critical = sha);
#   U  lad_crit directly: classify spans, a done upload and an upload in flight cover a hash (NB1);
#   I  the identity phase under pipefail off, as on the node: a failing or empty rapidgzip differs,
#      a corrupt input is an input_defect, a garbage tail (gzip exit 2) a gz_warning only; I-mut restores B1's bug and must fail;
#   P  ours' plain path under a cohort node's engine env: it runs without AK2_ENGINE_* (else it
#      takes the engine path, a resident copy of the table; O0 at c1); P-mut removes the strip and must fail;
#   X  every ladder.body-compat.tsv row: both body versions, each classifier under the node's env;
#      for an unaffected classifier identical invocations (argv, whole env) and records (phase
#      markers, lad-sample fields, rc handling); different invocations for an affected one; X-mut
#      shows both comparisons fail on a planted difference;
#   N  negative control: the reverse redirection order (> /dev/null 2> >(...)) streams nothing,
#      while the file still gets every line, so A's streaming check can fail.
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BODY="$ROOT/scripts/g3/ladder.body.sh"
TD=$(mktemp -d "${TMPDIR:-/tmp}/ak2-ladstream.XXXXXX") || exit 2
trap '[ "${KEEP:-0}" = 1 ] || rm -rf "$TD"' EXIT
echo "ladder-stream-test: shell flags $-; work $TD"
NF=0
pass() { echo "ok   $*"; }
bad() { echo "FAIL $*"; NF=$((NF + 1)); }
check() { if eval "$2"; then pass "$1"; else bad "$1"; fi; }

mkdir -p "$TD/bin"
command -v sha256sum > /dev/null || printf '#!/usr/bin/env bash\nexec shasum -a 256 "$@"\n' > "$TD/bin/sha256sum"
cat > "$TD/bin/stat" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = -c%s ]; then wc -c < "$2" | tr -d ' '; else exec /usr/bin/stat "$@"; fi
EOF
cat > "$TD/bin/fake-k2" << 'EOF'
#!/usr/bin/env bash
# A stand-in for kraken2 / ours' plain path: upstream's stderr lines, an output and a report.
ARGS0="$*"
out="" rep="" in=()
while [ $# -gt 0 ]; do case $1 in --output) out=$2; shift 2 ;; --report) rep=$2; shift 2 ;; --db|--threads) shift 2 ;; -*) shift ;; *) in+=("$1"); shift ;; esac; done
echo "$(perl -MTime::HiRes=time -e 'printf "%.3f", time') start $out" >> "$FAKE_LOG"
# Cases P and X: the command line and the whole environment this invocation saw (less the volatile
# PWD, SHLVL, _ and OLDPWD).
[ -n "${FAKE_ENVLOG:-}" ] && { mkdir -p "$FAKE_ENVLOG.d"; { printf 'args %s\n' "$(basename "$0") ${ARGS0:-}"; env | grep -vE '^(PWD|SHLVL|_|OLDPWD)=' | sed 's/^/env /'; } > "$FAKE_ENVLOG.d/$$"; }
# As upstream's wrapper: one `gzip -dc FILE` per mate, found on PATH.
if [ "${FAKE_GZ:-0}" = 1 ]; then for f in "${in[@]}"; do gzip -dc "$f" > /dev/null; done; fi
printf 'Loading database information...' >&2; sleep 0.3; echo ' done.' >&2
printf 'C\tread1\t9606\t150|150\t9606:1\n' > "$out"; printf '100.00\t1\t1\tR\t1\troot (%s)\n' "$out" > "$rep"
sleep 0.3
# FAKE_B_EXTRA: B classifies that many seconds longer (case B: a span that surely covers A's hashing).
case $out in */B/output) sleep "${FAKE_B_EXTRA:-0}" ;; esac
echo "10 sequences (0.00 Mbp) processed in 0.300s (2.0 Kseq/m, 0.00 Mbp/m)." >&2
echo "  5 sequences classified (50.00%)" >&2
exit 0
EOF
cat > "$TD/bin/fake-engine" << 'EOF'
#!/usr/bin/env bash
# A stand-in for the cohort-mode engine at rank 0 of 2: its timing lines, then one home sample (A,
# whose outputs it writes), one sample homed on rank 1 (B: a peer line here) and A's report.
o="$FAKE_OUT"
[ -n "${FAKE_ENVLOG:-}" ] && { mkdir -p "$FAKE_ENVLOG.d"; { printf 'args %s\n' "$(basename "$0") $*"; env | grep -vE '^(PWD|SHLVL|_|OLDPWD)=' | sed 's/^/env /'; } > "$FAKE_ENVLOG.d/$$"; }
tl() { printf 'ak2-timing\t%s\t%s\t%s\t0\t0\t0\t0\n' "$1" "$2" "$3" >&2; }
echo "Loading database information..." >&2
sleep 0.4; tl shard-load-0 0.1 0.4
sleep 0.4; printf 'ak2-engine\tetag\tetag\tx-2\tcomputed\tx-2\trequests\t1\n' >&2; tl etag 0.5 0.4
sleep 0.4; tl rendezvous 0.9 0.2; tl connect 1.1 0.1
mkdir -p "$o/A"; printf 'C\tA.1\t9606\n' > "$o/A/output"; printf 'report A\n' > "$o/A/report"
sleep 0.3
printf 'ak2-sample\tbatch\t0\tname\tA\tmode\tparallel\ts3client\t-\trank\t0\trole\thome\tinflight\t1\tthreads\t2\tstart_s\t1.2\twall_s\t0.3\tsetup_s\t0.01\tclassify_s\t0.25\tclose_s\t0.01\treport_s\t0.01\tstatus\t0\tsequences\t10\tbases\t3000\tclassified\t5\tplace\tmod\tweight\t10\n' >&2
printf 'ak2-sample\tbatch\t0\tname\tB\tmode\tparallel\ts3client\t-\trank\t0\trole\tpeer\tinflight\t1\tthreads\t2\tstart_s\t1.2\twall_s\t0.3\tsetup_s\t0\tclassify_s\t0\tclose_s\t0\treport_s\t0\tstatus\t0\tsequences\t0\tbases\t0\tclassified\t0\tplace\tmod\tweight\t20\n' >&2
exit 0
EOF
for g in real-gzip shim-gzip; do
  printf '#!/usr/bin/env bash\nfor a in "$@"; do :; done\necho "%s $(basename "$a")" >> "$FAKE_GZLOG"\n' "$g" > "$TD/bin/$g"
done
chmod +x "$TD/bin/"*
export PATH="$TD/bin:$PATH"

# The body's functions: its helpers line by line, lad_assign, and the marked block.
FN="$TD/fn.sh"
fnof() {  # NAME BODY: one function of the body, one-line or block
  awk -v n="$1" 'index($0, n "() {") == 1 { if ($0 ~ /}$/) { print; exit } p = 1 } p { print } p && /^}/ { exit }' "$2"
}
mkfn() {  # BODY: the functions the cases drive
  for f in now emit emit_sample lad_push lad_assign; do fnof "$f" "$1"; done
  sed -n '/^# ---- load and classify/,/^# ---- end of the functions/p' "$1"
}
mkfn "$BODY" > "$FN"
check "the body's marked block was found" "grep -q '^lad_watch() {' '$FN' && grep -q '^lad_one() {' '$FN' && grep -q '^lad_assign() {' '$FN'"

# The env a rung gives these functions, plus stand-ins for the preamble's and lever.sh's helpers.
setup_case() {  # NAME
  C="$TD/$1"; mkdir -p "$C/sd/done" "$C/sd/ack" "$C/sd/err" "$C/sd/start" "$C/out" "$C/in"
  export FAKE_LOG="$C/fake.log" FAKE_OUT="$C/out" FAKE_GZLOG="$C/gz.log"
  : > "$FAKE_LOG"; : > "$FAKE_GZLOG"
}
run_case() {  # NAME ENGINE OUT_UPLOAD UPSERIAL: the functions in a subshell, its stdout the "run log"
  local name=$1
  (
    W="$C"; SD="$C/sd"; OUTD="$C/out"; INDIR="$C/in"; DBDIR="$C/db"; J="$C/lad.jsonl"; LS="$C/lad-samples.jsonl"; LV_REC="$C/lever.jsonl"
    : > "$J"; : > "$LS"; : > "$LV_REC"
    AK2_MAIN_PID=$BASHPID; ENGINE=$2; OUT_UPLOAD=$3; UPSERIAL=$4
    RUNG=S9; ARM=S; COHORT=3; CLASSIFIER=upstream; K2=fake-k2; OURS=fake-engine; DECOMP=(); DB_LOAD=mmap; T=2
    SAMPLES=(A B C); PAIRS=(10 20 30); BYTES=(100 200 300); MINE=(0 1 2); PROCS=${CASE_PROCS:-2}; PLACEMENT=mod
    RANK=0; GROUP=0; SHARD=0; NPROC=2; GZMODE=gzip; GZK=""; OUTURL=s3://bucket/x/out/S9; ENGINE_ENV=(X=1)
    declare -A S5BAD=() IDSEC=() GZSHA=() RGSHA=() GZRC=() RGRC=()
    [ "$ENGINE" = 1 ] && { RUNG=O1; ARM=O; CLASSIFIER=ours-engine; MINE=(0 1); }
    [ "${CASE_CLASSIFIER:-}" = ours-plain ] && { RUNG=O0; ARM=O; CLASSIFIER=ours-plain; OURS=fake-k2; DECOMP=(AK2_DECOMPRESS=pipe); }
    ak2_phase() { echo "$1" >> "$C/phases.txt"; printf 'ak2-phase\t%s\n' "$1"; }
    ak2_say() { echo "ak2: $*"; }
    ak2_err() { echo "ERR $*" >> "$C/errors"; }
    ak2_push() { cp "$1" "$C/pushed-$2"; }
    lv_upload_enqueue() {  # sha256 at enqueue (as lever.sh); a serial session uploads before returning
      local te sha th t1
      te=$(now); sha=$(sha256sum "$1" | cut -d' ' -f1); sleep 0.1; th=$(now)   # the hash takes 0.1 s
      printf '{"kind":"upload-enqueue","t":%s,"local":"%s","url":"%s","sha256":"%s","sha256_seconds":%s}\n' "$th" "$1" "$2" "$sha" \
        "$(awk -v a="$te" -v b="$th" 'BEGIN{printf "%.3f", b - a}')" >> "$LV_REC"
      sleep 0.4; t1=$(now)
      [ "$UPSERIAL" = 1 ] && printf '{"kind":"upload","local":"%s","t_start":%s,"t_end":%s}\n' "$1" "$te" "$t1" >> "$LV_REC"
      echo "$te $t1 $1" >> "$C/uploads.log"
    }
    # shellcheck disable=SC1090
    . "${CASE_FN:-$FN}"
    if [ "${5:-}" = s5 ]; then
      GZMODE=rapidgzip-P2; GZK=2; S5BAD[B]=1; for s in A B C; do for m in 1 2; do GZSHA[${s}_$m.fastq.gz]=$(printf "%064d" $m); RGSHA[${s}_$m.fastq.gz]=$(printf "%064d" $m); done; done; RGSHA[B_2.fastq.gz]=$(printf "%064d" 9); REAL_GZIP="$TD/bin/real-gzip"; SHIMGZ="$TD/bin/shim-gzip"
      for s in A B C; do : > "$INDIR/${s}_1.fastq.gz"; : > "$INDIR/${s}_2.fastq.gz"; done
      lad_s5_fallback || echo "lad_s5_fallback failed"
      export FAKE_GZ=1
    fi
    CPIDS=()
    if [ "$ENGINE" = 1 ]; then lad_engine; else lad_lanes; fi
    lad_watch
    lad_push
    echo "case-end CRC=$CRC FAIL=$FAIL NDONE=$NDONE"
    echo "shacrit-sum=$SHACRIT_S"
  ) > "$C/run.log" 2>&1
}
samples() { sed -n 's/^lad-sample //p' "$C/run.log"; }
samplesof() { sed -n 's/^lad-sample //p' "$1"; }

# ---- A: per-sample path, serial uploads ----
setup_case A
run_case A 0 awscp-default 1
check "A: the run ended cleanly" "grep -q 'case-end CRC=0 FAIL=0 NDONE=3' '$C/run.log'"
for s in A B C; do
  check "A: $s's 'done.' line streamed into the run log" "grep -q '^\[S9 $s\] Loading database information... done.\$' '$C/run.log'"
  check "A: $s's 'processed in' line streamed" "grep -q '^\[S9 $s\] 10 sequences (0.00 Mbp) processed in 0.300s' '$C/run.log'"
done
check "A: each stderr file has its lines" "[ \$(cat '$C'/sd/err/* | grep -c 'processed in') = 3 ]"
check "A: phases: classify, opened by the watcher" "[ \"\$(cat '$C/phases.txt')\" = classify ]"
check "A: 3 lad-sample lines streamed" "[ \$(samples | wc -l) = 3 ]"
check "A: the pushed lad-samples.jsonl equals the streamed lines" "diff <(samples) '$C/pushed-lad-samples.jsonl' > /dev/null"
ok=1
for s in A B C; do
  o=$(sha256sum "$C/out/$s/output" | cut -d' ' -f1); r=$(sha256sum "$C/out/$s/report" | cut -d' ' -f1)
  samples | jq -e --arg s "$s" --arg o "$o" --arg r "$r" 'select(.accession == $s) | .v == 1 and .arm == "S" and .rung == "S9"
    and .cohort == 3 and .rc == 0 and .outputs.output.sha256 == $o and .outputs.report.sha256 == $r
    and (.outputs.output.bytes | type) == "number" and .phases.classify > 0.5 and .phases["classify-process"] == 0.3
    and .phases.upload > 0.9 and .s5.status == "n/a" and (.pairs | type) == "number"' > /dev/null || ok=0
done
check "A: every lad-sample has contract v1 fields, the files' sha256 and the serial upload's seconds" "[ $ok = 1 ]"
# Lane 0 runs A then C (j mod 2): C must start after A's last upload ended.
a_up_end=$(grep "/out/A/report" "$C/uploads.log" | awk '{print $2}')
c_start=$(grep "/out/C/output" "$C/fake.log" | awk '{print $1}')
check "A: serial: C started ($c_start) after A's uploads ended ($a_up_end)" "awk -v a='$a_up_end' -v c='$c_start' 'BEGIN{exit !(c >= a)}'"

# ---- B: overlap (the lane does not wait) ----
setup_case B
# B classifies 3 s longer than A and C: it starts with A, before A is done, and outlives all of the main
# shell's work on A (poll, two hashes, the stand-in upload: about 1 s), so A's hashes are covered.
FAKE_B_EXTRA=3 run_case B 0 s5cmd-overlap 0
check "B: the run ended cleanly" "grep -q 'case-end CRC=0 FAIL=0 NDONE=3' '$C/run.log'"
a_up_end=$(grep "/out/A/report" "$C/uploads.log" | awk '{print $2}')
c_start=$(grep "/out/C/output" "$C/fake.log" | awk '{print $1}')
check "B: overlap: C started ($c_start) before A's uploads ended ($a_up_end)" "awk -v a='$a_up_end' -v c='$c_start' 'BEGIN{exit !(c < a)}'"
# sha-critical is the part of a sample's hash that no classify span on the node covers.
lastcrit() {  # the last-finishing sample: its hash comes after every classify span, so all critical
  sed -n 's/^lad-sample //p' "$1" | jq -se 'max_by(.t_end) | .phases.sha > 0.15 and .phases["sha-critical"] == .phases.sha' > /dev/null
}
check "A: serial, 2 lanes: the last sample's hash is all critical" "lastcrit '$TD/A/run.log'"
check "B: overlap: the last sample's hash is all critical" "lastcrit '$TD/B/run.log'"
check "B: overlap: A, hashed while B still classified, has sha-critical 0" "samplesof '$TD/B/run.log' | jq -se '(map(select(.accession == \"A\"))[0] | .phases.sha > 0.15 and .phases[\"sha-critical\"] == 0) and (map(select(.accession == \"B\"))[0].t_end > (map(select(.accession == \"A\"))[0].t_end + 2))' > /dev/null"
# ---- S: one lane, serial: the lane is idle while each sample hashes, so every hash is critical ----
setup_case S
CASE_PROCS=1 run_case S 0 awscp-default 1
check "S: the run ended cleanly" "grep -q 'case-end CRC=0 FAIL=0 NDONE=3' '$C/run.log'"
check "S: one serial lane: every sample's sha-critical is all of its sha" "[ \$(samples | jq -s 'map(select(.phases[\"sha-critical\"] == .phases.sha and .phases.sha > 0.15)) | length') = 3 ]"
check "B: the node's sha-critical total (lad-net's share) is the sum of its samples'" "[ \"\$(sed -n 's/^shacrit-sum=//p' '$TD/B/run.log')\" = \"\$(samplesof '$TD/B/run.log' | jq -rs 'map(.phases[\"sha-critical\"]) | add * 1000 | round / 1000 | tostring' | awk '{printf \"%.3f\", \$1}')\" ]"
check "B: no upload seconds in an overlap lad-sample" "[ \$(samplesof '$TD/B/run.log' | jq -s 'map(select(.phases.upload != null)) | length') = 0 ]"

# ---- C: the engine path ----
setup_case C
run_case C 1 s5cmd-overlap 0
check "C: the run ended cleanly (one home sample)" "grep -q 'case-end CRC=0 FAIL=0 NDONE=1' '$C/run.log'"
check "C: phases etag-hash.k2d then classify" "[ \"\$(tr '\n' ' ' < '$C/phases.txt')\" = 'etag-hash.k2d classify ' ]"
check "C: the engine's ak2 lines streamed" "grep -q \$'^\\\\[O1\\\\] ak2-sample\\tbatch\\t0\\tname\\tA' '$C/run.log' && grep -q \$'^\\\\[O1\\\\] ak2-timing\\tconnect' '$C/run.log'"
check "C: one lad-sample, for the home sample A only" "[ \"\$(samples | jq -r .accession | tr '\n' ' ')\" = 'A ' ]"
check "C: its engine phases and arm O" "samples | jq -e '.arm == \"O\" and .phases[\"engine-classify\"] == 0.25 and .outputs.output.sha256 != null' > /dev/null"

# ---- F: the S5 fallback (sample B failed the identity phase) ----
setup_case F
run_case F 0 s5cmd-overlap 0 s5
check "F: the run ended cleanly" "grep -q 'case-end CRC=0 FAIL=0 NDONE=3' '$C/run.log'"
check "F: B's mates went to GNU gzip, nothing else did" "[ \"\$(grep '^real-gzip' '$C/gz.log' | sort | tr '\n' ' ')\" = 'real-gzip B_1.fastq.gz real-gzip B_2.fastq.gz ' ]"
check "F: A's and C's mates went to the shim" "[ \$(grep -c '^shim-gzip [AC]_[12].fastq.gz' '$C/gz.log') = 4 ] && ! grep -q '^shim-gzip B' '$C/gz.log'"
check "F: the fallback calls are logged" "[ \$(grep -c gzip-fallback '$C/s5fb/calls') = 2 ]"
check "F: B's lad-sample says differs, fallback gzip; A's identical at P 2" "samples | jq -se '(map(select(.accession == \"B\"))[0].s5 | .status == \"differs\" and .fallback == \"gzip\" and .P == 2)
  and (map(select(.accession == \"A\"))[0].s5 | .status == \"identical\" and .fallback == \"none\")' > /dev/null"
check "F: s5 carries both decompressors' per-mate sha256: equal for identical, unequal for differs" "samples | jq -se '
  (map(select(.accession == \"A\"))[0].s5 | (.gz_sha256 | length) == 2 and .gz_sha256 == .rg_sha256)
  and (map(select(.accession == \"B\"))[0].s5 | .gz_sha256 != .rg_sha256 and .gz_sha256[0] == .rg_sha256[0])' > /dev/null"
check "A: s5 is n/a, fallback none, no sha lists, when no shim is in use" "[ \$(sed -n 's/^lad-sample //p' '$TD/A/run.log' | jq -s 'map(select(.s5.status == \"n/a\" and .s5.fallback == \"none\" and .s5.gz_sha256 == null)) | length') = 3 ]"
for c in A B C F; do
  check "$c: every lad-sample has t_start <= t_end, epoch seconds to the ms" "[ \$(sed -n 's/^lad-sample //p' '$TD/$c/run.log' | jq -s 'map(select((.t_start | type) == \"number\" and .t_end >= .t_start and .t_start > 1.7e9
    and ([.t_start, .t_end] | map(tostring | split(\".\") | (.[1] // \"\") | length <= 3) | all))) | length') = \$(grep -c '^lad-sample ' '$TD/$c/run.log') ]"
done
check "F: phase seconds have at most 3 decimals" "samples | jq -se '[.[].phases[] | tostring | split(\".\") | (.[1] // \"\") | length <= 3] | all' > /dev/null"

# ---- U: lad_crit's covering spans: classify spans and uploads (NB1) ----
# One sample classified over [100, 200]; its hash is [250, 260]. Alone, all 10 s are critical.
# A finished upload over [245, 255] covers 5 s of it; an upload in flight since max(255, its
# enqueue at 257) covers the rest but 2 s.
setup_case U
crit_u() {  # MODE: none | done | inflight -> lad_crit's seconds
  (
    SD="$C/sd"; ENGINE=0; CPIDS=(); UPSERIAL=0
    . "$FN"
    printf '100\n' > "$SD/start/0"; printf '0 100 200 0\n' > "$SD/done/0"
    LV_UP_TSV=""; UPENQ_T=()
    if [ "$1" != none ]; then
      LV_UP_TSV="$C/uploads.tsv"; LV_UP_T0=0
      printf 'seq\tmode\tlocal\turl\tbytes\tsha256\tt_enqueue\tt_start\tt_end\trc\n1\ts5cmd-overlap\tx\ts3://b/x\t1\th\t240\t245\t255\t0\n' > "$LV_UP_TSV"
    fi
    if [ "$1" = inflight ]; then
      sleep 30 & LV_UP_PID=$!; LV_UP_LANE=1; LV_UP_N=2; UPENQ_T=(240 257)
    fi
    lad_crit 250 260
    [ -n "${LV_UP_PID:-}" ] && kill "$LV_UP_PID" 2> /dev/null
  )
}
check "U: no uploads: all 10 s of the hash are critical" "[ \"\$(crit_u none)\" = 10.000 ]"
check "U: a finished upload over [245, 255] leaves 5 s" "[ \"\$(crit_u done)\" = 5.000 ]"
check "U: plus an upload in flight from 257 leaves 2 s" "[ \"\$(crit_u inflight)\" = 2.000 ]"
# The engine path: its classify span is [CLS_T0, the exit lad_engine recorded in eng.end]. A hash
# after the recorded exit is critical even before the watch loop notices; with no eng.end yet the
# engine is running and covers it.
crit_e() {  # EXIT_T or "": lad_crit 250 260 on the engine path, classify from 100
  (
    W="$C"; SD="$C/sd"; ENGINE=1; CPIDS=(); CLS_T0=100; LV_UP_TSV=""; UPENQ_T=()
    . "$FN"
    rm -f "$W/eng.end"; [ -n "$1" ] && echo "$1" > "$W/eng.end"
    lad_crit 250 260
  )
}
check "U: engine exited at 200 (eng.end): a hash over [250, 260] is all critical" "[ \"\$(crit_e 200)\" = 10.000 ]"
check "U: engine exited at 255: 5 s critical" "[ \"\$(crit_e 255)\" = 5.000 ]"
check "U: engine still running (no eng.end): covered" "[ \"\$(crit_e '')\" = 0.000 ]"
check "C: lad_engine recorded the engine's exit (eng.end) after its last sample line" \
  "[ -s '$TD/C/eng.end' ] && awk -v e=\"\$(cat '$TD/C/eng.end')\" -v s=\"\$(sed -n 's/^lad-sample //p' '$TD/C/run.log' | jq -r .t_end)\" 'BEGIN{exit !(e >= s)}'"

# ---- I: the identity phase with a failing tool (B1) ----
# GNU gzip stands in as itself; the rapidgzip stand-in writes the same bytes but exits 3 on B_1,
# and writes nothing (exit 0) on C_2. A must be identical; B and C must differ and fall back, with
# the tools' real exit codes recorded.
setup_case I
cat > "$TD/bin/fake-rg" << 'EOF'
#!/usr/bin/env bash
for a in "$@"; do :; done
case $(basename "$a") in
  B_1.fastq.gz) gzip -dc "$a"; exit 3 ;;
  C_2.fastq.gz) exit 0 ;;
  F_1.fastq.gz) gzip -dc "$a" 2> /dev/null; exit 0 ;;   # the full stream, exit 0, past F_1's garbage tail
  *) exec gzip -dc "$a" ;;
esac
EOF
chmod +x "$TD/bin/fake-rg"
identity_run() {  # FN CASEDIR: lad_identity under the node's shell options (pipefail off: spawn's bash -e
  # payload runs `set +e` and nothing turns pipefail on), its output in CASEDIR/run.log
  local fn=$1 c=$2
  (
    set +o pipefail
    W="$c"; SD="$c/sd"; INDIR="$c/in"; J="$c/lad.jsonl"; LS="$c/lad-samples.jsonl"; : > "$J"; : > "$LS"
    SAMPLES=(A B C D E F); NEED=(0 1 2 3 4 5); NPROC=4; GZK=2; REAL_GZIP=$(command -v gzip); LV_RG="$TD/bin/fake-rg"; SHIMGZ="$TD/bin/shim-gzip"
    declare -A S5BAD=() IDSEC=() GZSHA=() RGSHA=() GZRC=() RGRC=()
    ak2_say() { echo "ak2: $*"; }
    ak2_push() { :; }
    . "$fn"
    echo "pipefail: $(set -o | awk '$1 == "pipefail" {print $2}')"
    for s in A B C D E F; do for m in 1 2; do printf '@r%s\nACGT\n+\nIIII\n' "$s$m" | gzip -c > "$INDIR/${s}_$m.fastq.gz"; done; done
    printf 'not a gzip stream' > "$INDIR/D_1.fastq.gz"   # GNU gzip fails on it: an input defect
    # A garbage tail: gzip warns (exit 2, the stream complete). E: the rapidgzip stand-in passes gzip's
    # exit 2 on (differs); F: it exits 0 with the same bytes (identical: gzip's warning alone is no difference).
    for s in E F; do printf 'trailing garbage\n' >> "$INDIR/${s}_1.fastq.gz"; done
    lad_identity; echo "identity-rc=$? bad=$(printf '%s\n' "${!S5BAD[@]}" | sort | tr '\n' ' ')"
  ) > "$c/run.log" 2>&1
}
b1_exit_ok() {  # CASEDIR: B_1's recorded exits are the tools' real ones
  sed -n 's/^lad-identity //p' "$1/run.log" | jq -e 'select(.file == "B_1.fastq.gz") | .rapidgzip_exit == 3 and .gzip_exit == 0' > /dev/null
}
identity_run "$FN" "$C"
ids() { sed -n 's/^lad-identity //p' "$C/run.log"; }
check "I: runs with pipefail off, as on the node" "grep -q '^pipefail: off\$' '$C/run.log'"
check "I: B, C, D and E differ, A and F do not" "grep -q 'identity-rc=0 bad=B C D E \$' '$C/run.log'"
check "I: E_1's garbage tail: gzip exit 2 is a warning (gz_warning), not an input defect; rapidgzip's exit 2 differs" \
  "ids | jq -e 'select(.file == \"E_1.fastq.gz\") | .gzip_exit == 2 and .gz_warning == true and .input_defect == false and .identical == false and .rapidgzip_exit == 2' > /dev/null"
check "I: F_1: gzip exit 2 with rapidgzip's equal stream and exit 0 is identical" \
  "ids | jq -e 'select(.file == \"F_1.fastq.gz\") | .gzip_exit == 2 and .gz_warning == true and .input_defect == false and .identical == true' > /dev/null"
check "I: B_1's rapidgzip exit is the tool's real 3, its gzip exit 0" "ids | jq -e 'select(.file == \"B_1.fastq.gz\") | .rapidgzip_exit == 3 and .gzip_exit == 0 and .identical == false' > /dev/null"
check "I: C_2's empty output differs (exit 0, the empty-stream sha256)" "ids | jq -e 'select(.file == \"C_2.fastq.gz\") | .rapidgzip_exit == 0 and .identical == false
  and .rapidgzip_sha256 == \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\" and (.why | test(\"empty output\"))' > /dev/null"
check "I: A's mates are identical with both exits 0" "[ \$(ids | jq -s 'map(select((.file | startswith(\"A_\")) and .identical and .gzip_exit == 0 and .rapidgzip_exit == 0)) | length') = 2 ]"
check "I: the fallback was installed for B, C, D and E" "[ -x '$C/s5fb/gzip' ] && [ \$(grep -c . '$C/s5fb/inputs') = 8 ]"
check "I: GNU gzip failing on D_1 is an input defect; no other input is" "[ \$(ids | jq -s 'map(select(.input_defect)) | map(.file) | join(\" \")') = '\"D_1.fastq.gz\"' ]"
# Mutation (T1): restore B1's bug (PIPESTATUS read outside the substitution) in a copy of the body;
# the exit check must then fail, so case I can tell the fix from the bug.
sed 's/; exit "\${PIPESTATUS\[0\]}"); \([gh]r\)=\$?/); \1=${PIPESTATUS[0]}/' "$BODY" > "$TD/body-b1bug.sh"
check "I-mut: the mutation restored the old form on both tools' lines" "[ \$(grep -c '); [gh]r=\${PIPESTATUS\[0\]}' '$TD/body-b1bug.sh') = 2 ]"
mkfn "$TD/body-b1bug.sh" > "$TD/fn-b1bug.sh"
setup_case Imut
identity_run "$TD/fn-b1bug.sh" "$C"
check "I-mut: with the old bug, B_1's exit check fails (the probe resolves it)" "! b1_exit_ok '$C'"
check "I: with the fix, B_1's exit check passes" "b1_exit_ok '$TD/I'"

# ---- P: ours' plain path under a cohort node's env (O0 at c1, 843e958) ----
# make run gives every cohort node AK2_ENGINE_N/RANK/RENDEZVOUS; ours takes the engine path (a
# resident copy of the table, --memory-mapping ignored) whenever AK2_ENGINE_N is set. lad_one must
# run ours' plain path without them, and keep --memory-mapping and AK2_DECOMPRESS.
penv() {  # CASE FN: case P's ours-plain lanes with the node's engine env exported
  setup_case "$1"; export FAKE_ENVLOG="$C/env.log"; : > "$FAKE_ENVLOG"
  ( export AK2_ENGINE_N=1 AK2_ENGINE_RANK=0 AK2_ENGINE_RENDEZVOUS=s3://b/x/rendezvous AK2_COHORT_ID=x
    CASE_CLASSIFIER=ours-plain CASE_FN=$2 run_case "$1" 0 awscp-default 1 )
  cat "$FAKE_ENVLOG.d"/* > "$C/env.log" 2> /dev/null
  unset FAKE_ENVLOG
}
penv P "$FN"
check "P: the run ended cleanly" "grep -q 'case-end CRC=0 FAIL=0 NDONE=3' '$C/run.log'"
check "P: ours' plain path ran 3 times, each with --memory-mapping" "[ \$(grep -c '^args fake-k2 .*--memory-mapping' '$C/env.log') = 3 ]"
check "P: it kept AK2_DECOMPRESS=pipe" "[ \$(grep -c '^env AK2_DECOMPRESS=pipe\$' '$C/env.log') = 3 ]"
check "P: it saw no AK2_ENGINE_* or AK2_COHORT" "! grep -qE '^env AK2_(ENGINE_|COHORT=)' '$C/env.log'"
# Mutation: without the strip (lad_one at 843e958) the same probe must see AK2_ENGINE_N.
sed 's/cmd=(env "\${noeng\[@\]}" /cmd=(env /' "$BODY" > "$TD/body-engenv.sh"
check "P-mut: the mutation removed the strip" "! grep -q 'noeng\[@\]' '$TD/body-engenv.sh'"
mkfn "$TD/body-engenv.sh" > "$TD/fn-engenv.sh"
penv Pmut "$TD/fn-engenv.sh"
check "P-mut: without the strip ours' plain path sees AK2_ENGINE_N=1 (the probe resolves it)" "[ \$(grep -c '^env AK2_ENGINE_N=1\$' '$C/env.log') = 3 ]"

# ---- X: every scripts/g3/ladder.body-compat.tsv row, by behaviour ----
# Both body versions a row names, each classifier under a cohort node's env (as P). For each
# unaffected classifier the two must agree on:
#   - the invocations: argv and the whole environment (less PWD, SHLVL, _ and OLDPWD);
#   - the body's records around them: the phase markers (ak2_phase, lad-phase), the lad-sample lines'
#     field set with accession, rung, arm and rc, the per-sample done records' rc, and the case's
#     CRC/FAIL/NDONE (rc handling). Times and sha256s are volatile and not compared.
# For each affected classifier the invocations must differ (the probe resolves the change it declares
# harmless). ladder_body_compat.py check confines a row's changes to this block, inside the row's
# functions, so this probe covers them; X-mut shows each comparison fails on a planted difference.
xrec() {  # CASE DIR: the run's records, normalised, into DIR/rec.norm
  local c=$1
  { echo "phases: $(tr '\n' ' ' < "$c/phases.txt" 2> /dev/null)"
    sed -n 's/^lad-phase //p' "$c/run.log" | jq -c '{phase, how}' | sed 's/^/lad-phase /'
    sed -n 's/^lad-sample //p' "$c/run.log" | jq -c '{accession, rung, arm, classifier, rc, fields: ([paths(scalars) | map(tostring) | join(".")] | sort)}' | sort | sed 's/^/lad-sample /'
    for f in "$c"/sd/done/*; do [ -f "$f" ] && echo "done $(basename "$f") rc $(awk '{print $1}' "$f")"; done | sort
    grep '^case-end ' "$c/run.log"
  } > "$c/rec.norm"
}
xprobe() {  # CASE FN CLASSIFIER: the classifier invocations, normalised, into $C/env.norm; records into $C/rec.norm
  setup_case "$1"; export FAKE_ENVLOG="$C/env.log"; : > "$FAKE_ENVLOG"
  cp "$2" "$TD/fn-xprobe.sh"   # one path for every version: CASE_FN reaches the classifier's env
  ( export AK2_ENGINE_N=1 AK2_ENGINE_RANK=0 AK2_ENGINE_RENDEZVOUS=s3://b/x/rendezvous AK2_COHORT_ID=x
    case $3 in
      upstream) CASE_FN=$TD/fn-xprobe.sh run_case "$1" 0 awscp-default 1 ;;
      ours-plain) CASE_CLASSIFIER=ours-plain CASE_FN=$TD/fn-xprobe.sh run_case "$1" 0 awscp-default 1 ;;
      ours-engine) CASE_FN=$TD/fn-xprobe.sh run_case "$1" 1 s5cmd-overlap 0 ;;
    esac )
  unset FAKE_ENVLOG
  # one line per invocation: its argv and env lines, the case dir normalised, sorted within it
  for f in "$C/env.log.d"/*; do [ -f "$f" ] && { sed "s#$C#C#g" "$f" | LC_ALL=C sort | tr '\n' '\036'; echo; }; done | LC_ALL=C sort > "$C/env.norm"
  xrec "$C"
}
XN=0
while IFS=$'\t' read -r xf xt xun xaff; do
  XN=$((XN + 1))
  for v in "$xf" "$xt"; do
    python3 "$ROOT/scripts/lib/ladder_body_compat.py" body-at "$v" > "$TD/body-$v.sh" ||
      { bad "X$XN: body ${v:0:12} is not in git history (CI needs fetch-depth 0)"; continue 2; }
    mkfn "$TD/body-$v.sh" > "$TD/fn-$v.sh"
  done
  for cl in ${xun//,/ } ${xaff//,/ }; do
    xprobe "X$XN-$cl-from" "$TD/fn-$xf.sh" "$cl"; a="$C/env.norm"; ra="$C/rec.norm"
    xprobe "X$XN-$cl-to" "$TD/fn-$xt.sh" "$cl"; b="$C/env.norm"; rb="$C/rec.norm"
    check "X$XN ($cl): the probe saw the classifier run, and its records" "grep -q '^args ' '$a' && grep -q '^args ' '$b' && grep -q '^lad-sample ' '$ra' && grep -q '^case-end ' '$ra'"
    case ",$xun," in
      *",$cl,"*)
        check "X$XN ${xf:0:12} -> ${xt:0:12}: $cl (declared unaffected) runs with the same argv and whole env" "cmp -s '$a' '$b'"
        check "X$XN ${xf:0:12} -> ${xt:0:12}: $cl (declared unaffected) leaves the same phase markers, lad-sample fields and rc handling" "cmp -s '$ra' '$rb'" ;;
      *) check "X$XN ${xf:0:12} -> ${xt:0:12}: $cl (declared affected) runs differently" "! cmp -s '$a' '$b'" ;;
    esac
  done
done < <(python3 "$ROOT/scripts/lib/ladder_body_compat.py" rows)
check "X: ladder.body-compat.tsv has rows to probe" "[ $XN -gt 0 ]"
# X-mut: the comparisons resolve. On the current body, upstream: one extra env var for the
# classifier must change the env comparison; a done record that writes rc 1 must change the records.
xmut() {  # OUT OLD NEW: the body with one exact replacement
  python3 -c 'import sys; o, a, b = sys.argv[1:4]; s = open(sys.argv[4]).read(); assert s.count(a) == 1, a; open(o, "w").write(s.replace(a, b))' "$@" "$BODY"
}
xmut "$TD/body-xenv.sh" '  local -a cmd=("$K2") noeng=()' '  local -a cmd=(env AK2_XMUT=1 "$K2") noeng=()'
xmut "$TD/body-xrc.sh" "  printf '%s %s %s %s\n' \"\$rc\" \"\$t0\"" "  printf '%s %s %s %s\n' 1 \"\$t0\""
check "X-mut: both mutations applied" "! cmp -s '$BODY' '$TD/body-xenv.sh' && ! cmp -s '$BODY' '$TD/body-xrc.sh'"
mkfn "$BODY" > "$TD/fn-xcur.sh"; mkfn "$TD/body-xenv.sh" > "$TD/fn-xenv.sh"; mkfn "$TD/body-xrc.sh" > "$TD/fn-xrc.sh"
xprobe Xm-cur "$TD/fn-xcur.sh" upstream; mca="$C/env.norm"; mcr="$C/rec.norm"
xprobe Xm-env "$TD/fn-xenv.sh" upstream
check "X-mut: an extra env var for upstream's invocation fails the env comparison" "! cmp -s '$mca' '$C/env.norm'"
xprobe Xm-rc "$TD/fn-xrc.sh" upstream
check "X-mut: a done record with another rc fails the record comparison" "! cmp -s '$mcr' '$C/rec.norm'"

# ---- N: negative control ----
setup_case N
( fake-k2 --output "$C/out/o" --report "$C/out/r" > /dev/null 2> >(tee "$C/neg.err" | sed -u 's/^/[neg] /'); sleep 1 ) > "$C/run.log" 2>&1
check "N: the reverse order streams nothing" "! grep -q '^\[neg\]' '$C/run.log'"
check "N: while its file has every line" "grep -q 'processed in' '$C/neg.err'"

echo "ladder-stream-test: $NF failure(s)"
[ "$NF" = 0 ]
