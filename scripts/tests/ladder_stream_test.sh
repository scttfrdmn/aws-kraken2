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
out="" rep="" in=()
while [ $# -gt 0 ]; do case $1 in --output) out=$2; shift 2 ;; --report) rep=$2; shift 2 ;; --db|--threads) shift 2 ;; -*) shift ;; *) in+=("$1"); shift ;; esac; done
echo "$(perl -MTime::HiRes=time -e 'printf "%.3f", time') start $out" >> "$FAKE_LOG"
# As upstream's wrapper: one `gzip -dc FILE` per mate, found on PATH.
if [ "${FAKE_GZ:-0}" = 1 ]; then for f in "${in[@]}"; do gzip -dc "$f" > /dev/null; done; fi
printf 'Loading database information...' >&2; sleep 0.3; echo ' done.' >&2
printf 'C\tread1\t9606\t150|150\t9606:1\n' > "$out"; printf '100.00\t1\t1\tR\t1\troot (%s)\n' "$out" > "$rep"
sleep 0.3
echo "10 sequences (0.00 Mbp) processed in 0.300s (2.0 Kseq/m, 0.00 Mbp/m)." >&2
echo "  5 sequences classified (50.00%)" >&2
exit 0
EOF
cat > "$TD/bin/fake-engine" << 'EOF'
#!/usr/bin/env bash
# A stand-in for the cohort-mode engine at rank 0 of 2: its timing lines, then one home sample (A,
# whose outputs it writes), one sample homed on rank 1 (B: a peer line here) and A's report.
o="$FAKE_OUT"
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
fnof() {  # NAME: one function of the body, one-line or block
  awk -v n="$1" 'index($0, n "() {") == 1 { if ($0 ~ /}$/) { print; exit } p = 1 } p { print } p && /^}/ { exit }' "$BODY"
}
{
  for f in now emit emit_sample lad_push lad_assign; do fnof "$f"; done
  sed -n '/^# ---- load and classify/,/^# ---- end of the functions/p' "$BODY"
} > "$FN"
check "the body's marked block was found" "grep -q '^lad_watch() {' '$FN' && grep -q '^lad_one() {' '$FN' && grep -q '^lad_assign() {' '$FN'"

# The env a rung gives these functions, plus stand-ins for the preamble's and lever.sh's helpers.
setup_case() {  # NAME
  C="$TD/$1"; mkdir -p "$C/sd/done" "$C/sd/ack" "$C/sd/err" "$C/out" "$C/in"
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
    SAMPLES=(A B C); PAIRS=(10 20 30); BYTES=(100 200 300); MINE=(0 1 2); PROCS=2; PLACEMENT=mod
    RANK=0; GROUP=0; SHARD=0; NPROC=2; GZMODE=gzip; GZK=""; OUTURL=s3://bucket/x/out/S9; ENGINE_ENV=(X=1)
    declare -A S5BAD=() IDSEC=() GZSHA=() RGSHA=()
    [ "$ENGINE" = 1 ] && { RUNG=O1; ARM=O; CLASSIFIER=ours-engine; MINE=(0 1); }
    ak2_phase() { echo "$1" >> "$C/phases.txt"; printf 'ak2-phase\t%s\n' "$1"; }
    ak2_say() { echo "ak2: $*"; }
    ak2_err() { echo "ERR $*" >> "$C/errors"; }
    ak2_push() { cp "$1" "$C/pushed-$2"; }
    lv_upload_enqueue() {  # sha256 at enqueue (as lever.sh); a serial session uploads before returning
      local te sha t1
      te=$(now); sha=$(sha256sum "$1" | cut -d' ' -f1)
      printf '{"kind":"upload-enqueue","local":"%s","url":"%s","sha256":"%s","sha256_seconds":0.01}\n' "$1" "$2" "$sha" >> "$LV_REC"
      sleep 0.5; t1=$(now)
      [ "$UPSERIAL" = 1 ] && printf '{"kind":"upload","local":"%s","t_start":%s,"t_end":%s}\n' "$1" "$te" "$t1" >> "$LV_REC"
      echo "$te $t1 $1" >> "$C/uploads.log"
    }
    # shellcheck disable=SC1090
    . "$FN"
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
  ) > "$C/run.log" 2>&1
}
samples() { sed -n 's/^lad-sample //p' "$C/run.log"; }

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
run_case B 0 s5cmd-overlap 0
check "B: the run ended cleanly" "grep -q 'case-end CRC=0 FAIL=0 NDONE=3' '$C/run.log'"
a_up_end=$(grep "/out/A/report" "$C/uploads.log" | awk '{print $2}')
c_start=$(grep "/out/C/output" "$C/fake.log" | awk '{print $1}')
check "B: overlap: C started ($c_start) before A's uploads ended ($a_up_end)" "awk -v a='$a_up_end' -v c='$c_start' 'BEGIN{exit !(c < a)}'"
check "B: no upload seconds in an overlap lad-sample" "[ \$(samples | jq -s 'map(select(.phases.upload != null)) | length') = 0 ]"

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

# ---- N: negative control ----
setup_case N
( fake-k2 --output "$C/out/o" --report "$C/out/r" > /dev/null 2> >(tee "$C/neg.err" | sed -u 's/^/[neg] /'); sleep 1 ) > "$C/run.log" 2>&1
check "N: the reverse order streams nothing" "! grep -q '^\[neg\]' '$C/run.log'"
check "N: while its file has every line" "grep -q 'processed in' '$C/neg.err'"

echo "ladder-stream-test: $NF failure(s)"
[ "$NF" = 0 ]
