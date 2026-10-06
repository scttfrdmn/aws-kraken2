#!/usr/bin/env bash
# make oracle (issue #17): Law 1, end to end. For each case, run upstream's kraken2 wrapper at the
# pin and our bin/aws-kraken2 with identical arguments on real reads against a real database, and
# byte-compare --output, --report and the classified/unclassified files, plus the exit status.
# See docs/oracle.md for the case design.
#
# Usage: scripts/oracle.sh [viral|standard8|all]        (default: $DB, else viral)
# Env:   ORACLE_THREADS  the multi-thread count (default 8; single-thread cases use 1)
#        ORACLE_CASES    a regex; only cases whose name matches run (development only: the
#                        manifest records it and the summary says the matrix was filtered)
#        DECOMP_BIN      a directory holding the gzip/bzip2 to put first on PATH (else
#                        /tmp/gnugzip/inst/bin when present, else the system's)
#        ORACLE_KEEP     1 = keep every case's outputs (default: only those of failing cases)
# Writes results/g1/oracle-<db>-<UTC timestamp>/{manifest.json,cases.tsv,checks.tsv,summary.md}
# (every number in them is computed here; nothing is typed in) and large outputs under
# .cache/oracle/. Exits non-zero on any difference, on any upstream exit status other than the
# case expects, or on a failed coverage check.
set +e
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
. scripts/pin.env
. scripts/paths.sh
echo "oracle: shell flags $-"
INVOCATION="scripts/oracle.sh $*"

SEL=${1:-${DB:-viral}}
case "$SEL" in
  viral) DBS=(viral) ;;
  standard8) DBS=(standard8) ;;
  all) DBS=(viral standard8) ;;
  *) echo "usage: $0 [viral|standard8|all]" >&2; exit 2 ;;
esac
TH=${ORACLE_THREADS:-8}
FILTER=${ORACLE_CASES:-}
KEEP=${ORACLE_KEEP:-0}

if [ -n "${DECOMP_BIN:-}" ]; then PATH="$DECOMP_BIN:$PATH"
elif [ -x /tmp/gnugzip/inst/bin/gzip ]; then PATH="/tmp/gnugzip/inst/bin:$PATH"; fi
export PATH
for t in jq perl awk cmp gzip; do
  command -v "$t" >/dev/null || { echo "oracle: need $t" >&2; exit 1; }
done
if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }
else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

# ---- build and inputs -------------------------------------------------------------------------
K2DIR=$(scripts/oracle-build.sh) || { echo "oracle: upstream build failed" >&2; exit 1; }
UP="$K2DIR/kraken2"
make -s build || { echo "oracle: go build failed" >&2; exit 1; }
OURS="$ROOT/bin/aws-kraken2"
SAMPLES=(SRR062634 ERR478965 SRR28305653)
N=200000
for acc in "${SAMPLES[@]}"; do
  [ -s "$K2_READS/${acc}_$N.SOURCE" ] || scripts/fetch-reads.sh "$acc" "$N" >/dev/null \
    || { echo "oracle: cannot fetch reads $acc" >&2; exit 1; }
done
stem() {  # sample label -> read path stem (without _1.fq)
  case "$1" in
    S1) echo "$K2_READS/SRR062634_$N" ;;
    S2) echo "$K2_READS/ERR478965_$N" ;;
    S3) echo "$K2_READS/SRR28305653_$N" ;;
    *) echo "$VAR/$1" ;;
  esac
}

TS=$(date -u +%Y%m%dT%H%M%SZ)
WORKROOT="$K2_SHARED_ROOT/.cache/oracle/$TS"
VAR="$WORKROOT/variants"
mkdir -p "$VAR"
# Variants of the real reads, made with awk (coverage of paths the raw samples never reach).
#   slash:  SRR062634 with the mate number moved into the identifier ("ID/1 comment"), so paired
#           --output must trim it (classify's /1 /2 rule) while the sequence outputs keep it.
#   short:  ERR478965 with some mates cut below k (every 5th mate 1 to 20 bases, every 3rd mate 2
#           to 30, every 13th of both to 0), so single-end hit lists are empty ("0:0") and
#           paired ones end at the mate border ("|:|").
#   mates:  ERR478965 with the last 10 records of mate 2 removed (unequal mate files: upstream
#           writes every pair it can, then exits 65 without the report).
for m in 1 2; do
  awk -v m="$m" 'NR%4==1{sp=index($0," "); if(sp==0){print $0 "/" m} else {print substr($0,1,sp-1) "/" m substr($0,sp)}; next} {print}' \
    "$K2_READS/SRR062634_${N}_$m.fq" > "$VAR/slash_$m.fq"
  awk -v m="$m" 'NR%4==1{i++} (NR%4==2||NR%4==0){L=-1; if(i%13==0)L=0; else if(m==1&&i%5==0)L=20; else if(m==2&&i%3==0)L=30; if(L>=0)$0=substr($0,1,L)} {print}' \
    "$K2_READS/ERR478965_${N}_$m.fq" > "$VAR/short_$m.fq"
done
cp "$K2_READS/ERR478965_${N}_1.fq" "$VAR/mates_1.fq"
head -n $((4 * (N - 10))) "$K2_READS/ERR478965_${N}_2.fq" > "$VAR/mates_2.fq"
for v in slash short mates; do
  for m in 1 2; do gzip -nc "$VAR/${v}_$m.fq" > "$VAR/${v}_$m.fq.gz"; done
done

# ---- the matrix ---------------------------------------------------------------------------------
# name|sample|layout|form|expected upstream exit|outputs|extra arguments[|control arguments]
#   sample: S1 SRR062634 (human WGS, 100 bp), S2 ERR478965 (trimmed, 45-94 bp),
#           S3 SRR28305653 (150 bp), or a variant above
#   layout: se | pe (--paired, two files);  form: fq (plain) | gz (gzip, auto-detected)
#   outputs: o --output, r --report, c --classified-out/--unclassified-out (with # when paired),
#            n --classified-out without # (an error when paired). Without o, --output - .
# Every case also gets --db and --threads $TH (a later --threads in the extra arguments wins).
# A control case (name control-*) adds its control arguments to our side only: it must come out
# different, which shows the comparison can see a one-option change (Law 4).
CASES=(
  "se-default|S1|se|fq|0|orc|"
  "pe-default-gz|S1|pe|gz|0|orc|"
  "se-default|S2|se|fq|0|orc|"
  "pe-default-gz|S2|pe|gz|0|orc|"
  "se-default-gz|S3|se|gz|0|orc|"
  "pe-default|S3|pe|fq|0|orc|"
  "pe-t1|S1|pe|fq|0|orc|--threads 1"
  "se-t1-gz|S3|se|gz|0|orc|--threads 1"
  "pe-gzflag|S2|pe|gz|0|or|--gzip-compressed"
  "pe-conf0|S1|pe|fq|0|or|--confidence 0"
  "pe-conf0.1|S1|pe|fq|0|orc|--confidence 0.1"
  "pe-conf0.5|S1|pe|fq|0|or|--confidence 0.5"
  "se-conf0.1|S3|se|fq|0|or|--confidence 0.1"
  "pe-conf0.5-gz|S2|pe|gz|0|or|--confidence 0.5"
  "pe-mhg1|S1|pe|fq|0|or|--minimum-hit-groups 1"
  "pe-mhg3|S1|pe|fq|0|or|--minimum-hit-groups 3"
  "se-mhg3|S2|se|fq|0|or|--minimum-hit-groups 3"
  "pe-mhg2|S3|pe|fq|0|or|--minimum-hit-groups 2"
  "pe-quick|S1|pe|fq|0|orc|--quick"
  "pe-quick-conf0.5|S1|pe|fq|0|or|--quick --confidence 0.5"
  "se-quick-mhg1-gz|S3|se|gz|0|or|--quick --minimum-hit-groups 1"
  "pe-zero|S1|pe|fq|0|r|--report-zero-counts"
  "se-mpa|S1|se|fq|0|r|--use-mpa-style"
  "pe-mpa-zero-gz|S3|pe|gz|0|r|--use-mpa-style --report-zero-counts"
  "pe-conf0.1-zero|S2|pe|fq|0|r|--confidence 0.1 --report-zero-counts"
  "pe-names|S1|pe|fq|0|or|--use-names"
  "se-names-conf0.5|S3|se|fq|0|or|--use-names --confidence 0.5"
  "se-q20|S1|se|fq|0|orc|--minimum-base-quality 20"
  "pe-q20-gz|S2|pe|gz|0|orc|--minimum-base-quality 20"
  "pe-mmap|S1|pe|fq|0|orc|--memory-mapping"
  "se-mmap-t1|S3|se|fq|0|or|--memory-mapping --threads 1"
  "pe-slash|slash|pe|fq|0|orc|"
  "se-slash|slash|se|fq|0|oc|"
  "se-short|short|se|fq|0|orc|"
  "pe-short|short|pe|fq|0|orc|"
  "pe-short-q20-gz|short|pe|gz|0|orc|--minimum-base-quality 20"
  "pe-short-quick|short|pe|fq|0|or|--quick"
  "pe-mates-differ|mates|pe|fq|65|orc|"
  "pe-cls-nohash|S1|pe|fq|65|on|"
  "pe-conf-range|S1|pe|fq|255|or|--confidence 1.5"
  "se-mpa-noreport|S1|se|fq|64|o|--use-mpa-style"
  "se-threads0|S1|se|fq|64|o|--threads 0"
  "control-conf|S1|pe|fq|0|or||--confidence 0.05"
  "control-mhg|S3|se|fq|0|orc||--minimum-hit-groups 3"
)
KINDS=(output report c1 c2 u1 u2)

db_dir() {
  case "$1" in
    viral) echo "$K2_DB_ROOT/k2_viral_20260626" ;;
    standard8) echo "$K2_DB_ROOT/k2_standard_08_GB_20260626" ;;
  esac
}

# files SIDE DIR LAYOUT OUTS -> sets ARGS_OUT (the output arguments) and the path of each kind
outargs() {
  local side=$1 dir=$2 layout=$3 outs=$4
  OUTARGS=()
  P_output="$dir/$side.output"; P_report="$dir/$side.report"
  P_c1=""; P_c2=""; P_u1=""; P_u2=""
  if [[ $outs == *o* ]]; then OUTARGS+=(--output "$P_output"); else OUTARGS+=(--output -); P_output=""; fi
  if [[ $outs == *r* ]]; then OUTARGS+=(--report "$P_report"); else P_report=""; fi
  if [[ $outs == *c* ]]; then
    if [ "$layout" = pe ]; then
      OUTARGS+=(--classified-out "$dir/$side.cls#.fq" --unclassified-out "$dir/$side.uncls#.fq")
      P_c1="$dir/$side.cls_1.fq"; P_c2="$dir/$side.cls_2.fq"
      P_u1="$dir/$side.uncls_1.fq"; P_u2="$dir/$side.uncls_2.fq"
    else
      OUTARGS+=(--classified-out "$dir/$side.cls.fq" --unclassified-out "$dir/$side.uncls.fq")
      P_c1="$dir/$side.cls.fq"; P_u1="$dir/$side.uncls.fq"
    fi
  fi
  if [[ $outs == *n* ]]; then
    OUTARGS+=(--classified-out "$dir/$side.cls.fq")
    P_c1="$dir/$side.cls.fq"
  fi
}

# fsha PATH: sha256 of an output file, or "absent" (an output the case did not produce).
fsha() { if [ -n "$1" ] && [ -f "$1" ]; then sha "$1"; elif [ -n "$1" ]; then echo absent; else echo -; fi; }

# firstdiff A B: the first differing lines, for the log.
firstdiff() {
  if [ -f "$1" ] && [ -f "$2" ]; then
    cmp "$1" "$2" | head -1
    diff "$1" "$2" | head -6
  else
    echo "one side absent: $1 $( [ -f "$1" ] && echo present || echo absent ), $2 $( [ -f "$2" ] && echo present || echo absent )"
  fi
}

# Normalized stderr (informational): timing figures and program names removed.
normerr() { sed -E 's/processed in [0-9.]+s \([^)]*\)/processed/; s#^[^ :]*(kraken2|aws-kraken2): #PROG: #; s#\r##g; s#/(upstream|ours)\.#/SIDE.#g' "$1"; }

STATUS=0
run_db() {
  local db=$1 dbdir; dbdir=$(db_dir "$db")
  if [ ! -s "$dbdir/SOURCE" ]; then
    scripts/fetch-db.sh "$db" >/dev/null || { echo "oracle: cannot fetch db $db" >&2; STATUS=1; return; }
  fi
  local RES="results/g1/oracle-$db-$TS" W="$WORKROOT/$db"
  if [ -e "$RES" ]; then echo "oracle: $RES exists" >&2; STATUS=1; return; fi
  mkdir -p "$RES" "$W"
  "$ROOT/bin/k2probe" opts "$dbdir/opts.k2d" > "$RES/opts.json"
  local LOG="$RES/run.log"
  : > "$LOG"
  log() { echo "$*" | tee -a "$LOG"; }
  log "shell flags: $-"
  log "invocation: $INVOCATION  (db=$db threads=$TH filter='${FILTER}')"
  local start; start=$(date -u +%FT%TZ)
  local T="$RES/cases.tsv"
  {
    printf 'case\tsample\tlayout\tform\targs\texpected_exit\tupstream_exit\tours_exit\tupstream_s\tours_s'
    for k in "${KINDS[@]}"; do printf '\t%s_upstream_sha256\t%s_ours_sha256' "$k" "$k"; done
    printf '\tfiles_compared\tidentical\tupstream_exit_ok\tstderr_same\tcontrol\tpass\tupstream_classify_s\tours_classify_s\n'
  } > "$T"
  local c name sample layout form expect outs extra ctl
  for c in "${CASES[@]}"; do
    ctl=""
    IFS='|' read -r name sample layout form expect outs extra ctl <<< "$c"
    local cname="$name-$sample"
    if [ -n "$FILTER" ] && ! [[ $cname =~ $FILTER ]]; then continue; fi
    local d="$W/$cname"; rm -rf "$d"; mkdir -p "$d"
    local st; st=$(stem "$sample")
    local sfx=.fq; [ "$form" = gz ] && sfx=.fq.gz
    local inputs=("${st}_1$sfx"); local lay=()
    if [ "$layout" = pe ]; then inputs+=("${st}_2$sfx"); lay=(--paired); fi
    # shellcheck disable=SC2206
    local xa=($extra)
    local base=(--db "$dbdir" --threads "$TH" "${lay[@]}" "${xa[@]}")
    # upstream
    outargs upstream "$d" "$layout" "$outs"
    local up=("$UP" "${base[@]}" "${OUTARGS[@]}" "${inputs[@]}")
    local U_out=$P_output U_rep=$P_report U_c1=$P_c1 U_c2=$P_c2 U_u1=$P_u1 U_u2=$P_u2
    echo "+ ${up[*]}" >> "$LOG"
    local t0 t1 t2 ue oe
    t0=$(now); "${up[@]}" > "$d/upstream.stdout" 2> "$d/upstream.stderr"; ue=$?; t1=$(now)
    # ours, identical arguments but its own output names
    outargs ours "$d" "$layout" "$outs"
    # shellcheck disable=SC2206
    local ca=($ctl)
    local ou=("$OURS" "${base[@]}" "${ca[@]}" "${OUTARGS[@]}" "${inputs[@]}")
    local O_out=$P_output O_rep=$P_report O_c1=$P_c1 O_c2=$P_c2 O_u1=$P_u1 O_u2=$P_u2
    echo "+ ${ou[*]}" >> "$LOG"
    "${ou[@]}" > "$d/ours.stdout" 2> "$d/ours.stderr"; oe=$?; t2=$(now)

    local ident=yes nfiles=0 row k us os
    row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$cname" "$sample" "$layout" "$form" \
      "${extra:--}" "$expect" "$ue" "$oe" \
      "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')" \
      "$(awk -v a="$t1" -v b="$t2" 'BEGIN{printf "%.3f", b-a}')")
    for k in "${KINDS[@]}"; do
      local uv="U_$k" ov="O_$k"
      [ "$k" = output ] && uv=U_out && ov=O_out
      [ "$k" = report ] && uv=U_rep && ov=O_rep
      us=$(fsha "${!uv}"); os=$(fsha "${!ov}")
      row+=$(printf '\t%s\t%s' "$us" "$os")
      if [ "$us" != - ]; then
        nfiles=$((nfiles + 1))
        if [ "$us" != "$os" ]; then
          ident=no
          log "${ctl:+(control, expected) }DIFF $db $cname $k:"; firstdiff "${!uv}" "${!ov}" | tee -a "$LOG"
        fi
      fi
    done
    # Standard output is a compared output too (it is empty when --output names a file).
    if ! cmp -s "$d/upstream.stdout" "$d/ours.stdout"; then
      ident=no; log "DIFF $db $cname stdout:"; firstdiff "$d/upstream.stdout" "$d/ours.stdout" | tee -a "$LOG"
    fi
    [ "$ue" = "$oe" ] || { ident=no; log "DIFF $db $cname exit: upstream $ue, ours $oe"; }
    local upok=yes; [ "$ue" = "$expect" ] || { upok=no; log "UNEXPECTED $db $cname: upstream exit $ue, case expects $expect"; }
    local errsame=yes
    cmp -s <(normerr "$d/upstream.stderr") <(normerr "$d/ours.stderr") || errsame=no
    local isctl=no pass=no
    [ -n "$ctl" ] && isctl=yes
    if [ "$upok" = yes ] && { { [ $isctl = no ] && [ "$ident" = yes ]; } || { [ $isctl = yes ] && [ "$ident" = no ]; }; }; then pass=yes; fi
    local uc oc
    uc=$(sed -nE 's/.*processed in ([0-9.]+)s.*/\1/p' "$d/upstream.stderr" | tail -1)
    oc=$(sed -nE 's/.*processed in ([0-9.]+)s.*/\1/p' "$d/ours.stderr" | tail -1)
    row+=$(printf '\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$nfiles" "$ident" "$upok" "$errsame" "$isctl" "$pass" "${uc:--}" "${oc:--}")
    echo "$row" >> "$T"
    log "case $db $cname: upstream exit $ue, ours $oe, $nfiles files, identical=$ident, control=$isctl, pass=$pass, stderr_same=$errsame"
    [ "$pass" = yes ] || STATUS=1
    # Coverage evidence is taken from upstream's own outputs before they are deleted.
    coverage "$db" "$cname" "$d" "$U_out" "$U_c1" "$U_u1"
    if [ "$KEEP" != 1 ] && [ "$pass" = yes ]; then rm -rf "$d"/*.fq "$d"/*.output; fi
  done
  checks "$db" "$RES"
  local stop; stop=$(date -u +%FT%TZ)
  manifest "$db" "$dbdir" "$RES" "$start" "$stop"
  summarize "$db" "$RES" > "$RES/summary.md"
  log "results: $RES"
}

# coverage DB CASE DIR OUTPUT C1 U1: per-case evidence that a case reached the path it is for.
declare -A EVID
coverage() {
  local db=$1 c=$2 out=$4 c1=$5 u1=$6
  [ -n "$out" ] && [ -f "$out" ] || return 0
  EVID["$db|$c|output_sha"]=$(sha "$out")
  case "$c" in
    se-short-short)
      EVID["$db|$c|empty_hitlists"]=$(awk -F'\t' '$NF=="0:0"' "$out" | wc -l | tr -d ' ') ;;
    pe-short-short)
      EVID["$db|$c|final_border"]=$(awk -F'\t' '$NF ~ /\|:\|$/' "$out" | wc -l | tr -d ' ')
      EVID["$db|$c|border_only"]=$(awk -F'\t' '$NF=="|:|"' "$out" | wc -l | tr -d ' ') ;;
    pe-slash-slash)
      EVID["$db|$c|output_ids_with_mate_suffix"]=$(awk -F'\t' '$2 ~ /\/[12]$/' "$out" | wc -l | tr -d ' ')
      EVID["$db|$c|seqout_ids_with_mate_suffix"]=$(cat "$c1" "$u1" | awk 'NR%4==1 && $1 ~ /\/1$/' | wc -l | tr -d ' ') ;;
    se-slash-slash)
      EVID["$db|$c|output_ids_with_mate_suffix"]=$(awk -F'\t' '$2 ~ /\/[12]$/' "$out" | wc -l | tr -d ' ') ;;
    se-q20-S1)
      EVID["$db|$c|masked_bases_in_seqout"]=$(cat "$c1" "$u1" | awk 'NR%4==2{n+=gsub(/x/,"")} END{print n+0}') ;;
  esac
}

# checks DB RES: Law 4 resolution checks, from the evidence above, into checks.tsv.
checks() {
  local db=$1 RES=$2 f="$2/checks.tsv"
  printf 'check\tvalue\twant\tok\n' > "$f"
  ck() {  # name value op want
    local ok=no
    case "$3" in
      gt) [ "$2" != "" ] && [ "$2" -gt "$4" ] 2>/dev/null && ok=yes ;;
      eq) [ "$2" = "$4" ] && ok=yes ;;
      ne) [ -n "$2" ] && [ "$2" != "$4" ] && ok=yes ;;
    esac
    printf '%s\t%s\t%s %s\t%s\n' "$1" "${2:-n/a}" "$3" "$4" "$ok" >> "$f"
    [ "$ok" = yes ] || [ -n "$FILTER" ] || STATUS=1
  }
  ck "se-short: single-end reads with an empty hit list (0:0)" "${EVID[$db|se-short-short|empty_hitlists]:-}" gt 0
  ck "pe-short: pairs whose hit list ends at the mate border (|:|)" "${EVID[$db|pe-short-short|final_border]:-}" gt 0
  ck "pe-short: pairs with no minimizers at all (hit list |:|)" "${EVID[$db|pe-short-short|border_only]:-}" gt 0
  ck "pe-slash: --output IDs still ending in /1 or /2 (trimmed in paired mode)" "${EVID[$db|pe-slash-slash|output_ids_with_mate_suffix]:-}" eq 0
  ck "pe-slash: sequence-output IDs ending in /1 (kept as read)" "${EVID[$db|pe-slash-slash|seqout_ids_with_mate_suffix]:-}" gt 0
  ck "se-slash: --output IDs ending in /1 (not trimmed single-end)" "${EVID[$db|se-slash-slash|output_ids_with_mate_suffix]:-}" gt 0
  ck "se-q20: bases masked to x in the sequence outputs" "${EVID[$db|se-q20-S1|masked_bases_in_seqout]:-}" gt 0
  ck "se-q20 vs se-default (S1): -Q 20 changes --output" "${EVID[$db|se-q20-S1|output_sha]:-}" ne "${EVID[$db|se-default-S1|output_sha]:-x}"
  ck "pe-t1 (1 thread, plain) vs pe-default-gz (${TH} threads, gzip), S1: same --output" "${EVID[$db|pe-t1-S1|output_sha]:-a}" eq "${EVID[$db|pe-default-gz-S1|output_sha]:-b}"
  ck "pe-mmap vs pe-default-gz, S1: same --output" "${EVID[$db|pe-mmap-S1|output_sha]:-a}" eq "${EVID[$db|pe-default-gz-S1|output_sha]:-b}"
  ck "pe-quick vs pe-default-gz, S1: --quick changes --output" "${EVID[$db|pe-quick-S1|output_sha]:-}" ne "${EVID[$db|pe-default-gz-S1|output_sha]:-x}"
  local mh; mh=$(jq -r .minimum_acceptable_hash_value "$RES/opts.json")
  printf '%s\t%s\t%s\t%s\n' "minimum_acceptable_hash_value (nonzero: the subthreshold skip path runs)" "$mh" "info" "-" >> "$f"
}

manifest() {
  local db=$1 dbdir=$2 RES=$3 start=$4 stop=$5
  local dirty=false
  if ! git diff --quiet HEAD -- . ':!results' || [ -n "$(git ls-files --others --exclude-standard -- . ':!results')" ]; then dirty=true; fi
  local canon=false; [ "$(uname -s)/$(uname -m)" = Linux/aarch64 ] && canon=true
  local reads='[]' s
  for s in "${SAMPLES[@]}"; do
    reads=$(jq --arg stem "${s}_$N" --rawfile src "$K2_READS/${s}_$N.SOURCE" '. + [{stem: $stem, source: $src}]' <<< "$reads")
  done
  local variants='[]' v m
  for v in slash short mates; do
    for m in 1 2; do
      variants=$(jq --arg f "${v}_$m.fq" --arg h "$(sha "$VAR/${v}_$m.fq")" '. + [{file: $f, sha256: $h}]' <<< "$variants")
    done
  done
  local total ident upbad ckbad failed=false
  total=$(awk 'NR>1' "$RES/cases.tsv" | wc -l | tr -d ' ')
  ident=$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)c[$i]=i} NR>1 && $c["pass"]=="yes"' "$RES/cases.tsv" | wc -l | tr -d ' ')
  upbad=$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)c[$i]=i} NR>1 && $c["upstream_exit_ok"]!="yes"' "$RES/cases.tsv" | wc -l | tr -d ' ')
  ckbad=$(awk -F'\t' 'NR>1 && $4=="no"' "$RES/checks.tsv" | wc -l | tr -d ' ')
  if [ "$total" = 0 ] || [ "$ident" != "$total" ] || [ "$upbad" != 0 ] || { [ "$ckbad" != 0 ] && [ -z "$FILTER" ]; }; then failed=true; fi
  jq -n \
    --arg gate g1 --arg what "make oracle: upstream kraken2 vs bin/aws-kraken2, byte-identity (Law 1, #17)" \
    --arg invocation "$INVOCATION" --arg filter "$FILTER" --argjson threads "$TH" \
    --arg db "$db" --arg dbname "$(basename "$dbdir")" --rawfile dbsource "$dbdir/SOURCE" \
    --arg etag "$(awk '$1=="etag"{print $2}' "$dbdir/SOURCE" | tr -d '"')" \
    --slurpfile opts "$RES/opts.json" \
    --arg commit "$(git rev-parse HEAD)" --argjson dirty "$dirty" \
    --arg pin "$UPSTREAM_PIN" --arg classify_sha "$(sha "$K2DIR/classify")" \
    --arg kraken2_sha "$(sha "$K2DIR/kraken2")" --rawfile upbuild "$K2DIR/BUILD" \
    --arg compiler "$(awk '$1=="cxx"{$1=""; sub(/^ /,""); print}' "$K2DIR/BUILD")" \
    --arg go "$(go version)" --arg ours_sha "$(sha "$OURS")" \
    --arg os "$(uname -s)" --arg arch "$(uname -m)" --arg kernel "$(uname -r)" \
    --arg model "$(sysctl -n hw.model 2>/dev/null || cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo unknown)" \
    --argjson canonical "$canon" \
    --arg gzip "$(gzip --version 2>&1 | head -1)" --arg gzip_path "$(command -v gzip)" \
    --argjson reads "$reads" --argjson variants "$variants" \
    --arg start "$start" --arg stop "$stop" \
    --argjson cases "$total" --argjson identical "$ident" --argjson upstream_unexpected "$upbad" \
    --argjson ckbad "$ckbad" --argjson failed "$failed" \
    '{gate:$gate, what:$what, invocation:$invocation, case_filter:$filter, threads:$threads,
      commit:$commit, dirty:$dirty, upstream_pin:$pin,
      upstream:{classify_sha256:$classify_sha, kraken2_sha256:$kraken2_sha, build:$upbuild, compiler:$compiler},
      ours:{aws_kraken2_sha256:$ours_sha, go:$go},
      host:{os:$os, arch:$arch, kernel:$kernel, model:$model, canonical_platform:$canonical,
            note:(if $canonical then "Linux aarch64: the canonical oracle platform"
                  else "NOT the canonical platform (Linux aarch64): development evidence only" end)},
      gzip:{version:$gzip, path:$gzip_path},
      db:{name:$db, dir:$dbname, source:$dbsource, etag:$etag, opts:$opts[0]},
      reads:$reads, variants:$variants,
      start:$start, stop:$stop,
      cases:$cases, cases_passed:$identical, upstream_unexpected_exit:$upstream_unexpected,
      coverage_checks_failed:$ckbad, failed:$failed}' > "$RES/manifest.json"
}

# summarize DB RES: summary.md, every number derived from cases.tsv and checks.tsv.
summarize() {
  local db=$1 RES=$2
  local man="$RES/manifest.json"
  echo "# make oracle: $db, $TS"
  echo
  echo "Upstream \`kraken2\` at \`$UPSTREAM_PIN\` vs \`bin/aws-kraken2\` at \`$(jq -r .commit "$man")\`" \
       "(dirty: $(jq -r .dirty "$man")), on $(jq -r '.host.os + " " + .host.arch' "$man")."
  echo "$(jq -r .host.note "$man")."
  [ -n "$FILTER" ] && echo && echo "**Filtered run (ORACLE_CASES='$FILTER'): not the full matrix.**"
  echo
  awk -F'\t' '
    NR==1 { for (i=1;i<=NF;i++) c[$i]=i; next }
    $c["control"]=="yes" { nc++; if ($c["identical"]=="no") cseen++; else cl=cl "\n- " $c["case"]; next }
    { n++; files+=$c["files_compared"]
      if ($c["identical"]=="yes") same++; else { diff++; dl=dl "\n- " $c["case"] }
      if ($c["upstream_exit_ok"]!="yes") { bad++; bl=bl "\n- " $c["case"] " (upstream exit " $c["upstream_exit"] ", expected " $c["expected_exit"] ")" }
      if ($c["stderr_same"]!="yes") { es++; el=el " " $c["case"] }
      if ($c["upstream_s"]+0 > 0) { ut+=$c["upstream_s"]; ot+=$c["ours_s"] }
      if ($c["upstream_classify_s"] != "-") { uc+=$c["upstream_classify_s"]; oc+=$c["ours_classify_s"] } }
    END {
      printf "| | count |\n|---|---|\n"
      printf "| comparison cases | %d |\n| output files compared (both sides) | %d |\n", n, files
      printf "| cases identical (all files, stdout and exit status) | %d |\n| cases differing | %d |\n", same, diff
      printf "| upstream exit other than expected | %d |\n", bad
      printf "| stderr differs after removing timings (informational, not under Law 1) | %d |\n", es
      printf "| control cases (one option changed on our side only) | %d |\n| control cases the comparison flagged as different | %d |\n", nc, cseen
      if (cl) printf "\nControl cases NOT flagged (the comparison is blind):%s\n", cl
      if (diff) printf "\nDiffering cases:%s\n", dl
      if (bad) printf "\nUnexpected upstream exits:%s\n", bl
      if (es) printf "\nstderr differs (informational):%s\n", el
      printf "\nTimings (informational, not a benchmark: one run each, warm page cache, development host unless the manifest says otherwise). Wall-clock sum over the comparison cases, whole process including DB load: upstream %.1fs, ours %.1fs. Sum of the classification phase as each reports it on stderr (\"processed in\"): upstream %.2fs, ours %.2fs.\n", ut, ot, uc, oc
    }' "$RES/cases.tsv"
  echo
  echo "## Coverage checks (Law 4: could the matrix have seen the effect?)"
  echo
  echo "| check | value | want | ok |"
  echo "|---|---|---|---|"
  awk -F'\t' 'NR>1 { printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' "$RES/checks.tsv"
  echo
  echo "Per-case arguments, exit statuses, timings and sha256 of every output on both sides:"
  echo "\`cases.tsv\`. Run metadata: \`manifest.json\`. Log with first differing lines: \`run.log\`."
  echo "Case design: docs/oracle.md."
}

for db in "${DBS[@]}"; do run_db "$db"; done
if [ "$STATUS" != 0 ]; then echo "oracle: FAILED (see results/g1/oracle-*-$TS/summary.md)" >&2; else echo "oracle: ok"; fi
exit "$STATUS"
