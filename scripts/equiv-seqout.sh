#!/usr/bin/env bash
# Oracle equivalence for internal/seqio + internal/seqout (issues #12, #16). Runs upstream kraken2
# at the pin on real reads against the Viral DB with --output, --classified-out and
# --unclassified-out, then runs the Go test that rebuilds the classified/unclassified files from
# upstream's --output and byte-compares them. See docs/equiv-seqout.md.
# Usage: scripts/equiv-seqout.sh [reads-stem [extra-stem...]]
#   default stem .cache/reads/SRR062634_200000 (all cases); extra stems (default ERR478965_200000
#   when fetched) get the plain/gzip single-end and paired FASTQ cases.
set +e
echo "shell flags: $-"
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
. scripts/pin.env
MAIN=${K2_MAIN:-$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##')}
K2="$MAIN/.oracle/$UPSTREAM_PIN/kraken2"
DB=${K2_DB:-$MAIN/.cache/db/k2_viral_20260626}
STEM=${1:-$MAIN/.cache/reads/SRR062634_200000}
[ $# -gt 0 ] && shift
EXTRA=("$@")
if [ $# -eq 0 ] && [ -s "$MAIN/.cache/reads/ERR478965_200000.SOURCE" ]; then
  EXTRA=("$MAIN/.cache/reads/ERR478965_200000")
fi
THREADS=${THREADS:-4}
DATE=$(date -u +%F)
WORK="$MAIN/.cache/equiv-seqout/$DATE"
RES="$ROOT/results/g1/seqio-seqout-$DATE"
for f in "$K2" "$DB/hash.k2d" "${STEM}_1.fq" "${STEM}_2.fq" "${STEM}_1.fq.gz" "${STEM}_2.fq.gz"; do
  [ -e "$f" ] || { echo "equiv-seqout: missing $f (make oracle / scripts/fetch-db.sh / scripts/fetch-reads.sh)" >&2; exit 1; }
done
mkdir -p "$WORK" "$RES"
LOG="$RES/run.log"
: > "$LOG"
log() { echo "$*" | tee -a "$LOG"; }
log "shell flags: $-"
log "pin $UPSTREAM_PIN  db $DB  reads $STEM  threads $THREADS  work $WORK"

# FASTA inputs: the same real reads, reformatted (single-line, and wrapped at 60 columns).
for m in 1 2; do
  awk 'NR%4==1{print ">" substr($0,2)} NR%4==2{print}' "${STEM}_$m.fq" > "$WORK/r_$m.fa"
  awk 'NR%4==1{print ">" substr($0,2)} NR%4==2{s=$0; while(length(s)>60){print substr(s,1,60); s=substr(s,61)} print s}' \
    "${STEM}_$m.fq" > "$WORK/r_$m.wrap.fa"
  gzip -nc "$WORK/r_$m.wrap.fa" > "$WORK/r_$m.wrap.fa.gz"
  # FASTQ with CRLF line ends; and with the mate suffix moved into the identifier
  # ("@SRR062634.1/1<TAB>HWI-...") and a tab before the comment.
  awk '{printf "%s\r\n", $0}' "${STEM}_$m.fq" > "$WORK/r_$m.crlf.fq"
  awk -v m="$m" 'NR%4==1{sp=index($0," "); c=substr($0,sp+1); sub(/\/[12]$/,"",c); print substr($0,1,sp-1) "/" m "\t" c; next} {print}' \
    "${STEM}_$m.fq" > "$WORK/r_$m.slash.fq"
done

: > "$WORK/cases.tsv"
: > "$RES/commands.txt"
# run <name> <paired 0/1> <gzip-flag 0/1> <minq> <inputs...>
run() {
  local name=$1 paired=$2 gz=$3 minq=$4; shift 4
  local cls uncls flags=()
  if [ "$paired" = 1 ]; then cls="$WORK/$name.cls#.seq"; uncls="$WORK/$name.uncls#.seq"; flags+=(--paired)
  else cls="$WORK/$name.cls.seq"; uncls="$WORK/$name.uncls.seq"; fi
  [ "$gz" = 1 ] && flags+=(--gzip-compressed)
  [ "$minq" != 0 ] && flags+=(--minimum-base-quality "$minq")
  local cmd=("$K2" --db "$DB" --threads "$THREADS" "${flags[@]}" --output "$WORK/$name.kraken"
             --classified-out "$cls" --unclassified-out "$uncls" "$@")
  echo "${cmd[*]}" >> "$RES/commands.txt"
  "${cmd[@]}" 2> "$WORK/$name.stderr"
  local st=$?
  log "$name: upstream exit $st; $(tr '\r' '\n' < "$WORK/$name.stderr" | grep -E 'processed|classified' | tr -s ' ' | paste -sd' ' -)"
  [ "$st" = 0 ] || return
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$name" "$paired" "$gz" "$minq" "$WORK/$name.kraken" "$cls" "$uncls" >> "$WORK/cases.tsv"
  printf '\t%s' "$@" >> "$WORK/cases.tsv"
  echo >> "$WORK/cases.tsv"
}
run se_fq_plain        0 0 0  "${STEM}_1.fq"
run se_fq_gz_auto      0 0 0  "${STEM}_1.fq.gz"
run se_fq_gz_flag      0 1 0  "${STEM}_1.fq.gz"
run pe_fq_plain        1 0 0  "${STEM}_1.fq" "${STEM}_2.fq"
run pe_fq_gz_auto      1 0 0  "${STEM}_1.fq.gz" "${STEM}_2.fq.gz"
run se_fq_q20          0 0 20 "${STEM}_1.fq"
run pe_fq_gz_q20       1 0 20 "${STEM}_1.fq.gz" "${STEM}_2.fq.gz"
run se_fa              0 0 0  "$WORK/r_1.fa"
run se_fa_wrap         0 0 0  "$WORK/r_1.wrap.fa"
run pe_fa_wrap_gz      1 0 0  "$WORK/r_1.wrap.fa.gz" "$WORK/r_2.wrap.fa.gz"
run pe_fa_plain        1 0 0  "$WORK/r_1.fa" "$WORK/r_2.fa"
run se_fq_crlf         0 0 0  "$WORK/r_1.crlf.fq"
run pe_fq_crlf         1 0 0  "$WORK/r_1.crlf.fq" "$WORK/r_2.crlf.fq"
run pe_fq_slash_tab    1 0 0  "$WORK/r_1.slash.fq" "$WORK/r_2.slash.fq"
for X in "${EXTRA[@]}"; do
  A=$(basename "$X" | cut -d_ -f1)
  log "extra sample: $X ($(tr '\n' ' ' < "$X.SOURCE"))"
  run "${A}_se_fq_plain"   0 0 0 "${X}_1.fq"
  run "${A}_se_fq_gz_auto" 0 0 0 "${X}_1.fq.gz"
  run "${A}_pe_fq_plain"   1 0 0 "${X}_1.fq" "${X}_2.fq"
  run "${A}_pe_fq_gz_auto" 1 0 0 "${X}_1.fq.gz" "${X}_2.fq.gz"
done

K2_SEQOUT_ORACLE="$WORK" K2_SEQOUT_SUMMARY="$RES/summary.tsv" \
  go test -count=1 -v -run TestOracleSeqout ./internal/seqout/ 2>&1 | tee -a "$LOG"
st=${PIPESTATUS[0]}
log "go test exit $st"

{ echo "{"
  echo "  \"what\": \"seqio+seqout oracle equivalence (issues #12, #16)\","
  echo "  \"commit\": \"$(git rev-parse HEAD)\","
  echo "  \"dirty\": $( [ -n "$(git status --porcelain -- . ':!results')" ] && echo true || echo false ),"
  echo "  \"upstream_pin\": \"$UPSTREAM_PIN\","
  echo "  \"host\": \"$(uname -srm)\","
  echo "  \"date_utc\": \"$(date -u +%FT%TZ)\","
  echo "  \"threads\": $THREADS,"
  echo "  \"db\": \"$(basename "$DB")\","
  echo "  \"db_source\": \"$(tr '\n' ';' < "$DB/SOURCE" | sed 's/"/\\"/g')\","
  echo "  \"reads_source\": \"$(tr '\n' ';' < "${STEM}.SOURCE")\","
  echo "  \"extra_reads_source\": ["
  for X in "${EXTRA[@]}"; do echo "    \"$(tr '\n' ';' < "$X.SOURCE")\","; done | sed '$ s/,$//'
  echo "  ]"
  echo "}"; } > "$RES/manifest.json"
exit "$st"
