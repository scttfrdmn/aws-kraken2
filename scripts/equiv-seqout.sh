#!/usr/bin/env bash
# Oracle equivalence for internal/seqio + internal/seqout (issues #12, #16). Runs upstream kraken2
# at the pin on real reads against the Viral DB with --output, --classified-out and
# --unclassified-out, then runs the Go tests that rebuild the classified/unclassified files from
# upstream's --output and byte-compare them, and that compare seqio's decompressed bytes with
# what the wrapper's `gzip -dc` / `bzip2 -dc` hand to classify. See docs/equiv-seqout.md.
# Usage: scripts/equiv-seqout.sh [reads-stem [extra-stem...]]
#   default stem .cache/reads/SRR062634_200000 (all cases); extra stems (default ERR478965_200000
#   when fetched) get the plain/gzip single-end and paired FASTQ cases.
# Exits non-zero if any upstream run exits other than its case expects, if fewer cases ran than
# expected, or if a Go test fails.
set +e
echo "shell flags: $-"
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
. scripts/pin.env
MAIN=${K2_MAIN:-$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##')}
K2DIR="$MAIN/.oracle/$UPSTREAM_PIN"
K2="$K2DIR/kraken2"
DB=${K2_DB:-$MAIN/.cache/db/k2_viral_20260626}
STEM=${1:-$MAIN/.cache/reads/SRR062634_200000}
[ $# -gt 0 ] && shift
EXTRA=("$@")
if [ $# -eq 0 ] && [ -s "$MAIN/.cache/reads/ERR478965_200000.SOURCE" ]; then
  EXTRA=("$MAIN/.cache/reads/ERR478965_200000")
fi
# DECOMP_BIN: a directory holding the gzip/bzip2 to use (both here and in upstream's wrapper,
# which finds them on PATH). The canonical platform's are GNU gzip and bzip2 1.0.x; on macOS,
# /usr/bin/gzip is Apple's, which truncates its output differently on a damaged stream.
[ -n "$DECOMP_BIN" ] && export PATH="$DECOMP_BIN:$PATH"
THREADS=${THREADS:-4}
DATE=$(date -u +%F)
WORK="$MAIN/.cache/equiv-seqout/$DATE"
RES="$ROOT/results/g1/seqio-seqout-$DATE"
for f in "$K2" "$K2DIR/classify" "$DB/hash.k2d" "${STEM}_1.fq" "${STEM}_2.fq" "${STEM}_1.fq.gz" "${STEM}_2.fq.gz"; do
  [ -e "$f" ] || { echo "equiv-seqout: missing $f (make oracle / scripts/fetch-db.sh / scripts/fetch-reads.sh)" >&2; exit 1; }
done
rm -rf "$WORK" "$RES"
mkdir -p "$WORK" "$RES"
LOG="$RES/run.log"
: > "$LOG"
log() { echo "$*" | tee -a "$LOG"; }
log "shell flags: $-"
log "pin $UPSTREAM_PIN  db $DB  reads $STEM  threads $THREADS  work $WORK"
FAILED=0

# Inputs derived from the real reads (reformatted, recompressed or damaged with standard tools).
W=$WORK
for m in 1 2; do
  R="${STEM}_$m.fq"
  awk 'NR%4==1{print ">" substr($0,2)} NR%4==2{print}' "$R" > "$W/r_$m.fa"
  awk 'NR%4==1{print ">" substr($0,2)} NR%4==2{s=$0; while(length(s)>60){print substr(s,1,60); s=substr(s,61)} print s}' \
    "$R" > "$W/r_$m.wrap.fa"
  gzip -nc "$W/r_$m.wrap.fa" > "$W/r_$m.wrap.fa.gz"
  # CRLF line ends; and the mate suffix moved into the identifier with a tab before the comment.
  awk '{printf "%s\r\n", $0}' "$R" > "$W/r_$m.crlf.fq"
  awk -v m="$m" 'NR%4==1{sp=index($0," "); c=substr($0,sp+1); sub(/\/[12]$/,"",c); print substr($0,1,sp-1) "/" m "\t" c; next} {print}' \
    "$R" > "$W/r_$m.slash.fq"
  bzip2 -c "$R" > "$W/r_$m.fq.bz2"
  # Two gzip members, concatenated.
  { head -n 400000 "$R" | gzip -nc; tail -n +400001 "$R" | gzip -nc; } > "$W/r_$m.multi.fq.gz"
done
R1="${STEM}_1.fq"; R2="${STEM}_2.fq"; N=$(( $(wc -l < "$R1") / 4 ))
{ cat "$R1.gz"; head -c 4096 /dev/zero; } > "$W/r_1.zeropad.fq.gz"
{ cat "$R1.gz"; printf 'trailing garbage\n'; } > "$W/r_1.garbage.fq.gz"
head -c $(( $(wc -c < "$R1.gz") / 2 )) "$R1.gz" > "$W/r_1.trunc.fq.gz"
{ cat "$W/r_1.fq.bz2"; printf 'trailing garbage\n'; } > "$W/r_1.garbage.fq.bz2"
# Malformed: record 1000's quality one short, record 2000's one long.
awk 'NR==4000{print substr($0,1,length($0)-1); next} NR==8000{print $0 "I"; next} {print}' "$R1" > "$W/r_1.malformed.fq"
head -n $(( 4 * (N - 10) )) "$R2" > "$W/r_2.short.fq"
head -n $(( 4 * (N - 10) )) "$R1" > "$W/r_1.short.fq"
: > "$W/empty.fq"
perl -pe 'chomp if eof' "$R1" > "$W/r_1.nonl.fq"
perl -pe 'chomp if eof' "$W/r_1.wrap.fa" > "$W/r_1.nonl.wrap.fa"

# What the wrapper's decompressors hand to classify, for the seqio decompression test.
: > "$W/decomp.tsv"
dc() { # dc <gzip|bzip2> <file>
  local out
  out="$W/dc.$(basename "$2").out"
  "$1" -dc "$2" > "$out" 2> "$out.stderr"
  local st=$?
  log "$1 -dc $(basename "$2"): exit $st $(head -c 200 "$out.stderr" | tr '\n' ' ')"
  printf '%s\t%s\t%s\n' "$1" "$2" "$out" >> "$W/decomp.tsv"
}
dc gzip "$R1.gz"; dc gzip "$W/r_1.multi.fq.gz"; dc gzip "$W/r_1.zeropad.fq.gz"
dc gzip "$W/r_1.garbage.fq.gz"; dc gzip "$W/r_1.trunc.fq.gz"; dc gzip "$R1"
dc bzip2 "$W/r_1.fq.bz2"; dc bzip2 "$W/r_1.garbage.fq.bz2"

: > "$W/cases.tsv"
: > "$RES/commands.txt"
CASES=0
# run <name> <expected exit> <paired 0/1> <none|gz|bz2 flag> <minq> <inputs...>
run() {
  local name=$1 want=$2 paired=$3 comp=$4 minq=$5; shift 5
  local cls uncls flags=()
  CASES=$((CASES + 1))
  if [ "$paired" = 1 ]; then cls="$W/$name.cls#.seq"; uncls="$W/$name.uncls#.seq"; flags+=(--paired)
  else cls="$W/$name.cls.seq"; uncls="$W/$name.uncls.seq"; fi
  [ "$comp" = gz ] && flags+=(--gzip-compressed)
  [ "$comp" = bz2 ] && flags+=(--bzip2-compressed)
  [ "$minq" != 0 ] && flags+=(--minimum-base-quality "$minq")
  local cmd=("$K2" --db "$DB" --threads "$THREADS" "${flags[@]}" --output "$W/$name.kraken"
             --classified-out "$cls" --unclassified-out "$uncls" "$@")
  echo "${cmd[*]}" >> "$RES/commands.txt"
  "${cmd[@]}" 2> "$W/$name.stderr"
  local st=$?
  log "$name: upstream exit $st (expected $want); $(tr '\r' '\n' < "$W/$name.stderr" | grep -E 'processed|classified|records' | tr -s ' ' | paste -sd' ' - | head -c 400)"
  if [ "$st" != "$want" ]; then
    log "FAIL $name: upstream exit $st, case expects $want"; FAILED=1; return
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$name" "$paired" "$comp" "$minq" "$st" \
    "$W/$name.kraken" "$cls" "$uncls" "$W/$name.stderr" >> "$W/cases.tsv"
  printf '\t%s' "$@" >> "$W/cases.tsv"
  echo >> "$W/cases.tsv"
}
run se_fq_plain             0  0 none 0  "$R1"
run se_fq_gz_auto           0  0 none 0  "$R1.gz"
run se_fq_gz_flag           0  0 gz   0  "$R1.gz"
run pe_fq_plain             0  1 none 0  "$R1" "$R2"
run pe_fq_gz_auto           0  1 none 0  "$R1.gz" "$R2.gz"
run se_fq_q20               0  0 none 20 "$R1"
run pe_fq_gz_q20            0  1 none 20 "$R1.gz" "$R2.gz"
run se_fa                   0  0 none 0  "$W/r_1.fa"
run se_fa_wrap              0  0 none 0  "$W/r_1.wrap.fa"
run pe_fa_wrap_gz           0  1 none 0  "$W/r_1.wrap.fa.gz" "$W/r_2.wrap.fa.gz"
run pe_fa_plain             0  1 none 0  "$W/r_1.fa" "$W/r_2.fa"
run se_fq_crlf              0  0 none 0  "$W/r_1.crlf.fq"
run pe_fq_crlf              0  1 none 0  "$W/r_1.crlf.fq" "$W/r_2.crlf.fq"
run pe_fq_slash_tab         0  1 none 0  "$W/r_1.slash.fq" "$W/r_2.slash.fq"
run se_fq_gz_multimember    0  0 none 0  "$W/r_1.multi.fq.gz"
run pe_fq_gz_multimember    0  1 none 0  "$W/r_1.multi.fq.gz" "$W/r_2.multi.fq.gz"
run se_fq_gz_zeropad        0  0 none 0  "$W/r_1.zeropad.fq.gz"
run se_fq_gz_garbage        0  0 none 0  "$W/r_1.garbage.fq.gz"
run se_fq_gz_truncated      0  0 none 0  "$W/r_1.trunc.fq.gz"
run se_fq_gzflag_on_plain   0  0 gz   0  "$R1"
run se_fq_bz2_auto          0  0 none 0  "$W/r_1.fq.bz2"
run se_fq_bz2_flag          0  0 bz2  0  "$W/r_1.fq.bz2"
run pe_fq_bz2_auto          0  1 none 0  "$W/r_1.fq.bz2" "$W/r_2.fq.bz2"
run se_fq_bz2_garbage       0  0 none 0  "$W/r_1.garbage.fq.bz2"
run se_fq_malformed         65 0 none 0  "$W/r_1.malformed.fq"
run pe_fq_mate2_short       65 1 none 0  "$R1" "$W/r_2.short.fq"
run pe_fq_mate1_short       65 1 none 0  "$W/r_1.short.fq" "$R2"
run se_empty                0  0 none 0  "$W/empty.fq"
run se_fq_no_final_newline  0  0 none 0  "$W/r_1.nonl.fq"
run se_fa_no_final_newline  0  0 none 0  "$W/r_1.nonl.wrap.fa"
for X in "${EXTRA[@]}"; do
  A=$(basename "$X" | cut -d_ -f1)
  log "extra sample: $X ($(tr '\n' ' ' < "$X.SOURCE"))"
  run "${A}_se_fq_plain"    0 0 none 0 "${X}_1.fq"
  run "${A}_se_fq_gz_auto"  0 0 none 0 "${X}_1.fq.gz"
  run "${A}_pe_fq_plain"    0 1 none 0 "${X}_1.fq" "${X}_2.fq"
  run "${A}_pe_fq_gz_auto"  0 1 none 0 "${X}_1.fq.gz" "${X}_2.fq.gz"
done
EXPECTED=$(( 30 + 4 * ${#EXTRA[@]} ))
GOT=$(wc -l < "$W/cases.tsv" | tr -d ' ')
log "cases: $GOT recorded, $CASES run, $EXPECTED expected"
if [ "$GOT" != "$EXPECTED" ] || [ "$CASES" != "$EXPECTED" ]; then log "FAIL: case count"; FAILED=1; fi

K2_SEQOUT_ORACLE="$W" K2_SEQOUT_SUMMARY="$RES/summary.tsv" K2_SEQOUT_EXPECTED_CASES="$EXPECTED" \
  go test -count=1 -v -run TestOracleSeqout ./internal/seqout/ 2>&1 | tee -a "$LOG"
st=${PIPESTATUS[0]}
log "go test seqout exit $st"
[ "$st" = 0 ] || FAILED=1
K2_DECOMP_ORACLE="$W/decomp.tsv" K2_DECOMP_SUMMARY="$RES/decompress.tsv" \
  go test -count=1 -v -run TestOracleDecompress ./internal/seqio/ 2>&1 | tee -a "$LOG"
st=${PIPESTATUS[0]}
log "go test seqio exit $st"
[ "$st" = 0 ] || FAILED=1
RESULT=$( [ "$FAILED" = 0 ] && echo PASS || echo FAIL )
log "result: $RESULT"

{ echo "{"
  echo "  \"what\": \"seqio+seqout oracle equivalence (issues #12, #16)\","
  echo "  \"result\": \"$RESULT\","
  echo "  \"cases\": $GOT,"
  echo "  \"commit\": \"$(git rev-parse HEAD)\","
  echo "  \"dirty\": $( [ -n "$(git status --porcelain -- . ':!results')" ] && echo true || echo false ),"
  echo "  \"upstream_pin\": \"$UPSTREAM_PIN\","
  echo "  \"classify_sha256\": \"$(shasum -a 256 "$K2DIR/classify" | cut -d' ' -f1)\","
  echo "  \"go_version\": \"$(go version)\","
  echo "  \"gzip_version\": \"$(gzip --version 2>&1 | head -1 | sed 's/"/\\"/g')\","
  echo "  \"bzip2_version\": \"$(bzip2 --help 2>&1 | head -1 | sed 's/"/\\"/g')\","
  echo "  \"host\": \"$(uname -srm)\","
  echo "  \"canonical_platform\": \"Linux aarch64; this host is $( [ "$(uname -s)/$(uname -m)" = Linux/aarch64 ] && echo canonical || echo development-only )\","
  echo "  \"date_utc\": \"$(date -u +%FT%TZ)\","
  echo "  \"threads\": $THREADS,"
  echo "  \"db\": \"$(basename "$DB")\","
  echo "  \"db_source\": \"$(tr '\n' ';' < "$DB/SOURCE" | sed 's/"/\\"/g')\","
  echo "  \"reads_source\": \"$(tr '\n' ';' < "${STEM}.SOURCE")\","
  echo "  \"extra_reads_source\": ["
  for X in "${EXTRA[@]}"; do echo "    \"$(tr '\n' ';' < "$X.SOURCE")\","; done | sed '$ s/,$//'
  echo "  ]"
  echo "}"; } > "$RES/manifest.json"
exit "$FAILED"
