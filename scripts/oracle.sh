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
#        ORACLE_ENGINE   a list of shard counts, e.g. "1 2 3 4 8" (make oracle-engine): upstream
#                        runs once per case and ours runs once per N through the sharded engine
#                        (AK2_ENGINE_N=N, cmd/aws-kraken2/engine.go), each byte-compared with it;
#                        one cases.tsv row per (case, N). Results go to oracle-engine-<db>-<UTC>.
#        ORACLE_ENGINE_TRANSPORT  local (default) | tcp: AK2_ENGINE_TRANSPORT for those runs
#        ORACLE_ENGINE_TAIL       AK2_ENGINE_TAIL (overlap tail cells; default the engine's 302)
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
. scripts/pin-identity.sh
pin_identity || { echo "$(basename "$0"): cannot establish the upstream pin identity" >&2; exit 1; }
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
# Engine mode: ENG_NS holds the shard counts; plain mode is one pass with no engine ("").
ETR=${ORACLE_ENGINE_TRANSPORT:-local}
ETAIL=${ORACLE_ENGINE_TAIL:-}
if [ -n "${ORACLE_ENGINE:-}" ]; then
  read -r -a ENG_NS <<< "$ORACLE_ENGINE"
  for n in "${ENG_NS[@]}"; do
    [[ $n =~ ^[1-9][0-9]*$ ]] || { echo "oracle: ORACLE_ENGINE: bad shard count '$n'" >&2; exit 2; }
  done
  case "$ETR" in local|tcp) ;; *) echo "oracle: ORACLE_ENGINE_TRANSPORT=$ETR: want local or tcp" >&2; exit 2 ;; esac
  [ -z "$ETAIL" ] || [[ $ETAIL =~ ^[0-9]+$ ]] || { echo "oracle: ORACLE_ENGINE_TAIL=$ETAIL: want a cell count" >&2; exit 2; }
  MODE=engine
else
  ENG_NS=("")
  MODE=plain
fi

if [ -n "${DECOMP_BIN:-}" ]; then PATH="$DECOMP_BIN:$PATH"
elif [ -x /tmp/gnugzip/inst/bin/gzip ]; then PATH="/tmp/gnugzip/inst/bin:$PATH"; fi
export PATH
# The wrapper reads these; a case that wants one sets it itself.
unset KRAKEN2_DB_PATH KRAKEN2_DEFAULT_DB KRAKEN2_NUM_THREADS
for t in jq perl awk cmp gzip bzip2 find; do
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
#   empty:  empty files (no input: upstream opens no output file until an input holds data).
#   fasta:  SRR062634 as FASTA, one line per sequence;  fastaw: SRR28305653 as FASTA wrapped at 60.
#   bz:     ERR478965 compressed with bzip2.
for m in 1 2; do
  awk -v m="$m" 'NR%4==1{sp=index($0," "); if(sp==0){print $0 "/" m} else {print substr($0,1,sp-1) "/" m substr($0,sp)}; next} {print}' \
    "$K2_READS/SRR062634_${N}_$m.fq" > "$VAR/slash_$m.fq"
  awk -v m="$m" 'NR%4==1{i++} (NR%4==2||NR%4==0){L=-1; if(i%13==0)L=0; else if(m==1&&i%5==0)L=20; else if(m==2&&i%3==0)L=30; if(L>=0)$0=substr($0,1,L)} {print}' \
    "$K2_READS/ERR478965_${N}_$m.fq" > "$VAR/short_$m.fq"
done
: > "$VAR/empty_1.fq"; : > "$VAR/empty_2.fq"
for m in 1 2; do
  awk 'NR%4==1{print ">" substr($0,2)} NR%4==2{print}' "$K2_READS/SRR062634_${N}_$m.fq" > "$VAR/fasta_$m.fa"
  awk 'NR%4==1{print ">" substr($0,2)} NR%4==2{s=$0; while(length(s)>60){print substr(s,1,60); s=substr(s,61)} print s}' \
    "$K2_READS/SRR28305653_${N}_$m.fq" > "$VAR/fastaw_$m.fa"
  bzip2 -c "$K2_READS/ERR478965_${N}_$m.fq" > "$VAR/bz_$m.fq.bz2"
done
cp "$K2_READS/ERR478965_${N}_1.fq" "$VAR/mates_1.fq"
head -n $((4 * (N - 10))) "$K2_READS/ERR478965_${N}_2.fq" > "$VAR/mates_2.fq"
for v in slash short mates empty; do
  for m in 1 2; do gzip -nc "$VAR/${v}_$m.fq" > "$VAR/${v}_$m.fq.gz"; done
done

# ---- the matrix ---------------------------------------------------------------------------------
# name|sample|layout|form|expected upstream exit|outputs|extra arguments[|control arguments]
#   sample: S1 SRR062634 (human WGS, 100 bp), S2 ERR478965 (trimmed, 45-94 bp),
#           S3 SRR28305653 (150 bp), or a variant above; "A,B" = several inputs in one run
#   layout: se | pe (--paired, two files)
#   form:   fq (plain) | gz (gzip, auto-detected) | fa (FASTA) | bz2 (bzip2, auto-detected)
#   outputs: o --output, r --report, c --classified-out/--unclassified-out (with # when paired),
#            n --classified-out without # (an error when paired), s no --output at all (the
#            per-read output goes to standard output). Without o or s, --output - .
#            Lower case: the file must exist on both sides when the expected exit is 0. Upper
#            case: requested, but must be absent on both sides (e.g. empty input). Letters after
#            "!": requested at a path in a directory that does not exist (unwritable); the file
#            must be absent on both sides.
#   extra arguments: as given, except ENV:NAME=VALUE (set in the environment of both runs),
#            @DBNAME / @DBPARENT (the database's directory name / its parent), and NOTHREADS
#            (no --threads). With --db among them, the default --db is not added.
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
  "se-multi|S1,S2|se|fq|0|orc|"
  "pe-multi-gz|S2,S3|pe|gz|0|orc|--report-zero-counts"
  "se-empty|empty|se|fq|0|OrC|"
  "se-empty-zero|empty|se|fq|0|Or|--report-zero-counts"
  "se-stdout|S1|se|fq|0|sr|"
  "pe-stdout-cls-gz|S3|pe|gz|0|src|--threads 4"
  "pe-fasta|fasta|pe|fa|0|orc|"
  "se-fasta-wrap|fastaw|se|fa|0|orc|"
  "pe-bz2-auto|bz|pe|bz2|0|orc|"
  "se-bz2-flag|bz|se|bz2|0|or|--bzip2-compressed"
  "pe-db-by-name|S1|pe|fq|0|or|ENV:KRAKEN2_DB_PATH=/nonexistent::@DBPARENT --db @DBNAME"
  "se-env-threads|S3|se|fq|0|or|ENV:KRAKEN2_NUM_THREADS=3 NOTHREADS"
  "se-report-unwritable|S1|se|fq|0|o!r|"
  "se-seqout-unwritable|S1|se|fq|0|o!c|"
  "pe-seqout-unwritable|S1|pe|fq|1|o!c|"
  "se-output-unwritable|S1|se|fq|1|r!o|"
  "pe-empty-then-S1|empty,S1|pe|fq|0|orc|"
  "pe-mates-differ|mates|pe|fq|65|orc|"
  "pe-cls-nohash|S1|pe|fq|65|on|"
  "pe-conf-range|S1|pe|fq|255|or|--confidence 1.5"
  "se-mpa-noreport|S1|se|fq|64|o|--use-mpa-style"
  "se-threads0|S1|se|fq|64|o|--threads 0"
  "control-conf|S1|pe|fq|0|or||--confidence 0.05"
  "control-mhg|S3|se|fq|0|orc||--minimum-hit-groups 3"
)
KINDS=(output report c1 c2 u1 u2 stdout)

db_dir() {
  case "$1" in
    viral) echo "$K2_DB_ROOT/k2_viral_20260626" ;;
    standard8) echo "$K2_DB_ROOT/k2_standard_08_GB_20260626" ;;
  esac
}

# outargs SIDE DIR LAYOUT OUTS: sets OUTARGS (the output arguments), P_<kind> (each output's
# path, "" if not requested) and Q_<kind> (must | absent | "": the existence requirement).
outargs() {
  local side=$1 dir=$2 layout=$3 outs=$4 norm=${4%%!*} bad="" k
  [[ $outs == *!* ]] && bad=${outs#*!}
  OUTARGS=()
  for k in output report c1 c2 u1 u2 stdout; do printf -v "P_$k" ''; printf -v "Q_$k" ''; done
  P_stdout="$dir/$side.stdout"
  want() {  # letter -> must|absent|"" for this side's OUTS
    if [[ $bad == *$1* ]]; then echo absent
    elif [[ $norm == *$1* ]]; then echo must
    elif [[ $norm == *${1^^}* ]]; then echo absent
    fi
  }
  where() { if [[ $bad == *$1* ]]; then echo "$dir/nodir"; else echo "$dir"; fi; }
  local q
  q=$(want o)
  if [ -n "$q" ]; then P_output="$(where o)/$side.output"; Q_output=$q; OUTARGS+=(--output "$P_output")
  elif [[ $norm != *s* ]]; then OUTARGS+=(--output -); fi
  [[ $norm == *s* ]] && Q_stdout=must
  q=$(want r)
  if [ -n "$q" ]; then P_report="$(where r)/$side.report"; Q_report=$q; OUTARGS+=(--report "$P_report"); fi
  q=$(want c)
  if [ -n "$q" ]; then
    local w; w=$(where c)
    if [ "$layout" = pe ]; then
      OUTARGS+=(--classified-out "$w/$side.cls#.fq" --unclassified-out "$w/$side.uncls#.fq")
      P_c1="$w/$side.cls_1.fq"; P_c2="$w/$side.cls_2.fq"; P_u1="$w/$side.uncls_1.fq"; P_u2="$w/$side.uncls_2.fq"
      Q_c1=$q; Q_c2=$q; Q_u1=$q; Q_u2=$q
    else
      OUTARGS+=(--classified-out "$w/$side.cls.fq" --unclassified-out "$w/$side.uncls.fq")
      P_c1="$w/$side.cls.fq"; P_u1="$w/$side.uncls.fq"; Q_c1=$q; Q_u1=$q
    fi
  fi
  if [[ $norm == *n* ]]; then
    OUTARGS+=(--classified-out "$dir/$side.cls.fq"); P_c1="$dir/$side.cls.fq"; Q_c1=must
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
normerr() { perl -0pe 's/ak2-(timing|engine)\t[^\n]*\n//g' "$1" | sed -E 's/processed in [0-9.]+s \([^)]*\)/processed/; s#^[^ :]*(kraken2|aws-kraken2): #PROG: #; s#\r##g; s#/(n[0-9]+/)?(nodir/)?(upstream|ours)\.#/\2SIDE.#g'; }

STATUS=0
declare -A ETP EWP
NROWS=$(( ${#CASES[@]} * ${#ENG_NS[@]} ))
run_db() {
  local db=$1 dbdir; dbdir=$(db_dir "$db")
  if [ ! -s "$dbdir/SOURCE" ]; then
    scripts/fetch-db.sh "$db" >/dev/null || { echo "oracle: cannot fetch db $db" >&2; STATUS=1; return; }
  fi
  ETP=(); EWP=()
  local RES="results/g1/oracle-$db-$TS" W="$WORKROOT/$db"
  [ "$MODE" = engine ] && RES="results/g1/oracle-engine-$db-$TS"
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
    printf '\tfiles_compared\tidentical\tupstream_exit_ok\tstderr_same\tcontrol\tpass\tupstream_classify_s\tours_classify_s\trequested_outputs_ok\tunexpected_files\tengine_n\ttail_probes\twrap_probes\n'
  } > "$T"
  local ran=0
  local c name sample layout form expect outs extra ctl
  for c in "${CASES[@]}"; do
    ctl=""
    IFS='|' read -r name sample layout form expect outs extra ctl <<< "$c"
    local cname="$name-$sample"
    if [ -n "$FILTER" ] && ! [[ $cname =~ $FILTER ]]; then continue; fi
    ran=$((ran + 1))
    local d="$W/$cname"; rm -rf "$d"; mkdir -p "$d"
    local sfx
    case "$form" in fq) sfx=.fq ;; gz) sfx=.fq.gz ;; fa) sfx=.fa ;; bz2) sfx=.fq.bz2 ;; esac
    local inputs=() lay=() one st
    # A sample list "A,B" is several inputs (pairs when paired), classified in one run.
    for one in ${sample//,/ }; do
      st=$(stem "$one")
      inputs+=("${st}_1$sfx")
      [ "$layout" = pe ] && inputs+=("${st}_2$sfx")
    done
    [ "$layout" = pe ] && lay=(--paired)
    # Extra arguments: ENV:, @DBNAME, @DBPARENT and NOTHREADS are expanded here.
    local xa=() envs=() tok hasdb=no thr=(--threads "$TH")
    for tok in $extra; do
      tok=${tok//@DBNAME/$(basename "$dbdir")}; tok=${tok//@DBPARENT/$(dirname "$dbdir")}
      case "$tok" in
        ENV:*) envs+=("${tok#ENV:}") ;;
        NOTHREADS) thr=() ;;
        --db) hasdb=yes; xa+=("$tok") ;;
        *) xa+=("$tok") ;;
      esac
    done
    local dba=(--db "$dbdir"); [ $hasdb = yes ] && dba=()
    local base=("${dba[@]}" "${thr[@]}" "${lay[@]}" "${xa[@]}")
    # upstream
    outargs upstream "$d" "$layout" "$outs"
    local up=("$UP" "${base[@]}" "${OUTARGS[@]}" "${inputs[@]}")
    local U_out=$P_output U_rep=$P_report U_c1=$P_c1 U_c2=$P_c2 U_u1=$P_u1 U_u2=$P_u2 U_std=$P_stdout
    local R_output=$Q_output R_report=$Q_report R_c1=$Q_c1 R_c2=$Q_c2 R_u1=$Q_u1 R_u2=$Q_u2 R_stdout=$Q_stdout
    echo "+ ${envs[*]} ${up[*]}" >> "$LOG"
    local t0 tu t1 t2 ue oe
    t0=$(now); env "${envs[@]}" "${up[@]}" > "$U_std" 2> "$d/upstream.stderr"; ue=$?; tu=$(now)
    # Coverage evidence is taken from upstream's own outputs before they are deleted.
    coverage "$db" "$cname" "$d" "$U_out" "$U_c1" "$U_u1"
    # ours, identical arguments but its own output names: once (plain), or once per shard count
    # through the engine, each in its own directory n<N>.
    local EN allpass=yes
    for EN in "${ENG_NS[@]}"; do
    local od=$d lab=$cname eenv=()
    if [ -n "$EN" ]; then
      od="$d/n$EN"; rm -rf "$od"; mkdir -p "$od"; lab="$cname@n$EN"
      eenv=(AK2_ENGINE_N="$EN" AK2_ENGINE_TRANSPORT="$ETR" AK2_TIMINGS=1)
      [ -n "$ETAIL" ] && eenv+=(AK2_ENGINE_TAIL="$ETAIL")
    fi
    outargs ours "$od" "$layout" "$outs"
    # shellcheck disable=SC2206
    local ca=($ctl)
    local ou=("$OURS" "${base[@]}" "${ca[@]}" "${OUTARGS[@]}" "${inputs[@]}")
    local O_out=$P_output O_rep=$P_report O_c1=$P_c1 O_c2=$P_c2 O_u1=$P_u1 O_u2=$P_u2 O_std=$P_stdout
    echo "+ ${envs[*]} ${eenv[*]} ${ou[*]}" >> "$LOG"
    t1=$(now); env "${envs[@]}" "${eenv[@]}" "${ou[@]}" > "$O_std" 2> "$od/ours.stderr"; oe=$?; t2=$(now)

    local ident=yes nfiles=0 ndiff=0 reqok=yes row k us os
    row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$lab" "$sample" "$layout" "$form" \
      "${extra:--}" "$expect" "$ue" "$oe" \
      "$(awk -v a="$t0" -v b="$tu" 'BEGIN{printf "%.3f", b-a}')" \
      "$(awk -v a="$t1" -v b="$t2" 'BEGIN{printf "%.3f", b-a}')")
    for k in "${KINDS[@]}"; do
      local uv="U_$k" ov="O_$k" rv="R_$k"
      [ "$k" = output ] && uv=U_out && ov=O_out
      [ "$k" = report ] && uv=U_rep && ov=O_rep
      [ "$k" = stdout ] && uv=U_std && ov=O_std
      us=$(fsha "${!uv}"); os=$(fsha "${!ov}")
      row+=$(printf '\t%s\t%s' "$us" "$os")
      if [ "$us" != - ]; then
        nfiles=$((nfiles + 1))
        if [ "$us" != "$os" ]; then
          ident=no; ndiff=$((ndiff + 1))
          log "${ctl:+(control, expected) }DIFF $db $lab $k:"; firstdiff "${!uv}" "${!ov}" | tee -a "$LOG"
        fi
      fi
      # Existence (only when the case expects success): a requested output must be there on
      # both sides (standard output: non-empty), an expected-absent one on neither.
      if [ "$expect" = 0 ]; then
        case "${!rv}" in
          must)
            if [ "$k" = stdout ]; then [ -s "${!uv}" ] && [ -s "${!ov}" ] || { reqok=no; log "MISSING $db $lab: $k empty"; }
            else [ -f "${!uv}" ] && [ -f "${!ov}" ] || { reqok=no; log "MISSING $db $lab: $k (upstream $us, ours $os)"; }; fi ;;
          absent)
            [ ! -e "${!uv}" ] && [ ! -e "${!ov}" ] || { reqok=no; log "PRESENT $db $lab: $k should be absent (upstream $us, ours $os)"; } ;;
        esac
      fi
    done
    [ "$ue" = "$oe" ] || { ident=no; log "DIFF $db $lab exit: upstream $ue, ours $oe"; }
    # Anything else written into the case directory (or this N's directory) is unexpected.
    local known extra_files f
    known=$(printf '%s\n' "$d/upstream.stderr" "$od/ours.stderr" "$U_std" "$O_std" "$U_out" "$O_out" "$U_rep" "$O_rep" \
      "$U_c1" "$U_c2" "$U_u1" "$U_u2" "$O_c1" "$O_c2" "$O_u1" "$O_u2" | grep -v '^$')
    extra_files=$( { if [ "$MODE" = engine ]; then find "$d" -mindepth 1 -path "$d/n[0-9]*" -prune -o -print
                     find "$od" -mindepth 1; else find "$d" -mindepth 1; fi; } |
      while read -r f; do printf '%s\n' "$known" | grep -qxF -- "$f" || echo "${f#"$d"/}"; done | tr '\n' ' ')
    extra_files=${extra_files% }
    [ -z "$extra_files" ] || log "UNEXPECTED FILES $db $lab: $extra_files"
    local upok=yes; [ "$ue" = "$expect" ] || { upok=no; log "UNEXPECTED $db $lab: upstream exit $ue, case expects $expect"; }
    local errsame=yes
    cmp -s <(normerr "$d/upstream.stderr") <(normerr "$od/ours.stderr") || errsame=no
    local isctl=no pass=no
    [ -n "$ctl" ] && isctl=yes
    # A control passes only if both sides exit alike and at least one output file differs.
    if [ "$upok" = yes ] && [ "$reqok" = yes ] && [ -z "$extra_files" ] &&
       { { [ $isctl = no ] && [ "$ident" = yes ]; } || { [ $isctl = yes ] && [ "$ue" = "$oe" ] && [ "$ndiff" -gt 0 ]; }; }; then pass=yes; fi
    local uc oc
    uc=$(sed -nE 's/.*processed in ([0-9.]+)s.*/\1/p' "$d/upstream.stderr" | tail -1)
    oc=$(sed -nE 's/.*processed in ([0-9.]+)s.*/\1/p' "$od/ours.stderr" | tail -1)
    # Engine evidence (Law 4): lookups whose probe ended in a shard's overlap tail, and those
    # that ended in the wrapped part of the last shard's tail (cmd/aws-kraken2/engine.go).
    local tp=- wp=-
    if [ -n "$EN" ]; then
      read -r tp wp < <(awk -F'\t' '$1=="ak2-engine" && $2=="shard" {
          for (i = 3; i < NF; i++) { if ($i=="tail_probes") t += $(i+1); if ($i=="wrap_probes") w += $(i+1) } }
        END { print t+0, w+0 }' "$od/ours.stderr")
      ETP[$EN]=$(( ${ETP[$EN]:-0} + tp )); EWP[$EN]=$(( ${EWP[$EN]:-0} + wp ))
    fi
    row+=$(printf '\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$nfiles" "$ident" "$upok" "$errsame" "$isctl" "$pass" "${uc:--}" "${oc:--}" "$reqok" "${extra_files:--}" "${EN:--}" "$tp" "$wp")
    echo "$row" >> "$T"
    log "case $db $lab: upstream exit $ue, ours $oe, $nfiles files, identical=$ident, control=$isctl, pass=$pass, stderr_same=$errsame"
    if [ "$pass" = yes ]; then
      [ "$KEEP" = 1 ] || [ "$od" = "$d" ] || rm -rf "$od"/*.fq "$od"/*.output "$od"/*.stdout
    else
      STATUS=1; allpass=no
    fi
    done
    if [ "$KEEP" != 1 ] && [ "$allpass" = yes ]; then rm -rf "$d"/*.fq "$d"/*.output "$d"/*.stdout; fi
  done
  # The matrix itself: a filter that matches nothing, or an unfiltered run that did not record
  # every case, is a failure.
  local rows; rows=$(awk 'NR>1' "$T" | wc -l | tr -d ' ')
  MATRIX_OK=yes
  if [ "$ran" = 0 ]; then log "FAIL: no case matched filter '$FILTER'"; MATRIX_OK=no; fi
  if [ -z "$FILTER" ] && [ "$rows" != "$NROWS" ]; then log "FAIL: $rows rows recorded, $NROWS expected (${#CASES[@]} cases x ${#ENG_NS[@]})"; MATRIX_OK=no; fi
  checks "$db" "$RES"
  local stop; stop=$(date -u +%FT%TZ)
  manifest "$db" "$dbdir" "$RES" "$start" "$stop"
  summarize "$db" "$RES" > "$RES/summary.md"
  # The manifest's verdict is the run's.
  jq -e '.failed == false' "$RES/manifest.json" >/dev/null || STATUS=1
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
  local EN
  if [ "$MODE" = engine ]; then
    for EN in "${ENG_NS[@]}"; do
      [ "$EN" = 1 ] && continue
      printf '%s\t%s\t%s\t%s\n' "engine N=$EN: lookups whose probe ended in a shard's overlap tail, summed over cases (real-data reach of the tail path; synthetic coverage: internal/engine tests)" "${ETP[$EN]:-0}" "info" "-" >> "$f"
      printf '%s\t%s\t%s\t%s\n' "engine N=$EN: of those, ended past slot C-1 in the last shard's wrapped tail" "${EWP[$EN]:-0}" "info" "-" >> "$f"
    done
  fi
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
  for v in slash_1.fq slash_2.fq short_1.fq short_2.fq mates_1.fq mates_2.fq fasta_1.fa fasta_2.fa \
           fastaw_1.fa fastaw_2.fa bz_1.fq.bz2 bz_2.fq.bz2; do
    variants=$(jq --arg f "$v" --arg h "$(sha "$VAR/$v")" '. + [{file: $f, sha256: $h}]' <<< "$variants")
  done
  local total ident upbad ckbad failed=false
  total=$(awk 'NR>1' "$RES/cases.tsv" | wc -l | tr -d ' ')
  ident=$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)c[$i]=i} NR>1 && $c["pass"]=="yes"' "$RES/cases.tsv" | wc -l | tr -d ' ')
  upbad=$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)c[$i]=i} NR>1 && $c["upstream_exit_ok"]!="yes"' "$RES/cases.tsv" | wc -l | tr -d ' ')
  ckbad=$(awk -F'\t' 'NR>1 && $4=="no"' "$RES/checks.tsv" | wc -l | tr -d ' ')
  if [ "$total" = 0 ] || [ "$ident" != "$total" ] || [ "$upbad" != 0 ] || [ "$MATRIX_OK" != yes ] ||
     { [ -z "$FILTER" ] && [ "$total" != "$NROWS" ]; } || { [ "$ckbad" != 0 ] && [ -z "$FILTER" ]; }; then failed=true; fi
  jq -n \
    --arg gate g1 --arg what "make oracle: upstream kraken2 vs bin/aws-kraken2, byte-identity (Law 1, #17)" \
    --arg invocation "$INVOCATION" --arg filter "$FILTER" --argjson threads "$TH" \
    --arg db "$db" --arg dbname "$(basename "$dbdir")" --rawfile dbsource "$dbdir/SOURCE" \
    --arg etag "$(awk '$1=="etag"{print $2}' "$dbdir/SOURCE" | tr -d '"')" \
    --slurpfile opts "$RES/opts.json" \
    --arg commit "$(git rev-parse HEAD)" --argjson dirty "$dirty" \
    --arg pin "$UPSTREAM_SHA" --arg describe "$UPSTREAM_DESCRIBE" --arg classify_sha "$(sha "$K2DIR/classify")" \
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
    --argjson ckbad "$ckbad" --argjson failed "$failed" --argjson defined "$NROWS" --argjson ncases "${#CASES[@]}" \
    --arg mode "$MODE" --arg engine_ns "${ENG_NS[*]}" --arg engine_transport "$ETR" --arg engine_tail "$ETAIL" \
    '{gate:$gate, what:$what, invocation:$invocation, case_filter:$filter, threads:$threads,
      commit:$commit, dirty:$dirty, upstream_pin:$pin, upstream_describe:$describe,
      upstream:{sha:$pin, describe:$describe, classify_sha256:$classify_sha, kraken2_sha256:$kraken2_sha, build:$upbuild, compiler:$compiler},
      ours:{aws_kraken2_sha256:$ours_sha, go:$go},
      host:{os:$os, arch:$arch, kernel:$kernel, model:$model, canonical_platform:$canonical,
            note:(if $canonical then "Linux aarch64: the canonical oracle platform"
                  else "NOT the canonical platform (Linux aarch64): development evidence only" end)},
      gzip:{version:$gzip, path:$gzip_path},
      db:{name:$db, dir:$dbname, source:$dbsource, etag:$etag, opts:$opts[0]},
      reads:$reads, variants:$variants,
      start:$start, stop:$stop,
      cases:$cases, cases_passed:$identical, upstream_unexpected_exit:$upstream_unexpected,
      cases_defined:$defined, case_kinds_defined:$ncases, coverage_checks_failed:$ckbad, failed:$failed,
      mode:$mode,
      engine:(if $mode == "engine" then {shard_counts:($engine_ns | split(" ") | map(tonumber)),
               transport:$engine_transport,
               tail_cells:(if $engine_tail == "" then "default (engine.DefaultTail, 302)" else ($engine_tail | tonumber) end),
               note:"upstream ran once per case; ours ran once per shard count, each compared with it (one cases.tsv row per case and N)"}
              else null end)}' > "$RES/manifest.json"
}

# summarize DB RES: summary.md, every number derived from cases.tsv and checks.tsv.
summarize() {
  local db=$1 RES=$2
  local man="$RES/manifest.json"
  if [ "$MODE" = engine ]; then
    echo "# make oracle-engine: $db, $TS (shard counts ${ENG_NS[*]}, transport $ETR, tail ${ETAIL:-302 default})"
  else
    echo "# make oracle: $db, $TS"
  fi
  echo
  echo "Upstream \`kraken2\` at \`$UPSTREAM_SHA\` (\`$UPSTREAM_DESCRIBE\`) vs \`bin/aws-kraken2\` at \`$(jq -r .commit "$man")\`" \
       "(dirty: $(jq -r .dirty "$man")), on $(jq -r '.host.os + " " + .host.arch' "$man")."
  echo "$(jq -r .host.note "$man")."
  [ -n "$FILTER" ] && echo && echo "**Filtered run (ORACLE_CASES='$FILTER'): not the full matrix.**"
  echo
  awk -F'\t' '
    NR==1 { for (i=1;i<=NF;i++) c[$i]=i; next }
    $c["control"]=="yes" { nc++; if ($c["pass"]=="yes") cseen++; else cl=cl "\n- " $c["case"]; next }
    { n++; files+=$c["files_compared"]
      if ($c["identical"]=="yes") same++; else { diff++; dl=dl "\n- " $c["case"] }
      if ($c["upstream_exit_ok"]!="yes") { bad++; bl=bl "\n- " $c["case"] " (upstream exit " $c["upstream_exit"] ", expected " $c["expected_exit"] ")" }
      if ($c["stderr_same"]!="yes") { es++; el=el " " $c["case"] }
      if ($c["requested_outputs_ok"]!="yes") { rq++; rl=rl "\n- " $c["case"] }
      if ($c["unexpected_files"]!="-") { uf++; ul=ul "\n- " $c["case"] ": " $c["unexpected_files"] }
      if ($c["upstream_s"]+0 > 0) { ut+=$c["upstream_s"]; ot+=$c["ours_s"] }
      if ($c["upstream_classify_s"] != "-") { uc+=$c["upstream_classify_s"]; oc+=$c["ours_classify_s"] } }
    END {
      printf "| | count |\n|---|---|\n"
      printf "| comparison cases | %d |\n| output files compared (both sides) | %d |\n", n, files
      printf "| cases identical (all files, stdout and exit status) | %d |\n| cases differing | %d |\n", same, diff
      printf "| upstream exit other than expected | %d |\n", bad
      printf "| requested output missing, or expected-absent output present | %d |\n| cases with unexpected files | %d |\n", rq, uf
      printf "| stderr differs after removing timings (informational, not under Law 1) | %d |\n", es
      printf "| control cases (one option changed on our side only) | %d |\n| control cases flagged (same exit, at least one output file differs) | %d |\n", nc, cseen
      if (cl) printf "\nControl cases NOT flagged (the comparison is blind):%s\n", cl
      if (diff) printf "\nDiffering cases:%s\n", dl
      if (bad) printf "\nUnexpected upstream exits:%s\n", bl
      if (rq) printf "\nOutput existence wrong:%s\n", rl
      if (uf) printf "\nUnexpected files:%s\n", ul
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
